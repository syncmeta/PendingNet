package pnserver

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"sbtally/internal/pairing"
)

func TestEnrollAndAuthenticatedStatus(t *testing.T) {
	store, _ := testStore(t)
	pairFile, err := store.CreatePairing(10 * time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	handler := (&API{Store: store}).Handler()

	body, _ := json.Marshal(map[string]string{
		"token": pairFile.Enrollment.Token, "device_name": "PendingNet iPhone",
	})
	enrollReq := httptest.NewRequest(http.MethodPost, "/v1/enroll", bytes.NewReader(body))
	enrollReq.Header.Set("Content-Type", "application/json")
	enrollRec := httptest.NewRecorder()
	handler.ServeHTTP(enrollRec, enrollReq)
	if enrollRec.Code != http.StatusCreated {
		t.Fatalf("enroll status %d: %s", enrollRec.Code, enrollRec.Body.String())
	}
	var enrolled struct {
		AccessToken string     `json:"access_token"`
		Server      ServerInfo `json:"server"`
	}
	if err := json.NewDecoder(enrollRec.Body).Decode(&enrolled); err != nil {
		t.Fatal(err)
	}
	if enrolled.AccessToken == "" || enrolled.Server.ServerID != pairFile.ServerID {
		t.Fatalf("unexpected enrollment: %#v", enrolled)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	req.Header.Set("Authorization", "Bearer "+enrolled.AccessToken)
	statusRec := httptest.NewRecorder()
	handler.ServeHTTP(statusRec, req)
	if statusRec.Code != http.StatusOK {
		t.Fatalf("status endpoint returned %d", statusRec.Code)
	}
}

func TestStatusRejectsMissingDeviceToken(t *testing.T) {
	store, _ := testStore(t)
	req := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	rec := httptest.NewRecorder()
	(&API{Store: store}).Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d, want 401", rec.Code)
	}
}

func TestHTTPRecordsPeerIPNotForwardedHeader(t *testing.T) {
	store, now := testStore(t)
	pairFile, err := store.CreatePairing(10 * time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	handler := (&API{Store: store}).Handler()
	body, _ := json.Marshal(map[string]string{"token": pairFile.Enrollment.Token, "device_name": "Mac"})
	req := httptest.NewRequest(http.MethodPost, "/v1/enroll", bytes.NewReader(body))
	req.RemoteAddr = "198.51.100.4:5555"
	req.Header.Set("X-Forwarded-For", "192.0.2.99")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("enroll: %d %s", rec.Code, rec.Body.String())
	}
	var enrolled struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&enrolled); err != nil {
		t.Fatal(err)
	}
	store.Now = func() time.Time { return now.Add(time.Hour) }
	status := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	status.RemoteAddr = "[2001:db8::2]:7777"
	status.Header.Set("X-Forwarded-For", "192.0.2.99")
	status.Header.Set("Authorization", "Bearer "+enrolled.AccessToken)
	statusRec := httptest.NewRecorder()
	handler.ServeHTTP(statusRec, status)
	if statusRec.Code != http.StatusOK {
		t.Fatalf("status: %d", statusRec.Code)
	}
	state, err := store.Load()
	if err != nil {
		t.Fatal(err)
	}
	got := state.Users[0].LoginIPs
	if len(got) != 2 || got[0].IP != "198.51.100.4" || got[1].IP != "2001:db8::2" {
		t.Fatalf("unexpected peer IPs: %#v", got)
	}
}

