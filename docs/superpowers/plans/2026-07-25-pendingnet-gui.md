# PendingNet GUI 改版（阶段 A）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 SBTally GUI 升级为 PendingNet：免密启停、三接管模式（TUN/系统代理/仅端口）、三规则（全局/白名单/黑名单，零重启切换）、规则集自动更新、菜单栏全功能。

**Architecture:** GUI(PendingNet.app) —XPC→ 特权助手(SMAppService daemon, root, 启停引擎/切接管模式/系统代理) + —HTTP→ sbtally daemon :7777(统计/Clash API 中转/规则集更新)。三规则做成 sing-box 自定义 clash_mode（Global/Whitelist/Blacklist），切换零重启。接管模式 = 预生成 tun/notun 两份配置，助手拷贝激活 + kickstart。

**Tech Stack:** Go（generator/daemon）、Swift/SwiftUI + SMAppService + XPC（GUI/helper）、xcodegen、launchd。

**Spec:** `docs/superpowers/specs/2026-07-25-pendingnet-gui-design.md`

## Global Constraints

- GUI 显示名一律 **PendingNet**；bundle id **net.pending.PendingNet**；helper 标签 **net.pending.PendingNet.helper**。
- **不改** io.sbtally.\* launchd 标签、sbtally CLI/daemon 名、/usr/local/etc/sbtally/ 路径（阶段 B 迁移）。
- 引擎配置目录 /usr/local/etc/sbtally/：master.json（激活）、master-tun.json、master-notun.json、mode（当前接管模式）、\*.srs（属主改用户）。
- 规则集文件名固定：geosite-cn.srs, geoip-cn.srs, geosite-geolocation-noncn.srs, geosite-category-ads-all.srs, geosite-gfw.srs。
- clash 模式名固定字符串：`Global` / `Whitelist` / `Blacklist`（UI 显示 全局/白名单/黑名单）。默认 Whitelist。
- 启动离线安全：任何改动不得让 sing-box 启动依赖网络（规则集必须 local 类型）。
- Go 测试 `go test ./...`；Swift 包测试 `cd app/SBTallyCore && swift test`；GUI 构建 `cd app && xcodegen generate && xcodebuild -project SBTally.xcodeproj -scheme PendingNet -configuration Release -derivedDataPath /tmp/pn-dd build`。
- 提交遵循用户全局规则：小单元自动提交，只 add 相关文件，trailer `Co-Authored-By: Claude <noreply@anthropic.com>`。

---

### Task 1: 生成器——三 clash_mode 规则 + local 规则集 + 默认模式

**Files:**
- Modify: `internal/sbconfig/generate.go`
- Test: `internal/sbconfig/generate_test.go`

**Interfaces:**
- Produces: `Options` 新增字段 `RuleSetDir string`（非空 ⇒ 输出 local 规则集，路径 `<dir>/<file>`）、`DefaultMode string`（默认 "Whitelist"，写入 clash_api.default_mode）。规则含 clash_mode Global/Whitelist/Blacklist 三组；新增规则集 tag `geosite-gfw`。

- [ ] **Step 1: 失败测试**

在 `generate_test.go` 追加：

```go
func TestGenerateThreeModesLocalRuleSets(t *testing.T) {
	out, err := Generate([]VPS{{Name: "v1", Outbounds: []Outbound{{Tag: "hy2", Raw: json.RawMessage(`{"type":"hysteria2","tag":"hy2"}`)}}}},
		Options{EnableTun: true, RuleSetDir: "/usr/local/etc/sbtally"})
	if err != nil {
		t.Fatal(err)
	}
	var c map[string]any
	if err := json.Unmarshal(out, &c); err != nil {
		t.Fatal(err)
	}
	route := c["route"].(map[string]any)
	s := string(out)
	for _, want := range []string{
		`"clash_mode": "Global"`, `"clash_mode": "Whitelist"`, `"clash_mode": "Blacklist"`,
		`"geosite-gfw"`, `"/usr/local/etc/sbtally/geosite-gfw.srs"`,
		`"default_mode": "Whitelist"`,
	} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %s", want)
		}
	}
	for _, rs := range route["rule_set"].([]any) {
		m := rs.(map[string]any)
		if m["type"] != "local" {
			t.Errorf("rule_set %v not local", m["tag"])
		}
	}
	if strings.Contains(s, `"download_detour"`) {
		t.Error("remote rule-set leaked")
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `go test ./internal/sbconfig/ -run ThreeModes -v` → FAIL（缺字段/缺规则）。

- [ ] **Step 3: 实现**

`generate.go` 改动四处：

1. Options 增加：

```go
	RuleSetDir  string // non-empty: emit local rule-sets from this dir (offline-safe startup)
	DefaultMode string // clash_api default_mode, default "Whitelist"
