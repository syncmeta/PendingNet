package pnserver

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestApplyManagedConfigRejectsMismatchedEngineBeforeHooks(t *testing.T) {
	store, services, original := provisionedManagedConfigFixture(t)
	candidate := original
	candidate.Xray = replaceJSONValue(t, candidate.Xray, "inbounds", "port", float64(8443))
	called := false
	err := store.ApplyManagedConfig(services, candidate, ManagedConfigHooks{
		Validate: func(ManagedConfigPaths) error { called = true; return nil },
		Restart:  func() error { called = true; return nil },
	})
	if !errors.Is(err, ErrManagedConfigInvalid) || called {
		t.Fatalf("mismatched engine reached hooks or was accepted: %v", err)
	}
	after, err := store.ReadManagedConfig(services)
	if err != nil || after.Revision != original.Revision {
		t.Fatalf("mismatched engine changed live files: %v", err)
	}
}

func provisionedManagedConfigFixture(t *testing.T) (*Store, string, ManagedConfig) {
	t.Helper()
	store, now := testStore(t)
	services := t.TempDir()
	artifacts, err := BuildProvisionArtifacts(ProvisionOptions{
		ServerIP: "203.0.113.10", RealitySNI: "www.cloudflare.com", ServicesDir: services,
	}, nil, now)
	if err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string][]byte{
		"xray.json": artifacts.XrayConfig, "hysteria.json": artifacts.Hysteria2Config,
		"hysteria.crt": artifacts.Hysteria2CertPEM, "hysteria.key": artifacts.Hysteria2KeyPEM,
	} {
		if err := os.WriteFile(filepath.Join(services, name), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := store.SaveNodeProfile(artifacts.NodeProfile); err != nil {
		t.Fatal(err)
	}
	snapshot, err := store.ReadManagedConfig(services)
	if err != nil {
		t.Fatal(err)
	}
	return store, services, snapshot
}

func TestManagedConfigConsistencyMatchesGeneratedServices(t *testing.T) {
	services := t.TempDir()
	artifacts, err := BuildProvisionArtifacts(ProvisionOptions{
		ServerIP: "203.0.113.10", RealitySNI: "www.cloudflare.com", ServicesDir: services,
	}, nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(services, "hysteria.crt"), artifacts.Hysteria2CertPEM, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(services, "hysteria.key"), artifacts.Hysteria2KeyPEM, 0o600); err != nil {
		t.Fatal(err)
	}
	profile := artifacts.NodeProfile
	profile.Version = nodeProfileVersion
	profile.ServerID = "server-1"
	node, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	snapshot := ManagedConfig{Node: node, Xray: artifacts.XrayConfig, Hysteria: artifacts.Hysteria2Config}
	if err := ValidateManagedConfigConsistency(snapshot, services); err != nil {
		t.Fatalf("generated service configuration rejected: %v", err)
	}
	for _, change := range []struct {
		name string
		edit func(*ManagedConfig)
	}{
		{"xray-port", func(c *ManagedConfig) { c.Xray = replaceJSONValue(t, c.Xray, "inbounds", "port", float64(8443)) }},
		{"xray-uuid", func(c *ManagedConfig) { c.Xray = replaceJSONValue(t, c.Xray, "inbounds", "id", "different") }},
		{"reality-key", func(c *ManagedConfig) { c.Xray = replaceJSONValue(t, c.Xray, "inbounds", "privateKey", "different") }},
		{"hysteria-password", func(c *ManagedConfig) { c.Hysteria = replaceJSONValue(t, c.Hysteria, "auth", "password", "different") }},
		{"hysteria-listen", func(c *ManagedConfig) { c.Hysteria = replaceJSONValue(t, c.Hysteria, "listen", "", ":8443") }},
		{"hysteria-cert", func(c *ManagedConfig) { c.Hysteria = replaceJSONValue(t, c.Hysteria, "tls", "cert", "/tmp/other.crt") }},
		{"client-pin", func(c *ManagedConfig) {
			var profile NodeProfile
			if err := json.Unmarshal(c.Node, &profile); err != nil {
				t.Fatal(err)
			}
			profile.Protocols[1].Hysteria2.CertificatePublicKeySHA256 = "different"
			c.Node, _ = json.Marshal(profile)
		}},
	} {
		t.Run(change.name, func(t *testing.T) {
			changed := snapshot
			change.edit(&changed)
			if err := ValidateManagedConfigConsistency(changed, services); err == nil {
				t.Fatal("mismatched client/server configuration accepted")
			}
		})
	}
}

func replaceJSONValue(t *testing.T, data []byte, section, key string, value any) []byte {
	t.Helper()
	var object map[string]any
	if err := json.Unmarshal(data, &object); err != nil {
		t.Fatal(err)
	}
	if section == "inbounds" {
		inbound := object["inbounds"].([]any)[0].(map[string]any)
		switch key {
		case "port":
			inbound["port"] = value
		case "id":
			inbound["settings"].(map[string]any)["clients"].([]any)[0].(map[string]any)["id"] = value
		case "privateKey":
			inbound["streamSettings"].(map[string]any)["realitySettings"].(map[string]any)["privateKey"] = value
		}
	} else if key == "" {
		object[section] = value
	} else {
		object[section].(map[string]any)[key] = value
	}
	changed, err := json.Marshal(object)
	if err != nil {
		t.Fatal(err)
	}
	return changed
}