func TestAdminUsersEndpointSeparatesRolesAndHidesTokenHashes(t *testing.T) {
	store, _ := testStore(t)
	regularLink, err := store.CreatePairing(time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	adminLink, err := store.CreateAdminPairing(time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	regular, err := store.Enroll(regularLink.Enrollment.Token, "client")
	if err != nil {
		t.Fatal(err)
	}
	admin, err := store.Enroll(adminLink.Enrollment.Token, "manager")
	if err != nil {
		t.Fatal(err)
	}
	handler := (&API{Store: store}).Handler()
	for _, sample := range []struct {
		token string
		want  int
	}{
		{"", http.StatusUnauthorized},
		{regular.Token, http.StatusForbidden},
		{admin.Token, http.StatusOK},
	} {
		req := httptest.NewRequest(http.MethodGet, "/v1/admin/users", nil)
		if sample.token != "" {
			req.Header.Set("Authorization", "Bearer "+sample.token)
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != sample.want {
			t.Fatalf("token role status: got %d want %d (%s)", rec.Code, sample.want, rec.Body.String())
		}
		if sample.want == http.StatusOK {
			if !bytes.Contains(rec.Body.Bytes(), []byte(`"login_ips"`)) && !bytes.Contains(rec.Body.Bytes(), []byte(`"users"`)) {
				t.Fatalf("unexpected user response: %s", rec.Body.String())
			}
			if bytes.Contains(rec.Body.Bytes(), []byte("token_sha256")) || bytes.Contains(rec.Body.Bytes(), []byte(admin.Token)) {
				t.Fatalf("secret leaked in users response: %s", rec.Body.String())
			}
		}
	}
}

func TestAdminCanRevokeUserButOrdinaryClientCannot(t *testing.T) {
	store, _ := testStore(t)
	regularLink, _ := store.CreatePairing(time.Hour)
	adminLink, _ := store.CreateAdminPairing(time.Hour)
	regular, _ := store.Enroll(regularLink.Enrollment.Token, "client")
	admin, _ := store.Enroll(adminLink.Enrollment.Token, "manager")
	client, _ := store.Authenticate(regular.Token)
	handler := (&API{Store: store}).Handler()
	path := "/v1/admin/users/" + client.UserID + "/revoke"
	for _, sample := range []struct {
		token string
		want  int
	}{
		{regular.Token, http.StatusForbidden},
		{admin.Token, http.StatusNoContent},
	} {
		req := httptest.NewRequest(http.MethodPost, path, nil)
		req.Header.Set("Authorization", "Bearer "+sample.token)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != sample.want {
			t.Fatalf("revoke status %d want %d: %s", rec.Code, sample.want, rec.Body.String())
		}
	}
	if _, err := store.Authenticate(regular.Token); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("revoked credential still authenticates: %v", err)
	}
}

func TestAdminEnrollmentResponseCarriesAuthoritativeRole(t *testing.T) {
	store, _ := testStore(t)
	link, err := store.CreateAdminPairing(time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]string{"token": link.Enrollment.Token, "device_name": "manager"})
	req := httptest.NewRequest(http.MethodPost, "/v1/enroll", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	(&API{Store: store}).Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("enroll %d: %s", rec.Code, rec.Body.String())
	}
	var result struct {
		Role string `json:"role"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	if result.Role != "admin" {
		t.Fatalf("server did not report admin role: %#v", result)
	}
}

func TestOnlyAdminCanIssueExplicitlyScopedPairingLinks(t *testing.T) {
	store, _ := testStore(t)
	regularLink, _ := store.CreatePairing(time.Hour)
	adminLink, _ := store.CreateAdminPairing(time.Hour)
	regular, _ := store.Enroll(regularLink.Enrollment.Token, "client")
	admin, _ := store.Enroll(adminLink.Enrollment.Token, "manager")
	handler := (&API{Store: store}).Handler()
	issue := func(token, body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/v1/admin/pairings", bytes.NewBufferString(body))
		req.Header.Set("Authorization", "Bearer "+token)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec
	}
	if got := issue(regular.Token, `{"role":"admin","ttl_seconds":600}`); got.Code != http.StatusForbidden {
		t.Fatalf("ordinary client issued admin link: %d", got.Code)
	}
	before, _ := store.Load()
	if got := issue(admin.Token, `{"ttl_seconds":600}`); got.Code != http.StatusBadRequest {
		t.Fatalf("implicit role accepted: %d", got.Code)
	}
	if got := issue(admin.Token, `{"role":"root","ttl_seconds":600}`); got.Code != http.StatusBadRequest {
		t.Fatalf("unknown role accepted: %d", got.Code)
	}
	afterInvalid, _ := store.Load()
	if len(afterInvalid.Pairings) != len(before.Pairings) {
		t.Fatal("invalid request created a pairing")
	}
	for _, role := range []string{"client", "admin"} {
		rec := issue(admin.Token, `{"role":"`+role+`","ttl_seconds":600}`)
		if rec.Code != http.StatusCreated || rec.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("issue %s: %d", role, rec.Code)
		}
		var payload struct {
			Link string `json:"link"`
		}
		if err := json.NewDecoder(rec.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		parsed, err := pairing.ParseURL(payload.Link, store.now())
		if err != nil {
			t.Fatal(err)
		}
		if role == "admin" && parsed.Enrollment.Role != "admin" {
			t.Fatal("admin link lost role")
		}
		if role == "client" && parsed.Enrollment.Role != "" {
			t.Fatal("client link gained admin role")
		}
	}
}

func TestClientConfigExportRequiresAdminAndDoesNotCacheSecrets(t *testing.T) {
	store, _ := testStore(t)
	if err := store.SaveNodeProfile(testRealityProfile()); err != nil {
		t.Fatal(err)
	}
	ordinaryLink, _ := store.CreatePairing(time.Hour)
	adminLink, _ := store.CreateAdminPairing(time.Hour)
	ordinary, _ := store.Enroll(ordinaryLink.Enrollment.Token, "client")
	admin, _ := store.Enroll(adminLink.Enrollment.Token, "manager")
	handler := (&API{Store: store}).Handler()
	request := func(token, platform string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/v1/admin/client-config?platform="+platform, nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec
	}
	for _, sample := range []struct {
		token string
		want  int
	}{{"", http.StatusUnauthorized}, {ordinary.Token, http.StatusForbidden}} {
		rec := request(sample.token, "android")
		if rec.Code != sample.want || rec.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("unprivileged export: status=%d cache=%q", rec.Code, rec.Header().Get("Cache-Control"))
		}
		if bytes.Contains(rec.Body.Bytes(), []byte("11111111-1111-1111-1111-111111111111")) {
			t.Fatal("unprivileged response leaked connection credential")
		}
	}
	if rec := request(admin.Token, "ios"); rec.Code != http.StatusBadRequest {
		t.Fatalf("unsupported platform: %d", rec.Code)
	}
	for _, platform := range []string{"android", "windows"} {
		rec := request(admin.Token, platform)
		if rec.Code != http.StatusOK || rec.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("%s export: status=%d cache=%q body=%s", platform, rec.Code, rec.Header().Get("Cache-Control"), rec.Body.String())
		}
		want, err := BuildClientConfig(testRealityProfile(), platform)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(rec.Body.Bytes(), want) {
			t.Fatalf("%s export differs from CLI generator", platform)
		}
	}
}

func TestAdminConfigSnapshotIsVersionedAndPrivate(t *testing.T) {
	store, _ := testStore(t)
	services := t.TempDir()
	profile := NodeProfile{Protocols: []NodeProtocol{{ID: "reality", Type: "vless-reality", DisplayName: "Reality"}}}
	if err := store.SaveNodeProfile(profile); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{
		"xray.json":     `{"secret":"xray-private"}`,
		"hysteria.json": `{"secret":"hy2-private"}`,
	} {
		if err := os.WriteFile(filepath.Join(services, name), []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	regularLink, _ := store.CreatePairing(time.Hour)
	adminLink, _ := store.CreateAdminPairing(time.Hour)
	regular, _ := store.Enroll(regularLink.Enrollment.Token, "client")
	admin, _ := store.Enroll(adminLink.Enrollment.Token, "manager")
	handler := (&API{Store: store, ServicesDir: services}).Handler()
	get := func(token string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/v1/admin/config", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec
	}
	if rec := get(regular.Token); rec.Code != http.StatusForbidden || bytes.Contains(rec.Body.Bytes(), []byte("xray-private")) {
		t.Fatalf("ordinary client saw configuration: %d", rec.Code)
	}
	first := get(admin.Token)
	if first.Code != http.StatusOK || first.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("admin config: %d", first.Code)
	}
	var snapshot struct {
		Revision string          `json:"revision"`
		Node     json.RawMessage `json:"node"`
		Xray     json.RawMessage `json:"xray"`
		Hysteria json.RawMessage `json:"hysteria"`
	}
	if err := json.NewDecoder(first.Body).Decode(&snapshot); err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Revision) != 64 || !bytes.Contains(snapshot.Xray, []byte("xray-private")) ||
		!bytes.Contains(snapshot.Hysteria, []byte("hy2-private")) || len(snapshot.Node) == 0 {
		t.Fatalf("incomplete config snapshot: %#v", snapshot)
	}
	if err := os.WriteFile(filepath.Join(services, "xray.json"), []byte(`{"secret":"changed"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	second := get(admin.Token)
	var changed struct {
		Revision string `json:"revision"`
	}
	if err := json.NewDecoder(second.Body).Decode(&changed); err != nil {
		t.Fatal(err)
	}
	if changed.Revision == snapshot.Revision {
		t.Fatal("config revision did not change")
	}
}

func TestAdminConfigUpdateFailsClosedWithoutHooks(t *testing.T) {
	store, services, snapshot := managedConfigFixture(t)
	adminLink, _ := store.CreateAdminPairing(time.Hour)
	admin, _ := store.Enroll(adminLink.Enrollment.Token, "manager")
	regularLink, _ := store.CreatePairing(time.Hour)
	regular, _ := store.Enroll(regularLink.Enrollment.Token, "client")
	candidate := snapshot
	candidate.Xray = append(append([]byte(nil), snapshot.Xray...), '\n')
	body, _ := json.Marshal(candidate)
	request := func(token string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPut, "/v1/admin/config", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+token)
		rec := httptest.NewRecorder()
		(&API{Store: store, ServicesDir: services}).Handler().ServeHTTP(rec, req)
		return rec
	}
	if got := request(regular.Token); got.Code != http.StatusForbidden {
		t.Fatalf("ordinary device could update config: %d", got.Code)
	}
	if got := request(admin.Token); got.Code != http.StatusServiceUnavailable || got.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("unwired update was accepted: %d %s", got.Code, got.Body.String())
	}
	after, err := store.ReadManagedConfig(services)
	if err != nil || after.Revision != snapshot.Revision {
		t.Fatalf("unwired update changed files: %v", err)
	}
}

func TestAdminConfigUpdateChecksRevisionAndReturnsNewSnapshot(t *testing.T) {
	store, services, snapshot := managedConfigFixture(t)
	adminLink, _ := store.CreateAdminPairing(time.Hour)
	admin, _ := store.Enroll(adminLink.Enrollment.Token, "manager")
	validations, restarts := 0, 0
	api := &API{Store: store, ServicesDir: services, ConfigHooks: ManagedConfigHooks{
		Validate: func(ManagedConfigPaths) error { validations++; return nil },
		Restart:  func() error { restarts++; return nil },
	}}
	request := func(candidate ManagedConfig) *httptest.ResponseRecorder {
		body, _ := json.Marshal(candidate)
		req := httptest.NewRequest(http.MethodPut, "/v1/admin/config", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+admin.Token)
		rec := httptest.NewRecorder()
		api.Handler().ServeHTTP(rec, req)
		return rec
	}
	candidate := snapshot
	candidate.Xray = append(append([]byte(nil), snapshot.Xray...), '\n')
	candidate.Revision = "stale"
	if got := request(candidate); got.Code != http.StatusConflict || validations != 0 || restarts != 0 {
		t.Fatalf("stale update reached hooks: %d", got.Code)
	}
	candidate.Revision = snapshot.Revision
	got := request(candidate)
	if got.Code != http.StatusOK || validations != 1 || restarts != 1 {
		t.Fatalf("valid update failed: %d %s", got.Code, got.Body.String())
	}
	var updated ManagedConfig
	if err := json.NewDecoder(got.Body).Decode(&updated); err != nil || updated.Revision == snapshot.Revision {
		t.Fatalf("updated revision unavailable: %v", err)
	}
	if got := request(candidate); got.Code != http.StatusConflict || validations != 1 || restarts != 1 {
		t.Fatalf("replayed update reached hooks: %d", got.Code)
	}
}

func TestNodeProfileRequiresDeviceToken(t *testing.T) {
	store, _ := testStore(t)
	profile := NodeProfile{Protocols: []NodeProtocol{{
		ID: "reality", Type: "vless-reality", DisplayName: "Reality",
		VLESSReality: &VLESSReality{Server: "203.0.113.10", ServerPort: 443},
	}}}
	if err := store.SaveNodeProfile(profile); err != nil {
		t.Fatal(err)
	}
	handler := (&API{Store: store}).Handler()

	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodGet, "/v1/node", nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized node status %d", unauthorized.Code)
	}

	pairFile, err := store.CreatePairing(10 * time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	credential, err := store.Enroll(pairFile.Enrollment.Token, "test device")
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "/v1/node", nil)
	req.Header.Set("Authorization", "Bearer "+credential.Token)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || !bytes.Contains(rec.Body.Bytes(), []byte(`"vless-reality"`)) {
		t.Fatalf("node status %d: %s", rec.Code, rec.Body.String())
	}
}

