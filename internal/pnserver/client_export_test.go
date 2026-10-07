package pnserver

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func testRealityProfile() NodeProfile {
	return NodeProfile{Protocols: []NodeProtocol{{
		ID: "reality", Type: "vless-reality",
		VLESSReality: &VLESSReality{
			Server: "203.0.113.10", ServerPort: 443,
			UUID: "11111111-1111-1111-1111-111111111111", Flow: "xtls-rprx-vision",
			ServerName: "www.example.com", PublicKey: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x42}, 32)), ShortID: "abcdef12",
		},
	}}}
}

func TestGeneratedClientConfigsWithInstalledSingBox(t *testing.T) {
	binary, err := exec.LookPath("sing-box")
	if err != nil {
		t.Skip("sing-box is not installed")
	}
	for _, platform := range []string{"android", "windows"} {
		t.Run(platform, func(t *testing.T) {
			b, err := BuildClientConfig(testRealityProfile(), platform)
			if err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(t.TempDir(), "config.json")
			if err := os.WriteFile(path, b, 0o600); err != nil {
				t.Fatal(err)
			}
			if output, err := exec.Command(binary, "check", "-c", path).CombinedOutput(); err != nil {
				t.Fatalf("sing-box rejected %s config: %v\n%s", platform, err, output)
			}
		})
	}
}

func TestBuildClientConfigPlatforms(t *testing.T) {
	for _, platform := range []string{"android", "windows"} {
		t.Run(platform, func(t *testing.T) {
			b, err := BuildClientConfig(testRealityProfile(), platform)
			if err != nil {
				t.Fatal(err)
			}
			var config struct {
				Inbounds []struct {
					Type           string `json:"type"`
					AutoRoute      bool   `json:"auto_route"`
					SetSystemProxy bool   `json:"set_system_proxy"`
				} `json:"inbounds"`
				Outbounds []struct {
					Type       string `json:"type"`
					Server     string `json:"server"`
					ServerPort int    `json:"server_port"`
					UUID       string `json:"uuid"`
					Flow       string `json:"flow"`
					TLS        struct {
						Enabled bool `json:"enabled"`
						Reality struct {
							Enabled   bool   `json:"enabled"`
							PublicKey string `json:"public_key"`
						} `json:"reality"`
					} `json:"tls"`
				} `json:"outbounds"`
				Route struct {
					Final               string `json:"final"`
					AutoDetectInterface bool   `json:"auto_detect_interface"`
				} `json:"route"`
			}
			if err := json.Unmarshal(b, &config); err != nil {
				t.Fatal(err)
			}
			if len(config.Inbounds) != 1 || len(config.Outbounds) != 1 ||
				config.Outbounds[0].Type != "vless" || config.Outbounds[0].Server != "203.0.113.10" ||
				config.Outbounds[0].ServerPort != 443 || config.Outbounds[0].UUID == "" ||
				config.Outbounds[0].Flow != "xtls-rprx-vision" || !config.Outbounds[0].TLS.Enabled ||
				!config.Outbounds[0].TLS.Reality.Enabled || config.Outbounds[0].TLS.Reality.PublicKey == "" ||
				config.Route.Final != "proxy" {
				t.Fatalf("incomplete %s export", platform)
			}
			if platform == "android" && (config.Inbounds[0].Type != "tun" || !config.Inbounds[0].AutoRoute || !config.Route.AutoDetectInterface) {
				t.Fatal("Android VPN export must protect outbound from TUN routing loop")
			}
			if platform == "windows" && (config.Inbounds[0].Type != "mixed" || !config.Inbounds[0].SetSystemProxy) {
				t.Fatal("Windows export must be usable as a local system proxy")
			}
		})
	}
}

func TestBuildClientConfigRejectsInvalidInput(t *testing.T) {
	for _, tc := range []struct {
		name, platform string
		profile        NodeProfile
	}{
		{"unknown platform", "ios", testRealityProfile()},
		{"missing protocol", "android", NodeProfile{}},
		{"missing credential", "windows", NodeProfile{Protocols: []NodeProtocol{{Type: "vless-reality", VLESSReality: &VLESSReality{Server: "203.0.113.10", ServerPort: 443}}}}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := BuildClientConfig(tc.profile, tc.platform)
			if err == nil || strings.Contains(err.Error(), "11111111-1111") {
				t.Fatalf("expected safe validation error, got %v", err)
			}
		})
	}
}
