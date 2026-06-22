# sing-box per-application traffic statistics — Design Spec

- **Date:** 2026-06-22
- **Status:** Draft for review
- **Working name:** `sbtally` (placeholder, easy to rename)

## 1. Goal

A Little Snitch–style traffic-statistics tool for traffic going **through sing-box** on macOS:

- **Per-application** accounting (the core value): how much each app uploaded/downloaded, and to which destinations.
- **Per-domain / per-destination** accounting.
- **Historical** rollups queryable over arbitrary time ranges, plus a **live monitor**.
- A **SwiftUI** dashboard (menu-bar + window) as the GUI.
- Architected so **iOS can be added later** with minimal rework — *reservations only* in this phase, no iOS code.

Non-goal: blocking/enforcement. This is observation only (stats, not a firewall).

## 2. Key constraints that drive the shape

1. **Per-app attribution requires socket→process resolution.** sing-box can only do this reliably when it runs as a **standalone root TUN CLI** with `route.find_process: true`. The macOS App Store client (SFM) runs sing-box inside a sandboxed Network Extension that generally cannot resolve processes. → **We replace SFM with a standalone sing-box CLI.** (User has explicitly accepted this.)
2. **Data tap = the Clash API.** sing-box implements the mihomo/clash-compatible REST + WebSocket API. The `/connections` WebSocket streams a full snapshot of active connections roughly once per second; each connection carries **cumulative** byte counters plus `process`, `processPath`, `host`, source/dest, `chains`, and `rule`.
3. **Collection must be always-on, independent of the GUI.** You want stats even when no window is open → a **background daemon** owns the data tap and storage; the SwiftUI app is a *client*.
4. **iOS is fundamentally different** (see §10): no standalone CLI (Network Extension instead), no background daemon, and **no per-app/process identity at all** → on iOS, per-app degrades to per-domain. The architecture must absorb that without schema/UI churn.

## 3. Components

| # | Component | Lang | Runs as | Responsibility |
|---|-----------|------|---------|----------------|
| 1 | **sing-box (reconfigured)** | — | root launchd daemon | Standalone TUN with `find_process` + `clash_api`. Replaces SFM. |
| 2 | **`sbtally` daemon** | Go | user launchd agent | Clash WS → delta accumulator → SQLite rollups; serves local JSON + SSE API on `127.0.0.1`. |
| 3 | **`sbtally` CLI** | Go | on demand | `apps` / `domains` / `app <name>` read SQLite directly; optional `live` terminal monitor via the daemon's SSE. |
| 4 | **SBTally.app** | SwiftUI (macOS 13+) | GUI app | Menu-bar live rates + window (Live / Apps / Domains / App detail) consuming the daemon API. Primary GUI. |

Components 2 and 3 are the **same Go binary** with subcommands.

## 4. Architecture & data flow

```
                         ┌─────────────────────────── sbtally daemon ───────────────────────────┐
 app sockets             │                                                                       │
     │ (TUN)             │   ConnectionsSource          Accumulator           Store (SQLite)     │
     ▼                   │   (clash WS client)  ──snap──▶ delta math ──rollup──▶ traffic table    │
 sing-box (root TUN) ───▶│        │                          │                                    │
   Clash API :9090       │        └────────────▶ Live rate calc ──▶ SSE broadcaster              │
        ▲                │                                              │            HTTP JSON    │
        │                └──────────────────────────────────────────────┼──────────────┬─────────┘
        │ ws /connections                                                │ /api/live    │ /api/*
        │                                                                ▼              ▼
        │                                                       ┌──────────────────────────────┐
        └─────────────────── (read-only, same host) ───────────│  SBTally.app (SwiftUI)        │
                                                                │  StatsProvider ← APIClient    │
   sbtally CLI ──reads──▶ SQLite file directly                  └──────────────────────────────┘
```

One Clash-API WebSocket subscription powers **both** persistent accounting and the live feed.

## 5. Repository layout

