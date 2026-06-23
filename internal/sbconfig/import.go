// Package sbconfig imports and (in Phase 3c) generates sing-box configs.
package sbconfig

import "encoding/json"

// Outbound is one proxy outbound lifted from an existing config.
type Outbound struct {
	Tag  string
	Type string
	Raw  json.RawMessage // the original outbound object, re-emittable verbatim
}

var builtinOutbound = map[string]bool{
	"direct": true, "block": true, "dns": true, "selector": true, "urltest": true,
}

// ExtractOutbounds returns the server (non-builtin) outbounds from a sing-box config.
func ExtractOutbounds(configJSON []byte) ([]Outbound, error) {
	var cfg struct {
		Outbounds []json.RawMessage `json:"outbounds"`
	}
	if err := json.Unmarshal(configJSON, &cfg); err != nil {
		return nil, err
	}
	out := []Outbound{}
	for _, raw := range cfg.Outbounds {
		var head struct {
			Tag  string `json:"tag"`
			Type string `json:"type"`
		}
		if err := json.Unmarshal(raw, &head); err != nil {
			return nil, err
		}
		if builtinOutbound[head.Type] {
			continue
		}
		out = append(out, Outbound{Tag: head.Tag, Type: head.Type, Raw: raw})
	}
	return out, nil
}
