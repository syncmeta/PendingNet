package pnserver

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// SystemdUnit renders the service definition installed by pendingnet-server.
// Keeping this in Go makes the server package its own installer instead of
// requiring a separately versioned shell script.
func SystemdUnit(binaryPath, stateDir string) (string, error) {
	if !filepath.IsAbs(binaryPath) || !filepath.IsAbs(stateDir) {
		return "", errors.New("systemd binary and state paths must be absolute")
	}
	if strings.ContainsAny(binaryPath+stateDir, "\n\r") {
		return "", errors.New("systemd paths must not contain newlines")
	}
	return fmt.Sprintf(`[Unit]
Description=PendingNet Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%s serve --state-dir %s
Restart=on-failure
RestartSec=3
User=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=%s

[Install]
WantedBy=multi-user.target
`, systemdQuote(binaryPath), systemdQuote(stateDir), systemdQuote(stateDir)), nil
}

func systemdQuote(value string) string {
	return `"` + strings.ReplaceAll(value, `"`, `\"`) + `"`
}

// InstallExecutable atomically copies the currently running executable to its
// stable service path. Existing installations are replaced only at rename.
func InstallExecutable(source, destination string) error {
	if !filepath.IsAbs(source) || !filepath.IsAbs(destination) {
		return errors.New("executable paths must be absolute")
	}
	if filepath.Clean(source) == filepath.Clean(destination) {
		return os.Chmod(destination, 0o755)
	}
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(destination), ".pendingnet-server-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if err := tmp.Chmod(0o755); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.ReadFrom(in); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpPath, destination)
}

func WriteSystemdUnit(path, content string) error {
	if !filepath.IsAbs(path) {
		return errors.New("systemd unit path must be absolute")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".pendingnet-unit-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.WriteString(content); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}
