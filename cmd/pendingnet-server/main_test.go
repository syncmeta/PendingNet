package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"sbtally/internal/pairing"
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

	// 不带 --format 就是链接：默认那条路要有测试盯着，改默认值不该是静悄悄的。
	out.Reset()
	if err := run([]string{
		"pair", "create", "--state-dir", dir, "--ttl", "5m",
	}, &out, &errOut); err != nil {
		t.Fatalf("pair create: %v (%s)", err, errOut.String())
	}
	link := strings.TrimSpace(out.String())
	if _, err := pairing.ParseURL(link, time.Now()); err != nil {
		t.Fatalf("default output is not a pairing link (%q): %v", link, err)
	}

	pairPath := filepath.Join(dir, "exports", "vps-test.pdn")
	out.Reset()
	if err := run([]string{
		"pair", "create", "--state-dir", dir, "--ttl", "5m", "--format", "json", "--out", pairPath,
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
	written, err := os.ReadFile(pairPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pairing.Parse(bytes.TrimSpace(written), time.Now()); err != nil {
		t.Fatalf("--format json did not write a pairing document: %v", err)
	}

	// --out 跟着 format 走：链接进文件，而不是文件里躺着一份 JSON。
	linkPath := filepath.Join(dir, "exports", "vps-test.txt")
	out.Reset()
	if err := run([]string{
		"pair", "create", "--state-dir", dir, "--ttl", "5m", "--out", linkPath,
	}, &out, &errOut); err != nil {
		t.Fatalf("pair create: %v (%s)", err, errOut.String())
	}
	writtenLink, err := os.ReadFile(linkPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pairing.ParseURL(string(writtenLink), time.Now()); err != nil {
		t.Fatalf("--out did not write a pairing link: %v", err)
	}

	out.Reset()
	if err := run([]string{
		"pair", "create", "--state-dir", dir, "--format", "qr",
	}, &out, &errOut); err == nil {
		t.Fatal("expected an unknown --format to be rejected")
	}

	out.Reset()
	if err := run([]string{"status", "--state-dir", dir}, &out, &errOut); err != nil {
		t.Fatalf("status: %v (%s)", err, errOut.String())
	}
	if !strings.Contains(out.String(), `"active_pairings": 3`) || !strings.Contains(out.String(), `"devices": 0`) {
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

// 一键脚本的 --force-provision 走的是这条：--force 允许覆盖 PendingNet 自己写的
// node profile，--replace-existing 是接管 singb 那条，两个混用只会让人误以为
// 「重装一次」还能保住旧客户端。
func TestProvisionForceAndReplaceExistingAreMutuallyExclusive(t *testing.T) {
	var out, errOut bytes.Buffer
	err := run([]string{
		"provision", "--server-ip", "203.0.113.20",
		"--force", "--replace-existing", "--skip-download",
	}, &out, &errOut)
	if err == nil {
		t.Fatal("expected --force with --replace-existing to be rejected")
	}
	if !strings.Contains(err.Error(), "--force and --replace-existing") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestProvisionForceIsAcceptedByDryRun(t *testing.T) {
	dir := t.TempDir()
	var out, errOut bytes.Buffer
	if err := run([]string{
		"init", "--state-dir", dir, "--name", "VPS Test", "--endpoint", "https://203.0.113.20:7443",
	}, &out, &errOut); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := run([]string{
		"provision", "--dry-run", "--force", "--skip-download",
		"--state-dir", dir, "--server-ip", "203.0.113.20",
	}, &out, &errOut); err != nil {
		t.Fatalf("provision --force dry run: %v (%s)", err, errOut.String())
	}
	if !strings.Contains(out.String(), `"changes_applied": false`) {
		t.Fatalf("unexpected provision plan: %s", out.String())
	}
}

func TestVersionCommandReportsFeatures(t *testing.T) {
	var out, errOut bytes.Buffer
	if err := run([]string{"version"}, &out, &errOut); err != nil {
		t.Fatalf("version: %v (%s)", err, errOut.String())
	}
	got := out.String()
	// 版本串没注入时必须老实报 dev，不许编一个数字出来。
	if !strings.HasPrefix(got, "pendingnet-server dev\n") {
		t.Fatalf("uninjected build should report dev, got %q", got)
	}
	// deploy/vps-install.sh 靠这一行判断已装的服务端会不会吐链接。
	if !strings.Contains(got, "features  "+featurePairingLink) {
		t.Fatalf("version output must advertise %s: %q", featurePairingLink, got)
	}
}
