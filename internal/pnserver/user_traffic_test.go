package pnserver

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestUserProxyCredentialsAreUniqueAndRevokeRemovesBothProtocols(t *testing.T) {
	s := NewStore(t.TempDir())
	_, err := s.Initialize("VPS", "https://203.0.113.1:7443")
	if err != nil {
		t.Fatal(err)
	}
	_ = s.SaveNodeProfile(testRealityProfile())
	_, _ = s.CreatePairing(time.Hour)
	_, _ = s.CreatePairing(time.Hour)
	accounts, err := s.EnsureUserProxyAccounts()
	if err != nil {
		t.Fatal(err)
	}
	st, _ := s.Load()
	a, b := st.Users[0].ID, st.Users[1].ID
	if accounts.Users[a].UUID == accounts.Users[b].UUID || accounts.Users[a].Password == accounts.Users[b].Password {
		t.Fatal("shared credentials")
	}
	p, err := s.UserNodeProfile(a)
	if err != nil {
		t.Fatal(err)
	}
	if p.Protocols[0].VLESSReality.UUID != accounts.Users[a].UUID {
		t.Fatal("not user-specific")
	}
	xr := json.RawMessage(`{"inbounds":[{"protocol":"vless","settings":{"clients":[{"id":"legacy"}]}}]}`)
	hy := json.RawMessage(`{"auth":{"type":"password","password":"legacy"}}`)
	_, _ = s.CreateAdminPairing(time.Hour)
	if err := s.RevokeUser(a); err != nil {
		t.Fatal(err)
	}
	st, _ = s.Load()
	accounts, _ = s.EnsureUserProxyAccounts()
	x, h, err := BuildUserProxyConfigs(xr, hy, st, accounts)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(x), accounts.Users[a].UUID) || strings.Contains(string(h), accounts.Users[a].Password) || strings.Contains(string(x), "legacy") || strings.Contains(string(h), "legacy") {
		t.Fatal("revoked or legacy credential retained")
	}
	if !strings.Contains(string(x), b) || !strings.Contains(string(h), UserHysteriaName(b)) {
		t.Fatal("missing active user")
	}
	if _, err = s.UserNodeProfile(a); err != ErrUnauthorized {
		t.Fatal("revoked user can export")
	}
}

func TestUserTrafficAccumulationPersistsAndHandlesEngineRestart(t *testing.T) {
	dir := t.TempDir()
	s := NewStore(dir)
	sample := map[string]TrafficCounters{"usr_1": {Upload: 100, Download: 200}}
	if err := s.RecordUserTraffic("xray", "pid:1", sample); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordUserTraffic("xray", "pid:1", sample); err != nil {
		t.Fatal(err)
	}
	sample["usr_1"] = TrafficCounters{Upload: 150, Download: 240}
	_ = s.RecordUserTraffic("xray", "pid:1", sample)
	_ = s.RecordUserTraffic("xray", "pid:2", map[string]TrafficCounters{"usr_1": {Upload: 170, Download: 250}})
	_ = s.RecordUserTraffic("hysteria2", "pid:3", map[string]TrafficCounters{"usr_1": {Upload: 20, Download: 30}})
	v, err := NewStore(dir).UserTraffic()
	if err != nil {
		t.Fatal(err)
	}
	if v["usr_1"].Upload != 340 || v["usr_1"].Download != 520 {
		t.Fatalf("wrong accumulated data: %+v", v)
	}
	if err := s.RecordUserTraffic("xray", "pid:2", map[string]TrafficCounters{"usr_1": {Upload: -1}}); err == nil {
		t.Fatal("negative counter accepted")
	}
}

func TestUserProxyApplyRollsBackFailedRestart(t *testing.T) {
	dir := t.TempDir()
	s := NewStore(dir)
	_, _ = s.Initialize("VPS", "https://203.0.113.1:7443")
	_ = s.SaveNodeProfile(testRealityProfile())
	_, _ = s.CreatePairing(time.Hour)
	services := filepath.Join(dir, "services")
	_ = os.MkdirAll(services, 0700)
	x := []byte(`{"inbounds":[{"protocol":"vless","settings":{"clients":[{"id":"old"}]}}]}`)
	h := []byte(`{"auth":{"type":"password","password":"old"}}`)
	_ = os.WriteFile(filepath.Join(services, "xray.json"), x, 0600)
	_ = os.WriteFile(filepath.Join(services, "hysteria.json"), h, 0600)
	calls := 0
	hooks := ManagedConfigHooks{Validate: func(ManagedConfigPaths) error { return nil }, Restart: func() error {
		calls++
		if calls == 1 {
			return errors.New("fixture startup failed")
		}
		return nil
	}}
	if err := s.SyncUserProxyServices(services, hooks); err == nil {
		t.Fatal("accepted failed engine startup")
	}
	got, _ := os.ReadFile(filepath.Join(services, "xray.json"))
	if !bytes.Equal(got, x) {
		t.Fatal("did not roll back Reality")
	}
	got, _ = os.ReadFile(filepath.Join(services, "hysteria.json"))
	if !bytes.Equal(got, h) {
		t.Fatal("did not roll back Hysteria2")
	}
	if calls != 2 {
		t.Fatal("rollback did not restart restored configuration")
	}
	if _, err := os.Stat(filepath.Join(dir, "user-proxy-update.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("completed rollback retained journal")
	}
}

func TestNoActiveUserRemovesAllSharedCredentials(t *testing.T) {
	s := NewStore(t.TempDir())
	if _, err := s.Initialize("VPS", "https://203.0.113.1:7443"); err != nil {
		t.Fatal(err)
	}
	accounts, err := s.EnsureUserProxyAccounts()
	if err != nil {
		t.Fatal(err)
	}
	state, _ := s.Load()
	x, h, err := BuildUserProxyConfigs([]byte(`{"inbounds":[{"protocol":"vless","settings":{"clients":[{"id":"legacy"}]}}]}`), []byte(`{"auth":{"type":"password","password":"legacy"}}`), state, accounts)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(x), "legacy") || strings.Contains(string(h), "legacy") {
		t.Fatal("shared credential retained")
	}
	var config struct {
		Auth struct {
			Userpass map[string]string `json:"userpass"`
		} `json:"auth"`
	}
	if err := json.Unmarshal(h, &config); err != nil {
		t.Fatal(err)
	}
	if len(config.Auth.Userpass) != 1 || config.Auth.Userpass["pendingnet-disabled"] == "" {
		t.Fatal("empty Hysteria auth is invalid")
	}
}
