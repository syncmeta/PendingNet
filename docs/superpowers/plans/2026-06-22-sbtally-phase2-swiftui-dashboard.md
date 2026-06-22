# sbtally Phase 2 — SwiftUI Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A native macOS SwiftUI app (menu-bar + window) that visualizes the Phase 1 daemon's stats over its JSON/SSE API — live per-app rates, per-app and per-domain totals, app drill-down.

**Architecture:** XcodeGen-generated `.xcodeproj` (`app/`). Testable logic (Models, byte format, SSE parser, `APIStatsProvider`) lives in the app target and is unit-tested via `xcodebuild test` (URLProtocol stub for the network). Views are compile-checked via `xcodebuild build`. The app talks to `http://127.0.0.1:7777` (the daemon). Data access goes through a `StatsProvider` protocol so the network impl is swappable/testable.

**Tech Stack:** Swift 5 language mode (avoids Swift 6 strict-concurrency churn) on Xcode 26 / macOS 14+ deployment, SwiftUI, Swift Charts, `Table`, `MenuBarExtra`, async/await + `AsyncStream`, XCTest, XcodeGen.

**Verification cmds:**
- `cd app && xcodegen generate`
- `xcodebuild -project app/SBTally.xcodeproj -scheme SBTally -destination 'platform=macOS' build`
- `xcodebuild -project app/SBTally.xcodeproj -scheme SBTally -destination 'platform=macOS' test`

---

## File Structure

```
internal/core/query.go            # MODIFY: non-nil slices ([] not null) — Task 1
internal/core/query_test.go       # MODIFY: assert JSON marshals as []
app/
  project.yml                     # XcodeGen spec
  SBTally/
    SBTallyApp.swift              # @main App: MenuBarExtra + Window
    Models.swift                  # Codable mirrors of Go DTOs
    ByteFormat.swift              # humanBytes()
    SSEParser.swift               # parse "data: <json>" -> [LiveAppGroup]
    StatsProvider.swift           # protocol (the data seam)
    APIStatsProvider.swift        # URLSession + SSE implementation
    AppState.swift                # @MainActor ObservableObject
    Views/
      DashboardView.swift         # window root: tabs + since picker
      LiveView.swift
      AppsView.swift
      DomainsView.swift
      MenuBarView.swift
  SBTallyTests/
    ModelsTests.swift
    ByteFormatTests.swift
    SSEParserTests.swift
    APIStatsProviderTests.swift   # URLProtocol stub
```

---

## Task 1: Go API returns non-nil slices (`[]` not `null`)

**Files:** Modify `internal/core/query.go`, `internal/core/query_test.go`

- [ ] **Step 1: Add failing test (JSON marshals as `[]` on empty)**

Append to `internal/core/query_test.go`:
```go
func TestEmptyAppsMarshalsAsArray(t *testing.T) {
	s, err := OpenStore(filepath.Join(t.TempDir(), "e.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	apps, err := s.Apps(0, 1, 0) // empty range
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(apps)
	if string(b) != "[]" {
		t.Fatalf("got %q want []", b)
	}
}
```
Add `"encoding/json"` to that file's imports.

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/core/ -run TestEmptyAppsMarshalsAsArray -v`
Expected: FAIL (`got "null" want []`).

- [ ] **Step 3: Make slices non-nil in `query.go`**

In `Apps`, `Domains`, `Series` change `var out []T` to the initialized form:
```go
out := []AppStat{}     // in Apps
out := []DomainStat{}  // in Domains
out := []Point{}       // in Series
```
In `AppDetail`, initialize Domains:
```go
d := AppDetail{App: app, Domains: []DomainStat{}}
```

- [ ] **Step 4: Run to verify pass**

Run: `go test ./internal/core/ -v`
Expected: PASS (all, including the new test).

- [ ] **Step 5: Commit**

```bash
git add internal/core/query.go internal/core/query_test.go
git commit -m "fix(core): query results marshal as [] not null when empty"
```

---

## Task 2: XcodeGen project skeleton that builds

**Files:** Create `app/project.yml`, `app/SBTally/SBTallyApp.swift` (minimal)

- [ ] **Step 1: Write the project spec**

`app/project.yml`:
```yaml
name: SBTally
options:
  bundleIdPrefix: dev.sbtally
  deploymentTarget:
    macOS: "14.0"
settings:
  base:
    SWIFT_VERSION: "5.0"
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    GENERATE_INFOPLIST_FILE: "YES"
    PRODUCT_NAME: SBTally
