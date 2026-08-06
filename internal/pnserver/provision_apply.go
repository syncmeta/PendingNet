package pnserver

import (
	"errors"
	"os"
	"path/filepath"
)

type ProvisionLayout struct {
	ServicesDir      string
	XrayUnitPath     string
	HysteriaUnitPath string
}

func DefaultProvisionLayout(servicesDir string) ProvisionLayout {
	if servicesDir == "" {
		servicesDir = DefaultServicesDir
	}
	return ProvisionLayout{
		ServicesDir:      servicesDir,
		XrayUnitPath:     "/etc/systemd/system/pendingnet-xray.service",
		HysteriaUnitPath: "/etc/systemd/system/pendingnet-hysteria.service",
	}
}

// ApplyProvisionArtifacts atomically installs generated service material. It
// does not start processes or publish the node profile; callers do that only
// after engine validation and systemd health checks succeed.
func ApplyProvisionArtifacts(artifacts ProvisionArtifacts, layout ProvisionLayout) error {
	if !filepath.IsAbs(layout.ServicesDir) || !filepath.IsAbs(layout.XrayUnitPath) || !filepath.IsAbs(layout.HysteriaUnitPath) {
		return errors.New("provision layout paths must be absolute")
	}
	if err := os.MkdirAll(layout.ServicesDir, 0o700); err != nil {
		return err
	}
	files := []struct {
		path string
		data []byte
		mode os.FileMode
	}{
		{filepath.Join(layout.ServicesDir, "xray.json"), artifacts.XrayConfig, 0o600},
		{filepath.Join(layout.ServicesDir, "hysteria.json"), artifacts.Hysteria2Config, 0o600},
		{filepath.Join(layout.ServicesDir, "hysteria.crt"), artifacts.Hysteria2CertPEM, 0o644},
		{filepath.Join(layout.ServicesDir, "hysteria.key"), artifacts.Hysteria2KeyPEM, 0o600},
	}
	for _, file := range files {
		if len(file.data) == 0 {
			return errors.New("provision artifact is empty")
		}
		if err := writeFileAtomic(file.path, file.data, file.mode); err != nil {
			return err
		}
	}
	if err := WriteSystemdUnit(layout.XrayUnitPath, artifacts.XraySystemdUnit); err != nil {
		return err
	}
	return WriteSystemdUnit(layout.HysteriaUnitPath, artifacts.HysteriaSystemdUnit)
}

func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".pendingnet-file-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
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
	return os.Rename(tmpPath, path)
}
