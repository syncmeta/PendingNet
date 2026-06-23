# sbtally Phase 3 (part A) — Clash API client + config import

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Two fully headless-testable Go pieces of the control layer: (1) a Clash API client that performs the runtime switches (VPS/protocol selectors + routing mode), and (2) a config importer that extracts proxy outbounds from a user's existing sing-box config. The config *generator* is Phase 3c (separate plan, validated with `sing-box check`).

**Architecture:** `internal/clashapi` wraps the mihomo/clash REST API (`PATCH /configs` for mode, `PUT /proxies/{name}` for selectors, `GET /proxies` to read state) — verified against `httptest` (and runnable against the existing `cmd/mockclash`). `internal/sbconfig` gets `import.go`, which parses a sing-box config's `outbounds` array and returns the non-builtin (server) outbounds as `{Tag, Type, Raw}` for the generator to re-emit.

**Tech Stack:** Go stdlib `net/http`, `encoding/json`, `httptest`.

---

## File Structure

```
internal/clashapi/
  client.go        # Client: SetMode, SelectProxy, Proxies
  client_test.go   # httptest assertions on method/path/body/auth
internal/sbconfig/
  import.go        # Outbound + ExtractOutbounds
  import_test.go
```

---

## Task 1: Clash API client

**Files:** Create `internal/clashapi/client.go`, `internal/clashapi/client_test.go`

- [ ] **Step 1: Write the failing test**

`internal/clashapi/client_test.go`:
```go
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/clashapi/ -v`
Expected: FAIL (undefined: New).

- [ ] **Step 3: Implement**

`internal/clashapi/client.go`:
```go
// Package clashapi performs runtime switches against the sing-box Clash API:
// routing mode (PATCH /configs) and selector outbounds (PUT /proxies/{name}).
package clashapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

type Client struct {
	base   string
	secret string
	http   *http.Client
}

func New(addr, secret string) *Client {
	return &Client{base: "http://" + addr, secret: secret, http: &http.Client{Timeout: 5 * time.Second}}
}

type Proxy struct {
	Type string   `json:"type"`
	Now  string   `json:"now"`
	All  []string `json:"all"`
}

func (c *Client) do(ctx context.Context, method, path string, body any) (*http.Response, error) {
	var rdr io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		rdr = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, rdr)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.secret != "" {
		req.Header.Set("Authorization", "Bearer "+c.secret)
	}
	return c.http.Do(req)
}

func (c *Client) SetMode(ctx context.Context, mode string) error {
	resp, err := c.do(ctx, http.MethodPatch, "/configs", map[string]string{"mode": mode})
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("set mode: status %d", resp.StatusCode)
	}
	return nil
}

func (c *Client) SelectProxy(ctx context.Context, selector, name string) error {
	resp, err := c.do(ctx, http.MethodPut, "/proxies/"+selector, map[string]string{"name": name})
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("select proxy: status %d", resp.StatusCode)
	}
	return nil
}

func (c *Client) Proxies(ctx context.Context) (map[string]Proxy, error) {
	resp, err := c.do(ctx, http.MethodGet, "/proxies", nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var wrap struct {
		Proxies map[string]Proxy `json:"proxies"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&wrap); err != nil {
		return nil, err
	}
	return wrap.Proxies, nil
}
```

- [ ] **Step 4: Run to verify pass**

Run: `go test ./internal/clashapi/ -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add internal/clashapi/client.go internal/clashapi/client_test.go
git commit -m "feat(clashapi): runtime client for mode + selector switching"
```

---

## Task 2: Config import (extract outbounds)

**Files:** Create `internal/sbconfig/import.go`, `internal/sbconfig/import_test.go`

- [ ] **Step 1: Write the failing test**

`internal/sbconfig/import_test.go`:
```go
package sbconfig

import "testing"

func TestExtractOutboundsSkipsBuiltins(t *testing.T) {
	cfg := []byte(`{
	  "outbounds": [
	    {"type":"vless","tag":"vpsA-reality","server":"1.2.3.4","uuid":"x"},
	    {"type":"hysteria2","tag":"vpsA-hy2","server":"1.2.3.4"},
	    {"type":"selector","tag":"proxy","outbounds":["vpsA-reality"]},
	    {"type":"direct","tag":"direct"},
	    {"type":"block","tag":"block"}
	  ]}`)
	obs, err := ExtractOutbounds(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if len(obs) != 2 {
		t.Fatalf("got %d outbounds, want 2: %+v", len(obs), obs)
	}
	if obs[0].Tag != "vpsA-reality" || obs[0].Type != "vless" {
		t.Fatalf("got %+v", obs[0])
	}
	// Raw must round-trip the original object
	if !contains(string(obs[1].Raw), `"hysteria2"`) {
		t.Fatalf("raw missing type: %s", obs[1].Raw)
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || indexOf(s, sub) >= 0)
}
func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/sbconfig/ -v`
Expected: FAIL (undefined: ExtractOutbounds).

- [ ] **Step 3: Implement**

`internal/sbconfig/import.go`:
```go
// Package sbconfig imports and (in Phase 3c) generates sing-box configs.
package sbconfig

import "encoding/json"

// Outbound is one proxy outbound lifted from an existing config.
type Outbound struct {
	Tag  string
	Type string
	Raw  json.RawMessage // the original outbound object, re-emittable verbatim
}

var builtinOutbound = map[string]bool{
	"direct": true, "block": true, "dns": true, "selector": true, "urltest": true,
}

// ExtractOutbounds returns the server (non-builtin) outbounds from a sing-box config.
func ExtractOutbounds(configJSON []byte) ([]Outbound, error) {
	var cfg struct {
		Outbounds []json.RawMessage `json:"outbounds"`
	}
	if err := json.Unmarshal(configJSON, &cfg); err != nil {
		return nil, err
	}
	out := []Outbound{}
	for _, raw := range cfg.Outbounds {
		var head struct {
			Tag  string `json:"tag"`
			Type string `json:"type"`
		}
		if err := json.Unmarshal(raw, &head); err != nil {
			return nil, err
		}
		if builtinOutbound[head.Type] {
			continue
		}
		out = append(out, Outbound{Tag: head.Tag, Type: head.Type, Raw: raw})
	}
	return out, nil
}
```

- [ ] **Step 4: Run to verify pass**

Run: `go test ./internal/sbconfig/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/sbconfig/import.go internal/sbconfig/import_test.go
git commit -m "feat(sbconfig): import/extract server outbounds from a sing-box config"
```

---

## Self-Review

**Spec coverage (§9):** Clash client (switch VPS/protocol/mode) → Task 1; config import (extract outbounds) → Task 2. Config *generator* (§9.1/9.3/9.4/9.5) is intentionally deferred to Phase 3c (its own `sing-box check`-driven plan).

**Placeholder scan:** none — full code + commands.

**Type consistency:** `Client`/`New`/`SetMode`/`SelectProxy`/`Proxies`/`Proxy{Type,Now,All}` consistent across test + impl; `Outbound{Tag,Type,Raw}` + `ExtractOutbounds` consistent.

**Verification note:** Both pieces are fully headless. Task 1 can also be smoke-run against `cmd/mockclash` (its `/proxies/` and `/configs` stubs return 204). Their real effect on traffic is part of the final sing-box verification.
```
