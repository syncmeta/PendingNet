# sbtally Phase 1 — Stats Backbone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Go collector that subscribes to a sing-box Clash API `/connections` WebSocket, accounts per-(app, host) traffic into SQLite, and exposes it via a local JSON/SSE API and a CLI.

**Architecture:** A single Go binary `sbtally` with subcommands. `internal/source` taps the Clash API (and defines the swappable `ConnectionsSource`). `internal/core` holds the correctness-critical delta accumulator, the SQLite store, queries, and byte formatting. `internal/daemon` wires source→accumulator→store, computes live rates, and serves HTTP/SSE. `internal/cli` renders reports. Everything is verifiable headlessly: pure logic via synthetic snapshots, the WS client against a mock server — no real sing-box needed for Phase 1.

**Tech Stack:** Go 1.26, `modernc.org/sqlite` (pure-Go, no cgo), `github.com/coder/websocket`, stdlib (`net/http`, `database/sql`, `encoding/json`, `text/tabwriter`, `flag`).

**Key invariant (do not "fix"):** The accumulator does **not** reset on WS reconnect. Clash connection IDs are stable while a connection lives, so a delta from the last-seen cumulative counter correctly captures bytes transferred during a disconnect gap; vanished IDs are dropped; restarted-sing-box IDs start fresh. Resetting would lose gap bytes.

---

## File Structure

```
sbtally/
  go.mod                          # module sbtally
  internal/source/
    source.go                     # Connection, Snapshot, ConnectionsSource interface
    decode.go                     # decodeSnapshot([]byte,int64) — pure, unit-tested
    decode_test.go
    clashws.go                    # ClashSource: WS client implementing the interface
    clashws_test.go               # against a mock coder/websocket server
  internal/core/
    dto.go                        # AppStat/DomainStat/AppDetail/Point/Summary/LiveAppGroup
    keys.go                       # AppKey/HostKey fallback helpers
    keys_test.go
    accumulator.go                # delta accounting -> []Rollup
    accumulator_test.go
    store.go                      # OpenStore + WriteRollups (UPSERT)
    store_test.go
    query.go                      # Apps/Domains/AppDetail/Series/Summary
    query_test.go
    bytes.go                      # HumanBytes
    bytes_test.go
  internal/daemon/
    live.go                       # computeLive(prev,cur) + LiveHub (SSE broadcaster)
    live_test.go
    server.go                     # http.ServeMux over the store + /api/live
    server_test.go
    window.go                     # parseWindow("7d") -> (since,until)
    window_test.go
    daemon.go                     # Run loop: source -> accumulator -> store + live
    daemon_test.go
  internal/cli/
    cli.go                        # apps/domains/app + table render; live (SSE client)
    cli_test.go
  cmd/sbtally/
    main.go                       # subcommand dispatch
```

`internal/server` from the spec is folded into `internal/daemon` for Phase 1 (fewer packages; same responsibilities).

---

## Task 1: Module skeleton + dependencies

**Files:**
- Create: `go.mod`
- Create: `cmd/sbtally/main.go` (temporary stub)

- [ ] **Step 1: Initialize the module and fetch deps**

Run:
```bash
cd /Users/hey/Untitled/Pendingname/PendingNet
go mod init sbtally
go get modernc.org/sqlite@latest
go get github.com/coder/websocket@latest
```
Expected: `go.mod` + `go.sum` created listing both modules.

- [ ] **Step 2: Add a stub main so the module builds**

`cmd/sbtally/main.go`:
```go
package main

import "fmt"

func main() {
	fmt.Println("sbtally")
}
```

- [ ] **Step 3: Verify it builds**

Run: `go build ./...`
Expected: no output, exit 0.

- [ ] **Step 4: Commit**

```bash
git add go.mod go.sum cmd/sbtally/main.go
git commit -m "chore: init sbtally Go module + deps"
```

---

## Task 2: Source types + interface

**Files:**
- Create: `internal/source/source.go`

- [ ] **Step 1: Define the connection model and interface**

`internal/source/source.go`:
```go
package source

import "context"

// Connection is one active connection as reported by the Clash API.
type Connection struct {
	ID          string
	Process     string // metadata.process     (may be empty)
	ProcessPath string // metadata.processPath  (may be empty)
	Host        string // metadata.host (sniffed domain; may be empty)
	DestIP      string
	DestPort    string
	Network     string
	Chains      []string
	Rule        string
	Upload      int64 // cumulative bytes for this connection
	Download    int64
}

// Snapshot is a full set of active connections at a point in time.
type Snapshot struct {
	At          int64 // unix seconds
	Connections []Connection
}

// ConnectionsSource is the swappable data tap.
type ConnectionsSource interface {
	Snapshots(ctx context.Context) (<-chan Snapshot, error)
}
```

- [ ] **Step 2: Verify it compiles**

Run: `go build ./internal/source/`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add internal/source/source.go
git commit -m "feat(source): connection model + ConnectionsSource interface"
```

---

## Task 3: Key-fallback helpers

**Files:**
- Create: `internal/core/keys.go`
- Test: `internal/core/keys_test.go`

- [ ] **Step 1: Write the failing test**

`internal/core/keys_test.go`:
```go
package core

import (
	"testing"

	"sbtally/internal/source"
)

func TestAppKeyFallback(t *testing.T) {
	cases := []struct {
		c    source.Connection
		want string
	}{
		{source.Connection{Process: "Safari"}, "Safari"},
		{source.Connection{ProcessPath: "/Applications/Foo.app/Contents/MacOS/Foo"}, "Foo"},
		{source.Connection{Host: "example.com"}, "example.com"},
		{source.Connection{}, "unknown"},
	}
	for _, tc := range cases {
		if got := AppKey(tc.c); got != tc.want {
			t.Errorf("AppKey(%+v)=%q want %q", tc.c, got, tc.want)
		}
	}
}