targets:
  SBTally:
    type: application
    platform: macOS
    sources:
      - path: SBTally
  SBTallyTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: SBTallyTests
    dependencies:
      - target: SBTally
schemes:
  SBTally:
    build:
      targets:
        SBTally: all
        SBTallyTests: [test]
    test:
      targets:
        - SBTallyTests
```

- [ ] **Step 2: Minimal app + test dir so generation succeeds**

`app/SBTally/SBTallyApp.swift`:
```swift
import SwiftUI

@main
struct SBTallyApp: App {
    var body: some Scene {
        Window("sbtally", id: "main") {
            Text("sbtally")
        }
    }
}
```

`app/SBTallyTests/PlaceholderTests.swift`:
```swift
import XCTest

final class PlaceholderTests: XCTestCase {
    func testPlaceholder() { XCTAssertTrue(true) }
}
```

- [ ] **Step 3: Generate + build**

Run:
```bash
cd app && xcodegen generate && cd ..
xcodebuild -project app/SBTally.xcodeproj -scheme SBTally -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Add `.gitignore` for Xcode/derived data, commit**

`app/.gitignore`:
```
*.xcodeproj
DerivedData/
.DS_Store
```
(We regenerate the `.xcodeproj` from `project.yml`, so it's not committed.)

```bash
git add app/.gitignore app/project.yml app/SBTally/SBTallyApp.swift app/SBTallyTests/PlaceholderTests.swift
git commit -m "feat(app): XcodeGen SwiftUI app skeleton (builds)"
```

---

## Task 3: Models (Codable mirrors)

**Files:** Create `app/SBTally/Models.swift`, `app/SBTallyTests/ModelsTests.swift`; delete placeholder test.

- [ ] **Step 1: Write the failing test**

`app/SBTallyTests/ModelsTests.swift`:
```swift
import XCTest
@testable import SBTally

final class ModelsTests: XCTestCase {
    func testDecodeAppStats() throws {
        let json = #"[{"app":"Safari","upload":100,"download":200,"total":300}]"#.data(using: .utf8)!
        let apps = try JSONDecoder().decode([AppStat].self, from: json)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].app, "Safari")
        XCTAssertEqual(apps[0].total, 300)
    }

    func testDecodeEmptyArray() throws {
        let apps = try JSONDecoder().decode([AppStat].self, from: Data("[]".utf8))
        XCTAssertTrue(apps.isEmpty)
    }

    func testDecodeLiveGroup() throws {
        let json = #"{"app":"X","upRate":10,"downRate":2,"conns":3,"topHost":"a.com"}"#.data(using: .utf8)!
        let g = try JSONDecoder().decode(LiveAppGroup.self, from: json)
        XCTAssertEqual(g.upRate, 10)
        XCTAssertEqual(g.topHost, "a.com")
    }

    func testDecodeAppDetail() throws {
        let json = #"{"app":"Mail","domains":[{"host":"c.com","upload":1,"download":2,"total":3}]}"#.data(using: .utf8)!
        let d = try JSONDecoder().decode(AppDetail.self, from: json)
        XCTAssertEqual(d.domains.first?.host, "c.com")
    }
}
```

- [ ] **Step 2: Delete placeholder, write Models**

Delete `app/SBTallyTests/PlaceholderTests.swift`.

`app/SBTally/Models.swift`:
```swift
import Foundation

struct AppStat: Codable, Identifiable, Hashable {
    let app: String
    let upload, download, total: Int64
    var id: String { app }
}

struct DomainStat: Codable, Identifiable, Hashable {
    let host: String
    let upload, download, total: Int64
    var id: String { host }
}

struct AppDetail: Codable {
    let app: String
    let domains: [DomainStat]
}

struct Point: Codable, Identifiable {
    let bucket: Int64
    let upload, download: Int64
    var id: Int64 { bucket }
}

struct Summary: Codable {
    let since: Int64
    let upload, download, total: Int64
    let apps, hosts: Int
}

struct LiveAppGroup: Codable, Identifiable, Hashable {
    let app: String
    let upRate, downRate: Int64
    let conns: Int
    let topHost: String
    var id: String { app }
}
```

- [ ] **Step 3: Regenerate + test**

Run:
```bash
cd app && xcodegen generate && cd ..
xcodebuild -project app/SBTally.xcodeproj -scheme SBTally -destination 'platform=macOS' test 2>&1 | tail -8
```
Expected: `** TEST SUCCEEDED **` (ModelsTests pass).

- [ ] **Step 4: Commit**

```bash
git add app/SBTally/Models.swift app/SBTallyTests/ModelsTests.swift
git rm app/SBTallyTests/PlaceholderTests.swift
git commit -m "feat(app): Codable models mirroring the daemon DTOs"
```

---

## Task 4: Byte formatting

**Files:** Create `app/SBTally/ByteFormat.swift`, `app/SBTallyTests/ByteFormatTests.swift`

- [ ] **Step 1: Write the failing test**

`app/SBTallyTests/ByteFormatTests.swift`:
```swift
import XCTest
@testable import SBTally

final class ByteFormatTests: XCTestCase {
    func testHumanBytes() {
        XCTAssertEqual(humanBytes(0), "0 B")
        XCTAssertEqual(humanBytes(512), "512 B")
        XCTAssertEqual(humanBytes(1024), "1.0 KiB")
        XCTAssertEqual(humanBytes(1_048_576), "1.0 MiB")
        XCTAssertEqual(humanBytes(1_073_741_824), "1.0 GiB")
    }
}
```

- [ ] **Step 2: Implement**

`app/SBTally/ByteFormat.swift`:
```swift
import Foundation

func humanBytes(_ n: Int64) -> String {
    let unit: Int64 = 1024
    if n < unit { return "\(n) B" }
    var div = unit
    var exp = 0
    var x = n / unit
    while x >= unit { div *= unit; exp += 1; x /= unit }
    let units = ["K", "M", "G", "T", "P", "E"]
    return String(format: "%.1f %@iB", Double(n) / Double(div), units[exp])
}
```

- [ ] **Step 3: Regenerate + test, commit**

```bash
cd app && xcodegen generate && cd ..
xcodebuild -project app/SBTally.xcodeproj -scheme SBTally -destination 'platform=macOS' test 2>&1 | tail -6
git add app/SBTally/ByteFormat.swift app/SBTallyTests/ByteFormatTests.swift
git commit -m "feat(app): humanBytes formatter"
```
Expected: TEST SUCCEEDED.

---

## Task 5: SSE parser

**Files:** Create `app/SBTally/SSEParser.swift`, `app/SBTallyTests/SSEParserTests.swift`

- [ ] **Step 1: Write the failing test**

`app/SBTallyTests/SSEParserTests.swift`:
```swift
import XCTest
@testable import SBTally

final class SSEParserTests: XCTestCase {
    func testParsesDataLine() {
        let line = #"data: [{"app":"X","upRate":5,"downRate":1,"conns":2,"topHost":"h"}]"#
        let groups = SSEParser.parse(dataLine: line)
        XCTAssertEqual(groups?.count, 1)
        XCTAssertEqual(groups?.first?.app, "X")
    }

    func testIgnoresNonDataLine() {
        XCTAssertNil(SSEParser.parse(dataLine: ": keepalive"))
        XCTAssertNil(SSEParser.parse(dataLine: ""))
    }
}
```

- [ ] **Step 2: Implement**

`app/SBTally/SSEParser.swift`:
```swift
import Foundation

enum SSEParser {
    /// Parses a single SSE line of the form `data: <json-array>` into live groups.
    static func parse(dataLine line: String) -> [LiveAppGroup]? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([LiveAppGroup].self, from: data)
    }
}
```

- [ ] **Step 3: Regenerate + test, commit**

```bash
cd app && xcodegen generate && cd ..
xcodebuild -project app/SBTally.xcodeproj -scheme SBTally -destination 'platform=macOS' test 2>&1 | tail -6
git add app/SBTally/SSEParser.swift app/SBTallyTests/SSEParserTests.swift
git commit -m "feat(app): SSE data-line parser for live groups"
```
Expected: TEST SUCCEEDED.

---

## Task 6: StatsProvider protocol + APIStatsProvider

**Files:** Create `app/SBTally/StatsProvider.swift`, `app/SBTally/APIStatsProvider.swift`, `app/SBTallyTests/APIStatsProviderTests.swift`

- [ ] **Step 1: Write the failing test (URLProtocol stub)**

`app/SBTallyTests/APIStatsProviderTests.swift`:
```swift
import XCTest
@testable import SBTally

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body: Data = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class APIStatsProviderTests: XCTestCase {
    private func provider() -> APIStatsProvider {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return APIStatsProvider(baseURL: URL(string: "http://127.0.0.1:7777")!,
                                session: URLSession(configuration: cfg))
    }

    func testApps() async throws {
        StubURLProtocol.body = Data(#"[{"app":"Safari","upload":1,"download":2,"total":3}]"#.utf8)
        let apps = try await provider().apps(since: "24h", top: 20)
        XCTAssertEqual(apps.first?.app, "Safari")
    }

    func testSummary() async throws {
        StubURLProtocol.body = Data(#"{"since":0,"upload":10,"download":5,"total":15,"apps":2,"hosts":3}"#.utf8)
        let s = try await provider().summary(since: "24h")
        XCTAssertEqual(s.total, 15)
    }
}
```

- [ ] **Step 2: Implement protocol + provider**

`app/SBTally/StatsProvider.swift`:
```swift
import Foundation

protocol StatsProvider {
    func summary(since: String) async throws -> Summary
    func apps(since: String, top: Int) async throws -> [AppStat]
    func domains(since: String, top: Int) async throws -> [DomainStat]
    func appDetail(_ name: String, since: String) async throws -> AppDetail
    func series(name: String?, since: String) async throws -> [Point]
    func live() -> AsyncStream<[LiveAppGroup]>
}
```

`app/SBTally/APIStatsProvider.swift`:
```swift
import Foundation

struct APIStatsProvider: StatsProvider {
    var baseURL: URL
    var session: URLSession = .shared

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = query
        let (data, resp) = try await session.data(from: comps.url!)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func summary(since: String) async throws -> Summary {
        try await get("/api/summary", [.init(name: "since", value: since)])
    }
    func apps(since: String, top: Int) async throws -> [AppStat] {
        try await get("/api/apps", [.init(name: "since", value: since), .init(name: "top", value: String(top))])
    }
    func domains(since: String, top: Int) async throws -> [DomainStat] {
        try await get("/api/domains", [.init(name: "since", value: since), .init(name: "top", value: String(top))])
    }
    func appDetail(_ name: String, since: String) async throws -> AppDetail {
        try await get("/api/app/\(name)", [.init(name: "since", value: since)])
    }
    func series(name: String?, since: String) async throws -> [Point] {
        var q = [URLQueryItem(name: "since", value: since)]
        if let name { q.append(.init(name: "name", value: name)) }
        return try await get("/api/series", q)
    }

    func live() -> AsyncStream<[LiveAppGroup]> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let url = baseURL.appendingPathComponent("/api/live")
                    let (bytes, resp) = try await session.bytes(from: url)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                        continuation.finish(); return
                    }
                    for try await line in bytes.lines {
                        if let groups = SSEParser.parse(dataLine: line) {
                            continuation.yield(groups)
                        }
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [ ] **Step 3: Regenerate + test, commit**

```bash
cd app && xcodegen generate && cd ..
xcodebuild -project app/SBTally.xcodeproj -scheme SBTally -destination 'platform=macOS' test 2>&1 | tail -8
git add app/SBTally/StatsProvider.swift app/SBTally/APIStatsProvider.swift app/SBTallyTests/APIStatsProviderTests.swift
git commit -m "feat(app): StatsProvider protocol + URLSession/SSE implementation"
```
Expected: TEST SUCCEEDED.

---

## Task 7: AppState (view model)

**Files:** Create `app/SBTally/AppState.swift`

- [ ] **Step 1: Implement**

`app/SBTally/AppState.swift`:
```swift
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var since: String = "24h"
    @Published var apps: [AppStat] = []
    @Published var domains: [DomainStat] = []
    @Published var summary: Summary?
    @Published var live: [LiveAppGroup] = []
    @Published var lastError: String?

    let provider: StatsProvider
    private var liveTask: Task<Void, Never>?

    init(provider: StatsProvider) { self.provider = provider }

    func refresh() async {
        do {
            async let a = provider.apps(since: since, top: 50)
            async let d = provider.domains(since: since, top: 50)
            async let s = provider.summary(since: since)
            self.apps = try await a
            self.domains = try await d
            self.summary = try await s
            self.lastError = nil
        } catch {
            self.lastError = String(describing: error)
        }
    }

    func startLive() {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            guard let self else { return }
            for await groups in await self.provider.live() {
                await MainActor.run {
                    self.live = groups.sorted { ($0.upRate + $0.downRate) > ($1.upRate + $1.downRate) }
                }
            }
        }
    }

    func stopLive() { liveTask?.cancel() }
}
```

- [ ] **Step 2: Build (compile-check), commit**

```bash
cd app && xcodegen generate && cd ..
xcodebuild -project app/SBTally.xcodeproj -scheme SBTally -destination 'platform=macOS' build 2>&1 | tail -5
git add app/SBTally/AppState.swift
git commit -m "feat(app): AppState view model (refresh + live stream)"
```
Expected: BUILD SUCCEEDED. (If Swift flags `provider.live()` actor isolation, the `await` forms above resolve it; if not needed, the compiler will warn—remove redundant `await`.)

---

## Task 8: Stats views (Apps / Domains)

**Files:** Create `app/SBTally/Views/AppsView.swift`, `app/SBTally/Views/DomainsView.swift`

- [ ] **Step 1: Implement**

`app/SBTally/Views/AppsView.swift`:
```swift
import SwiftUI

