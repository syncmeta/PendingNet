package pnserver

func xrayDNSPolicy() map[string]any {
	return map[string]any{"servers": []string{"https+local://1.1.1.1/dns-query"}, "queryStrategy": "UseIP"}
}

func hysteriaDNSPolicy() map[string]any {
	return map[string]any{"type": "https", "https": map[string]any{
		"addr": "1.1.1.1:443", "sni": "cloudflare-dns.com", "timeout": "10s", "insecure": false,
	}}
}

// Upgrade only the bare defaults emitted by older PendingNet versions during
// the existing validate/apply/rollback transaction. Custom DNS and outbound
// settings are preserved. Force prevents a system-DNS fallback on DoH failure;
// IPv4v6 preserves access to IPv6-only destinations.
func migrateDefaultServerDNS(xray, hysteria map[string]any) {
	if _, exists := xray["dns"]; !exists {
		if outbounds, ok := xray["outbounds"].([]any); ok {
			for _, raw := range outbounds {
				outbound, ok := raw.(map[string]any)
				if !ok || len(outbound) != 2 || outbound["tag"] != "direct" || outbound["protocol"] != "freedom" {
					continue
				}
				xray["dns"] = xrayDNSPolicy()
				outbound["settings"] = map[string]any{"domainStrategy": "ForceIPv4v6"}
			}
		}
	}
	if _, exists := hysteria["resolver"]; !exists {
		hysteria["resolver"] = hysteriaDNSPolicy()
	}
}
