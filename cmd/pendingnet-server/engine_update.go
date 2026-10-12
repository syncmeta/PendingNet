package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"sbtally/internal/pnserver"
)

func runUpdateEngines(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("update-engines", flag.ContinueOnError)
	fs.SetOutput(stderr)
	state := fs.String("state-dir", defaultStateDir, "existing PendingNet state directory")
	services := fs.String("services-dir", pnserver.DefaultServicesDir, "existing managed engine configurations")
	xray := fs.String("xray-binary", pnserver.DefaultXrayBinary, "managed Xray binary")
	hy2 := fs.String("hysteria-binary", pnserver.DefaultHysteriaBinary, "managed Hysteria binary")
	dry := fs.Bool("dry-run", false, "show this PendingNet release's engine targets without changes")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("unexpected update arguments")
	}
	lock, err := pnserver.ReleaseEngineLock()
	if err != nil {
		return err
	}
	if *dry {
		return writeIndentedJSON(stdout, lock)
	}
	if runtime.GOOS != "linux" || os.Geteuid() != 0 {
		return errors.New("update-engines requires root on Linux")
	}
	// Verify a valid deployed state and snapshot, without rewriting either.
	snapshot, err := pnserver.NewStore(*state).ReadManagedConfig(*services)
	if err != nil {
		return err
	}
	expected := map[string]struct{ binary, config, protocol, port string }{}
	var xr struct {
		Inbounds []struct {
			Port int `json:"port"`
		} `json:"inbounds"`
	}
	var hy struct {
		Listen string `json:"listen"`
	}
	if json.Unmarshal(snapshot.Xray, &xr) != nil || len(xr.Inbounds) != 1 || xr.Inbounds[0].Port < 1 || xr.Inbounds[0].Port > 65535 {
		return errors.New("unsupported managed Xray listener layout")
	}
	if json.Unmarshal(snapshot.Hysteria, &hy) != nil {
		return errors.New("invalid Hysteria listener")
	}
	_, port, err := net.SplitHostPort(hy.Listen)
	if err != nil {
		return errors.New("unsupported Hysteria listener layout")
	}
	n, err := strconv.Atoi(port)
	if err != nil || n < 1 || n > 65535 {
		return errors.New("invalid Hysteria port")
	}
	expected["pendingnet-xray.service"] = struct{ binary, config, protocol, port string }{*xray, filepath.Join(*services, "xray.json"), "tcp", strconv.Itoa(xr.Inbounds[0].Port)}
	expected["pendingnet-hysteria.service"] = struct{ binary, config, protocol, port string }{*hy2, filepath.Join(*services, "hysteria.json"), "udp", port}
	command := func(name string, args ...string) (string, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, name, args...).Output()
		return string(out), err
	}
	active := func(unit string) (bool, error) {
		out, err := command("systemctl", "show", unit, "-p", "ActiveState", "--value")
		if err != nil {
			return false, err
		}
		s := strings.TrimSpace(out)
		if s != "active" && s != "inactive" {
			return false, fmt.Errorf("service %s is not settled (%s)", unit, s)
		}
		return s == "active", nil
	}
	hooks := pnserver.EngineUpdateHooks{
		Managed: func(unit, binary string) error {
			e, ok := expected[unit]
			if !ok || binary != e.binary {
				return errors.New("unsupported managed service")
			}
			out, err := command("systemctl", "show", unit, "-p", "FragmentPath", "--value")
			if err != nil {
				return err
			}
			if strings.TrimSpace(out) != "/etc/systemd/system/"+unit {
				return fmt.Errorf("%s is not a PendingNet-installed service", unit)
			}
			out, err = command("systemctl", "show", unit, "-p", "ExecStart", "--value")
			if err != nil {
				return err
			}
			if !strings.Contains(out, "path="+binary+" ;") || !strings.Contains(out, e.config+" ;") {
				return fmt.Errorf("%s uses a different binary or configuration", unit)
			}
			// Shared executables owned by other services must not be overwritten.
			pidOut, err := command("systemctl", "show", unit, "-p", "MainPID", "--value")
			if err != nil {
				return err
			}
			own := strings.TrimSpace(pidOut)
			paths, _ := filepath.Glob("/proc/[0-9]*/exe")
			for _, path := range paths {
				target, err := os.Readlink(path)
				if err == nil && strings.TrimSuffix(target, " (deleted)") == binary && filepath.Base(filepath.Dir(path)) != own {
					return fmt.Errorf("%s is also used by another process; refusing update", binary)
				}
			}
			return nil
		},
		Active: active,
		Validate: func(a, b string) error {
			for _, item := range []struct{ path, version string }{{a, strings.TrimPrefix(lock.Xray.Version, "v")}, {b, strings.TrimPrefix(lock.Hysteria2.Version, "app/v")}} {
				out, err := command(item.path, "version")
				if err != nil || !strings.Contains(out, item.version) {
					return errors.New("candidate engine version does not match release lock")
				}
			}
			if _, err := command(a, "run", "-test", "-config", filepath.Join(*services, "xray.json")); err != nil {
				return errors.New("candidate Xray rejected existing configuration")
			}
			current, err := pnserver.NewStore(*state).ReadManagedConfig(*services)
			if err != nil {
				return err
			}
			if current.Revision != snapshot.Revision {
				return errors.New("managed configuration changed during engine preparation")
			}
			return nil
		},
		Stop:  func(unit string) error { _, err := command("systemctl", "stop", unit); return err },
		Start: func(unit string) error { _, err := command("systemctl", "start", unit); return err },
		Healthy: func(unit string) error {
			e := expected[unit]
			stable := 0
			lastPID := ""
			for tick := 0; tick < 20; tick++ {
				running, err := active(unit)
				if err != nil || !running {
					return fmt.Errorf("%s did not remain active", unit)
				}
				pidOut, err := command("systemctl", "show", unit, "-p", "MainPID", "--value")
				if err != nil {
					return err
				}
				pid := strings.TrimSpace(pidOut)
				sockets, err := command("ss", "-lntup")
				if err != nil {
					return err
				}
				found := false
				for _, line := range strings.Split(sockets, "\n") {
					fields := strings.Fields(line)
					if len(fields) > 4 && fields[0] == e.protocol && strings.HasSuffix(fields[4], ":"+e.port) && strings.Contains(line, "pid="+pid+",") && pid != "0" {
						found = true
					}
				}
				if found && pid == lastPID {
					stable++
				} else {
					stable = 0
				}
				lastPID = pid
				if stable >= 5 {
					return nil
				}
				time.Sleep(500 * time.Millisecond)
			}
			return fmt.Errorf("%s did not expose a stable process-owned listener", unit)
		},
	}
	if err := pnserver.UpdateReleaseProxyEngines(context.Background(), pnserver.EngineUpdateOptions{StateDir: *state, XrayBinary: *xray, HysteriaBinary: *hy2}, hooks); err != nil {
		return err
	}
	fmt.Fprintf(stdout, "Release engines aligned: Xray %s, Hysteria2 %s; existing configuration and credentials preserved\n", lock.Xray.Version, lock.Hysteria2.Version)
	return nil
}