```

2. rules 中段替换（原 `clash_mode Direct/Global` 两行起，到 whitelist 尾部）。共享前缀（sniff/resolve/hijack-dns/AppRules/ads/private）保持不变，之后：

```go
	rules = append(rules,
		map[string]any{"rule_set": "geosite-ads", "action": "reject"},
		map[string]any{"ip_is_private": true, "outbound": "direct"},
		// Global: everything else → proxy.
		map[string]any{"clash_mode": "Global", "outbound": "proxy"},
		// Blacklist: only GFW-listed names → proxy, rest direct.
		map[string]any{"clash_mode": "Blacklist", "rule_set": "geosite-gfw", "outbound": "proxy"},
		map[string]any{"clash_mode": "Blacklist", "outbound": "direct"},
		// Whitelist (default fall-through): CN direct, known-foreign proxy, final proxy.
		map[string]any{"rule_set": []string{"geoip-cn", "geosite-cn"}, "outbound": "direct"},
		map[string]any{"rule_set": "geosite-noncn", "outbound": "proxy"},
	)
```

（原有 AppRules 循环仍插在 ads 之前，与现状一致；删除原 `clash_mode: Direct/Global` 两行。）

3. ruleSet 构造改为二选一：

```go
	files := map[string]string{
		"geosite-cn":     "geosite-cn.srs",
		"geoip-cn":       "geoip-cn.srs",
		"geosite-noncn":  "geosite-geolocation-noncn.srs",
		"geosite-ads":    "geosite-category-ads-all.srs",
		"geosite-gfw":    "geosite-gfw.srs",
	}
	ruleSet := []any{}
	if opts.RuleSetDir != "" {
		for tag, f := range files { // deterministic order: iterate a sorted slice of tags
			ruleSet = append(ruleSet, map[string]any{"type": "local", "tag": tag,
				"format": "binary", "path": opts.RuleSetDir + "/" + f})
		}
	} else {
		// remote 分支保留现有四条 + gfw（download_detour proxy），仅测试/预览用
	}
```

（实现时用 `sort.Strings` 固定顺序，保证输出可复现。gfw 远程 URL 用 MetaCubeX（官方 SagerNet 源无 gfw 文件，已实测 404）：`https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/gfw.srs`。noncn 远程文件名保持 `geosite-geolocation-!cn.srs`，local 文件名用约定的 `geosite-geolocation-noncn.srs`。）

4. clashAPI 增加 `"default_mode": str(opts.DefaultMode, "Whitelist")`。

- [ ] **Step 4: 全量测试**

Run: `go test ./...` → PASS（老测试若断言 Direct/Global 行为需同步更新）。

- [ ] **Step 5: Commit**

```bash
git add internal/sbconfig/generate.go internal/sbconfig/generate_test.go
git commit -m "feat(sbconfig): three clash modes + local rule-sets + default_mode

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: CLI + update-config.sh——双变体输出，吸收 python 补丁

**Files:**
- Modify: `cmd/sbtally/main.go`（config generate 子命令）
- Modify: `deploy/update-config.sh`
- Test: 手工 `sing-box check`

**Interfaces:**
- Consumes: Task 1 的 `Options.RuleSetDir`。
- Produces: `sbtally config generate --ruleset-dir DIR --out-dir DIR`：向 out-dir 写 `master-tun.json`（EnableTun=true）与 `master-notun.json`（false）两份；保留原 `--out`（单文件，向后兼容）。

- [ ] **Step 1: main.go 的 generate 分支加 flags**

```go
	rulesetDir := fs.String("ruleset-dir", "", "emit local rule-sets from this dir")
	outDir := fs.String("out-dir", "", "write master-tun.json and master-notun.json here")
```

`--out-dir` 非空时循环两次 Generate（EnableTun true/false），分别写 `filepath.Join(*outDir, "master-tun.json")` / `master-notun.json`（0644）。

- [ ] **Step 2: update-config.sh 简化**

删除内嵌 python；生成改为：

