package pnserver

import (
	"bytes"
	"context"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestBuildProvisionArtifactsCreatesMatchingPolicyFreeServices(t *testing.T) {
	now := time.Date(2026, 7, 31, 12, 0, 0, 0, time.UTC)
	artifacts, err := BuildProvisionArtifacts(ProvisionOptions{
		ServerIP: "203.0.113.10", RealitySNI: "www.cloudflare.com",
	}, bytes.NewReader(bytes.Repeat([]byte{0x42}, 4096)), now)
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts.NodeProfile.Protocols) != 2 {
		t.Fatalf("protocols: %#v", artifacts.NodeProfile)
	}
	reality := artifacts.NodeProfile.Protocols[0].VLESSReality
	if reality == nil || reality.ServerPort != 443 || reality.PublicKey == "" || reality.UUID == "" {
		t.Fatalf("bad Reality node: %#v", reality)
	}
	hy2 := artifacts.NodeProfile.Protocols[1].Hysteria2
	if hy2 == nil || hy2.ServerPort != 443 || hy2.CertificatePublicKeySHA256 == "" {
		t.Fatalf("bad Hysteria2 node: %#v", hy2)
	}

	var xray map[string]any
	if err := json.Unmarshal(artifacts.XrayConfig, &xray); err != nil {
		t.Fatal(err)
	}
	text := string(artifacts.XrayConfig)
	if !strings.Contains(text, `"privateKey"`) || strings.Contains(text, reality.PublicKey) {
		t.Fatal("Xray server config must contain only the Reality private key")
	}
	for _, forbidden := range []string{"route_set", `"tun"`, `"clash_api"`} {
		if strings.Contains(text, forbidden) {
			t.Errorf("server config leaked client policy %q", forbidden)
		}
	}

	block, _ := pem.Decode(artifacts.Hysteria2CertPEM)
	if block == nil {
		t.Fatal("invalid Hysteria certificate PEM")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	if len(cert.IPAddresses) != 1 || cert.IPAddresses[0].String() != "203.0.113.10" {
		t.Fatalf("certificate IP SAN: %v", cert.IPAddresses)
	}
	if !strings.Contains(artifacts.XraySystemdUnit, "CAP_NET_BIND_SERVICE") ||
		!strings.Contains(artifacts.HysteriaSystemdUnit, "ProtectSystem=strict") {
		t.Fatal("data-plane units are not hardened")
	}
}

func TestBuildProvisionArtifactsRejectsUnsafeInput(t *testing.T) {
	_, err := BuildProvisionArtifacts(ProvisionOptions{
		ServerIP: "not-an-ip", RealitySNI: "bad.example\nExecStart=evil",
	}, nil, time.Now())
	if err == nil {
		t.Fatal("expected invalid provision options")
	}
}

func TestGeneratedXrayConfigWithInstalledValidator(t *testing.T) {
	xray := os.Getenv("PENDINGNET_XRAY_BIN")
	if xray == "" {
		t.Skip("PENDINGNET_XRAY_BIN is not set")
	}
	artifacts, err := BuildProvisionArtifacts(ProvisionOptions{
		ServerIP: "203.0.113.10", RealitySNI: "www.cloudflare.com",
	}, nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(t.TempDir(), "xray.json")
	if err := os.WriteFile(configPath, artifacts.XrayConfig, 0o600); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command(xray, "run", "-test", "-config", configPath).CombinedOutput(); err != nil {
		t.Fatalf("Xray rejected generated config: %v\n%s", err, output)
	}
}

func TestGeneratedHysteriaConfigStartsWithInstalledValidator(t *testing.T) {
	hy2 := os.Getenv("PENDINGNET_HYSTERIA_BIN")
	if hy2 == "" {
		t.Skip("PENDINGNET_HYSTERIA_BIN is not set")
	}
	servicesDir := t.TempDir()
	artifacts, err := BuildProvisionArtifacts(ProvisionOptions{
		ServerIP: "203.0.113.10", RealitySNI: "www.cloudflare.com",
		XrayPort: 18442, Hysteria2Port: 18443, ServicesDir: servicesDir,
	}, nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(servicesDir, "hysteria.json"), artifacts.Hysteria2Config, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(servicesDir, "hysteria.crt"), artifacts.Hysteria2CertPEM, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(servicesDir, "hysteria.key"), artifacts.Hysteria2KeyPEM, 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()
	output, runErr := exec.CommandContext(ctx, hy2, "server", "--config", filepath.Join(servicesDir, "hysteria.json")).CombinedOutput()
	if ctx.Err() != context.DeadlineExceeded {
		t.Fatalf("Hysteria exited before validation window: %v\n%s", runErr, output)
	}
}
