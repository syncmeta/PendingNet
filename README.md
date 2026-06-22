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

## Status

Phase 1 (this) ships the Go collector daemon, JSON/SSE API, and CLI reports — usable on its own.
Later phases add the SwiftUI dashboard, the sing-box config generator + control panel
(VPS / protocol / routing-mode / TUN / system-proxy switching, per-app routing), and the
privileged helper. See `docs/superpowers/specs/` and `docs/superpowers/plans/`.
