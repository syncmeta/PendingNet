package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sbtally/internal/pnserver"
	"strings"
	"time"
)

func serviceOutput(name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, name, args...).Output()
}

func collectUserTraffic(store *pnserver.Store) error {
	if !store.UserTrafficEnabled() {
		return nil
	}
	return store.WithTrafficSamplerLock(func() error { return collectUserTrafficUnlocked(store) })
}

func collectUserTrafficUnlocked(store *pnserver.Store) error {
	state, err := store.Load()
	if err != nil {
		return err
	}
	known := map[string]bool{}
	hyNames := map[string]string{}
	for _, u := range state.Users {
		known[u.ID] = true
		hyNames[pnserver.UserHysteriaName(u.ID)] = u.ID
	}
	accounts, err := store.EnsureUserProxyAccounts()
	if err != nil {
		return err
	}
	errorsFound := []error{}
	for _, engine := range []string{"xray", "hysteria2"} {
		unit := "pendingnet-xray.service"
		if engine == "hysteria2" {
			unit = "pendingnet-hysteria.service"
		}
		active, err := serviceOutput("systemctl", "is-active", unit)
		if err != nil || strings.TrimSpace(string(active)) != "active" {
			continue
		}
		epoch, err := serviceOutput("systemctl", "show", unit, "-p", "InvocationID", "--value")
		if err != nil {
			errorsFound = append(errorsFound, err)
			continue
		}
		users := map[string]pnserver.TrafficCounters{}
		if engine == "xray" {
			data, err := serviceOutput(pnserver.DefaultXrayBinary, "api", "statsquery", "--server="+pnserver.XrayStatsAddress, "--pattern=user>>>", "--reset=false")
			if err != nil {
				errorsFound = append(errorsFound, errors.New("Xray user statistics unavailable"))
				continue
			}
			var value struct {
				Stat []struct {
					Name  string      `json:"name"`
					Value json.Number `json:"value"`
				} `json:"stat"`
			}
			if err = json.Unmarshal(data, &value); err != nil {
				errorsFound = append(errorsFound, errors.New("invalid Xray statistics"))
				continue
			}
			for _, v := range value.Stat {
				parts := strings.Split(v.Name, ">>>")
				if len(parts) != 4 || parts[0] != "user" || !known[parts[1]] || parts[2] != "traffic" {
					continue
				}
				n, err := v.Value.Int64()
				if err != nil || n < 0 {
					errorsFound = append(errorsFound, errors.New("invalid Xray counter"))
					continue
				}
				count := users[parts[1]]
				if parts[3] == "uplink" {
					count.Upload = n
				}
				if parts[3] == "downlink" {
					count.Download = n
				}
				users[parts[1]] = count
			}
		} else {
			req, _ := http.NewRequest(http.MethodGet, "http://"+pnserver.HysteriaStatsAddress+"/traffic", nil)
			req.Header.Set("Authorization", accounts.StatsSecret)
			client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{Proxy: nil}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
			resp, err := client.Do(req)
			if err != nil {
				errorsFound = append(errorsFound, errors.New("Hysteria2 user statistics unavailable"))
				continue
			}
			data, readErr := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
			resp.Body.Close()
			client.CloseIdleConnections()
			var value map[string]struct {
				Tx int64 `json:"tx"`
				Rx int64 `json:"rx"`
			}
			if readErr != nil || resp.StatusCode != 200 || json.Unmarshal(data, &value) != nil {
				errorsFound = append(errorsFound, errors.New("invalid Hysteria2 statistics"))
				continue
			}
			for id, v := range value {
				if userID, ok := hyNames[id]; ok {
					users[userID] = pnserver.TrafficCounters{Upload: v.Tx, Download: v.Rx}
				}
			}
		}
		after, err := serviceOutput("systemctl", "show", unit, "-p", "InvocationID", "--value")
		if err != nil || string(after) != string(epoch) {
			continue
		}
		if err = store.RecordUserTraffic(engine, strings.TrimSpace(string(epoch)), users); err != nil {
			errorsFound = append(errorsFound, err)
		}
	}
	return errors.Join(errorsFound...)
}

