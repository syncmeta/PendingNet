package pnserver

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
)

// BuildClientConfig exports a standalone sing-box profile from the public
// connection material stored on the server. It never reads server private keys
// or creates new credentials. The returned JSON contains client credentials and
// must be handled as a secret by the caller.
func BuildClientConfig(profile NodeProfile, platform string) ([]byte, error) {
	if platform != "android" && platform != "windows" {
		return nil, fmt.Errorf("unsupported client platform %q", platform)
	}
	var reality *VLESSReality
	for _, protocol := range profile.Protocols {
		if protocol.Type == "vless-reality" && protocol.VLESSReality != nil {
			reality = protocol.VLESSReality
			break
		}
	}
	if reality == nil {
		return nil, errors.New("node profile has no Reality protocol")
	}
	if net.ParseIP(reality.Server) == nil || reality.ServerPort < 1 || reality.ServerPort > 65535 ||
		reality.UUID == "" || reality.ServerName == "" || reality.PublicKey == "" || reality.ShortID == "" ||
		reality.Flow == "" {
		return nil, errors.New("Reality protocol is missing required connection fields")
	}

	config := map[string]any{
		"log": map[string]any{"level": "warn"},
		"outbounds": []any{map[string]any{
			"type": "vless", "tag": "proxy", "server": reality.Server,
			"server_port": reality.ServerPort, "uuid": reality.UUID, "flow": reality.Flow,
			"tls": map[string]any{
				"enabled": true, "server_name": reality.ServerName,
				"utls": map[string]any{"enabled": true, "fingerprint": "chrome"},
				"reality": map[string]any{
					"enabled": true, "public_key": reality.PublicKey, "short_id": reality.ShortID,
				},
			},
		}},
	}
	if platform == "android" {
		config["inbounds"] = []any{map[string]any{
			"type": "tun", "tag": "tun-in", "address": []string{"172.19.0.1/30"},
			"auto_route": true,
		}}
		// The Android graphical client uses this option to keep its outbound
		// sockets on the underlying network, outside its own VpnService TUN.
		config["route"] = map[string]any{"final": "proxy", "auto_detect_interface": true}
		config["dns"] = map[string]any{
			"servers": []any{map[string]any{
				"type": "https", "tag": "doh", "server": "1.1.1.1",
				"path": "/dns-query", "tls": map[string]any{"enabled": true, "server_name": "cloudflare-dns.com"},
				"detour": "proxy",
			}},
			"final": "doh",
		}
	} else {
		config["inbounds"] = []any{map[string]any{
			"type": "mixed", "tag": "local", "listen": "127.0.0.1",
			"listen_port": 2080, "set_system_proxy": true,
		}}
		config["route"] = map[string]any{"final": "proxy"}
	}
	b, err := json.MarshalIndent(config, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}
