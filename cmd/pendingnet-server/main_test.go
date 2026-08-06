package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInitPairAndStatusCommands(t *testing.T) {
	dir := t.TempDir()
	var out, errOut bytes.Buffer
	if err := run([]string{
		"init", "--state-dir", dir, "--name", "VPS Test", "--endpoint", "https://203.0.113.20:7443",
	}, &out, &errOut); err != nil {
		t.Fatalf("init: %v (%s)", err, errOut.String())
	}
	if !strings.Contains(out.String(), `"name": "VPS Test"`) {
		t.Fatalf("unexpected init output: %s", out.String())
	}

	pairPath := filepath.Join(dir, "exports", "vps-test.pdn")
	out.Reset()
	if err := run([]string{
		"pair", "create", "--state-dir", dir, "--ttl", "5m", "--out", pairPath,
	}, &out, &errOut); err != nil {
		t.Fatalf("pair create: %v (%s)", err, errOut.String())
	}
	info, err := os.Stat(pairPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("pair file permissions %o", info.Mode().Perm())
	}

	out.Reset()
	if err := run([]string{"status", "--state-dir", dir}, &out, &errOut); err != nil {
		t.Fatalf("status: %v (%s)", err, errOut.String())
	}
	if !strings.Contains(out.String(), `"active_pairings": 1`) || !strings.Contains(out.String(), `"devices": 0`) {
		t.Fatalf("unexpected status output: %s", out.String())
	}
}

func TestImportSingbCommand(t *testing.T) {
	dir := t.TempDir()
	var out, errOut bytes.Buffer
	if err := run([]string{
		"init", "--state-dir", dir, "--name", "VPS Test", "--endpoint", "https://203.0.113.20:7443",
	}, &out, &errOut); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(dir, "config.env")
	statePath := filepath.Join(dir, "state.env")
	if err := os.WriteFile(configPath, []byte(strings.Join([]string{
		"SERVER_IP=203.0.113.20", "XRAY_PORT=443", "XRAY_SNI=www.microsoft.com",
		"HY2_PORT=8443", "HY2_OBFS_TYPE=salamander",
	}, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(statePath, []byte(strings.Join([]string{
		"XRAY_UUID=11111111-1111-1111-1111-111111111111", "XRAY_PUBLIC_KEY=public-key",
		"XRAY_SHORT_ID=abcdef12", "XRAY_PRIVATE_KEY=must-not-leak", "HY2_PASSWORD=hy2-secret",
		"HY2_OBFS_PASSWORD=obfs-secret", "HY2_TLS_CERT_PUBKEY_SHA256=sha256:abcdef",
	}, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	out.Reset()
	if err := run([]string{
		"import-singb", "--state-dir", dir, "--config", configPath, "--state", statePath,
	}, &out, &errOut); err != nil {
		t.Fatalf("import-singb: %v (%s)", err, errOut.String())
	}
	if !strings.Contains(out.String(), `"vless-reality"`) || !strings.Contains(out.String(), `"hysteria2"`) {
		t.Fatalf("unexpected import output: %s", out.String())
	}

	out.Reset()
	if err := run([]string{"status", "--state-dir", dir}, &out, &errOut); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), `"protocols"`) || strings.Contains(out.String(), "must-not-leak") {
		t.Fatalf("unexpected status output: %s", out.String())
	}
}

func TestInstallDryRun(t *testing.T) {
	var out, errOut bytes.Buffer
	err := run([]string{
		"install", "--dry-run", "--name", "VPS Test",
		"--endpoint", "https://203.0.113.20:7443",
	}, &out, &errOut)
	if err != nil {
		t.Fatalf("install dry run: %v (%s)", err, errOut.String())
	}
	if !strings.Contains(out.String(), "ExecStart=") || strings.Contains(out.String(), ".sh") {
		t.Fatalf("unexpected unit:\n%s", out.String())
	}
}

func TestProvisionDryRun(t *testing.T) {
	dir := t.TempDir()
	var out, errOut bytes.Buffer
	if err := run([]string{
		"init", "--state-dir", dir, "--name", "VPS Test", "--endpoint", "https://203.0.113.20:7443",
	}, &out, &errOut); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := run([]string{
		"provision", "--dry-run", "--state-dir", dir,
		"--server-ip", "203.0.113.20", "--reality-sni", "www.cloudflare.com",
	}, &out, &errOut); err != nil {
		t.Fatalf("provision dry run: %v (%s)", err, errOut.String())
	}
	if !strings.Contains(out.String(), `"changes_applied": false`) || !strings.Contains(out.String(), `"hysteria2"`) {
		t.Fatalf("unexpected provision plan: %s", out.String())
	}
}