```bash
sbtally config generate "$@" --clash-secret "$(cat "$SECRET_FILE")" \
    --ruleset-dir /usr/local/etc/sbtally --out-dir "$TMPDIR_GEN"
```

对两份产物分别 `sing-box check`；安装：

```bash
sudo install -m 0644 "$TMPDIR_GEN"/master-*.json "$ETC/"
MODE=$(cat "$ETC/mode" 2>/dev/null || echo tun)
[[ "$MODE" == tun ]] && ACTIVE=master-tun.json || ACTIVE=master-notun.json
sudo install -m 0644 "$ETC/$ACTIVE" "$ETC/master.json"
sudo launchctl kickstart -k system/io.sbtally.singbox
```

（检验 notun 变体时规则集路径同目录，文件已在，无需 sed。）

- [ ] **Step 3: 真机验证**

```bash
go build -o /tmp/sbtally.bin ./cmd/sbtally && /tmp/sbtally.bin config generate \
  --vps t="$HOME/Library/Group Containers/287TTNZF8L.io.nekohasekai.sfavt/configs/config_70.json" \
  --ruleset-dir "$HOME/sbtally-srs" --out-dir /tmp/pnv && \
  sing-box check -c /tmp/pnv/master-tun.json && sing-box check -c /tmp/pnv/master-notun.json
```

Expected: 两个 check 都过（gfw srs 先手动下到 ~/sbtally-srs，见 Task 6 亦会装到 etc）。

- [ ] **Step 4: Commit**

```bash
git add cmd/sbtally/main.go deploy/update-config.sh
git commit -m "feat(cli): dual-variant config output + local ruleset flags

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: daemon 规则集自动更新器

**Files:**
- Create: `internal/daemon/rulesets.go`
- Test: `internal/daemon/rulesets_test.go`
- Modify: `internal/daemon/server.go`（注册路由）、`cmd/sbtally/main.go`（daemon 启动 updater，flag `--ruleset-dir`，默认 /usr/local/etc/sbtally）

**Interfaces:**
- Produces:

```go
type RuleSetUpdater struct { Dir string; ProxyAddr string; Client *http.Client } // ProxyAddr default "http://127.0.0.1:2080"
func NewRuleSetUpdater(dir, proxyAddr string) *RuleSetUpdater
func (u *RuleSetUpdater) UpdateAll(ctx context.Context) map[string]error // per-file result
func (u *RuleSetUpdater) Status() []RuleSetStatus // {Tag, File, ModTime}
func (u *RuleSetUpdater) RunEvery(ctx context.Context, d time.Duration)
func RegisterRuleSets(mux *http.ServeMux, u *RuleSetUpdater) // GET /api/rulesets, POST /api/rulesets/update
```

- URL 表：四个 SagerNet 官方 URL（noncn 本地名 geosite-geolocation-noncn.srs ↔ 远程 `geosite-geolocation-!cn.srs`）+ gfw 用 MetaCubeX：`https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/gfw.srs`（SagerNet 无此文件）。

- [ ] **Step 1: 失败测试**（httptest 假源 + 临时目录，注入 BaseURL——struct 加非导出 `geositeBase/geoipBase` 字段测试覆写）

```go
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
		if err != nil { t.Fatalf("%s: %v", f, err) }
	}
	b, _ := os.ReadFile(filepath.Join(dir, "geosite-cn.srs"))
	if !strings.HasPrefix(string(b), "SRSDATA-") { t.Error("not replaced") }
	if len(u.Status()) != 5 { t.Errorf("want 5 statuses") }
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
	if string(b) != "old" { t.Error("old file clobbered on failure") }
}
```

- [ ] **Step 2: 跑测试失败** `go test ./internal/daemon/ -run RuleSet -v` → FAIL。

- [ ] **Step 3: 实现** rulesets.go：下载到 `<file>.tmp` → 非空且 ≥1KB（真实 srs 最小几 KB；测试数据放宽为非空）→ `os.Rename` 原子替换。ProxyAddr 非空时 `http.Transport{Proxy: http.ProxyURL(...)}`。RunEvery 用 `time.Ticker`，首次跑前等 2 分钟（等引擎就绪）。RegisterRuleSets：GET 返回 `[{"tag":..,"file":..,"updated_at":RFC3339}]`；POST 同步跑 UpdateAll 并返回 per-file 错误 map。

- [ ] **Step 4: 测试过 + 全量** `go test ./...` → PASS。

- [ ] **Step 5: 接线** server.go/main.go：daemon 模式创建 updater（dir 来自 flag），`go u.RunEvery(ctx, 24*time.Hour)`，注册路由。构建冒烟：`go build ./...`。

- [ ] **Step 6: Commit**

```bash
git add internal/daemon/rulesets.go internal/daemon/rulesets_test.go internal/daemon/server.go cmd/sbtally/main.go
git commit -m "feat(daemon): rule-set auto-updater (24h via local proxy, atomic, offline-safe)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: 特权助手 PendingNetHelper（SMAppService + XPC）

