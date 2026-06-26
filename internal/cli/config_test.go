package cli

import (
	"encoding/json"
	"strings"
	"testing"

	"sbtally/internal/sbconfig"
)

const refFixture = "../sbconfig/testdata/reference_master.json"

func TestImportSummary(t *testing.T) {
	out, err := ImportSummary(refFixture)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "TAG") || !strings.Contains(out, "vless") && !strings.Contains(out, "hysteria2") {
		t.Fatalf("unexpected summary:\n%s", out)
	}
}

func TestGenerateConfigFromImport(t *testing.T) {
	cfg, err := GenerateConfig([]string{"vpsA=" + refFixture}, sbconfig.Options{
		EnableTun: true, MixedPort: 2080, ClashAPIAddr: "127.0.0.1:9090",
		AppRules: []sbconfig.AppRule{{Process: "Telegram", Target: "direct"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	var parsed struct {
		Outbounds []struct {
			Type string `json:"type"`
			Tag  string `json:"tag"`
		} `json:"outbounds"`
	}
	if err := json.Unmarshal(cfg, &parsed); err != nil {
		t.Fatalf("generated config is not valid JSON: %v", err)
	}
	var hasProxy, hasMix bool
	for _, o := range parsed.Outbounds {
		if o.Type == "selector" && o.Tag == "proxy" {
			hasProxy = true
		}
		if o.Type == "urltest" && o.Tag == "vpsA-mix" {
			hasMix = true
		}
	}
	if !hasProxy || !hasMix {
		t.Fatalf("missing proxy selector (%v) or vpsA-mix urltest (%v)", hasProxy, hasMix)
	}
}

func TestGenerateConfigRejectsBadSpec(t *testing.T) {
	if _, err := GenerateConfig([]string{"noequals"}, sbconfig.Options{}); err == nil {
		t.Fatal("expected error for bad spec")
	}
}
