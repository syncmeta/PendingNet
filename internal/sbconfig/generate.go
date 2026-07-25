package sbconfig

import (
	"encoding/json"
	"sort"
	"strings"
)

// VPS is a named group of imported proxy outbounds (e.g. its reality + hy2).
type VPS struct {
	Name      string
	Outbounds []Outbound
}

// AppRule routes a process to a target outbound tag, or blocks it.
type AppRule struct {
	Process string // process_name to match
	Target  string // an outbound/selector tag, or "block"
}

// Options tunes the generated master config.
type Options struct {
	ClashAPIAddr   string // default "127.0.0.1:9090"
	ClashSecret    string
	MixedPort      int    // default 2080
	TunStack       string // default "gvisor"
	EnableTun      bool
	GeositeBaseURL string // default official sing-geosite rule-set
	GeoipBaseURL   string // default official sing-geoip rule-set
	LogLevel       string // default "warn"
	AppRules       []AppRule
	RuleSetDir     string // non-empty: emit local rule-sets from this dir (offline-safe startup)
	DefaultMode    string // clash_api default_mode, default "Whitelist"
}

func str(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

// nsTag namespaces an imported outbound tag under its VPS so tags stay unique
// across VPS (real configs often reuse generic tags like "reality-tcp"/"hy2").
// Already-namespaced tags are left alone.
func nsTag(vpsName, tag string) string {
	if strings.HasPrefix(tag, vpsName+"-") {
		return tag
	}
	return vpsName + "-" + tag
}

// retagOutbound re-emits an imported outbound with a new tag, preserving every
// other field (server, keys, …) verbatim.
func retagOutbound(raw json.RawMessage, tag string) any {
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return raw
	}
	m["tag"] = tag
	return m
}