**Files:**
- Create: `app/PendingNetHelper/main.swift`（helper 全部逻辑，单文件）
- Create: `app/PendingNetHelper/HelperProtocol.swift`（GUI 与 helper 共用，加入两个 target）
- Create: `app/PendingNetHelper/net.pending.PendingNet.helper.plist`
- Modify: `app/project.yml`

**Interfaces:**
- Produces（GUI 依赖）：

```swift
@objc public protocol HelperProtocol {
    func startEngine(reply: @escaping (String?) -> Void)          // nil = ok, else error text
    func stopEngine(reply: @escaping (String?) -> Void)
    func setTakeover(_ mode: String, reply: @escaping (String?) -> Void) // "tun"|"sysproxy"|"local"
    func status(reply: @escaping (Bool, String, String) -> Void)  // running, mode, lastLogTail
}
```

- Mach service: `net.pending.PendingNet.helper`。

- [ ] **Step 1: HelperProtocol.swift**（如上，`import Foundation`）。

- [ ] **Step 2: helper plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>net.pending.PendingNet.helper</string>
    <key>BundleProgram</key><string>Contents/MacOS/PendingNetHelper</string>
    <key>MachServices</key><dict><key>net.pending.PendingNet.helper</key><true/></dict>
    <key>AssociatedBundleIdentifiers</key><array><string>net.pending.PendingNet</string></array>
</dict></plist>
```

- [ ] **Step 3: main.swift** 要点（完整实现）：

```swift
import Foundation

let ETC = "/usr/local/etc/sbtally"
let LABEL = "system/io.sbtally.singbox"

func sh(_ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (p.terminationStatus, out)
}
func launchctl(_ sub: [String]) -> String? {
    let (code, out) = sh(["/bin/launchctl"] + sub)
    return code == 0 ? nil : out
}
func networkServices() -> [String] { // active-ish: all listed services minus '*'-disabled
    let (_, out) = sh(["/usr/sbin/networksetup", "-listallnetworkservices"])
    return out.split(separator: "\n").dropFirst().map(String.init).filter { !$0.hasPrefix("*") }
}
func setSystemProxy(_ on: Bool) {
    for s in networkServices() {
        if on {
            _ = sh(["/usr/sbin/networksetup", "-setwebproxy", s, "127.0.0.1", "2080"])
            _ = sh(["/usr/sbin/networksetup", "-setsecurewebproxy", s, "127.0.0.1", "2080"])
            _ = sh(["/usr/sbin/networksetup", "-setsocksfirewallproxy", s, "127.0.0.1", "2080"])
        } else {
            _ = sh(["/usr/sbin/networksetup", "-setwebproxystate", s, "off"])
            _ = sh(["/usr/sbin/networksetup", "-setsecurewebproxystate", s, "off"])
            _ = sh(["/usr/sbin/networksetup", "-setsocksfirewallproxystate", s, "off"])
        }
    }
}
func currentMode() -> String {
    (try? String(contentsOfFile: "\(ETC)/mode", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "tun"
}
func engineRunning() -> Bool {
    let (code, out) = sh(["/bin/launchctl", "print", LABEL])
    return code == 0 && out.contains("state = running")
}

final class Helper: NSObject, HelperProtocol, NSXPCListenerDelegate {
    func startEngine(reply: @escaping (String?) -> Void) {
        _ = launchctl(["bootout", LABEL])   // idempotent
        let err = launchctl(["bootstrap", "system", "/Library/LaunchDaemons/io.sbtally.singbox.plist"])
        if err == nil && currentMode() == "sysproxy" { setSystemProxy(true) }
        reply(err)
    }
    func stopEngine(reply: @escaping (String?) -> Void) {
        setSystemProxy(false)               // unconditional: never leave stale proxy
        reply(launchctl(["bootout", LABEL]))
    }
    func setTakeover(_ mode: String, reply: @escaping (String?) -> Void) {
        guard ["tun", "sysproxy", "local"].contains(mode) else { return reply("bad mode") }
        let variant = mode == "tun" ? "master-tun.json" : "master-notun.json"
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: "\(ETC)/\(variant)"))
            try data.write(to: URL(fileURLWithPath: "\(ETC)/master.json"))
            try mode.write(toFile: "\(ETC)/mode", atomically: true, encoding: .utf8)
        } catch { return reply("\(error)") }
        setSystemProxy(mode == "sysproxy")
        reply(launchctl(["kickstart", "-k", LABEL]))
    }
    func status(reply: @escaping (Bool, String, String) -> Void) {
        let (_, tail) = sh(["/usr/bin/tail", "-n", "5", "/var/log/sbtally-singbox.log"])
        reply(engineRunning(), currentMode(), tail)
    }
    func listener(_ l: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        c.exportedObject = self
        c.resume()
        return true
    }
}

