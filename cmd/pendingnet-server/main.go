package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"sbtally/internal/pnserver"
)

const defaultStateDir = "/etc/pendingnet"

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		return errors.New("usage: pendingnet-server <init|install|provision|import-singb|pair create|status|serve> [flags]")
	}
	switch args[0] {
	case "init":
		return runInit(args[1:], stdout, stderr)
	case "install":
		return runInstall(args[1:], stdout, stderr)
	case "provision":
		return runProvision(args[1:], stdout, stderr)
	case "pair":
		if len(args) < 2 || args[1] != "create" {
			return errors.New("usage: pendingnet-server pair create [flags]")
		}
		return runPairCreate(args[2:], stdout, stderr)
	case "import-singb":
		return runImportSingb(args[1:], stdout, stderr)
	case "status":
		return runStatus(args[1:], stdout, stderr)
	case "serve":
		return runServe(args[1:], stdout, stderr)
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func runProvision(args []string, stdout, stderr io.Writer) (runErr error) {
	fs := flag.NewFlagSet("provision", flag.ContinueOnError)
	fs.SetOutput(stderr)
	serverIP := fs.String("server-ip", "", "public VPS IP address")
	realitySNI := fs.String("reality-sni", "www.cloudflare.com", "Reality camouflage hostname")
	xrayPort := fs.Int("xray-port", 443, "Reality TCP port")
	hy2Port := fs.Int("hy2-port", 443, "Hysteria2 UDP port")
	stateDir := fs.String("state-dir", defaultStateDir, "private PendingNet Server state directory")
	servicesDir := fs.String("services-dir", pnserver.DefaultServicesDir, "private proxy service configuration directory")
	xrayBinary := fs.String("xray-binary", pnserver.DefaultXrayBinary, "Xray executable path")
	hy2Binary := fs.String("hysteria-binary", pnserver.DefaultHysteriaBinary, "Hysteria2 executable path")
	skipDownload := fs.Bool("skip-download", false, "use already installed engine binaries")
	replaceExisting := fs.Bool("replace-existing", false, "replace imported xray.service and hysteria-server.service with PendingNet-managed services")
	dryRun := fs.Bool("dry-run", false, "generate and validate in memory without changing the VPS")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *serverIP == "" {
		return errors.New("--server-ip is required")
	}
	store := pnserver.NewStore(*stateDir)
	if _, err := store.Load(); err != nil {
		return fmt.Errorf("load PendingNet Server: %w", err)
	}
	opts := pnserver.ProvisionOptions{
		ServerIP: *serverIP, RealitySNI: *realitySNI, XrayPort: *xrayPort, Hysteria2Port: *hy2Port,
		XrayBinary: *xrayBinary, HysteriaBinary: *hy2Binary, ServicesDir: *servicesDir,
	}
	artifacts, err := pnserver.BuildProvisionArtifacts(opts, nil, time.Now())
	if err != nil {
		return err
	}
	if *dryRun {
		return writeIndentedJSON(stdout, map[string]any{
			"server_ip": *serverIP, "reality_sni": *realitySNI,
			"protocols": []string{"vless-reality", "hysteria2"}, "changes_applied": false,
		})
	}
	if os.Geteuid() != 0 {
		return errors.New("provision must run as root")
	}
	hadExistingNode := false
	if _, err := store.LoadNodeProfile(); err == nil {
		hadExistingNode = true
	} else if !errors.Is(err, pnserver.ErrNodeProfileNotFound) {
		return err
	}
	if hadExistingNode && !*replaceExisting {
		return pnserver.ErrAlreadyProvisioned
	}
	if *replaceExisting && !*skipDownload {
		return errors.New("--replace-existing requires --skip-download so existing verified engine binaries are preserved")
	}
	oldUnits := []string{"xray.service", "hysteria-server.service"}
	rollbackOldUnits := false
	if *replaceExisting {
		for _, unitName := range oldUnits {
			if err := runSystemctl(stdout, stderr, "disable", "--now", unitName); err != nil {
				for _, rollbackUnit := range oldUnits {
					_ = runSystemctl(io.Discard, io.Discard, "enable", "--now", rollbackUnit)
				}
				return fmt.Errorf("stop legacy service %s: %w", unitName, err)
			}
		}
		rollbackOldUnits = true
		defer func() {
			if runErr == nil || !rollbackOldUnits {
				return
			}
			for _, unitName := range oldUnits {
				_ = runSystemctl(io.Discard, io.Discard, "enable", "--now", unitName)
			}
		}()
	}
	if err := checkListenPort("tcp", *xrayPort); err != nil {
		return fmt.Errorf("Reality port: %w", err)
	}
	if err := checkListenPort("udp", *hy2Port); err != nil {
		return fmt.Errorf("Hysteria2 port: %w", err)
	}

	versions := pnserver.InstalledEngineVersions{Xray: "existing", Hysteria2: "existing"}
	if !*skipDownload {
		versions, err = pnserver.InstallLatestProxyEngines(context.Background(), *xrayBinary, *hy2Binary)
		if err != nil {
			return err
		}
	} else {
		for _, path := range []string{*xrayBinary, *hy2Binary} {
			if info, statErr := os.Stat(path); statErr != nil || info.Mode()&0o111 == 0 {
				return fmt.Errorf("engine binary is missing or not executable: %s", path)
			}
		}
	}
	layout := pnserver.DefaultProvisionLayout(*servicesDir)
	if err := pnserver.ApplyProvisionArtifacts(artifacts, layout); err != nil {
		return err
	}
	validate := exec.Command(*xrayBinary, "run", "-test", "-config", filepath.Join(*servicesDir, "xray.json"))
	validate.Stdout, validate.Stderr = stdout, stderr
	if err := validate.Run(); err != nil {
		return fmt.Errorf("validate Xray configuration: %w", err)
	}
	if err := validateHysteriaConfig(*hy2Binary, filepath.Join(*servicesDir, "hysteria.json"), stdout, stderr); err != nil {
		return err
	}

	unitNames := []string{filepath.Base(layout.XrayUnitPath), filepath.Base(layout.HysteriaUnitPath)}
	if err := runSystemctl(stdout, stderr, "daemon-reload"); err != nil {
		return err
	}
	for _, unitName := range unitNames {
		if err := runSystemctl(stdout, stderr, "enable", "--now", unitName); err != nil {
			for _, rollbackUnit := range unitNames {
				_ = runSystemctl(io.Discard, io.Discard, "disable", "--now", rollbackUnit)
			}
			return err
		}
		if err := runSystemctl(stdout, stderr, "is-active", "--quiet", unitName); err != nil {
			for _, rollbackUnit := range unitNames {
				_ = runSystemctl(io.Discard, io.Discard, "disable", "--now", rollbackUnit)
			}
			return fmt.Errorf("service %s did not become active: %w", unitName, err)
		}
	}
	if err := store.SaveNodeProfile(artifacts.NodeProfile); err != nil {
		for _, rollbackUnit := range unitNames {
			_ = runSystemctl(io.Discard, io.Discard, "disable", "--now", rollbackUnit)
		}
		return err
	}
	rollbackOldUnits = false
	return writeIndentedJSON(stdout, map[string]any{
		"server_ip": *serverIP, "protocols": []string{"vless-reality", "hysteria2"},
		"xray_version": versions.Xray, "hysteria2_version": versions.Hysteria2,
		"replaced_existing": *replaceExisting,
	})
}

func validateHysteriaConfig(binary, configPath string, stdout, stderr io.Writer) error {
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, "server", "--config", configPath)
	cmd.Stdout, cmd.Stderr = stdout, stderr
	err := cmd.Run()
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("validate Hysteria2 configuration: %w", err)
	}
	return errors.New("validate Hysteria2 configuration: server exited unexpectedly")
}

