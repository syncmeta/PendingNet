package pnserver

import (
	"encoding/json"
	"net/url"
	"strings"
	"testing"
)

func TestRealityLinkMatchesExportedOutbound(t *testing.T) {
	profile := testRealityProfile()
	links, err := BuildNodeLinks(profile, "test")
	if err != nil {
		t.Fatal(err)
	}
	uri, err := url.Parse(links[0].URL)
	if err != nil {
		t.Fatal(err)
	}
	data, err := BuildClientConfig(profile, "windows")
	if err != nil {
		t.Fatal(err)
	}
	var root map[string]any
	if err := json.Unmarshal(data, &root); err != nil {
		t.Fatal(err)
	}
	outbound := root["outbounds"].([]any)[0].(map[string]any)
	tls := outbound["tls"].(map[string]any)
	reality := tls["reality"].(map[string]any)
	for query, expected := range map[string]any{
		"flow": outbound["flow"], "sni": tls["server_name"],
		"pbk": reality["public_key"], "sid": reality["short_id"],
		"fp": tls["utls"].(map[string]any)["fingerprint"], "type": "tcp", "security": "reality",
	} {
		if uri.Query().Get(query) != expected {
			t.Errorf("link differs from runtime in %s", query)
		}
	}
	if uri.User.Username() != outbound["uuid"] || uri.Hostname() != outbound["server"] {
		t.Fatal("node identity changed")
	}
}

func TestNodeLinksKeepCredentialsEscapedAndPinned(t *testing.T) {
	profile := NodeProfile{Protocols: []NodeProtocol{
		{Type: "vless-reality", DisplayName: "Reality", VLESSReality: &VLESSReality{Server: "2001:db8::1", ServerPort: 443, UUID: "uuid", Flow: "xtls-rprx-vision", ServerName: "www.example.com", PublicKey: "public", ShortID: "abcd"}},
		{Type: "hysteria2", DisplayName: "Hysteria2", Hysteria2: &Hysteria2Node{Server: "203.0.113.1", ServerPort: 8443, Password: "a:b@c/?#%", ObfsType: "salamander", ObfsPassword: "obfs&?", ServerName: "203.0.113.1", CertificatePublicKeySHA256: "spki", CertificateSHA256: strings.Repeat("a", 64)}},
	}}
	links, err := BuildNodeLinks(profile, "测试 VPS")
	if err != nil {
		t.Fatal(err)
	}
	if len(links) != 2 {
		t.Fatal("missing protocols")
	}
	v, _ := url.Parse(links[0].URL)
	if v.Host != "[2001:db8::1]:443" || v.Query().Get("pbk") != "public" || v.Fragment != "测试 VPS" {
		t.Fatal(v)
	}
	h, _ := url.Parse(links[1].URL)
	if h.User.Username() != "a:b@c/?#%" {
		t.Fatal("password was changed")
	}
	if _, ok := h.User.Password(); ok {
		t.Fatal("colon was not escaped")
	}
	if h.Query().Get("pinSHA256") != strings.Repeat("a", 64) || h.Query().Get("pendingnet-spki") != "spki" || h.Query().Get("obfs-password") != "obfs&?" {
		t.Fatal("missing certificate pin or obfuscation")
	}
	profile.Protocols[1].Hysteria2.CertificateSHA256 = ""
	if _, err := BuildNodeLinks(profile, "test"); err == nil {
		t.Fatal("must not export unpinned self-signed Hysteria2")
	}
}