let delegate = Helper()
let listener = NSXPCListener(machServiceName: "net.pending.PendingNet.helper")
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
```

（XPC 调用方校验：初版接受任意连接——本机单用户、helper 动作有限且与 sudoers 兜底等价；`setCodeSigningRequirement` 在自签证书稳定后加，代码留 `// TODO(hardening)` 会违反无占位规则，故直接不写，记入阶段 B。）

- [ ] **Step 4: project.yml**

```yaml
name: PendingNet
options:
  bundleIdPrefix: net.pending
  deploymentTarget:
    macOS: "14.0"
settings:
  base:
    SWIFT_VERSION: "5.0"
    MARKETING_VERSION: "0.2.0"
    CURRENT_PROJECT_VERSION: "1"
    GENERATE_INFOPLIST_FILE: "YES"
packages:
  SBTallyCore:
    path: SBTallyCore
targets:
  PendingNetHelper:
    type: tool
    platform: macOS
    sources:
      - path: PendingNetHelper
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: net.pending.PendingNet.helper
        PRODUCT_NAME: PendingNetHelper
  PendingNet:
    type: application
    platform: macOS
    sources:
      - path: SBTally
      - path: PendingNetHelper/HelperProtocol.swift
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: net.pending.PendingNet
        PRODUCT_NAME: PendingNet
    dependencies:
      - package: SBTallyCore
        product: SBTallyCore
      - target: PendingNetHelper
        embed: false
    postBuildScripts:
      - name: Embed helper + daemon plist
        script: |
          APP="$BUILT_PRODUCTS_DIR/$PRODUCT_NAME.app"
          mkdir -p "$APP/Contents/Library/LaunchDaemons" "$APP/Contents/MacOS"
          cp "$BUILT_PRODUCTS_DIR/PendingNetHelper" "$APP/Contents/MacOS/"
          cp "$SRCROOT/PendingNetHelper/net.pending.PendingNet.helper.plist" "$APP/Contents/Library/LaunchDaemons/"
```

- [ ] **Step 5: 构建冒烟**

```bash
cd app && xcodegen generate && xcodebuild -project PendingNet.xcodeproj -scheme PendingNet -configuration Release -derivedDataPath /tmp/pn-dd build
```

Expected: BUILD SUCCEEDED，且 `/tmp/pn-dd/Build/Products/Release/PendingNet.app/Contents/MacOS/PendingNetHelper` 与 `Contents/Library/LaunchDaemons/...plist` 存在。

- [ ] **Step 6: Commit**