```
sbtally/                            # Go module: "sbtally"
  cmd/sbtally/main.go               # CLI + daemon entrypoint (macOS host)
  pkg/core/                         # PORTABLE, gomobile-ready — the iOS-reusable unit
    dto.go                          # platform-neutral data shapes
    accumulator.go                  # delta accounting (correctness-critical)
    accumulator_test.go
    store.go                        # SQLite via modernc.org/sqlite (pure Go)
    store_test.go
    query.go                        # aggregation queries
    query_test.go
  internal/source/
    source.go                       # ConnectionsSource interface + Connection/Snapshot types
    clashws.go                      # macOS host impl: coder/websocket client
  internal/daemon/daemon.go         # wires source → accumulator → store + live + server
  internal/server/
    server.go                       # JSON endpoints
    sse.go                          # /api/live Server-Sent Events
  internal/cli/                     # apps/domains/app/live subcommands + byte formatting
  deploy/
    singbox/config.template.json    # standalone TUN + find_process + clash_api
    launchd/io.sbtally.singbox.plist  # root: sing-box run
    launchd/io.sbtally.daemon.plist   # user agent: sbtally daemon
    install.sh
  app/                              # SBTally.app — Xcode project (SwiftUI, macOS 13+)
    SBTally/
      SBTallyApp.swift              # App + MenuBarExtra + Window
      StatsProvider.swift           # protocol  ← the iOS seam
      APIStatsProvider.swift        # URLSession + SSE implementation
      Models.swift                  # Codable mirrors of pkg/core DTOs
      Views/{LiveView,AppsView,DomainsView,AppDetailView}.swift
  docs/superpowers/specs/2026-06-22-singbox-traffic-stats-design.md
  README.md
```

`pkg/core` (not `internal/`) is deliberately exported so it can be `gomobile bind`-ed for iOS later. It must stay free of host-only dependencies. `modernc.org/sqlite` is pure-Go (no cgo), so it cross-compiles to iOS/arm64 — a concrete enabler for that path.

## 6. Portable core (`pkg/core`)

### 6.1 Connection model (`internal/source` types, consumed by core)

```go
type Connection struct {
    ID            string
    Process       string // metadata.process     (may be empty)
    ProcessPath   string // metadata.processPath  (may be empty)
    Host          string // metadata.host (sniffed domain; may be empty)
    DestIP        string
    DestPort      string
    Network       string // tcp/udp
    Chains        []string
    Rule          string
    Upload        int64  // cumulative bytes for this connection
    Download      int64  // cumulative bytes for this connection
}

type Snapshot struct {
    At          int64 // unix seconds when received
    Connections []Connection
}

// ConnectionsSource is the swappable data tap. macOS = clash WS; iOS = in-extension feed.
type ConnectionsSource interface {
    Snapshots(ctx context.Context) (<-chan Snapshot, error)
}
```

### 6.2 Delta accumulator (correctness-critical)

Each snapshot reports **cumulative** counters per active connection; connections vanish from the snapshot when closed. We accumulate **increments**, keyed by connection ID, into hourly buckets.

State: `last map[connID]{up, down}` and `pending map[bucketKey]{up, down}` where `bucketKey = (hourStart, app, host)`.

Per snapshot `S`:
- For each connection `c`:
  - `prev := last[c.ID]` (zero if absent — a new connection)
  - `du := c.Upload - prev.up; dd := c.Download - prev.down`
  - If `du < 0 || dd < 0` (counter reset / ID anomaly — should not happen with UUID IDs): clamp the negative delta(s) to `0` and rebaseline (`last[c.ID] = current`). Never add a negative.
  - `app := firstNonEmpty(c.Process, basename(c.ProcessPath), c.Host, "unknown")`
  - `host := firstNonEmpty(c.Host, c.DestIP, "unknown")`
  - Add `(du, dd)` to `pending[(hourFloor(S.At), app, host)]`.
  - `last[c.ID] = {c.Upload, c.Download}`
- Delete from `last` every ID **not** present in `S` (closed; already fully counted from prior snapshots).

**Flush:** every ~10 s, and on shutdown, UPSERT all `pending` rows into SQLite and clear `pending`. Hour boundaries are handled naturally because the bucket is part of the key.

**Documented limitation:** a connection that both opens and closes *between* two snapshots is never observed and its bytes are missed. These are tiny by definition; acceptable for traffic accounting. Noted in README.