// Generate builds a sing-box master config from the VPS outbounds and options.
// Day-to-day switching (VPS / protocol / mode) happens at runtime via the Clash
// API against the selectors and clash_mode rules this emits.
func Generate(vpsList []VPS, opts Options) ([]byte, error) {
	outbounds := []any{}
	vpsSelectors := []string{}

	for _, v := range vpsList {
		memberTags := []string{}
		for _, ob := range v.Outbounds {
			tag := nsTag(v.Name, ob.Tag)
			outbounds = append(outbounds, retagOutbound(ob.Raw, tag)) // re-emit, unique tag
			memberTags = append(memberTags, tag)
		}
		// mix = urltest auto-select over this VPS's protocols (reality + hy2).
		mixTag := v.Name + "-mix"
		outbounds = append(outbounds, map[string]any{
			"type": "urltest", "tag": mixTag, "outbounds": memberTags,
		})
		// per-VPS selector: pick a specific protocol or mix.
		outbounds = append(outbounds, map[string]any{
			"type": "selector", "tag": v.Name, "outbounds": append(append([]string{}, memberTags...), mixTag),
		})
		vpsSelectors = append(vpsSelectors, v.Name)
	}

	// top selector picks the VPS; plus a direct outbound.
	outbounds = append(outbounds,
		map[string]any{"type": "selector", "tag": "proxy", "outbounds": vpsSelectors},
		map[string]any{"type": "direct", "tag": "direct"},
	)

	rules := []any{
		map[string]any{"action": "sniff"},
		// Resolve destinations to IPv4 before routing so the IPv4-only TUN
		// handles sites with IPv6 (browsers otherwise hang on AAAA). CN names
		// via the local resolver, everything else via the proxy resolver.
		map[string]any{"rule_set": "geosite-cn", "action": "resolve", "server": "dns-local", "strategy": "prefer_ipv4"},
		map[string]any{"action": "resolve", "strategy": "prefer_ipv4"},
		map[string]any{"protocol": "dns", "action": "hijack-dns"},
	}
	for _, ar := range opts.AppRules {
		r := map[string]any{"process_name": []string{ar.Process}}
		if ar.Target == "block" {
			r["action"] = "reject"
		} else {
			r["outbound"] = ar.Target
		}
		rules = append(rules, r)
	}
	rules = append(rules,
		map[string]any{"rule_set": "geosite-ads", "action": "reject"},
		map[string]any{"ip_is_private": true, "outbound": "direct"},
		// Global: everything else → proxy.
		map[string]any{"clash_mode": "Global", "outbound": "proxy"},
		// Blacklist: only GFW-listed names → proxy, rest direct.
		map[string]any{"clash_mode": "Blacklist", "rule_set": "geosite-gfw", "outbound": "proxy"},
		map[string]any{"clash_mode": "Blacklist", "outbound": "direct"},
		// Whitelist (default fall-through): CN direct, known-foreign proxy, final proxy.
		map[string]any{"clash_mode": "Whitelist", "rule_set": []string{"geoip-cn", "geosite-cn"}, "outbound": "direct"},
		map[string]any{"clash_mode": "Whitelist", "rule_set": "geosite-noncn", "outbound": "proxy"},
	)

	files := map[string]string{
		"geosite-cn":     "geosite-cn.srs",
		"geoip-cn":       "geoip-cn.srs",
		"geosite-noncn":  "geosite-geolocation-noncn.srs",
		"geosite-ads":    "geosite-category-ads-all.srs",
		"geosite-gfw":    "geosite-gfw.srs",
	}
	ruleSet := []any{}
	if opts.RuleSetDir != "" {
		// local rule-sets: deterministic order
		tags := make([]string, 0, len(files))
		for tag := range files {
			tags = append(tags, tag)
		}
		sort.Strings(tags)
		for _, tag := range tags {
			ruleSet = append(ruleSet, map[string]any{"type": "local", "tag": tag,
				"format": "binary", "path": opts.RuleSetDir + "/" + files[tag]})
		}
	} else {
		// remote rule-sets
		geosite := str(opts.GeositeBaseURL, "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set")
		geoip := str(opts.GeoipBaseURL, "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set")
		remote := func(tag, base, file string) map[string]any {
			return map[string]any{"type": "remote", "tag": tag, "format": "binary",
				"url": base + "/" + file, "download_detour": "proxy"}
		}
		ruleSet = append(ruleSet,
			remote("geosite-cn", geosite, "geosite-cn.srs"),
			remote("geoip-cn", geoip, "geoip-cn.srs"),
			remote("geosite-noncn", geosite, "geosite-geolocation-!cn.srs"),
			remote("geosite-ads", geosite, "geosite-category-ads-all.srs"),
			map[string]any{"type": "remote", "tag": "geosite-gfw", "format": "binary",
				"url": "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/gfw.srs", "download_detour": "proxy"},
		)
	}

	inbounds := []any{}
	if opts.EnableTun {
		// Settings matched to a known-good macOS SFM TUN config: system stack,
		// IPv4-only address, mtu 1500, and NO strict_route (strict_route breaks
		// connectivity on macOS).
		inbounds = append(inbounds, map[string]any{
			"type": "tun", "tag": "tun-in",
			"address":    []string{"172.19.0.1/30"},
			"mtu":        1500,
			"auto_route": true,
			"stack":      str(opts.TunStack, "system"),
		})
	}
	mixedPort := opts.MixedPort
	if mixedPort == 0 {
		mixedPort = 2080
	}
	inbounds = append(inbounds, map[string]any{
		"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": mixedPort,
	})

	clashAPI := map[string]any{"external_controller": str(opts.ClashAPIAddr, "127.0.0.1:9090")}
	if opts.ClashSecret != "" {
		clashAPI["secret"] = opts.ClashSecret
	}
	clashAPI["default_mode"] = str(opts.DefaultMode, "Whitelist")

	cfg := map[string]any{
		"log": map[string]any{"level": str(opts.LogLevel, "warn")},
		"dns": map[string]any{
			"servers": []any{
				map[string]any{"type": "https", "tag": "dns-proxy", "server": "1.1.1.1", "path": "/dns-query", "detour": "proxy"},
				map[string]any{"type": "local", "tag": "dns-local"},
			},
			"rules":    []any{map[string]any{"rule_set": "geosite-cn", "server": "dns-local"}},
			"final":    "dns-proxy",
			"strategy": "prefer_ipv4",
		},
		"inbounds":  inbounds,
		"outbounds": outbounds,
		"route": map[string]any{
			"auto_detect_interface":   true,
			"find_process":            true,
			"default_domain_resolver": map[string]any{"server": "dns-proxy", "strategy": "prefer_ipv4"},
			"final":                   "proxy",
			"rules":                   rules,
			"rule_set":                ruleSet,
		},
		"experimental": map[string]any{
			"clash_api":  clashAPI,
			"cache_file": map[string]any{"enabled": true},
		},
	}
	return json.MarshalIndent(cfg, "", "  ")
}