func userProxyHooks(store *pnserver.Store) (pnserver.ManagedConfigHooks, error) {
	if runtime.GOOS != "linux" || os.Geteuid() != 0 {
		return pnserver.ManagedConfigHooks{}, errors.New("user proxy service changes require root on Linux")
	}
	units := []string{"pendingnet-xray.service", "pendingnet-hysteria.service"}
	active := map[string]bool{}
	for _, unit := range units {
		path, err := serviceOutput("systemctl", "show", unit, "-p", "FragmentPath", "--value")
		if err != nil || strings.TrimSpace(string(path)) != "/etc/systemd/system/"+unit {
			return pnserver.ManagedConfigHooks{}, errors.New("proxy unit is not installed by PendingNet")
		}
		binary := pnserver.DefaultXrayBinary
		config := "xray.json"
		if unit == units[1] {
			binary = pnserver.DefaultHysteriaBinary
			config = "hysteria.json"
		}
		command, err := serviceOutput("systemctl", "show", unit, "-p", "ExecStart", "--value")
		if err != nil || !strings.Contains(string(command), "path="+binary+" ;") || !strings.Contains(string(command), filepath.Join(store.Dir, "services", config)+" ;") {
			return pnserver.ManagedConfigHooks{}, errors.New("proxy unit uses an unexpected executable or configuration")
		}
	}
	captureActivity := func() error {
		for _, unit := range units {
			status, err := serviceOutput("systemctl", "show", unit, "-p", "ActiveState", "--value")
			if err != nil {
				return err
			}
			value := strings.TrimSpace(string(status))
			if value == "failed" {
				if _, err := os.Stat(filepath.Join(store.Dir, "user-proxy-update.json")); err == nil {
					active[unit] = true
					continue
				}
			}
			if value != "active" && value != "inactive" {
				return errors.New("proxy service is not settled")
			}
			active[unit] = value == "active"
		}
		return nil
	}
	profile, err := store.LoadNodeProfile()
	if err != nil {
		return pnserver.ManagedConfigHooks{}, err
	}
	if _, err := proxyListeners(profile, store.UserTrafficEnabled()); err != nil {
		return pnserver.ManagedConfigHooks{}, err
	}
	return pnserver.ManagedConfigHooks{
		Validate: func(p pnserver.ManagedConfigPaths) error {
			if err := captureActivity(); err != nil {
				return err
			}
			if _, err := serviceOutput(pnserver.DefaultXrayBinary, "run", "-test", "-config", p.Xray); err != nil {
				return errors.New("Xray rejected user configuration")
			}
			data, err := os.ReadFile(p.Hysteria)
			if err != nil {
				return err
			}
			var cfg map[string]any
			if json.Unmarshal(data, &cfg) != nil {
				return errors.New("invalid Hysteria2 user configuration")
			}
			return nil
		},
		Restart: func() error {
			// Use a separate Store: managed config application holds its own mutex.
			// Read after installation (or rollback) so health checks use live ports.
			liveStore := pnserver.NewStore(store.Dir)
			profile, err := liveStore.LoadNodeProfile()
			if err != nil {
				return err
			}
			listeners, err := proxyListeners(profile, liveStore.UserTrafficEnabled())
			if err != nil {
				return err
			}
			if len(active) == 0 {
				if err := captureActivity(); err != nil {
					return err
				}
			}
			if liveStore.UserTrafficEnabled() {
				_ = collectUserTraffic(liveStore)
			}
			for _, unit := range units {
				if active[unit] {
					if _, err := serviceOutput("systemctl", "restart", unit); err != nil {
						return errors.New("cannot restart user proxy service")
					}
				}
			}
			lastPID := map[string]string{}
			stable := 0
			for tick := 0; tick < 20; tick++ {
				sockets, err := serviceOutput("ss", "-lntup")
				if err != nil {
					return errors.New("cannot inspect user proxy listeners")
				}
				ready := true
				for _, unit := range units {
					if !active[unit] {
						continue
					}
					if _, err := serviceOutput("systemctl", "is-active", "--quiet", unit); err != nil {
						return errors.New("user proxy service did not remain active")
					}
					pidOut, err := serviceOutput("systemctl", "show", unit, "-p", "MainPID", "--value")
					pid := strings.TrimSpace(string(pidOut))
					if err != nil || pid == "" || pid == "0" {
						ready = false
						continue
					}
					if lastPID[unit] != pid {
						ready = false
					}
					lastPID[unit] = pid
					for protocol, port := range listeners[unit] {
						if protocol == "stats" {
							protocol = "tcp"
						}
						found := false
						for _, line := range strings.Split(string(sockets), "\n") {
							f := strings.Fields(line)
							if len(f) > 4 && f[0] == protocol && strings.HasSuffix(f[4], ":"+port) && strings.Contains(line, "pid="+pid+",") {
								found = true
								break
							}
						}
						if !found {
							ready = false
						}
					}
				}
				if ready {
					stable++
				} else {
					stable = 0
				}
				if stable >= 5 {
					return nil
				}
				time.Sleep(500 * time.Millisecond)
			}
			return errors.New("user proxy did not expose stable process-owned listeners")
		},
	}, nil
}

// Called on every restart so both new and restored ports are checked.
func proxyListeners(profile pnserver.NodeProfile, stats bool) (map[string]map[string]string, error) {
	listeners := map[string]map[string]string{}
	for _, p := range profile.Protocols {
		if p.VLESSReality != nil {
			listeners[serviceUnits["reality"]] = map[string]string{"tcp": fmt.Sprint(p.VLESSReality.ServerPort)}
			if stats {
				listeners[serviceUnits["reality"]]["stats"] = "17446"
			}
		}
		if p.Hysteria2 != nil {
			listeners[serviceUnits["hysteria"]] = map[string]string{"udp": fmt.Sprint(p.Hysteria2.ServerPort)}
			if stats {
				listeners[serviceUnits["hysteria"]]["stats"] = "17445"
			}
		}
	}
	if len(listeners) != 2 {
		return nil, errors.New("both managed protocols are required")
	}
	return listeners, nil
}

func syncUserServices(store *pnserver.Store) error {
	hooks, err := userProxyHooks(store)
	if err != nil {
		return err
	}
	return store.SyncUserProxyServices(filepath.Join(store.Dir, "services"), hooks)
}

func runSyncUsers(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("sync-users", flag.ContinueOnError)
	fs.SetOutput(stderr)
	dir := fs.String("state-dir", defaultStateDir, "private server state directory")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("unexpected sync-users arguments")
	}
	if err := syncUserServices(pnserver.NewStore(*dir)); err != nil {
		return err
	}
	fmt.Fprintln(stdout, "用户代理凭据和流量统计已启用；旧共享节点凭据已移除。")
	return nil
}

func runUserTraffic(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("traffic", flag.ContinueOnError)
	fs.SetOutput(stderr)
	dir := fs.String("state-dir", defaultStateDir, "private server state directory")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("unexpected traffic arguments")
	}
	store := pnserver.NewStore(*dir)
	if !store.UserTrafficEnabled() {
		return errors.New("user traffic is not enabled; run pendingnet-server sync-users")
	}
	if err := collectUserTraffic(store); err != nil {
		fmt.Fprintln(stderr, err)
	}
	values, err := store.UserTraffic()
	if err != nil {
		return err
	}
	return writeIndentedJSON(stdout, values)
}