### 6.3 Store (SQLite)

```sql
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;

CREATE TABLE IF NOT EXISTS traffic (
  bucket   INTEGER NOT NULL,   -- unix epoch of the hour start
  app      TEXT    NOT NULL,
  host     TEXT    NOT NULL,
  upload   INTEGER NOT NULL,
  download INTEGER NOT NULL,
  PRIMARY KEY (bucket, app, host)
);
```

UPSERT accumulation:

```sql
INSERT INTO traffic (bucket, app, host, upload, download) VALUES (?, ?, ?, ?, ?)
ON CONFLICT(bucket, app, host)
DO UPDATE SET upload = upload + excluded.upload, download = download + excluded.download;
```

The PK `(bucket, app, host)` orders by bucket first → time-range scans are efficient without extra indexes. DB path: `~/Library/Application Support/sbtally/sbtally.db` (shared by daemon writer and CLI/GUI readers; WAL allows concurrent reads).

### 6.4 Query layer & DTOs

```go
type AppStat    struct { App string;  Upload, Download, Total int64 }
type DomainStat struct { Host string; Upload, Download, Total int64 }
type AppDetail  struct { App string;  Domains []DomainStat }
type Point      struct { Bucket int64; Upload, Download int64 }   // chart series
type Summary    struct { Since int64; Upload, Download, Total int64; Apps, Hosts int }
type LiveAppGroup struct { App string; UpRate, DownRate int64; Conns int; TopHost string } // live SSE
```

