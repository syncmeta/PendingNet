package sbconfig

// ClashDNSPolicy keeps DNS selection aligned with the traffic mode. Upstream
// addresses are literals, so establishing DoH needs no plaintext bootstrap.
func ClashDNSPolicy(proxy string) map[string]any {
	return map[string]any{
		"servers": []any{
			map[string]any{"type": "https", "tag": "dns-proxy", "server": "1.1.1.1", "path": "/dns-query", "detour": proxy, "tls": map[string]any{"enabled": true, "server_name": "cloudflare-dns.com"}},
			map[string]any{"type": "https", "tag": "dns-direct", "server": "223.5.5.5", "path": "/dns-query", "tls": map[string]any{"enabled": true, "server_name": "dns.alidns.com"}},
		},
		"rules": []any{
			map[string]any{"clash_mode": "Global", "server": "dns-proxy"},
			map[string]any{"clash_mode": "Direct", "server": "dns-direct"},
			map[string]any{"clash_mode": "Blacklist", "rule_set": []string{"geosite-gfw"}, "server": "dns-proxy"},
			map[string]any{"clash_mode": "Blacklist", "server": "dns-direct"},
			map[string]any{"clash_mode": "Whitelist", "rule_set": []string{"geosite-cn"}, "server": "dns-direct"},
		},
		"final": "dns-proxy", "strategy": "prefer_ipv4", "independent_cache": true,
	}
}

func clashResolveRules() []any {
	direct := []any{
		map[string]any{"clash_mode": "Direct"},
		map[string]any{"type": "logical", "mode": "and", "rules": []any{
			map[string]any{"clash_mode": "Blacklist"}, map[string]any{"rule_set": []string{"geosite-gfw"}, "invert": true},
		}},
		map[string]any{"clash_mode": "Whitelist", "rule_set": []string{"geosite-cn"}},
	}
	// Resolve actions continue evaluating rules. Complementary predicates
	// ensure a name is not resolved again through the other upstream.
	return []any{
		map[string]any{"type": "logical", "mode": "or", "rules": direct, "invert": false, "action": "resolve", "server": "dns-direct", "strategy": "prefer_ipv4"},
		map[string]any{"type": "logical", "mode": "or", "rules": direct, "invert": true, "action": "resolve", "server": "dns-proxy", "strategy": "prefer_ipv4"},
	}
}
