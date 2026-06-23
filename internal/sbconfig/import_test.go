package sbconfig

import (
	"strings"
	"testing"
)

func TestExtractOutboundsSkipsBuiltins(t *testing.T) {
	cfg := []byte(`{
	  "outbounds": [
	    {"type":"vless","tag":"vpsA-reality","server":"1.2.3.4","uuid":"x"},
	    {"type":"hysteria2","tag":"vpsA-hy2","server":"1.2.3.4"},
	    {"type":"selector","tag":"proxy","outbounds":["vpsA-reality"]},
	    {"type":"direct","tag":"direct"},
	    {"type":"block","tag":"block"}
	  ]}`)
	obs, err := ExtractOutbounds(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if len(obs) != 2 {
		t.Fatalf("got %d outbounds, want 2: %+v", len(obs), obs)
	}
	if obs[0].Tag != "vpsA-reality" || obs[0].Type != "vless" {
		t.Fatalf("got %+v", obs[0])
	}
	if !strings.Contains(string(obs[1].Raw), `"hysteria2"`) {
		t.Fatalf("raw missing type: %s", obs[1].Raw)
	}
}

func TestExtractOutboundsEmpty(t *testing.T) {
	obs, err := ExtractOutbounds([]byte(`{"outbounds":[]}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(obs) != 0 {
		t.Fatalf("want empty, got %+v", obs)
	}
}