(`LiveAppGroup` is produced by the daemon's live calculator, streamed over `/api/live`, and mirrored in the Swift models.)

```go
```

Queries (all take a `since`/`until` window; list queries take `top`):
- `Apps(since,until,top)` → `[]AppStat` — `GROUP BY app` ordered by total desc.
- `Domains(since,until,top)` → `[]DomainStat` — `GROUP BY host`.
- `AppDetail(name,since,until)` → domains for one app — `WHERE app=? GROUP BY host`.
- `Series(by, name, since, until)` → `[]Point` — per-hour series for charts (optionally filtered to one app/host).
- `Summary(since,until)` → totals + distinct counts.

`since` accepts durations (`24h`, `7d`) or absolute timestamps.

## 7. Daemon: wiring, live feed, HTTP API

- **WS client** (`coder/websocket`): connect `ws://127.0.0.1:9090/connections` with `Authorization: Bearer <secret>`; parse snapshots; emit on the `Snapshots` channel. **Reconnect** with exponential backoff; on reconnect, flush `pending` and reset `last` (the connection set restarts).
- **Live rates:** computed from the same snapshots (per-connection delta ÷ elapsed), grouped by app → `LiveAppGroup{App, UpRate, DownRate, Conns, TopHost}`. Broadcast to SSE subscribers. No separate WS subscription.
- **HTTP (loopback only):**
  - `GET /api/summary?since=`
  - `GET /api/apps?since=&top=`
  - `GET /api/domains?since=&top=`
  - `GET /api/app/{name}?since=`
  - `GET /api/series?by=app|host&name=&since=`
  - `GET /api/live` → `text/event-stream` of `{apps:[LiveAppGroup], at}`
- **Auth:** bind to `127.0.0.1` only; no auth by default (personal machine). Optional `SBTALLY_TOKEN` env enforced as a bearer if set. Config via flags/env: `--clash-api` (default `127.0.0.1:9090`), `SBTALLY_SECRET`, `--listen` (default `127.0.0.1:7777`), `--db`.

## 8. SwiftUI app (`SBTally.app`)

- **Targets** macOS 13+ (Swift Charts). `MenuBarExtra` shows live ↑/↓ rate + top app; main `Window` has tabs **Live / Apps / Domains** and an **App detail** view.
- **Data layer is the iOS seam:**

  ```swift
  protocol StatsProvider {
      func summary(since: String) async throws -> Summary
      func apps(since: String, top: Int) async throws -> [AppStat]
      func domains(since: String, top: Int) async throws -> [DomainStat]
      func appDetail(_ name: String, since: String) async throws -> AppDetail
      func series(by: String, name: String?, since: String) async throws -> [Point]
      func live() -> AsyncStream<[LiveAppGroup]>   // SSE today; gomobile core on iOS
  }
  ```

  `APIStatsProvider` implements it over `URLSession` (+ SSE parsing). Views bind to a view model over `StatsProvider`, never to `URLSession` directly — so an iOS build swaps in a gomobile-backed provider and reuses the views.
- **Models** mirror `pkg/core` DTOs as `Codable`.
- **Build/verify note:** the Go daemon + CLI are fully testable/verifiable headlessly in this environment (curl the API, run the tests). The SwiftUI app can be **compile-checked** via `xcodebuild`, but running/iterating the GUI happens with the user (or via slow screen-control). The UI loop is collaborative.

## 9. Deploy — replacing SFM

- `deploy/singbox/config.template.json`: a standalone **TUN** inbound (`auto_route`, `strict_route`, gVisor stack), `route.find_process: true`, `experimental.clash_api { external_controller: "127.0.0.1:9090", secret }`, with clearly marked paste points for the user's existing **outbounds** and **route rules** (lifted from their current SFM config).
- `deploy/launchd/io.sbtally.singbox.plist` (root, `/Library/LaunchDaemons`): runs `sing-box run -c …`, `RunAtLoad` + `KeepAlive`. Needs root for TUN.
- `deploy/launchd/io.sbtally.daemon.plist` (user, `~/Library/LaunchAgents`): runs `sbtally daemon`.
- `deploy/install.sh`: builds the Go binary, installs/loads both services.
- **Migration:** disable/quit SFM first — two TUN providers conflict. Documented in README.

## 10. iOS — reservations now, limitations documented

**Reservations (zero/near-zero cost today):**
- Portable `pkg/core` (no host deps; pure-Go SQLite) → `gomobile bind`-able into an `.xcframework` later.
- `ConnectionsSource` interface → iOS supplies an in-extension implementation; accumulator/store/query unchanged.
- `StatsProvider` protocol + decoupled SwiftUI views → iOS reuses the views with a gomobile-backed provider.
- DTOs are platform-neutral; the `process → host → unknown` fallback already yields sensible per-domain data when process names are absent.

**Documented iOS limitations (so the future build is unsurprising):**
- sing-box on iOS is a **Packet Tunnel Network Extension**, not a root CLI; the data source differs.
- iOS exposes **no per-app/process identity** for socket traffic → iOS stats are **per-domain only**.
- iOS has **no general background daemon** → the core runs **in-app/in-extension** via gomobile; collection happens only while the tunnel is active.
- The heavy lifting (NE plumbing, gomobile bind) is explicitly **deferred** to the iOS phase.

## 11. Testing

- `accumulator_test.go`: growth across snapshots; connection close (no double count); brand-new connection mid-stream; missing `process` → `unknown`; empty `host` → DestIP fallback; negative-delta clamp; hour-boundary bucketing.
- `store_test.go`: UPSERT accumulation; WAL concurrent read while writing.
- `query_test.go`: seed an in-memory SQLite with known rollups; assert `apps`/`domains`/`appDetail`/`series`/`summary` aggregation, `since` filtering, and `top-N` ordering.
- byte-humanization unit test.
- The entire Go data path is verifiable headlessly. SwiftUI: `xcodebuild` compile-check; runtime iteration with the user.

## 12. Error handling

- WS disconnect → backoff reconnect; flush `pending`, reset `last` on reconnect.
- Clash API auth failure (401) → clear log message naming the secret mismatch.
- SQLite busy → WAL + `busy_timeout` + bounded retry.
- Empty/missing process or host → fallbacks, never an error.
- Daemon offline → CLI still reads the DB; SwiftUI shows an "offline" state and disables live.

## 13. Out of scope (YAGNI)

Blocking/enforcement; alerting; multi-host aggregation; a web UI (SwiftUI chosen); Prometheus/OTel export; app notarization/distribution (build locally); auth beyond optional loopback token.

## 14. Open items

- Final tool name (`sbtally` is a placeholder).
- sing-box TUN stack choice (gVisor vs system) — default gVisor; revisit if throughput matters.
```