```bash
git add app/PendingNetHelper app/project.yml
git commit -m "feat(app): PendingNetHelper privileged daemon (SMAppService + XPC)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: GUI——改名 + EngineController + 菜单栏/Control 全功能

**Files:**
- Create: `app/SBTally/EngineController.swift`
- Modify: `app/SBTally/SBTallyApp.swift`、`app/SBTally/AppState.swift`、`app/SBTally/Views/MenuBarView.swift`、`app/SBTally/Views/ControlView.swift`
- Test: SBTallyCore 现有测试不变；GUI 构建 + 真机冒烟

**Interfaces:**
- Consumes: Task 4 `HelperProtocol`；daemon `/api/control/*`（已有）、`/api/rulesets`（Task 3）。
- Produces:

```swift
@MainActor final class EngineController: ObservableObject {
    @Published var running: Bool
    @Published var takeover: String      // "tun"|"sysproxy"|"local"
    @Published var helperReady: Bool
    @Published var lastError: String?
    func registerHelper()                // SMAppService.daemon(plistName:).register()
    func start() async; func stop() async
    func setTakeover(_ m: String) async
    func refresh() async                 // helper status() → published props
}
```

- [ ] **Step 1: EngineController.swift**

```swift
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class EngineController: ObservableObject {
    @Published var running = false
    @Published var takeover = "tun"
    @Published var helperReady = false
    @Published var lastError: String?

    private let service = SMAppService.daemon(plistName: "net.pending.PendingNet.helper.plist")

    private func proxy() -> HelperProtocol? {
        let c = NSXPCConnection(machServiceName: "net.pending.PendingNet.helper",
                                options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        c.resume()
        return c.remoteObjectProxyWithErrorHandler { [weak self] e in
            Task { @MainActor in self?.lastError = e.localizedDescription; self?.helperReady = false }
        } as? HelperProtocol
    }

    func registerHelper() {
        do { try service.register(); helperReady = true }
        catch { lastError = "助手授权失败：\(error.localizedDescription)" }
    }
    func refresh() async {
        helperReady = service.status == .enabled
        guard helperReady, let p = proxy() else { return }
        await withCheckedContinuation { k in
            p.status { run, mode, _ in
                Task { @MainActor in self.running = run; self.takeover = mode; k.resume() }
            }
        }
    }
    private func call(_ f: (HelperProtocol, @escaping (String?) -> Void) -> Void) async {
        guard let p = proxy() else { return }
        await withCheckedContinuation { k in
            f(p) { err in Task { @MainActor in self.lastError = err; k.resume() } }
        }
        await refresh()
    }
    func start() async { await call { p, r in p.startEngine(reply: r) } }
    func stop() async { await call { p, r in p.stopEngine(reply: r) } }
    func setTakeover(_ m: String) async { await call { p, r in p.setTakeover(m, reply: r) } }
}
```

- [ ] **Step 2: SBTallyApp.swift 改名 + 注入**

Window 标题与 id 改 `Window("PendingNet", id: "main")`；`@StateObject private var engine = EngineController()`；MenuBarExtra label 换 `Image(systemName: "network")`，`.environmentObject(engine)` 传入两个 scene；`.task { await engine.refresh() }`。

- [ ] **Step 3: MenuBarView 重写**

```swift
struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var engine: EngineController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !engine.helperReady {
                Button("需要授权特权助手…") { engine.registerHelper() }
            } else {
                Toggle(engine.running ? "已连接" : "已停止", isOn: Binding(
                    get: { engine.running },
                    set: { on in Task { on ? await engine.start() : await engine.stop() } }))
                    .toggleStyle(.switch)
            }
            Picker("接管", selection: Binding(
                get: { engine.takeover },
                set: { m in Task { await engine.setTakeover(m) } })) {
                Text("TUN").tag("tun"); Text("系统代理").tag("sysproxy"); Text("仅端口").tag("local")
            }
            Picker("规则", selection: Binding(
                get: { state.mode },
                set: { m in Task { await state.setMode(m) } })) {
                Text("全局").tag("Global"); Text("白名单").tag("Whitelist"); Text("黑名单").tag("Blacklist")
            }
            // 现有 VPS/协议选择器与速率行保持，取自 state.control
            if let err = engine.lastError { Text(err).font(.caption).foregroundStyle(.red) }
            Divider()
            Button("打开 PendingNet") { openWindow(id: "main") }
            Button("退出") { NSApplication.shared.terminate(nil) }
        }
        .pickerStyle(.segmented)
        .padding(10)
        .frame(width: 300)
    }
}
```

（`state.mode` / `state.setMode` 已由 Phase 4 ControlProvider 提供，UI 值即 clash 模式字符串；若现值是 Rule/Global/Direct 旧集合，随 Task 1 配置更新后 daemon 透传新模式名，无代码改动。）

- [ ] **Step 4: ControlView 增补** 启停 Toggle + 接管 Picker（复用 MenuBarView 同款 Binding 写法）、规则集更新区（GET `/api/rulesets` 列表 + “立即更新” POST，简单 URLSession 调用，展示 updated_at）。用户可见字符串中 “SBTally” → “PendingNet”。

- [ ] **Step 5: 构建 + 真机冒烟**

```bash
cd app && xcodegen generate && xcodebuild -project PendingNet.xcodeproj -scheme PendingNet -configuration Release -derivedDataPath /tmp/pn-dd build && ditto /tmp/pn-dd/Build/Products/Release/PendingNet.app /Applications/PendingNet.app && open /Applications/PendingNet.app
```

冒烟清单：菜单栏出现 → 点“需要授权”（首次输一次密码）→ Toggle 停/启引擎（网络断/恢复）→ 切“仅端口”（TUN 消失，curl -x 127.0.0.1:2080 可用）→ 切回 TUN → 规则切“全局/黑名单”后 `curl 127.0.0.1:9090/proxies` 模式变化。

- [ ] **Step 6: Commit**

```bash
git add app/SBTally app/project.yml
git commit -m "feat(app): PendingNet rename + engine start/stop + takeover & rule pickers in menu bar

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: 部署收尾——gfw 规则集、目录属主、selfcheck、旧应用清理

**Files:**
- Modify: `deploy/install.sh`、`deploy/selfcheck.sh`、`deploy/SETUP.md`

**Interfaces:**
- Consumes: Task 2 双变体、Task 3 updater 路径约定。

- [ ] **Step 1: install.sh 增补**（幂等，放在装配置之后）

```bash
echo "==> Rule-sets: ownership + geosite-gfw"
sudo chown "$(id -un)":staff /usr/local/etc/sbtally /usr/local/etc/sbtally/*.srs 2>/dev/null || true
if [[ ! -f /usr/local/etc/sbtally/geosite-gfw.srs ]]; then
    curl -sfm 30 -o /tmp/geosite-gfw.srs \
      https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/gfw.srs \
      || curl -sfm 30 -x http://127.0.0.1:2080 -o /tmp/geosite-gfw.srs \
      https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/gfw.srs
    install -m 0644 /tmp/geosite-gfw.srs /usr/local/etc/sbtally/
fi
sudo rm -rf /Applications/SBTally.app
```

- [ ] **Step 2: selfcheck.sh 增补**（第 3 节后）

```bash
say "-- 3b. mode & rulesets"
MODE=$(cat /usr/local/etc/sbtally/mode 2>/dev/null || echo tun)
say "  takeover mode: $MODE"
CM=$(curl -sm 3 -H "Authorization: Bearer $SECRET" 127.0.0.1:9090/configs | python3 -c 'import json,sys;print(json.load(sys.stdin).get("mode",""))' 2>/dev/null)
if [[ -n "$CM" ]]; then ok "clash rule mode: $CM"; else bad "cannot read clash mode"; fi
for f in geosite-cn geoip-cn geosite-geolocation-noncn geosite-category-ads-all geosite-gfw; do
    [[ -s "/usr/local/etc/sbtally/$f.srs" ]] && ok "$f.srs present" || bad "$f.srs missing"
done
```

- [ ] **Step 3: SETUP.md** 校对：改 PendingNet 叫法、双变体说明、验证清单加“切接管模式/规则”。

- [ ] **Step 4: 真机跑一遍** `deploy/selfcheck.sh` 全 OK。

- [ ] **Step 5: Commit**

```bash
git add deploy/install.sh deploy/selfcheck.sh deploy/SETUP.md
git commit -m "chore(deploy): gfw ruleset, user-writable ruleset dir, selfcheck mode asserts

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Self-Review 结论

- Spec 覆盖：改名(T4/T5)、启停(T4/T5)、三接管(T2/T4/T5)、三规则(T1/T5)、协议/VPS(现有,T5 保留)、菜单栏(T5)、规则集自动更新(T3/T5/T6)、离线安全(T1 local 规则集/T3 失败保旧)、SFM 冲突检测已有 9090 报错路径(维持)。
- 已知妥协（记入阶段 B）：XPC 无 code-signing 校验；SMAppService 自签失败时的 sudoers 兜底未编码（真机验证 Task 5 冒烟时若 register 报错，临时用 `sudo launchctl` 手动装 helper plist 顶替，并在阶段 B 处理）。
- 类型/命名一致性：HelperProtocol 两处引用同文件共享；模式串 "tun/sysproxy/local" 与 "Global/Whitelist/Blacklist" 全文一致；文件名五元组三处（T1/T3/T6）一致。