struct AppsView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Table(state.apps) {
            TableColumn("App", value: \.app)
            TableColumn("Up") { Text(humanBytes($0.upload)).monospacedDigit() }
            TableColumn("Down") { Text(humanBytes($0.download)).monospacedDigit() }
            TableColumn("Total") { Text(humanBytes($0.total)).monospacedDigit() }
        }
    }
}
```

`app/SBTally/Views/DomainsView.swift`:
```swift
import SwiftUI

struct DomainsView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Table(state.domains) {
            TableColumn("Host", value: \.host)
            TableColumn("Up") { Text(humanBytes($0.upload)).monospacedDigit() }
            TableColumn("Down") { Text(humanBytes($0.download)).monospacedDigit() }
            TableColumn("Total") { Text(humanBytes($0.total)).monospacedDigit() }
        }
    }
}
```

- [ ] **Step 2: Build, commit**

```bash
cd app && xcodegen generate && cd ..
xcodebuild -project app/SBTally.xcodeproj -scheme SBTally -destination 'platform=macOS' build 2>&1 | tail -5
git add app/SBTally/Views/AppsView.swift app/SBTally/Views/DomainsView.swift
git commit -m "feat(app): Apps and Domains table views"
```
Expected: BUILD SUCCEEDED.

---

## Task 9: Live view

**Files:** Create `app/SBTally/Views/LiveView.swift`

- [ ] **Step 1: Implement**

`app/SBTally/Views/LiveView.swift`:
```swift
import SwiftUI

