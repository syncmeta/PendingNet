package sbconfig

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestGenerateNamespacesCollidingTags(t *testing.T) {
	ref, err := os.ReadFile("testdata/reference_master.json")
	if err != nil {
		t.Fatal(err)
	}
	obs, err := ExtractOutbounds(ref)
	if err != nil {
		t.Fatal(err)
	}
	// Same outbounds under two VPS — tags would collide without namespacing.
	cfg, err := Generate([]VPS{
		{Name: "n1", Outbounds: obs},
		{Name: "n2", Outbounds: obs},
	}, Options{EnableTun: true, ClashAPIAddr: "127.0.0.1:9090"})
	if err != nil {
		t.Fatal(err)
	}
	var parsed struct {
		Outbounds []struct {
			Tag string `json:"tag"`
		} `json:"outbounds"`
	}
	if err := json.Unmarshal(cfg, &parsed); err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, o := range parsed.Outbounds {
		if seen[o.Tag] {
			t.Fatalf("duplicate outbound tag %q", o.Tag)
		}
		seen[o.Tag] = true
	}
	if p, err := exec.LookPath("sing-box"); err == nil {
		f := filepath.Join(t.TempDir(), "g.json")
		if err := os.WriteFile(f, cfg, 0o644); err != nil {
			t.Fatal(err)
		}
		if out, err := exec.Command(p, "check", "-c", f).CombinedOutput(); err != nil {
			t.Fatalf("sing-box check failed: %v\n%s", err, out)
		}
	}
}

func TestGenerateStructureAndSingBoxCheck(t *testing.T) {
	ref, err := os.ReadFile("testdata/reference_master.json")
	if err != nil {
		t.Fatal(err)
	}
	obs, err := ExtractOutbounds(ref)
	if err != nil {
		t.Fatal(err)
	}
	if len(obs) != 2 {
		t.Fatalf("expected 2 imported outbounds (reality+hy2), got %d", len(obs))
	}

	cfg, err := Generate([]VPS{{Name: "vpsA", Outbounds: obs}}, Options{
		EnableTun: true, MixedPort: 2080, TunStack: "gvisor", ClashAPIAddr: "127.0.0.1:9090",
		AppRules: []AppRule{
			{Process: "Telegram", Target: "direct"},
			{Process: "BitTorrent", Target: "block"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	var parsed struct {
		Outbounds []map[string]any `json:"outbounds"`
		Route     struct {
			Rules []map[string]any `json:"rules"`
		} `json:"route"`
	}
	if err := json.Unmarshal(cfg, &parsed); err != nil {
		t.Fatal(err)
	}
	hasTag := func(tag, typ string) bool {
		for _, o := range parsed.Outbounds {
			if o["tag"] == tag && o["type"] == typ {
				return true
			}
		}
		return false
	}
	if !hasTag("proxy", "selector") {
		t.Error("missing top proxy selector")
	}
	if !hasTag("vpsA", "selector") {
		t.Error("missing vpsA selector")
	}
	if !hasTag("vpsA-mix", "urltest") {
		t.Error("missing vpsA-mix urltest")
	}
	if !hasTag("vpsA-reality", "vless") {
		t.Error("imported reality outbound not re-emitted verbatim")
	}

	foundApp := false
	for _, r := range parsed.Route.Rules {
		if pn, ok := r["process_name"].([]any); ok && len(pn) == 1 && pn[0] == "Telegram" {
			foundApp = true
		}
	}
	if !foundApp {
		t.Error("Telegram per-app rule missing")
	}

	// The real validation: the generated config must pass `sing-box check`.
	path, err := exec.LookPath("sing-box")
	if err != nil {
		t.Skip("sing-box not installed; skipping check")
	}
	f := filepath.Join(t.TempDir(), "gen.json")
	if err := os.WriteFile(f, cfg, 0o644); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command(path, "check", "-c", f).CombinedOutput(); err != nil {
		t.Fatalf("sing-box check failed on generated config: %v\n%s", err, out)
	}
}