func TestHostKeyFallback(t *testing.T) {
	if got := HostKey(source.Connection{Host: "a.com", DestIP: "1.2.3.4"}); got != "a.com" {
		t.Errorf("got %q want a.com", got)
	}
	if got := HostKey(source.Connection{DestIP: "1.2.3.4"}); got != "1.2.3.4" {
		t.Errorf("got %q want 1.2.3.4", got)
	}
	if got := HostKey(source.Connection{}); got != "unknown" {
		t.Errorf("got %q want unknown", got)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/core/ -run TestAppKeyFallback -v`
Expected: FAIL (undefined: AppKey).

- [ ] **Step 3: Implement**

`internal/core/keys.go`:
```go
package core

import (
	"path/filepath"

	"sbtally/internal/source"
)

// AppKey picks the best application label: process name, else binary basename,
// else sniffed host, else "unknown".
func AppKey(c source.Connection) string {
	if c.Process != "" {
		return c.Process
	}
	if c.ProcessPath != "" {
		return filepath.Base(c.ProcessPath)
	}
	if c.Host != "" {
		return c.Host
	}
	return "unknown"
}

// HostKey picks host, else destination IP, else "unknown".
func HostKey(c source.Connection) string {
	if c.Host != "" {
		return c.Host
	}
	if c.DestIP != "" {
		return c.DestIP
	}
	return "unknown"
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/core/ -run 'TestAppKeyFallback|TestHostKeyFallback' -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/core/keys.go internal/core/keys_test.go
git commit -m "feat(core): app/host key fallback helpers"
```

---

## Task 4: Delta accumulator

**Files:**
- Create: `internal/core/accumulator.go`
- Test: `internal/core/accumulator_test.go`

- [ ] **Step 1: Write the failing test**

`internal/core/accumulator_test.go`:
```go
package core

import (
	"sort"
	"testing"

	"sbtally/internal/source"
)

func rollupMap(rs []Rollup) map[string]Rollup {
	m := map[string]Rollup{}
	for _, r := range rs {
		m[r.App+"|"+r.Host] = r
	}
	return m
}

func TestAccumulatorDeltasAcrossSnapshots(t *testing.T) {
	a := NewAccumulator()
	// t=0: one Safari connection at 100/10
	a.Add(source.Snapshot{At: 0, Connections: []source.Connection{
		{ID: "c1", Process: "Safari", Host: "a.com", Upload: 100, Download: 10},
	}})
	// t=1: same connection grew to 300/40 -> delta 200/30
	a.Add(source.Snapshot{At: 1, Connections: []source.Connection{
		{ID: "c1", Process: "Safari", Host: "a.com", Upload: 300, Download: 40},
	}})
	got := rollupMap(a.Pending())
	r := got["Safari|a.com"]
	if r.Upload != 300 || r.Download != 40 {
		t.Fatalf("Safari|a.com = %d/%d want 300/40", r.Upload, r.Download)
	}
	if r.Bucket != 0 {
		t.Fatalf("bucket=%d want 0", r.Bucket)
	}
}

func TestAccumulatorClosedConnectionNotDoubleCounted(t *testing.T) {
	a := NewAccumulator()
	a.Add(source.Snapshot{At: 0, Connections: []source.Connection{
		{ID: "c1", Process: "X", Host: "h", Upload: 50, Download: 5},
	}})
	_ = a.Pending() // flush; c1 still tracked in last
	// c1 closed (absent); a new c2 appears
	a.Add(source.Snapshot{At: 1, Connections: []source.Connection{
		{ID: "c2", Process: "X", Host: "h", Upload: 7, Download: 1},
	}})
	got := rollupMap(a.Pending())
	// only c2's 7/1 should be counted now
	r := got["X|h"]
	if r.Upload != 7 || r.Download != 1 {
		t.Fatalf("X|h = %d/%d want 7/1", r.Upload, r.Download)
	}
	// internal: c1 must have been evicted
	if len(a.last) != 1 {
		t.Fatalf("last has %d entries want 1", len(a.last))
	}
}

func TestAccumulatorNegativeDeltaClamped(t *testing.T) {
	a := NewAccumulator()
	a.Add(source.Snapshot{At: 0, Connections: []source.Connection{
		{ID: "c1", Process: "X", Host: "h", Upload: 500, Download: 50},
	}})
	_ = a.Pending()
	// counter went backwards (anomaly) -> delta clamped to 0
	a.Add(source.Snapshot{At: 1, Connections: []source.Connection{
		{ID: "c1", Process: "X", Host: "h", Upload: 100, Download: 10},
	}})
	if rs := a.Pending(); len(rs) != 0 {
		t.Fatalf("expected no rollups, got %+v", rs)
	}
}

func TestAccumulatorHourBucketing(t *testing.T) {
	a := NewAccumulator()
	a.Add(source.Snapshot{At: 0, Connections: []source.Connection{
		{ID: "c1", Process: "X", Host: "h", Upload: 10},
	}})
	a.Add(source.Snapshot{At: 3600, Connections: []source.Connection{ // next hour
		{ID: "c1", Process: "X", Host: "h", Upload: 30}, // delta 20 into hour 3600
	}})
	rs := a.Pending()
	sort.Slice(rs, func(i, j int) bool { return rs[i].Bucket < rs[j].Bucket })
	if len(rs) != 2 || rs[0].Bucket != 0 || rs[0].Upload != 10 || rs[1].Bucket != 3600 || rs[1].Upload != 20 {
		t.Fatalf("unexpected rollups: %+v", rs)
	}
}

func TestAccumulatorMissingProcessFallsBackToUnknown(t *testing.T) {
	a := NewAccumulator()
	a.Add(source.Snapshot{At: 0, Connections: []source.Connection{
		{ID: "c1", DestIP: "9.9.9.9", Upload: 5, Download: 1},
	}})
	got := rollupMap(a.Pending())
	if _, ok := got["unknown|9.9.9.9"]; !ok {
		t.Fatalf("expected unknown|9.9.9.9, got %+v", got)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/core/ -run TestAccumulator -v`
Expected: FAIL (undefined: NewAccumulator, Rollup).

- [ ] **Step 3: Implement**

`internal/core/accumulator.go`:
```go
package core

import "sbtally/internal/source"

// Rollup is accumulated traffic for one (hour, app, host) bucket.
type Rollup struct {
	Bucket   int64
	App      string
	Host     string
	Upload   int64
	Download int64
}

type counters struct{ up, down int64 }

type bucketKey struct {
	bucket int64
	app    string
	host   string
}

// Accumulator turns cumulative per-connection counters into per-(hour,app,host) deltas.
type Accumulator struct {
	last    map[string]counters
	pending map[bucketKey]counters
}

func NewAccumulator() *Accumulator {
	return &Accumulator{
		last:    make(map[string]counters),
		pending: make(map[bucketKey]counters),
	}
}

func hourFloor(ts int64) int64 { return ts - ((ts%3600)+3600)%3600 }

// Add folds one snapshot into pending deltas.
func (a *Accumulator) Add(s source.Snapshot) {
	bucket := hourFloor(s.At)
	seen := make(map[string]struct{}, len(s.Connections))
	for _, c := range s.Connections {
		seen[c.ID] = struct{}{}
		prev := a.last[c.ID]
		du := c.Upload - prev.up
		dd := c.Download - prev.down
		if du < 0 {
			du = 0
		}
		if dd < 0 {
			dd = 0
		}
		if du != 0 || dd != 0 {
			k := bucketKey{bucket, AppKey(c), HostKey(c)}
			p := a.pending[k]
			p.up += du
			p.down += dd
			a.pending[k] = p
		}
		a.last[c.ID] = counters{c.Upload, c.Download}
	}
	for id := range a.last {
		if _, ok := seen[id]; !ok {
			delete(a.last, id)
		}
	}
}

// Pending returns and clears accumulated deltas for flushing to the store.
func (a *Accumulator) Pending() []Rollup {
	out := make([]Rollup, 0, len(a.pending))
	for k, v := range a.pending {
		out = append(out, Rollup{Bucket: k.bucket, App: k.app, Host: k.host, Upload: v.up, Download: v.down})
	}
	a.pending = make(map[bucketKey]counters)
	return out
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/core/ -run TestAccumulator -v`
Expected: PASS (all 5).

- [ ] **Step 5: Commit**

```bash
git add internal/core/accumulator.go internal/core/accumulator_test.go
git commit -m "feat(core): delta accumulator with hour bucketing"
```

---

## Task 5: SQLite store

**Files:**
- Create: `internal/core/store.go`
- Test: `internal/core/store_test.go`

- [ ] **Step 1: Write the failing test**

`internal/core/store_test.go`:
```go
package core

import (
	"path/filepath"
	"testing"
)

func TestStoreUpsertAccumulates(t *testing.T) {
	path := filepath.Join(t.TempDir(), "t.db")
	s, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	if err := s.WriteRollups([]Rollup{{Bucket: 0, App: "X", Host: "h", Upload: 10, Download: 1}}); err != nil {
		t.Fatal(err)
	}
	// same key again -> should accumulate, not overwrite
	if err := s.WriteRollups([]Rollup{{Bucket: 0, App: "X", Host: "h", Upload: 5, Download: 2}}); err != nil {
		t.Fatal(err)
	}
	apps, err := s.Apps(0, 3600, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(apps) != 1 || apps[0].Upload != 15 || apps[0].Download != 3 || apps[0].Total != 18 {
		t.Fatalf("got %+v want one row 15/3/18", apps)
	}
}
```

(Note: this test also exercises `Apps`, implemented in Task 6. Implement `store.go` now; the test will compile only after Task 6. To keep this task self-contained, temporarily assert via a raw count, then Task 6 swaps to `Apps`. Simpler: implement Task 5 and Task 6 back-to-back and run their tests together at the end of Task 6.)

- [ ] **Step 2: Implement the store**

`internal/core/store.go`:
```go
package core

import (
	"database/sql"

	_ "modernc.org/sqlite"
)

type Store struct{ db *sql.DB }

func OpenStore(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	for _, p := range []string{"PRAGMA journal_mode=WAL", "PRAGMA busy_timeout=5000"} {
		if _, err := db.Exec(p); err != nil {
			db.Close()
			return nil, err
		}
	}
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS traffic (
		bucket INTEGER NOT NULL, app TEXT NOT NULL, host TEXT NOT NULL,
		upload INTEGER NOT NULL, download INTEGER NOT NULL,
		PRIMARY KEY (bucket, app, host))`); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

// WriteRollups UPSERT-accumulates rollups in one transaction.
func (s *Store) WriteRollups(rs []Rollup) error {
	if len(rs) == 0 {
		return nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	stmt, err := tx.Prepare(`INSERT INTO traffic (bucket,app,host,upload,download) VALUES (?,?,?,?,?)
		ON CONFLICT(bucket,app,host) DO UPDATE SET
		  upload=upload+excluded.upload, download=download+excluded.download`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, r := range rs {
		if _, err := stmt.Exec(r.Bucket, r.App, r.Host, r.Upload, r.Download); err != nil {
			return err
		}
	}
	return tx.Commit()
}
```

- [ ] **Step 3: Commit (test runs after Task 6)**

```bash
git add internal/core/store.go internal/core/store_test.go
git commit -m "feat(core): SQLite store with UPSERT-accumulating rollups"
```

---

## Task 6: Queries + DTOs

**Files:**
- Create: `internal/core/dto.go`
- Create: `internal/core/query.go`
- Test: `internal/core/query_test.go`

- [ ] **Step 1: Define DTOs**

`internal/core/dto.go`:
```go
package core

type AppStat struct {
	App      string `json:"app"`
	Upload   int64  `json:"upload"`
	Download int64  `json:"download"`
	Total    int64  `json:"total"`
}

type DomainStat struct {
	Host     string `json:"host"`
	Upload   int64  `json:"upload"`
	Download int64  `json:"download"`
	Total    int64  `json:"total"`
}

type AppDetail struct {
	App     string       `json:"app"`
	Domains []DomainStat `json:"domains"`
}

type Point struct {
	Bucket   int64 `json:"bucket"`
	Upload   int64 `json:"upload"`
	Download int64 `json:"download"`
}

type Summary struct {
	Since    int64 `json:"since"`
	Upload   int64 `json:"upload"`
	Download int64 `json:"download"`
	Total    int64 `json:"total"`
	Apps     int   `json:"apps"`
	Hosts    int   `json:"hosts"`
}

type LiveAppGroup struct {
	App      string `json:"app"`
	UpRate   int64  `json:"upRate"`
	DownRate int64  `json:"downRate"`
	Conns    int    `json:"conns"`
	TopHost  string `json:"topHost"`
}
```

- [ ] **Step 2: Write the failing test**

`internal/core/query_test.go`:
```go
package core

import (
	"path/filepath"
	"testing"
)

func seed(t *testing.T) *Store {
	t.Helper()
	s, err := OpenStore(filepath.Join(t.TempDir(), "q.db"))
	if err != nil {
		t.Fatal(err)
	}
	rs := []Rollup{
		{Bucket: 0, App: "Safari", Host: "a.com", Upload: 100, Download: 10},
		{Bucket: 0, App: "Safari", Host: "b.com", Upload: 50, Download: 5},
		{Bucket: 3600, App: "Mail", Host: "c.com", Upload: 200, Download: 20},
	}
	if err := s.WriteRollups(rs); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestApps(t *testing.T) {
	s := seed(t)
	defer s.Close()
	apps, err := s.Apps(0, 7200, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(apps) != 2 || apps[0].App != "Mail" || apps[0].Total != 220 {
		t.Fatalf("got %+v; want Mail first (220)", apps)
	}
	if apps[1].App != "Safari" || apps[1].Total != 165 {
		t.Fatalf("got %+v; want Safari second (165)", apps)
	}
}

func TestAppsSinceFilter(t *testing.T) {
	s := seed(t)
	defer s.Close()
	apps, err := s.Apps(3600, 7200, 0) // only the Mail bucket
	if err != nil {
		t.Fatal(err)
	}
	if len(apps) != 1 || apps[0].App != "Mail" {
		t.Fatalf("got %+v want only Mail", apps)
	}
}

func TestAppDetail(t *testing.T) {
	s := seed(t)
	defer s.Close()
	d, err := s.AppDetail("Safari", 0, 7200)
	if err != nil {
		t.Fatal(err)
	}
	if len(d.Domains) != 2 || d.Domains[0].Host != "a.com" {
		t.Fatalf("got %+v want a.com first", d.Domains)
	}
}

func TestSummary(t *testing.T) {
	s := seed(t)
	defer s.Close()
	sm, err := s.Summary(0, 7200)
	if err != nil {
		t.Fatal(err)
	}
	if sm.Total != 385 || sm.Apps != 2 || sm.Hosts != 3 {
		t.Fatalf("got %+v want total 385 apps 2 hosts 3", sm)
	}
}

func TestSeries(t *testing.T) {
	s := seed(t)
	defer s.Close()
	pts, err := s.Series("", 0, 7200)
	if err != nil {
		t.Fatal(err)
	}
	if len(pts) != 2 || pts[0].Bucket != 0 || pts[1].Bucket != 3600 {
		t.Fatalf("got %+v want two buckets ordered", pts)
	}
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `go test ./internal/core/ -run 'TestApps|TestAppDetail|TestSummary|TestSeries|TestStoreUpsert' -v`
Expected: FAIL (undefined query methods).

- [ ] **Step 4: Implement queries**

`internal/core/query.go`:
```go
package core

import "strconv"

func (s *Store) Apps(since, until int64, top int) ([]AppStat, error) {
	q := `SELECT app, COALESCE(SUM(upload),0), COALESCE(SUM(download),0), COALESCE(SUM(upload+download),0) AS total
	      FROM traffic WHERE bucket>=? AND bucket<? GROUP BY app ORDER BY total DESC`
	if top > 0 {
		q += " LIMIT " + strconv.Itoa(top)
	}
	rows, err := s.db.Query(q, since, until)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AppStat
	for rows.Next() {
		var a AppStat
		if err := rows.Scan(&a.App, &a.Upload, &a.Download, &a.Total); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

func (s *Store) Domains(since, until int64, top int) ([]DomainStat, error) {
	q := `SELECT host, COALESCE(SUM(upload),0), COALESCE(SUM(download),0), COALESCE(SUM(upload+download),0) AS total
	      FROM traffic WHERE bucket>=? AND bucket<? GROUP BY host ORDER BY total DESC`
	if top > 0 {
		q += " LIMIT " + strconv.Itoa(top)
	}
	rows, err := s.db.Query(q, since, until)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DomainStat
	for rows.Next() {
		var d DomainStat
		if err := rows.Scan(&d.Host, &d.Upload, &d.Download, &d.Total); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

func (s *Store) AppDetail(app string, since, until int64) (AppDetail, error) {
	rows, err := s.db.Query(`SELECT host, COALESCE(SUM(upload),0), COALESCE(SUM(download),0), COALESCE(SUM(upload+download),0) AS total
		FROM traffic WHERE app=? AND bucket>=? AND bucket<? GROUP BY host ORDER BY total DESC`, app, since, until)
	if err != nil {
		return AppDetail{}, err
	}
	defer rows.Close()
	d := AppDetail{App: app}
	for rows.Next() {
		var ds DomainStat
		if err := rows.Scan(&ds.Host, &ds.Upload, &ds.Download, &ds.Total); err != nil {
			return AppDetail{}, err
		}
		d.Domains = append(d.Domains, ds)
	}
	return d, rows.Err()
}

func (s *Store) Series(app string, since, until int64) ([]Point, error) {
	q := `SELECT bucket, COALESCE(SUM(upload),0), COALESCE(SUM(download),0) FROM traffic WHERE bucket>=? AND bucket<?`
	args := []any{since, until}
	if app != "" {
		q += " AND app=?"
		args = append(args, app)
	}
	q += " GROUP BY bucket ORDER BY bucket"
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Point
	for rows.Next() {
		var p Point
		if err := rows.Scan(&p.Bucket, &p.Upload, &p.Download); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Store) Summary(since, until int64) (Summary, error) {
	row := s.db.QueryRow(`SELECT COALESCE(SUM(upload),0), COALESCE(SUM(download),0),
		COUNT(DISTINCT app), COUNT(DISTINCT host) FROM traffic WHERE bucket>=? AND bucket<?`, since, until)
	sm := Summary{Since: since}
	if err := row.Scan(&sm.Upload, &sm.Download, &sm.Apps, &sm.Hosts); err != nil {
		return Summary{}, err
	}
	sm.Total = sm.Upload + sm.Download
	return sm, nil
}
```

- [ ] **Step 5: Run to verify all core tests pass**

Run: `go test ./internal/core/ -v`
Expected: PASS (keys, accumulator, store, query).

- [ ] **Step 6: Commit**

```bash
git add internal/core/dto.go internal/core/query.go internal/core/query_test.go
git commit -m "feat(core): DTOs + apps/domains/appDetail/series/summary queries"
```

---

## Task 7: Byte humanization

**Files:**
- Create: `internal/core/bytes.go`
- Test: `internal/core/bytes_test.go`

- [ ] **Step 1: Write the failing test**

`internal/core/bytes_test.go`:
```go
package core

import "testing"

func TestHumanBytes(t *testing.T) {
	cases := map[int64]string{
		0:          "0 B",
		512:        "512 B",
		1024:       "1.0 KiB",
		1536:       "1.5 KiB",
		1048576:    "1.0 MiB",
		1073741824: "1.0 GiB",
	}
	for in, want := range cases {
		if got := HumanBytes(in); got != want {
			t.Errorf("HumanBytes(%d)=%q want %q", in, got, want)
		}
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/core/ -run TestHumanBytes -v`
Expected: FAIL (undefined: HumanBytes).

- [ ] **Step 3: Implement**

`internal/core/bytes.go`:
```go
package core

import "fmt"

// HumanBytes formats bytes with 1024-based units.
func HumanBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for x := n / unit; x >= unit; x /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/core/ -run TestHumanBytes -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/core/bytes.go internal/core/bytes_test.go
git commit -m "feat(core): HumanBytes formatter"
```

---

## Task 8: Snapshot decoding (Clash JSON → Snapshot)

**Files:**
- Create: `internal/source/decode.go`
- Test: `internal/source/decode_test.go`

- [ ] **Step 1: Write the failing test**

`internal/source/decode_test.go`:
```go
package source

import "testing"

func TestDecodeSnapshot(t *testing.T) {
	raw := []byte(`{
	  "downloadTotal": 999, "uploadTotal": 888,
	  "connections": [
	    {"id":"c1","metadata":{"network":"tcp","destinationIP":"1.2.3.4","destinationPort":"443",
	      "host":"example.com","process":"Safari","processPath":"/x/Safari"},
	     "upload":100,"download":200,"chains":["proxy","auto"],"rule":"RuleSet"}
	  ]}`)
	s, err := decodeSnapshot(raw, 1234)
	if err != nil {
		t.Fatal(err)
	}
	if s.At != 1234 || len(s.Connections) != 1 {
		t.Fatalf("got At=%d conns=%d", s.At, len(s.Connections))
	}
	c := s.Connections[0]
	if c.ID != "c1" || c.Process != "Safari" || c.Host != "example.com" ||
		c.DestIP != "1.2.3.4" || c.Upload != 100 || c.Download != 200 ||
		len(c.Chains) != 2 || c.Rule != "RuleSet" {
		t.Fatalf("bad decode: %+v", c)
	}
}

func TestDecodeSnapshotNullConnections(t *testing.T) {
	s, err := decodeSnapshot([]byte(`{"connections":null}`), 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Connections) != 0 {
		t.Fatalf("want 0 connections")
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/source/ -run TestDecodeSnapshot -v`
Expected: FAIL (undefined: decodeSnapshot).

- [ ] **Step 3: Implement**

`internal/source/decode.go`:
```go
package source

import "encoding/json"

type wsMetadata struct {
	Network         string `json:"network"`
	DestinationIP   string `json:"destinationIP"`
	DestinationPort string `json:"destinationPort"`
	Host            string `json:"host"`
	Process         string `json:"process"`
	ProcessPath     string `json:"processPath"`
}

type wsConn struct {
	ID       string     `json:"id"`
	Metadata wsMetadata `json:"metadata"`
	Upload   int64      `json:"upload"`
	Download int64      `json:"download"`
	Chains   []string   `json:"chains"`
	Rule     string     `json:"rule"`
}

type wsSnapshot struct {
	Connections []wsConn `json:"connections"`
}

func decodeSnapshot(data []byte, at int64) (Snapshot, error) {
	var w wsSnapshot
	if err := json.Unmarshal(data, &w); err != nil {
		return Snapshot{}, err
	}
	s := Snapshot{At: at, Connections: make([]Connection, 0, len(w.Connections))}
	for _, c := range w.Connections {
		s.Connections = append(s.Connections, Connection{
			ID: c.ID, Process: c.Metadata.Process, ProcessPath: c.Metadata.ProcessPath,
			Host: c.Metadata.Host, DestIP: c.Metadata.DestinationIP, DestPort: c.Metadata.DestinationPort,
			Network: c.Metadata.Network, Chains: c.Chains, Rule: c.Rule,
			Upload: c.Upload, Download: c.Download,
		})
	}
	return s, nil
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/source/ -run TestDecodeSnapshot -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/source/decode.go internal/source/decode_test.go
git commit -m "feat(source): decode Clash /connections JSON into Snapshot"
```

---

## Task 9: Clash WebSocket source

**Files:**
- Create: `internal/source/clashws.go`
- Test: `internal/source/clashws_test.go`

- [ ] **Step 1: Write the failing integration test (mock WS server)**

`internal/source/clashws_test.go`:
```go
package source

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestClashSourceReceivesSnapshots(t *testing.T) {
	gotAuth := make(chan string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth <- r.Header.Get("Authorization")
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close(websocket.StatusNormalClosure, "")
		_ = c.Write(r.Context(), websocket.MessageText, []byte(
			`{"connections":[{"id":"c1","metadata":{"process":"Safari","host":"a.com"},"upload":5,"download":1}]}`))
		<-r.Context().Done()
	}))
	defer srv.Close()

	addr := strings.TrimPrefix(srv.URL, "http://")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cs := NewClashSource(addr, "sek")
	ch, err := cs.Snapshots(ctx)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case snap := <-ch:
		if len(snap.Connections) != 1 || snap.Connections[0].Process != "Safari" {
			t.Fatalf("bad snapshot: %+v", snap)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for snapshot")
	}
	if a := <-gotAuth; a != "Bearer sek" {
		t.Fatalf("auth header = %q want Bearer sek", a)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/source/ -run TestClashSource -v`
Expected: FAIL (undefined: NewClashSource).

- [ ] **Step 3: Implement**

`internal/source/clashws.go`:
```go
package source

import (
	"context"
	"net/http"
	"time"

	"github.com/coder/websocket"
)

type ClashSource struct {
	addr   string // host:port
	secret string
}

func NewClashSource(addr, secret string) *ClashSource {
	return &ClashSource{addr: addr, secret: secret}
}

func (cs *ClashSource) Snapshots(ctx context.Context) (<-chan Snapshot, error) {
	ch := make(chan Snapshot)
	go func() {
		defer close(ch)
		backoff := time.Second
		for ctx.Err() == nil {
			err := cs.stream(ctx, ch)
			if ctx.Err() != nil {
				return
			}
			if err != nil {
				time.Sleep(backoff)
				if backoff < 30*time.Second {
					backoff *= 2
				}
				continue
			}
			backoff = time.Second
		}
	}()
	return ch, nil
}

func (cs *ClashSource) stream(ctx context.Context, ch chan<- Snapshot) error {
	u := "ws://" + cs.addr + "/connections"
	opts := &websocket.DialOptions{}
	if cs.secret != "" {
		opts.HTTPHeader = http.Header{"Authorization": {"Bearer " + cs.secret}}
	}
	c, _, err := websocket.Dial(ctx, u, opts)
	if err != nil {
		return err
	}
	defer c.Close(websocket.StatusNormalClosure, "")
	c.SetReadLimit(8 << 20) // connection lists can be large
	for {
		_, data, err := c.Read(ctx)
		if err != nil {
			return err
		}
		snap, err := decodeSnapshot(data, time.Now().Unix())
		if err != nil {
			continue // skip malformed frame
		}
		select {
		case ch <- snap:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/source/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/source/clashws.go internal/source/clashws_test.go
git commit -m "feat(source): Clash API WebSocket source with reconnect"
```

---

## Task 10: Live rate computation + SSE hub

**Files:**
- Create: `internal/daemon/live.go`
- Test: `internal/daemon/live_test.go`

- [ ] **Step 1: Write the failing test**

`internal/daemon/live_test.go`:
```go
package daemon

import (
	"testing"

	"sbtally/internal/source"
)

func TestComputeLiveRates(t *testing.T) {
	prev := source.Snapshot{At: 0, Connections: []source.Connection{
		{ID: "c1", Process: "Safari", Host: "a.com", Upload: 100, Download: 10},
	}}
	cur := source.Snapshot{At: 2, Connections: []source.Connection{ // dt=2s
		{ID: "c1", Process: "Safari", Host: "a.com", Upload: 300, Download: 30}, // +200/+20
	}}
	groups := computeLive(prev, cur)
	if len(groups) != 1 {
		t.Fatalf("want 1 group, got %d", len(groups))
	}
	g := groups[0]
	if g.App != "Safari" || g.UpRate != 100 || g.DownRate != 10 || g.Conns != 1 || g.TopHost != "a.com" {
		t.Fatalf("bad group: %+v", g)
	}
}

func TestComputeLiveNewConnectionCountsFromZero(t *testing.T) {
	prev := source.Snapshot{At: 0}
	cur := source.Snapshot{At: 1, Connections: []source.Connection{
		{ID: "n", Process: "X", Host: "h", Upload: 50, Download: 5},
	}}
	g := computeLive(prev, cur)
	if len(g) != 1 || g[0].UpRate != 50 {
		t.Fatalf("bad: %+v", g)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/daemon/ -run TestComputeLive -v`
Expected: FAIL (undefined: computeLive).

- [ ] **Step 3: Implement**

`internal/daemon/live.go`:
```go
package daemon

import (
	"sync"

	"sbtally/internal/core"
	"sbtally/internal/source"
)

func computeLive(prev, cur source.Snapshot) []core.LiveAppGroup {
	dt := cur.At - prev.At
	if dt <= 0 {
		dt = 1
	}
	prevMap := make(map[string]source.Connection, len(prev.Connections))
	for _, c := range prev.Connections {
		prevMap[c.ID] = c
	}
	type agg struct {
		up, down  int64
		conns     int
		topHost   string
		topBytes  int64
	}
	m := map[string]*agg{}
	for _, c := range cur.Connections {
		p := prevMap[c.ID]
		du := c.Upload - p.Upload
		dd := c.Download - p.Download
		if du < 0 {
			du = 0
		}
		if dd < 0 {
			dd = 0
		}
		app := core.AppKey(c)
		a := m[app]
		if a == nil {
			a = &agg{}
			m[app] = a
		}
		a.up += du
		a.down += dd
		a.conns++
		if tot := c.Upload + c.Download; tot >= a.topBytes {
			a.topBytes = tot
			a.topHost = core.HostKey(c)
		}
	}
	out := make([]core.LiveAppGroup, 0, len(m))
	for app, a := range m {
		out = append(out, core.LiveAppGroup{
			App: app, UpRate: a.up / dt, DownRate: a.down / dt,
			Conns: a.conns, TopHost: a.topHost,
		})
	}
	return out
}

// LiveHub fan-outs live groups to SSE subscribers.
type LiveHub struct {
	mu   sync.Mutex
	subs map[chan []core.LiveAppGroup]struct{}
}

func NewLiveHub() *LiveHub {
	return &LiveHub{subs: map[chan []core.LiveAppGroup]struct{}{}}
}

func (h *LiveHub) Subscribe() chan []core.LiveAppGroup {
	ch := make(chan []core.LiveAppGroup, 4)
	h.mu.Lock()
	h.subs[ch] = struct{}{}
	h.mu.Unlock()
	return ch
}

func (h *LiveHub) Unsubscribe(ch chan []core.LiveAppGroup) {
	h.mu.Lock()
	if _, ok := h.subs[ch]; ok {
		delete(h.subs, ch)
		close(ch)
	}
	h.mu.Unlock()
}

func (h *LiveHub) Publish(groups []core.LiveAppGroup) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs {
		select {
		case ch <- groups:
		default: // drop for slow subscribers
		}
	}
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/daemon/ -run TestComputeLive -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/daemon/live.go internal/daemon/live_test.go
git commit -m "feat(daemon): live rate computation + SSE hub"
```

---

## Task 11: Time-window parsing

**Files:**
- Create: `internal/daemon/window.go`
- Test: `internal/daemon/window_test.go`

- [ ] **Step 1: Write the failing test**

`internal/daemon/window_test.go`:
```go
package daemon

import "testing"

func TestParseWindow(t *testing.T) {
	now := int64(1_000_000)
	cases := []struct {
		in        string
		wantSince int64
	}{
		{"24h", now - 86400},
		{"7d", now - 7*86400},
		{"30m", now - 1800},
		{"", now - 86400}, // default 24h
	}
	for _, tc := range cases {
		since, until := parseWindow(tc.in, now)
		if since != tc.wantSince || until != now {
			t.Errorf("parseWindow(%q)=%d,%d want %d,%d", tc.in, since, until, tc.wantSince, now)
		}
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/daemon/ -run TestParseWindow -v`
Expected: FAIL (undefined: parseWindow).

- [ ] **Step 3: Implement**

`internal/daemon/window.go`:
```go
package daemon

import (
	"strconv"
	"strings"
)

// parseWindow turns "24h"/"7d"/"30m" into (since, until=now). Empty -> 24h.
func parseWindow(s string, now int64) (since, until int64) {
	until = now
	if s == "" {
		return now - 86400, until
	}
	unit := s[len(s)-1]
	n, err := strconv.ParseInt(strings.TrimSpace(s[:len(s)-1]), 10, 64)
	if err != nil {
		return now - 86400, until
	}
	var secs int64
	switch unit {
	case 'd':
		secs = n * 86400
	case 'h':
		secs = n * 3600
	case 'm':
		secs = n * 60
	default:
		secs = 86400
	}
	return now - secs, until
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/daemon/ -run TestParseWindow -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/daemon/window.go internal/daemon/window_test.go
git commit -m "feat(daemon): parseWindow duration helper"
```

---

## Task 12: HTTP/SSE server

**Files:**
- Create: `internal/daemon/server.go`
- Test: `internal/daemon/server_test.go`

- [ ] **Step 1: Write the failing test**

`internal/daemon/server_test.go`:
```go
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

	// Fix "now" so the 24h window includes bucket 0.
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/daemon/ -run TestServer -v`
Expected: FAIL (undefined: NewServer).

- [ ] **Step 3: Implement**

`internal/daemon/server.go`:
```go
package daemon

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"sbtally/internal/core"
)

type nowFunc func() int64

// NewServer builds the read API + live SSE over the store.
func NewServer(store *core.Store, hub *LiveHub, now nowFunc) *http.ServeMux {
	mux := http.NewServeMux()

	writeJSON := func(w http.ResponseWriter, v any) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(v)
	}
	win := func(r *http.Request) (int64, int64) {
		return parseWindow(r.URL.Query().Get("since"), now())
	}
	topOf := func(r *http.Request) int {
		n, _ := strconv.Atoi(r.URL.Query().Get("top"))
		return n
	}

	mux.HandleFunc("/api/summary", func(w http.ResponseWriter, r *http.Request) {
		s, u := win(r)
		v, err := store.Summary(s, u)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		writeJSON(w, v)
	})
	mux.HandleFunc("/api/apps", func(w http.ResponseWriter, r *http.Request) {
		s, u := win(r)
		v, err := store.Apps(s, u, topOf(r))
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		writeJSON(w, v)
	})
	mux.HandleFunc("/api/domains", func(w http.ResponseWriter, r *http.Request) {
		s, u := win(r)
		v, err := store.Domains(s, u, topOf(r))
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		writeJSON(w, v)
	})
	mux.HandleFunc("/api/app/", func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimPrefix(r.URL.Path, "/api/app/")
		if name == "" {
			http.Error(w, "missing app", 400)
			return
		}
		s, u := win(r)
		v, err := store.AppDetail(name, s, u)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		writeJSON(w, v)
	})
	mux.HandleFunc("/api/series", func(w http.ResponseWriter, r *http.Request) {
		s, u := win(r)
		v, err := store.Series(r.URL.Query().Get("name"), s, u)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		writeJSON(w, v)
	})
	mux.HandleFunc("/api/live", func(w http.ResponseWriter, r *http.Request) {
		fl, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "no flush", 500)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		ch := hub.Subscribe()
		defer hub.Unsubscribe(ch)
		for {
			select {
			case <-r.Context().Done():
				return
			case groups, ok := <-ch:
				if !ok {
					return
				}
				b, _ := json.Marshal(groups)
				_, _ = w.Write([]byte("data: "))
				_, _ = w.Write(b)
				_, _ = w.Write([]byte("\n\n"))
				fl.Flush()
			}
		}
	})
	return mux
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/daemon/ -run TestServer -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/daemon/server.go internal/daemon/server_test.go
git commit -m "feat(daemon): JSON read API + live SSE endpoint"
```

---

## Task 13: Daemon run loop

**Files:**
- Create: `internal/daemon/daemon.go`
- Test: `internal/daemon/daemon_test.go`

- [ ] **Step 1: Write the failing test (fake source)**

`internal/daemon/daemon_test.go`:
```go
package daemon

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"sbtally/internal/core"
	"sbtally/internal/source"
)

type fakeSource struct{ snaps []source.Snapshot }

func (f *fakeSource) Snapshots(ctx context.Context) (<-chan source.Snapshot, error) {
	ch := make(chan source.Snapshot)
	go func() {
		defer close(ch)
		for _, s := range f.snaps {
			select {
			case ch <- s:
			case <-ctx.Done():
				return
			}
		}
		<-ctx.Done()
	}()
	return ch, nil
}

func TestDaemonPersistsTraffic(t *testing.T) {
	st, err := core.OpenStore(filepath.Join(t.TempDir(), "d.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	src := &fakeSource{snaps: []source.Snapshot{
		{At: 0, Connections: []source.Connection{{ID: "c1", Process: "Safari", Host: "a.com", Upload: 100, Download: 10}}},
		{At: 1, Connections: []source.Connection{{ID: "c1", Process: "Safari", Host: "a.com", Upload: 300, Download: 40}}},
	}}
	d := New(src, st, NewLiveHub())
	d.FlushInterval = 20 * time.Millisecond

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { _ = d.Run(ctx); close(done) }()

	// wait for a flush, then stop
	time.Sleep(100 * time.Millisecond)
	cancel()
	<-done

	apps, err := st.Apps(0, 3600, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(apps) != 1 || apps[0].Upload != 300 || apps[0].Download != 40 {
		t.Fatalf("got %+v want Safari 300/40", apps)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/daemon/ -run TestDaemonPersists -v`
Expected: FAIL (undefined: New).

- [ ] **Step 3: Implement**

`internal/daemon/daemon.go`:
```go
package daemon

import (
	"context"
	"time"

	"sbtally/internal/core"
	"sbtally/internal/source"
)

type Daemon struct {
	src           source.ConnectionsSource
	store         *core.Store
	acc           *core.Accumulator
	hub           *LiveHub
	FlushInterval time.Duration
}

func New(src source.ConnectionsSource, store *core.Store, hub *LiveHub) *Daemon {
	return &Daemon{
		src: src, store: store, acc: core.NewAccumulator(), hub: hub,
		FlushInterval: 10 * time.Second,
	}
}

func (d *Daemon) Run(ctx context.Context) error {
	ch, err := d.src.Snapshots(ctx)
	if err != nil {
		return err
	}
	ticker := time.NewTicker(d.FlushInterval)
	defer ticker.Stop()
	var prev *source.Snapshot
	for {
		select {
		case <-ctx.Done():
			d.flush()
			return ctx.Err()
		case snap, ok := <-ch:
			if !ok {
				d.flush()
				return nil
			}
			d.acc.Add(snap)
			if prev != nil {
				d.hub.Publish(computeLive(*prev, snap))
			}
			s := snap
			prev = &s
		case <-ticker.C:
			d.flush()
		}
	}
}

func (d *Daemon) flush() { _ = d.store.WriteRollups(d.acc.Pending()) }
```

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/daemon/ -v`
Expected: PASS (all daemon tests).

- [ ] **Step 5: Commit**

```bash
git add internal/daemon/daemon.go internal/daemon/daemon_test.go
git commit -m "feat(daemon): run loop wiring source->accumulator->store+live"
```

---

## Task 14: CLI report rendering

**Files:**
- Create: `internal/cli/cli.go`
- Test: `internal/cli/cli_test.go`

- [ ] **Step 1: Write the failing test**

`internal/cli/cli_test.go`:
```go
package cli

import (
	"strings"
	"testing"

	"sbtally/internal/core"
)

func TestRenderAppsTable(t *testing.T) {
	apps := []core.AppStat{
		{App: "Safari", Upload: 1048576, Download: 2097152, Total: 3145728},
		{App: "Mail", Upload: 1024, Download: 0, Total: 1024},
	}
	out := RenderApps(apps)
	if !strings.Contains(out, "Safari") || !strings.Contains(out, "3.0 MiB") {
		t.Fatalf("missing Safari/total:\n%s", out)
	}
	// Safari (larger total) should be listed before Mail
	if strings.Index(out, "Safari") > strings.Index(out, "Mail") {
		t.Fatalf("order wrong:\n%s", out)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/cli/ -run TestRenderAppsTable -v`
Expected: FAIL (undefined: RenderApps).

- [ ] **Step 3: Implement**

`internal/cli/cli.go`:
```go
package cli

import (
	"fmt"
	"strings"
	"text/tabwriter"

	"sbtally/internal/core"
)

func RenderApps(apps []core.AppStat) string {
	var b strings.Builder
	w := tabwriter.NewWriter(&b, 0, 2, 2, ' ', 0)
	fmt.Fprintln(w, "APP\tUP\tDOWN\tTOTAL")
	for _, a := range apps {
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", a.App,
			core.HumanBytes(a.Upload), core.HumanBytes(a.Download), core.HumanBytes(a.Total))
	}
	w.Flush()
	return b.String()
}

func RenderDomains(ds []core.DomainStat) string {
	var b strings.Builder
	w := tabwriter.NewWriter(&b, 0, 2, 2, ' ', 0)
	fmt.Fprintln(w, "HOST\tUP\tDOWN\tTOTAL")
	for _, d := range ds {
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", d.Host,
			core.HumanBytes(d.Upload), core.HumanBytes(d.Download), core.HumanBytes(d.Total))
	}
	w.Flush()
	return b.String()
}

func RenderAppDetail(d core.AppDetail) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n", d.App)
	w := tabwriter.NewWriter(&b, 0, 2, 2, ' ', 0)
	fmt.Fprintln(w, "HOST\tUP\tDOWN\tTOTAL")
	for _, ds := range d.Domains {
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", ds.Host,
			core.HumanBytes(ds.Upload), core.HumanBytes(ds.Download), core.HumanBytes(ds.Total))
	}
	w.Flush()
	return b.String()
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `go test ./internal/cli/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/cli/cli.go internal/cli/cli_test.go
git commit -m "feat(cli): table rendering for apps/domains/app-detail"
```

---

## Task 15: main dispatch + end-to-end smoke

**Files:**
- Modify: `cmd/sbtally/main.go`

- [ ] **Step 1: Implement the entrypoint**

`cmd/sbtally/main.go`:
```go
package main

import (
	"context"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"sbtally/internal/cli"
	"sbtally/internal/core"
	"sbtally/internal/daemon"
	"sbtally/internal/source"
)

func defaultDBPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "sbtally", "sbtally.db")
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: sbtally <daemon|apps|domains|app|live> [flags]")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "daemon":
		runDaemon(os.Args[2:])
	case "apps":
		runQuery(os.Args[2:], "apps")
	case "domains":
		runQuery(os.Args[2:], "domains")
	case "app":
		runAppDetail(os.Args[2:])
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", os.Args[1])
		os.Exit(2)
	}
}

func runDaemon(args []string) {
	fs := flag.NewFlagSet("daemon", flag.ExitOnError)
	clashAPI := fs.String("clash-api", "127.0.0.1:9090", "Clash API host:port")
	listen := fs.String("listen", "127.0.0.1:7777", "stats HTTP listen addr")
	dbPath := fs.String("db", defaultDBPath(), "SQLite path")
	_ = fs.Parse(args)

	if err := os.MkdirAll(filepath.Dir(*dbPath), 0o755); err != nil {
		fatal(err)
	}
	st, err := core.OpenStore(*dbPath)
	if err != nil {
		fatal(err)
	}
	defer st.Close()

	hub := daemon.NewLiveHub()
	src := source.NewClashSource(*clashAPI, os.Getenv("SBTALLY_SECRET"))
	d := daemon.New(src, st, hub)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	srv := &http.Server{Addr: *listen, Handler: daemon.NewServer(st, hub, func() int64 { return time.Now().Unix() })}
	go func() { _ = srv.ListenAndServe() }()
	defer srv.Close()

	fmt.Printf("sbtally daemon: clash=%s listen=%s db=%s\n", *clashAPI, *listen, *dbPath)
	if err := d.Run(ctx); err != nil && err != context.Canceled {
		fatal(err)
	}
}

func openReadStore(args []string) (*core.Store, string, int) {
	fs := flag.NewFlagSet("q", flag.ExitOnError)
	since := fs.String("since", "24h", "window, e.g. 24h/7d/30m")
	top := fs.Int("top", 20, "limit")
	dbPath := fs.String("db", defaultDBPath(), "SQLite path")
	_ = fs.Parse(args)
	st, err := core.OpenStore(*dbPath)
	if err != nil {
		fatal(err)
	}
	return st, *since, *top
}

func windowFrom(since string) (int64, int64) {
	now := time.Now().Unix()
	// duplicate of daemon.parseWindow kept private; reuse via a tiny inline parse
	if since == "" {
		return now - 86400, now
	}
	unit := since[len(since)-1]
	n, err := strconv.ParseInt(since[:len(since)-1], 10, 64)
	if err != nil {
		return now - 86400, now
	}
	switch unit {
	case 'd':
		return now - n*86400, now
	case 'h':
		return now - n*3600, now
	case 'm':
		return now - n*60, now
	}
	return now - 86400, now
}

func runQuery(args []string, which string) {
	st, since, top := openReadStore(args)
	defer st.Close()
	s, u := windowFrom(since)
	if which == "apps" {
		v, err := st.Apps(s, u, top)
		if err != nil {
			fatal(err)
		}
		fmt.Print(cli.RenderApps(v))
	} else {
		v, err := st.Domains(s, u, top)
		if err != nil {
			fatal(err)
		}
		fmt.Print(cli.RenderDomains(v))
	}
}

func runAppDetail(args []string) {
	if len(args) == 0 {
		fatal(fmt.Errorf("usage: sbtally app <name> [flags]"))
	}
	name := args[0]
	st, since, _ := openReadStore(args[1:])
	defer st.Close()
	s, u := windowFrom(since)
	v, err := st.AppDetail(name, s, u)
	if err != nil {
		fatal(err)
	}
	fmt.Print(cli.RenderAppDetail(v))
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
```

(Note: `windowFrom` duplicates the small duration parse rather than exporting `daemon.parseWindow`, to keep the daemon helper unexported. Acceptable for ~10 lines. If a third caller appears, promote to `internal/core`.)

- [ ] **Step 2: Build everything**

Run: `go build ./... && go vet ./...`
Expected: exit 0.

- [ ] **Step 3: Run the full test suite**

Run: `go test ./...`
Expected: all packages PASS.

- [ ] **Step 4: End-to-end smoke without sing-box**

Run:
```bash
go run ./cmd/sbtally apps --db /tmp/sbtally-smoke.db
```
Expected: prints an `APP  UP  DOWN  TOTAL` header (empty DB → header only), exit 0. Confirms wiring: store opens, query runs, table renders.

- [ ] **Step 5: Commit**

```bash
git add cmd/sbtally/main.go
git commit -m "feat(cli): main subcommand dispatch (daemon/apps/domains/app)"
```

---

## Task 16: README quickstart + known limitation

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write the README**

`README.md`:
```markdown
# sbtally (Phase 1: stats backbone)

Per-application traffic statistics for traffic through sing-box, via the Clash API.

## Build
    go build ./cmd/sbtally

## Run the collector
sing-box must expose the Clash API (`experimental.clash_api.external_controller: "127.0.0.1:9090"`)
and have `route.find_process: true` for per-app names (requires the standalone CLI build in TUN mode — not SFM).

    SBTALLY_SECRET=<clash-secret> ./sbtally daemon --clash-api 127.0.0.1:9090 --listen 127.0.0.1:7777

## Query
    ./sbtally apps --since 7d --top 20
    ./sbtally domains --since 24h
    ./sbtally app Safari --since 7d

## API (for the upcoming SwiftUI dashboard)
GET /api/summary|apps|domains|app/{name}|series?since=24h[&top=N][&name=]
GET /api/live  (text/event-stream of per-app live rates)

## Known limitation
Connections that open and close between two ~1s Clash snapshots are not observed and their
(tiny) byte counts are missed. This is acceptable for traffic accounting.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: Phase 1 README quickstart"
```

---

## Self-Review (completed during planning)

**Spec coverage (§ of the design spec → task):**
- §7.1 connection model/interface → Task 2; §7.2 accumulator → Task 4; §7.3 store → Task 5; §7.4 queries/DTOs → Task 6.
- §8 WS client → Tasks 8–9; live + SSE → Tasks 10, 12; HTTP API → Task 12; daemon wiring → Task 13.
- CLI (apps/domains/app) → Tasks 14–15. Byte formatting → Task 7. Window parsing → Task 11.
- Deferred to later phases (not Phase 1): SwiftUI app (§11), config generator/Clash client (§9), privileged helper (§10), launchd/deploy (§12), `live` terminal subcommand (depends on SSE client — add in Phase 2 alongside the dashboard).

**Placeholder scan:** none — every step has runnable code/commands.

**Type consistency:** `Rollup`, `AppStat`/`DomainStat`/`AppDetail`/`Point`/`Summary`/`LiveAppGroup`, `AppKey`/`HostKey`, `OpenStore`/`WriteRollups`/`Apps`/`Domains`/`AppDetail`/`Series`/`Summary`, `NewClashSource`, `NewAccumulator`/`Add`/`Pending`, `New`/`Run`, `NewServer(store, hub, nowFunc)`, `NewLiveHub`/`Subscribe`/`Unsubscribe`/`Publish`, `computeLive`, `parseWindow`, `RenderApps`/`RenderDomains`/`RenderAppDetail` — all defined before use and referenced consistently.

**Note:** the `live` terminal subcommand is intentionally deferred to Phase 2 (it consumes the same `/api/live` SSE the SwiftUI app uses). Phase 1 ships the daemon, API, and CLI reports — independently usable.
```
