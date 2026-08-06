package pnserver

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestImportSingbCreatesPolicyFreeNodeProfile(t *testing.T) {
	store, _ := testStore(t)
	configPath := filepath.Join(t.TempDir(), "config.env")
	statePath := filepath.Join(t.TempDir(), "state.env")
	config := `
SERVER_IP=203.0.113.10
XRAY_SNI=www.cloudflare.com
XRAY_PORT=443
HY2_PORT=443
`
	state := `
XRAY_UUID=11111111-2222-3333-4444-555555555555
XRAY_PRIVATE_KEY=server-private-must-not-leak
XRAY_PUBLIC_KEY=reality-public
XRAY_SHORT_ID=0123456789abcdef
HY2_PASSWORD=hy2-secret
HY2_OBFS_TYPE=salamander
HY2_OBFS_PASSWORD=obfs-secret
HY2_TLS_CERT_PUBKEY_SHA256=base64-public-key-pin=
`
	if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(statePath, []byte(state), 0o600); err != nil {
		t.Fatal(err)
	}
	profile, err := store.ImportSingb(configPath, statePath)
	if err != nil {
		t.Fatal(err)
	}
	if len(profile.Protocols) != 2 || profile.Protocols[0].VLESSReality == nil || profile.Protocols[1].Hysteria2 == nil {
		t.Fatalf("unexpected profile: %#v", profile)
	}
	data, err := os.ReadFile(store.nodePath())
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"server-private-must-not-leak", "routing", "rule_set", "tun"} {
		if strings.Contains(string(data), forbidden) {
			t.Errorf("node profile leaked forbidden value %q", forbidden)
		}
	}
}

func TestRestrictedEnvRejectsShellSyntax(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bad.env")
	if err := os.WriteFile(path, []byte("SERVER_IP=$(curl attacker)\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readRestrictedEnv(path); err == nil {
		t.Fatal("expected unsafe shell syntax to fail")
	}
}
