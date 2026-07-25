package daemon

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
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

// TestConcurrentUpdateAllSerializes races several UpdateAll calls (as would
// happen if a manual POST /api/rulesets/update landed while the 24h ticker
// fired, or two rapid POSTs). Each response body encodes a monotonically
// increasing counter with a length that varies request to request; if
// updateMu failed to serialize whole UpdateAll runs, two concurrent
// updateOne calls writing the same "<file>.tmp" and renaming onto the same
// destination could interleave in a way that leaves a body that doesn't
// match any single complete response. Run with -race to also catch data
// races on the in-memory status map.
func TestConcurrentUpdateAllSerializes(t *testing.T) {
	var n int64
	var counterMu sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		counterMu.Lock()
		n++
		cur := n
		counterMu.Unlock()
		// Body length grows with the counter so a torn/interleaved write is
		// very unlikely to accidentally look like a valid complete body.
		body := strings.Repeat("X", int(cur)) + "-END-" + r.URL.Path
		w.Write([]byte(body))
	}))
	defer srv.Close()

	dir := t.TempDir()
	u := NewRuleSetUpdater(dir, "")
	u.geositeBase, u.geoipBase = srv.URL, srv.URL
	u.Client = srv.Client()

	const concurrency = 8
	var wg sync.WaitGroup
	wg.Add(concurrency)
	for i := 0; i < concurrency; i++ {
		go func() {
			defer wg.Done()
			for f, err := range u.UpdateAll(context.Background()) {
				if err != nil {
					t.Errorf("%s: %v", f, err)
				}
			}
		}()
	}
	wg.Wait()

	for _, spec := range ruleSetSpecs {
		b, err := os.ReadFile(filepath.Join(dir, spec.file))
		if err != nil {
			t.Fatalf("%s: %v", spec.file, err)
		}
		s := string(b)
		idx := strings.Index(s, "-END-")
		if idx < 0 {
			t.Errorf("%s: torn content, no -END- marker: %q", spec.file, s)
			continue
		}
		prefix := s[:idx]
		for _, c := range prefix {
			if c != 'X' {
				t.Errorf("%s: torn content, non-X byte in run: %q", spec.file, s)
				break
			}
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
