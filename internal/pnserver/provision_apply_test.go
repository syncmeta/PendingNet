package pnserver

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestApplyProvisionArtifactsUsesPrivatePermissions(t *testing.T) {
	root := t.TempDir()
	services := filepath.Join(root, "services")
	artifacts, err := BuildProvisionArtifacts(ProvisionOptions{
		ServerIP: "203.0.113.10", RealitySNI: "www.cloudflare.com", ServicesDir: services,
		XrayBinary: "/usr/local/bin/xray", HysteriaBinary: "/usr/local/bin/hysteria",
	}, bytes.NewReader(bytes.Repeat([]byte{0x24}, 4096)), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	layout := ProvisionLayout{
		ServicesDir:      services,
		XrayUnitPath:     filepath.Join(root, "systemd", "pendingnet-xray.service"),
		HysteriaUnitPath: filepath.Join(root, "systemd", "pendingnet-hysteria.service"),
	}
	if err := ApplyProvisionArtifacts(artifacts, layout); err != nil {
		t.Fatal(err)
	}
	for path, want := range map[string]os.FileMode{
		filepath.Join(services, "xray.json"):     0o600,
		filepath.Join(services, "hysteria.json"): 0o600,
		filepath.Join(services, "hysteria.crt"):  0o644,
		filepath.Join(services, "hysteria.key"):  0o600,
	} {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != want {
			t.Errorf("%s mode %o, want %o", path, info.Mode().Perm(), want)
		}
	}
}