func checkListenPort(network string, port int) error {
	address := ":" + strconv.Itoa(port)
	if network == "tcp" {
		listener, err := net.Listen("tcp", address)
		if err != nil {
			return fmt.Errorf("TCP/%d is unavailable: %w", port, err)
		}
		return listener.Close()
	}
	packet, err := net.ListenPacket("udp", address)
	if err != nil {
		return fmt.Errorf("UDP/%d is unavailable: %w", port, err)
	}
	return packet.Close()
}

func runSystemctl(stdout, stderr io.Writer, args ...string) error {
	cmd := exec.Command("systemctl", args...)
	cmd.Stdout, cmd.Stderr = stdout, stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("systemctl %s: %w", strings.Join(args, " "), err)
	}
	return nil
}

func runInstall(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("install", flag.ContinueOnError)
	fs.SetOutput(stderr)
	name := fs.String("name", "", "display name for this VPS")
	endpoint := fs.String("endpoint", "", "public PendingNet control URL")
	stateDir := fs.String("state-dir", defaultStateDir, "private PendingNet Server state directory")
	binaryDest := fs.String("binary-dest", "/usr/local/bin/pendingnet-server", "installed executable path")
	unitPath := fs.String("unit-path", "/etc/systemd/system/pendingnet-server.service", "systemd unit path")
	dryRun := fs.Bool("dry-run", false, "validate and print the unit without changing the system")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *name == "" || *endpoint == "" {
		return errors.New("--name and --endpoint are required")
	}
	unit, err := pnserver.SystemdUnit(*binaryDest, *stateDir)
	if err != nil {
		return err
	}
	if *dryRun {
		_, err := fmt.Fprint(stdout, unit)
		return err
	}
	if os.Geteuid() != 0 {
		return errors.New("install must run as root")
	}
	source, err := os.Executable()
	if err != nil {
		return err
	}
	if err := pnserver.InstallExecutable(source, *binaryDest); err != nil {
		return fmt.Errorf("install executable: %w", err)
	}
	store := pnserver.NewStore(*stateDir)
	if _, err := store.Load(); errors.Is(err, pnserver.ErrNotInitialized) {
		if _, err := store.Initialize(*name, *endpoint); err != nil {
			return fmt.Errorf("initialize server: %w", err)
		}
	} else if err != nil {
		return err
	}
	if err := pnserver.WriteSystemdUnit(*unitPath, unit); err != nil {
		return fmt.Errorf("write systemd unit: %w", err)
	}
	unitName := filepath.Base(*unitPath)
	for _, command := range [][]string{{"daemon-reload"}, {"enable", "--now", unitName}} {
		if err := runSystemctl(stdout, stderr, command...); err != nil {
			return err
		}
	}
	fmt.Fprintln(stdout, "PendingNet Server installed and started")
	return nil
}

