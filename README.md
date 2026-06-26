# sbtally (Phase 1: stats backbone)

Per-application traffic statistics for traffic through sing-box, via the Clash API.

## Build

    go build ./cmd/sbtally

## Run the collector

sing-box must expose the Clash API (`experimental.clash_api.external_controller: "127.0.0.1:9090"`)
and have `route.find_process: true` for per-app names (requires the standalone CLI build in TUN
mode — not the App Store / SFM build, whose network extension can't resolve processes).

    SBTALLY_SECRET=<clash-secret> ./sbtally daemon --clash-api 127.0.0.1:9090 --listen 127.0.0.1:7777

## Query

    ./sbtally apps --since 7d --top 20
    ./sbtally domains --since 24h
    ./sbtally app Safari --since 7d

## API (for the upcoming SwiftUI dashboard)

    GET /api/summary|apps|domains|app/{name}|series?since=24h[&top=N][&name=]
    GET /api/live   (text/event-stream of per-app live rates)

## Known limitation

Connections that open and close between two ~1s Clash snapshots are not observed and their
(tiny) byte counts are missed. This is acceptable for traffic accounting.

## Dashboard (Phase 2)

A native macOS SwiftUI app (menu-bar + window: Live / Apps / Domains tabs, a time-range
picker, and a menu-bar readout of live ↑/↓ totals). It reads the daemon at
`http://127.0.0.1:7777`, so start the daemon first.

    cd app && xcodegen generate
    open SBTally.xcodeproj      # then Run (⌘R) in Xcode

Shared logic (models, byte format, SSE parser, API client) lives in the `app/SBTallyCore`
Swift package and is unit-tested headlessly:

    cd app/SBTallyCore && swift test

## Generating the master config

Turn your existing sing-box config(s) into an sbtally master config (nested
VPS/protocol selectors, mix = reality+hy2 urltest, smart routing, find_process,
clash_api):

    sbtally config import path/to/config.json          # list its outbounds
    sbtally config generate --vps vpsA=vpsA.json --vps vpsB=vpsB.json --out master.json

The generated config is validated with `sing-box check`.

## Status

- **Phase 1** — collector daemon, JSON/SSE API, CLI reports. Done.
- **Phase 2** — SwiftUI dashboard (Live / Apps / Domains). Done.
- **Phase 3** — config import + master generator (sing-box-check validated), Clash API client. Done.
- **Phase 4** — control API + panel (VPS / protocol / mode switching). Done.
- **Remaining (needs a real sing-box / root)** — privileged helper (TUN, system proxy,
  config apply + restart), per-app routing editor, launchd deployment + SFM migration,
  and the final end-to-end verification.

See `docs/superpowers/specs/` and `docs/superpowers/plans/`.