struct LiveView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Table(state.live) {
            TableColumn("App", value: \.app)
            TableColumn("↑/s") { Text(humanBytes($0.upRate) + "/s").monospacedDigit() }
            TableColumn("↓/s") { Text(humanBytes($0.downRate) + "/s").monospacedDigit() }
            TableColumn("Conns") { Text(String($0.conns)).monospacedDigit() }
            TableColumn("Top host", value: \.topHost)
        }
        .overlay {
            if state.live.isEmpty {
                ContentUnavailableView("No live traffic", systemImage: "wifi",
                                       description: Text("Waiting for the daemon's live feed…"))
            }
        }
    }
}
```

- [ ] **Step 2: Build, commit**

```bash
cd app && xcodegen generate && cd ..
xcodebuild -project app/SBTally.xcodeproj -scheme SBTally -destination 'platform=macOS' build 2>&1 | tail -5
git add app/SBTally/Views/LiveView.swift
git commit -m "feat(app): live monitor view"
```
Expected: BUILD SUCCEEDED.

---

## Task 10: Dashboard + MenuBar + App wiring

**Files:** Create `app/SBTally/Views/DashboardView.swift`, `app/SBTally/Views/MenuBarView.swift`; rewrite `app/SBTally/SBTallyApp.swift`

- [ ] **Step 1: Dashboard root**

`app/SBTally/Views/DashboardView.swift`:
```swift
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            LiveView().tabItem { Label("Live", systemImage: "dot.radiowaves.left.and.right") }
            AppsView().tabItem { Label("Apps", systemImage: "app.badge") }
            DomainsView().tabItem { Label("Domains", systemImage: "globe") }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Since", selection: $state.since) {
                    Text("1h").tag("1h")
                    Text("24h").tag("24h")
                    Text("7d").tag("7d")
                    Text("30d").tag("30d")
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem(placement: .automatic) {
                Button { Task { await state.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onChange(of: state.since) { Task { await state.refresh() } }
        .navigationTitle("sbtally")
    }
}
```

- [ ] **Step 2: Menu bar content**

`app/SBTally/Views/MenuBarView.swift`:
```swift
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    private var totalUp: Int64 { state.live.reduce(0) { $0 + $1.upRate } }
    private var totalDown: Int64 { state.live.reduce(0) { $0 + $1.downRate } }

    var body: some View {
        VStack(alignment: .leading) {
            Text("↑ \(humanBytes(totalUp))/s   ↓ \(humanBytes(totalDown))/s")
                .monospacedDigit()
            Divider()
            ForEach(state.live.prefix(5)) { g in
                Text("\(g.app) — ↓\(humanBytes(g.downRate))/s")
            }
            Divider()
            Button("Open Dashboard") { openWindow(id: "main") }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(8)
        .frame(width: 240)
    }
}
```

- [ ] **Step 3: App entry**

`app/SBTally/SBTallyApp.swift` (replace):
```swift
import SwiftUI

@main
struct SBTallyApp: App {
    @StateObject private var state = AppState(
        provider: APIStatsProvider(baseURL: URL(string: "http://127.0.0.1:7777")!))

    var body: some Scene {
        Window("sbtally", id: "main") {
            DashboardView()
                .environmentObject(state)
                .frame(minWidth: 680, minHeight: 440)
                .task {
                    await state.refresh()
                    state.startLive()
                }
        }
        MenuBarExtra {
            MenuBarView().environmentObject(state)
        } label: {
            Image(systemName: "chart.bar.xaxis")
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 4: Build, commit**

```bash
cd app && xcodegen generate && cd ..
xcodebuild -project app/SBTally.xcodeproj -scheme SBTally -destination 'platform=macOS' build 2>&1 | tail -5
git add app/SBTally/Views/DashboardView.swift app/SBTally/Views/MenuBarView.swift app/SBTally/SBTallyApp.swift
git commit -m "feat(app): dashboard tabs, menu-bar extra, app wiring"
```
Expected: BUILD SUCCEEDED.

---

## Task 11: Full verification + run instructions

- [ ] **Step 1: Clean build + full test**

```bash
cd app && xcodegen generate && cd ..
xcodebuild -project app/SBTally.xcodeproj -scheme SBTally -destination 'platform=macOS' clean build test 2>&1 | tail -12
```
Expected: BUILD SUCCEEDED + TEST SUCCEEDED.

- [ ] **Step 2: Append run instructions to README**

Add under a new "## Dashboard (Phase 2)" section in `README.md`:
```markdown
## Dashboard (Phase 2)

    cd app && xcodegen generate
    open app/SBTally.xcodeproj   # then Run (⌘R) in Xcode

The app reads the daemon at http://127.0.0.1:7777. Start the daemon first
(`sbtally daemon …`). The window has Live / Apps / Domains tabs and a time-range
picker; the menu-bar icon shows live ↑/↓ totals.
```

```bash
git add README.md
git commit -m "docs: dashboard build/run instructions"
```

---

## Self-Review (completed during planning)

**Spec coverage (§11 SwiftUI app):** MenuBarExtra + Window → Task 10; StatsProvider protocol → Task 6; APIStatsProvider (URLSession + SSE) → Task 6; Models mirroring DTOs → Task 3; Live/Apps/Domains views → Tasks 8–9; view model → Task 7. App-detail drill-down view is deferred to a follow-up (the `appDetail` API + model are present; a dedicated view is additive and not load-bearing for the first usable dashboard). Swift Charts time-series is also deferred to a follow-up — Phase 2 ships tables + live first; charts layer onto the existing `series` API without rework.

**Placeholder scan:** none — every step has concrete code + commands.

**Type/contract consistency:** Swift `Codable` keys (`app/upload/download/total/host/since/apps/hosts/upRate/downRate/conns/topHost/bucket/domains`) exactly match the Go `json:"…"` tags from Phase 1. `StatsProvider` method set is identical across the protocol, the impl, the tests, and `AppState` call sites. Empty-result decoding is made safe by Task 1 (Go returns `[]`).

**Risk note:** Swift 6.3 strict concurrency is sidestepped via `SWIFT_VERSION = 5.0`. If `AppState.startLive`'s `await self.provider.live()` produces an "no async operations" warning, drop the redundant `await` (the build step will surface it). GUI runtime behavior (menu bar, window) is verified by the user in Xcode; everything else is verified by `xcodebuild build`/`test`.
```