func runImportSingb(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("import-singb", flag.ContinueOnError)
	fs.SetOutput(stderr)
	stateDir := fs.String("state-dir", defaultStateDir, "private PendingNet Server state directory")
	configPath := fs.String("config", "/etc/singb/config.env", "existing singb public configuration")
	secretsPath := fs.String("state", "/etc/singb/state.env", "existing singb generated connection state")
	if err := fs.Parse(args); err != nil {
		return err
	}
	profile, err := pnserver.NewStore(*stateDir).ImportSingb(*configPath, *secretsPath)
	if err != nil {
		return err
	}
	protocols := make([]string, 0, len(profile.Protocols))
	for _, protocol := range profile.Protocols {
		protocols = append(protocols, protocol.Type)
	}
	return writeIndentedJSON(stdout, map[string]any{
		"server_id":  profile.ServerID,
		"protocols":  protocols,
		"updated_at": profile.UpdatedAt,
	})
}

func runInit(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("init", flag.ContinueOnError)
	fs.SetOutput(stderr)
	name := fs.String("name", "", "display name for this VPS")
	endpoint := fs.String("endpoint", "", "public PendingNet control URL, e.g. https://203.0.113.10:7443")
	stateDir := fs.String("state-dir", defaultStateDir, "private PendingNet Server state directory")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *name == "" || *endpoint == "" {
		return errors.New("--name and --endpoint are required")
	}
	state, err := pnserver.NewStore(*stateDir).Initialize(*name, *endpoint)
	if err != nil {
		return err
	}
	return writeIndentedJSON(stdout, map[string]any{
		"server_id":          state.ServerID,
		"name":               state.Name,
		"control_endpoint":   state.ControlEndpoint,
		"certificate_sha256": state.CertificateSHA256,
		"state_dir":          *stateDir,
	})
}

