package daemon

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"sbtally/internal/clashapi"
)

func TestControlSelectModeAndProxies(t *testing.T) {
	var gotSelectPath, gotName, gotMode string
	clash := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPut && strings.HasPrefix(r.URL.Path, "/proxies/"):
			gotSelectPath = r.URL.Path
			var b struct {
				Name string `json:"name"`
			}
			body, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(body, &b)
			gotName = b.Name
			w.WriteHeader(http.StatusNoContent)
		case r.Method == http.MethodPatch && r.URL.Path == "/configs":
			var b struct {
				Mode string `json:"mode"`
			}
			body, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(body, &b)
			gotMode = b.Mode
			w.WriteHeader(http.StatusNoContent)
		case r.URL.Path == "/proxies":
			_, _ = w.Write([]byte(`{"proxies":{"proxy":{"type":"Selector","now":"vpsA","all":["vpsA","vpsB"]}}}`))
		}
	}))
	defer clash.Close()

	ctrl := clashapi.New(strings.TrimPrefix(clash.URL, "http://"), "")
	mux := http.NewServeMux()
	RegisterControl(mux, ctrl)

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/control/select",
		strings.NewReader(`{"selector":"proxy","name":"vpsB"}`)))
	if rec.Code != http.StatusNoContent {
		t.Fatalf("select status %d", rec.Code)
	}
	if gotSelectPath != "/proxies/proxy" || gotName != "vpsB" {
		t.Fatalf("got path=%s name=%s", gotSelectPath, gotName)
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/control/mode",
		strings.NewReader(`{"mode":"Global"}`)))
	if rec.Code != http.StatusNoContent {
		t.Fatalf("mode status %d", rec.Code)
	}
	if gotMode != "Global" {
		t.Fatalf("mode %q", gotMode)
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/control/proxies", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("proxies status %d", rec.Code)
	}
	var ps map[string]clashapi.Proxy
	if err := json.Unmarshal(rec.Body.Bytes(), &ps); err != nil {
		t.Fatal(err)
	}
	if ps["proxy"].Now != "vpsA" || len(ps["proxy"].All) != 2 {
		t.Fatalf("proxies %+v", ps)
	}
}
