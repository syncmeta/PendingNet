package pnserver

import (
	"encoding/json"
	"testing"
	"time"
)

func TestProvisionDNSIsEncryptedAndUsedByFreedom(t *testing.T) {
	a, err := BuildProvisionArtifacts(ProvisionOptions{ServerIP: "203.0.113.10", RealitySNI: "example.com"}, nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	var x, h map[string]any
	if err := json.Unmarshal(a.XrayConfig, &x); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(a.Hysteria2Config, &h); err != nil {
		t.Fatal(err)
	}
	dns, ok := x["dns"].(map[string]any)
	if !ok {
		t.Fatal("Xray has no encrypted resolver policy")
	}
	if dns["servers"].([]any)[0] != "https+local://1.1.1.1/dns-query" {
		t.Fatal("unexpected Xray DNS")
	}
	direct := x["outbounds"].([]any)[0].(map[string]any)
	if direct["settings"].(map[string]any)["domainStrategy"] != "ForceIPv4v6" {
		t.Fatal("Freedom may fall back to system DNS")
	}
	resolver, ok := h["resolver"].(map[string]any)
	if !ok || resolver["type"] != "https" {
		t.Fatal("Hysteria has no encrypted resolver policy")
	}
}

func TestBothClientExportsHaveDoHAndAndroidHijacksDNS(t *testing.T) {
	for _, platform := range []string{"android", "windows"} {
		data, err := BuildClientConfig(testRealityProfile(), platform)
		if err != nil {
			t.Fatal(err)
		}
		var root map[string]any
		if err := json.Unmarshal(data, &root); err != nil {
			t.Fatal(err)
		}
		if root["dns"] == nil {
			t.Errorf("%s export has no DoH", platform)
		}
		if platform == "android" && root["route"].(map[string]any)["rules"] == nil {
			t.Error("Android does not hijack DNS")
		}
	}
}

func TestExistingDefaultDNSMigrationPreservesCustomPolicies(t *testing.T) {
	x := map[string]any{"outbounds": []any{map[string]any{"tag": "direct", "protocol": "freedom"}}}
	h := map[string]any{"auth": map[string]any{"type": "password", "password": "fixture"}}
	migrateDefaultServerDNS(x, h)
	if x["dns"] == nil || h["resolver"] == nil {
		t.Fatal("legacy defaults were not migrated")
	}
	before, _ := json.Marshal([]any{x, h})
	migrateDefaultServerDNS(x, h)
	after, _ := json.Marshal([]any{x, h})
	if string(before) != string(after) {
		t.Fatal("migration is not idempotent")
	}
	customX := map[string]any{"dns": map[string]any{"servers": []string{"custom"}}, "outbounds": []any{map[string]any{"tag": "direct", "protocol": "freedom"}}}
	customH := map[string]any{"resolver": map[string]any{"type": "tls"}}
	before, _ = json.Marshal([]any{customX, customH})
	migrateDefaultServerDNS(customX, customH)
	after, _ = json.Marshal([]any{customX, customH})
	if string(before) != string(after) {
		t.Fatal("custom policy was overwritten")
	}
}
