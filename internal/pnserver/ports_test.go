package pnserver

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestChangePortsPreservesIdentityUsersAndEngineSettings(t *testing.T) {
	for _, perUser := range []bool{false, true} {
		t.Run(map[bool]string{false: "shared", true: "per-user"}[perUser], func(t *testing.T) {
			s, services, before := provisionedManagedConfigFixture(t)
			if perUser {
				for i := 0; i < 2; i++ {
					if _, err := s.CreatePairing(time.Hour); err != nil {
						t.Fatal(err)
					}
				}
				hooks := ManagedConfigHooks{Validate: func(ManagedConfigPaths) error { return nil }, Restart: func() error { return nil }}
				if err := s.SyncUserProxyServices(services, hooks); err != nil {
					t.Fatal(err)
				}
				before, _ = s.ReadManagedConfig(services)
			}
			stateBefore, _ := os.ReadFile(filepath.Join(s.Dir, "state.json"))
			accountsBefore, _ := os.ReadFile(filepath.Join(s.Dir, "user-proxy.json"))
			certBefore, _ := os.ReadFile(filepath.Join(services, "hysteria.crt"))
			calls := 0
			target := ProxyPorts{8443, 9443}
			err := s.ChangePorts(services, before.Revision, target, ManagedConfigHooks{
				Validate: func(paths ManagedConfigPaths) error {
					// Validation runs against staged files, before any live change.
					live, err := NewStore(s.Dir).ReadManagedConfig(services)
					if err != nil || live.Revision != before.Revision {
						t.Fatal("mutated before validation")
					}
					x, _ := os.ReadFile(paths.Xray)
					h, _ := os.ReadFile(paths.Hysteria)
					n, _ := os.ReadFile(paths.Node)
					if ports, err := ManagedConfigPorts(ManagedConfig{Node: n, Xray: x, Hysteria: h}); err != nil || ports != target {
						t.Fatal("staged ports do not match")
					}
					return nil
				},
				Restart: func() error {
					calls++
					live, err := NewStore(s.Dir).ReadManagedConfig(services)
					if err != nil {
						return err
					}
					if ports, err := ManagedConfigPorts(live); err != nil || ports != target {
						t.Fatal("restart sees stale ports")
					}
					return nil
				},
			})
			if err != nil || calls != 1 {
				t.Fatalf("change failed: %v, restarts %d", err, calls)
			}
			after, _ := s.ReadManagedConfig(services)
			assertOnlyPortsChanged(t, before, after)
			stateAfter, _ := os.ReadFile(filepath.Join(s.Dir, "state.json"))
			accountsAfter, _ := os.ReadFile(filepath.Join(s.Dir, "user-proxy.json"))
			certAfter, _ := os.ReadFile(filepath.Join(services, "hysteria.crt"))
			if !bytes.Equal(stateBefore, stateAfter) || !bytes.Equal(accountsBefore, accountsAfter) || !bytes.Equal(certBefore, certAfter) {
				t.Fatal("changed identity, users or certificate")
			}
			backup, err := os.ReadFile(filepath.Join(s.Dir, "management-backups", before.Revision, "node.json"))
			if err != nil || !bytes.Equal(backup, before.Node) {
				t.Fatal("missing original backup")
			}
		})
	}
}

func assertOnlyPortsChanged(t *testing.T, before, after ManagedConfig) {
	t.Helper()
	for i, pair := range [][2][]byte{{before.Node, after.Node}, {before.Xray, after.Xray}, {before.Hysteria, after.Hysteria}} {
		var a, b map[string]any
		if json.Unmarshal(pair[0], &a) != nil || json.Unmarshal(pair[1], &b) != nil {
			t.Fatal("invalid JSON")
		}
		switch i {
		case 0:
			delete(a, "updated_at")
			delete(b, "updated_at")
			for _, obj := range []map[string]any{a, b} {
				for _, raw := range obj["protocols"].([]any) {
					p := raw.(map[string]any)
					for _, k := range []string{"vless_reality", "hysteria2"} {
						if n, ok := p[k].(map[string]any); ok {
							delete(n, "server_port")
						}
					}
				}
			}
		case 1:
			delete(a["inbounds"].([]any)[0].(map[string]any), "port")
			delete(b["inbounds"].([]any)[0].(map[string]any), "port")
		case 2:
			delete(a, "listen")
			delete(b, "listen")
		}
		if !reflect.DeepEqual(a, b) {
			t.Fatalf("changed fields other than ports in document %d", i)
		}
	}
}

func TestChangePortsFailureAndNoopLeaveFilesUnchanged(t *testing.T) {
	for _, scenario := range []string{"invalid", "stale", "validation", "restart", "noop", "pending-user-sync", "mismatched-listener"} {
		t.Run(scenario, func(t *testing.T) {
			s, services, before := provisionedManagedConfigFixture(t)
			ports, _ := ManagedConfigPorts(before)
			target := ProxyPorts{8443, ports.Hysteria2}
			revision := before.Revision
			validated, restarts := 0, 0
			switch scenario {
			case "invalid":
				target.Reality = 65536
			case "stale":
				revision = "stale"
			case "noop":
				target = ports
			case "pending-user-sync":
				if err := os.WriteFile(filepath.Join(s.Dir, "user-proxy-update.json"), []byte(`{}`), 0600); err != nil {
					t.Fatal(err)
				}
			case "mismatched-listener":
				x := replaceJSONValue(t, before.Xray, "inbounds", "port", float64(8888))
				if err := os.WriteFile(filepath.Join(services, "xray.json"), x, 0600); err != nil {
					t.Fatal(err)
				}
				before, _ = s.ReadManagedConfig(services)
				revision = before.Revision
			}
			err := s.ChangePorts(services, revision, target, ManagedConfigHooks{
				Validate: func(ManagedConfigPaths) error {
					validated++
					if scenario == "validation" {
						return errors.New("fixture occupied port")
					}
					return nil
				},
				Restart: func() error {
					restarts++
					if scenario == "restart" && restarts == 1 {
						return errors.New("fixture failed restart")
					}
					live, err := NewStore(s.Dir).ReadManagedConfig(services)
					if err != nil {
						return err
					}
					if p, err := ManagedConfigPorts(live); err != nil || p != ports {
						t.Fatal("rollback did not restore old listener ports")
					}
					return nil
				},
			})
			if (scenario == "noop") != (err == nil) {
				t.Fatalf("unexpected result: %v", err)
			}
			after, readErr := s.ReadManagedConfig(services)
			if readErr != nil || after.Revision != before.Revision {
				t.Fatal("failed change altered live files")
			}
			if scenario == "restart" && restarts != 2 {
				t.Fatal("rollback did not restart original services")
			}
			if scenario != "restart" && restarts != 0 {
				t.Fatal("unexpected restart")
			}
			if scenario != "validation" && scenario != "restart" && validated != 0 {
				t.Fatal("invalid/noop change reached validator")
			}
		})
	}
}
