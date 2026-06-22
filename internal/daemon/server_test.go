package daemon

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"sbtally/internal/core"
)

func TestServerApps(t *testing.T) {
	st, err := core.OpenStore(filepath.Join(t.TempDir(), "s.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	_ = st.WriteRollups([]core.Rollup{{Bucket: 0, App: "Safari", Host: "a.com", Upload: 10, Download: 1}})

	srv := NewServer(st, NewLiveHub(), func() int64 { return 1000 })
	rec := httptest.NewRecorder()
	srv.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/apps?since=24h", nil))
	if rec.Code != 200 {
		t.Fatalf("status %d", rec.Code)
	}
	var apps []core.AppStat
	if err := json.Unmarshal(rec.Body.Bytes(), &apps); err != nil {
		t.Fatal(err)
	}
	if len(apps) != 1 || apps[0].App != "Safari" || apps[0].Total != 11 {
		t.Fatalf("got %+v", apps)
	}
}

func TestServerAppDetailPathParam(t *testing.T) {
	st, _ := core.OpenStore(filepath.Join(t.TempDir(), "s.db"))
	defer st.Close()
	_ = st.WriteRollups([]core.Rollup{{Bucket: 0, App: "Mail", Host: "c.com", Upload: 5, Download: 1}})
	srv := NewServer(st, NewLiveHub(), func() int64 { return 1000 })
	rec := httptest.NewRecorder()
	srv.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/app/Mail?since=24h", nil))
	var d core.AppDetail
	if err := json.Unmarshal(rec.Body.Bytes(), &d); err != nil {
		t.Fatal(err)
	}
	if d.App != "Mail" || len(d.Domains) != 1 || d.Domains[0].Host != "c.com" {
		t.Fatalf("got %+v", d)
	}
}