func TestAdminUserTrafficRenameAndPrivateNode(t *testing.T) {
	store, _ := testStore(t)
	if err := store.SaveNodeProfile(testRealityProfile()); err != nil {
		t.Fatal(err)
	}
	clientLink, _ := store.CreatePairing(time.Hour)
	adminLink, _ := store.CreateAdminPairing(time.Hour)
	client, _ := store.Enroll(clientLink.Enrollment.Token, "client")
	admin, _ := store.Enroll(adminLink.Enrollment.Token, "admin")
	device, _ := store.Authenticate(client.Token)
	accounts, err := store.EnsureUserProxyAccounts()
	if err != nil {
		t.Fatal(err)
	}
	if err := store.RecordUserTraffic("xray", "epoch", map[string]TrafficCounters{device.UserID: {Upload: 123, Download: 456}}); err != nil {
		t.Fatal(err)
	}
	syncs := 0
	handler := (&API{Store: store, UserSync: func() error { syncs++; return nil }}).Handler()
	request := func(method, path, token, body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+token)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec
	}
	users := request("GET", "/v1/admin/users", admin.Token, "")
	if users.Code != 200 || !bytes.Contains(users.Body.Bytes(), []byte(`"upload":123`)) {
		t.Fatalf("missing stats: %d %s", users.Code, users.Body.String())
	}
	for _, credential := range []string{client.Token, admin.Token, accounts.Users[device.UserID].UUID, accounts.Users[device.UserID].Password, accounts.StatsSecret} {
		if strings.Contains(users.Body.String(), credential) {
			t.Fatal("private credential leaked")
		}
	}
	path := "/v1/admin/users/" + device.UserID
	if rec := request("POST", path+"/rename", client.Token, `{"name":"renamed"}`); rec.Code != 403 {
		t.Fatal(rec.Code)
	}
	if rec := request("POST", path+"/rename", admin.Token, `{"name":"renamed"}`); rec.Code != 204 {
		t.Fatalf("rename: %d %s", rec.Code, rec.Body.String())
	}
	node := request("GET", path+"/node", admin.Token, "")
	if node.Code != 200 || !strings.Contains(node.Body.String(), accounts.Users[device.UserID].UUID) {
		t.Fatalf("private node: %d %s", node.Code, node.Body.String())
	}
	if rec := request("POST", path+"/revoke", admin.Token, ""); rec.Code != 204 {
		t.Fatal(rec.Code)
	}
	if rec := request("GET", path+"/node", admin.Token, ""); rec.Code != 404 {
		t.Fatal(rec.Code)
	}
	stats, _ := store.UserTraffic()
	if stats[device.UserID].Upload != 123 || syncs < 2 {
		t.Fatal("revocation lost history or skipped sync")
	}
}