func runPairCreate(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("pair create", flag.ContinueOnError)
	fs.SetOutput(stderr)
	stateDir := fs.String("state-dir", defaultStateDir, "private PendingNet Server state directory")
	ttl := fs.Duration("ttl", 10*time.Minute, "one-time pairing file lifetime (max 24h)")
	out := fs.String("out", "", "write the pairing credential to this path (default stdout)")
	format := fs.String("format", "link", "pairing credential format: link (pendingnet:// URL) or json (*.pdn document)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *format != "link" && *format != "json" {
		return fmt.Errorf("unknown --format %q, expected link or json", *format)
	}
	store := pnserver.NewStore(*stateDir)
	pairFile, err := store.CreatePairing(*ttl)
	if err != nil {
		return err
	}
	// 令牌是一次性的：走到这里它已经发出去了，两种形态装的是同一份凭据，
	// 只是包装不同。默认给链接——点一下就唤起导入，粘贴也认。
	var b []byte
	if *format == "link" {
		link, linkErr := pairFile.URL(time.Now())
		if linkErr != nil {
			return linkErr
		}
		b = []byte(link)
	} else if b, err = pairFile.Marshal(time.Now()); err != nil {
		return err
	}
	b = append(b, '\n')
	if *out == "" {
		_, err = stdout.Write(b)
		return err
	}
	if err := os.MkdirAll(filepath.Dir(*out), 0o700); err != nil {
		return err
	}
	if err := os.WriteFile(*out, b, 0o600); err != nil {
		return err
	}
	if err := os.Chmod(*out, 0o600); err != nil {
		return err
	}
	fmt.Fprintln(stdout, *out)
	return nil
}

func runStatus(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	fs.SetOutput(stderr)
	stateDir := fs.String("state-dir", defaultStateDir, "private PendingNet Server state directory")
	if err := fs.Parse(args); err != nil {
		return err
	}
	state, err := pnserver.NewStore(*stateDir).Load()
	if err != nil {
		return err
	}
	now := time.Now()
	activePairings := 0
	for _, grant := range state.Pairings {
		if grant.UsedAt == nil && now.Before(grant.ExpiresAt) {
			activePairings++
		}
	}
	result := map[string]any{
		"server_id":        state.ServerID,
		"name":             state.Name,
		"control_endpoint": state.ControlEndpoint,
		"devices":          len(state.Devices),
		"active_pairings":  activePairings,
	}
	if profile, err := pnserver.NewStore(*stateDir).LoadNodeProfile(); err == nil {
		protocols := make([]string, 0, len(profile.Protocols))
		for _, protocol := range profile.Protocols {
			protocols = append(protocols, protocol.Type)
		}
		result["protocols"] = protocols
	} else if !errors.Is(err, pnserver.ErrNodeProfileNotFound) {
		return err
	}
	return writeIndentedJSON(stdout, result)
}

func runServe(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(stderr)
	stateDir := fs.String("state-dir", defaultStateDir, "private PendingNet Server state directory")
	listen := fs.String("listen", "", "listen address (default endpoint port on all interfaces)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	store := pnserver.NewStore(*stateDir)
	state, err := store.Load()
	if err != nil {
		return err
	}
	addr := *listen
	if addr == "" {
		u, err := url.Parse(state.ControlEndpoint)
		if err != nil {
			return err
		}
		port := u.Port()
		if port == "" {
			port = strconv.Itoa(443)
		}
		addr = ":" + port
	}

	server := &http.Server{
		Addr:              addr,
		Handler:           (&pnserver.API{Store: store}).Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	fmt.Fprintf(stdout, "PendingNet Server %s listening on %s\n", state.ServerID, addr)
	err = server.ListenAndServeTLS(store.CertificatePath(), store.PrivateKeyPath())
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func writeIndentedJSON(w io.Writer, value any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(value)
}
