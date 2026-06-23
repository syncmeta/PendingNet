package clashapi

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSetMode(t *testing.T) {
	var gotMethod, gotPath, gotAuth string
	var gotBody map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath, gotAuth = r.Method, r.URL.Path, r.Header.Get("Authorization")
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &gotBody)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	c := New(strings.TrimPrefix(srv.URL, "http://"), "sek")
	if err := c.SetMode(context.Background(), "Global"); err != nil {
		t.Fatal(err)
	}
	if gotMethod != http.MethodPatch || gotPath != "/configs" {
		t.Fatalf("got %s %s", gotMethod, gotPath)
	}
	if gotAuth != "Bearer sek" {
		t.Fatalf("auth %q", gotAuth)
	}
	if gotBody["mode"] != "Global" {
		t.Fatalf("body %+v", gotBody)
	}
}

func TestSelectProxy(t *testing.T) {
	var gotPath string
	var gotBody map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &gotBody)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	c := New(strings.TrimPrefix(srv.URL, "http://"), "")
	if err := c.SelectProxy(context.Background(), "proxy", "vpsB"); err != nil {
		t.Fatal(err)
	}
	if gotPath != "/proxies/proxy" {
		t.Fatalf("path %q", gotPath)
	}
	if gotBody["name"] != "vpsB" {
		t.Fatalf("body %+v", gotBody)
	}
}

func TestProxies(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"proxies":{"proxy":{"type":"Selector","now":"vpsA","all":["vpsA","vpsB"]}}}`))
	}))
	defer srv.Close()

	c := New(strings.TrimPrefix(srv.URL, "http://"), "")
	ps, err := c.Proxies(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if ps["proxy"].Now != "vpsA" || len(ps["proxy"].All) != 2 {
		t.Fatalf("got %+v", ps["proxy"])
	}
}
