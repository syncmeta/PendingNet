package daemon

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestUpdateAllAtomicReplace(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("SRSDATA-" + r.URL.Path))
	}))
	defer srv.Close()
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "geosite-cn.srs"), []byte("old"), 0644)
	u := NewRuleSetUpdater(dir, "")
	u.geositeBase, u.geoipBase = srv.URL, srv.URL
	u.Client = srv.Client()
	errs := u.UpdateAll(context.Background())
	for f, err := range errs {
		if err != nil {
			t.Fatalf("%s: %v", f, err)
		}
	}
	b, _ := os.ReadFile(filepath.Join(dir, "geosite-cn.srs"))
	if !strings.HasPrefix(string(b), "SRSDATA-") {
		t.Error("not replaced")
	}
	if len(u.Status()) != 5 {
		t.Errorf("want 5 statuses")
	}
}

func TestUpdateFailureKeepsOldFile(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", 500)
	}))
	defer srv.Close()
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "geoip-cn.srs"), []byte("old"), 0644)
	u := NewRuleSetUpdater(dir, "")
	u.geositeBase, u.geoipBase = srv.URL, srv.URL
	u.Client = srv.Client()
	u.UpdateAll(context.Background())
	b, _ := os.ReadFile(filepath.Join(dir, "geoip-cn.srs"))
	if string(b) != "old" {
		t.Error("old file clobbered on failure")
	}
}

func TestNoTmpFileLeftBehindOnFailure(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", 500)
	}))
	defer srv.Close()
	dir := t.TempDir()
	u := NewRuleSetUpdater(dir, "")
	u.geositeBase, u.geoipBase = srv.URL, srv.URL
	u.Client = srv.Client()
	u.UpdateAll(context.Background())
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".tmp") {
			t.Errorf("leftover tmp file: %s", e.Name())
		}
	}
}

func TestRegisterRuleSetsEndpoints(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("SRSDATA-" + r.URL.Path))
	}))
	defer srv.Close()
	dir := t.TempDir()
	u := NewRuleSetUpdater(dir, "")
	u.geositeBase, u.geoipBase = srv.URL, srv.URL
	u.Client = srv.Client()

	mux := http.NewServeMux()
	RegisterRuleSets(mux, u)

	// POST update first so GET has data.
	rw := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/rulesets/update", nil)
	mux.ServeHTTP(rw, req)
	if rw.Code != 200 {
		t.Fatalf("update status %d", rw.Code)
	}
	if !strings.Contains(rw.Body.String(), "{") {
		t.Errorf("expected json object body, got %q", rw.Body.String())
	}

	rw2 := httptest.NewRecorder()
	req2 := httptest.NewRequest(http.MethodGet, "/api/rulesets", nil)
	mux.ServeHTTP(rw2, req2)
	if rw2.Code != 200 {
		t.Fatalf("get status %d", rw2.Code)
	}
	body := rw2.Body.String()
	if !strings.Contains(body, `"tag"`) || !strings.Contains(body, `"file"`) || !strings.Contains(body, `"updated_at"`) {
		t.Errorf("unexpected body: %s", body)
	}
}
