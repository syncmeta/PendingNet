# PendingNet for iOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **历史文档，别照抄标识符。** 这是当时的实施计划/设计，按原样留存。
> 里面的 bundle id、App Group、helper 标签都是**旧的** —— 2026-08-08 macOS 已从
> `net.pending.*` 归一到 `com.pendingname.pendingnet`（iOS 更早就换过）。当前值
> 以 `app/project.yml` 和 `PendingNetIdentifiers` 为准，迁移见 `docs/macos-updates.md`。

**Goal:** 让 PendingNet iOS 的 Packet Tunnel Extension 真正联网——内嵌 sing-box libbox 内核，把已配对 VPS 的节点资料转成隧道运行配置，支持全局代理、协议手选/自动测速与三档规则分流。

**Architecture:** 配置生成全部收进 `SBTallyCore` 的纯函数，由 `swift test` + `sing-box check` 双重验证；主 App 负责刷新节点资料、下载规则集、生成配置并通过 `startTunnel` options 下发；扩展只消费本地数据，用 libbox 的 `CommandServer` 驱动内核，`PlatformInterface.openTun` 负责把 libbox 的 tun 参数翻译成 `NEPacketTunnelNetworkSettings`。

**Tech Stack:** Swift 5 / SwiftUI / NetworkExtension / sing-box libbox (gomobile XCFramework) / XcodeGen / XCTest

**设计文档：** [2026-08-07-pendingnet-ios-design.md](../specs/2026-08-07-pendingnet-ios-design.md)

**参考实现：** `/Users/hey/Untitled/sing-box-for-apple-pd`（用户自己的 SFI fork，已完成 TestFlight 发布，属已验证代码）。本计划多处要求照抄该仓库，**照抄即可，不要重新设计**。

## Global Constraints

- **部署目标：** iOS 17.0，`SWIFT_VERSION = 5.0`（`app/project.yml` 现有设置，不改）。
- **App Group：** `group.net.pending.PendingNet`（App 与 Extension 共用）。
- **Bundle ID：** App `net.pending.PendingNet.ios`，Extension `net.pending.PendingNet.ios.PacketTunnel`。
- **libbox 构建入口：** sing-box 仓库内的 `go run ./cmd/internal/build_libbox -target apple -platform ios`。**不是** `gomobile bind`。
- **gomobile 依赖：** `github.com/sagernet/gomobile/cmd/gomobile@v0.1.12` 与 `github.com/sagernet/gomobile/cmd/gobind@v0.1.12`。**不是**官方 `golang.org/x/mobile`。
- **XCFramework：** 落在 `app/Vendor/Libbox.xcframework`，实测 358MB，**绝不入 git**。
- **配置归属铁律：** `/v1/node` 只贡献协议 outbounds。`tun`、`route`、`rule_set`、`dns` 一律由客户端生成，服务端不得影响。每个配置生成测试都必须带一条断言守住这条线。
- **DNS 铁律：** 配置中**不得出现 `local` 类型的 DNS server**。这是 4.6.1 实测的内存泄漏根因（266 个 goroutine 阻塞在 `darwinLookupSystemDNS` 的 cgo 调用）。
- **rule_set 铁律：** 一律 `"type": "local"` + `"format": "binary"`，指向 App Group 内的 `.srs` 文件。扩展内不得发起下载。
- **内存验收线：** 真机承载流量 10 分钟后，常驻内存 < 40MB、`stackInuse` < 12MB、`numGoroutine` 不随时间单调增长。
- **sing-box 版本基线：** 1.13.x。配置 schema 按 1.13 写（`tun.address` 而非 `inet4_address`；不使用已废弃的 `block` outbound）。
- **提交规范：** 每个 Task 至少一次提交，`git add` 只加本任务文件，禁止 `git add -A`。commit message 结尾附 `Co-Authored-By: Claude <noreply@anthropic.com>`。

## File Structure

**新建：**
- `app/SBTallyCore/Sources/SBTallyCore/PendingNetTunnelConfig.swift` — 隧道配置生成（纯函数）与 `PendingNetRouteMode`。
- `app/SBTallyCore/Sources/SBTallyCore/PendingNetTunnelPaths.swift` — App Group 目录布局，App 与 Extension 共用。
- `app/SBTallyCore/Tests/SBTallyCoreTests/PendingNetTunnelConfigTests.swift` — 上述两者的测试。
- `scripts/build-libbox-xcframework.sh` — libbox 构建脚本。
- `app/PacketTunnel/PendingNetPlatformInterface.swift` — `LibboxPlatformInterfaceProtocol` 实现。
- `app/PendingNetIOS/PendingNetTunnelController.swift` — `NETunnelProviderManager` 安装与启停。
- `app/PendingNetIOS/PendingNetRuleSetStore.swift` — 规则集下载与校验。

**修改：**
- `app/PacketTunnel/PacketTunnelProvider.swift` — 从占位实现改为真实 Provider。
- `app/PacketTunnel/PendingNetPacketTunnel.entitlements` — 加 App Group。
- `app/project.yml` — Libbox 依赖、App Group entitlements、Extension 源文件。
- `app/PendingNetIOS/PendingNetIOSHomeView.swift` — 隧道开关、协议选择、分流模式。
- `app/PendingNetIOS/PendingNetIOSController.swift` — 接入隧道控制器。
- `.gitignore` — 加 `app/Vendor/`。

---

### Task 1: 隧道配置骨架（全局代理模式）

**Files:**
- Create: `app/SBTallyCore/Sources/SBTallyCore/PendingNetTunnelConfig.swift`
- Test: `app/SBTallyCore/Tests/SBTallyCoreTests/PendingNetTunnelConfigTests.swift`

**Interfaces:**
- Consumes: `PendingNetRuntimeServer`（已存在于 `PendingNetRuntimeConfig.swift`，字段 `serverID`/`name`/`selectorTag`/`proxyOutbounds`），`PendingNetNodeProfile.runtimeServer(name:)`。
- Produces:
  - `public enum PendingNetRouteMode: String, Codable, Sendable, CaseIterable { case global, bypassCN, direct }`
  - `public enum PendingNetTunnelConfig { public static func make(runtimeServer: PendingNetRuntimeServer, routeMode: PendingNetRouteMode, ruleSetDirectory: String, cachePath: String) throws -> Data }`
  - 复用已有的 `PendingNetRuntimeConfigError`（不新增错误类型）。

本任务只实现 `routeMode == .global`；`.bypassCN` 与 `.direct` 在 Task 3 补全，本任务中对它们抛 `invalidLocalConfiguration`。DNS 段在 Task 2 补，本任务不产出 `dns` 键。

- [ ] **Step 1: 写失败测试**

新建 `app/SBTallyCore/Tests/SBTallyCoreTests/PendingNetTunnelConfigTests.swift`：

```swift
import XCTest
@testable import SBTallyCore

final class PendingNetTunnelConfigTests: XCTestCase {
    /// 构造一份双协议节点资料，字段与 PendingNetNodeProfile 的 CodingKeys 对齐。
    static func sampleProfile() -> PendingNetNodeProfile {
        PendingNetNodeProfile(
            version: 3,
            serverID: "pn_test_server",
            updatedAt: "2026-08-07T00:00:00Z",
            protocols: [
                .init(
                    id: "reality",
                    type: "vless-reality",
                    displayName: "Reality",
                    vlessReality: .init(
                        server: "203.0.113.10",
                        serverPort: 443,
                        uuid: "11111111-2222-3333-4444-555555555555",
                        flow: "xtls-rprx-vision",
                        serverName: "www.cloudflare.com",
                        publicKey: "cHVibGljLWtleS1wbGFjZWhvbGRlcg",
                        shortID: "0123abcd"
                    ),
                    hysteria2: nil
                ),
                .init(
                    id: "hy2",
                    type: "hysteria2",
                    displayName: "Hysteria2",
                    vlessReality: nil,
                    hysteria2: .init(
                        server: "203.0.113.10",
                        serverPort: 443,
                        password: "hy2-password",
                        obfsType: "salamander",
                        obfsPassword: "obfs-password",
                        serverName: "bing.com",
                        certificatePublicKeySHA256: "3q2+7wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
                    )
                ),
            ]
        )
    }

    static func sampleRuntimeServer() throws -> PendingNetRuntimeServer {
        try sampleProfile().runtimeServer(name: "Test VPS")
    }

    func testGlobalModeBuildsTunInboundAndSelector() throws {
        let server = try Self.sampleRuntimeServer()
        let data = try PendingNetTunnelConfig.make(
            runtimeServer: server,
            routeMode: .global,
            ruleSetDirectory: "/tmp/pendingnet-rulesets",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let inbounds = try XCTUnwrap(root["inbounds"] as? [[String: Any]])
        XCTAssertEqual(inbounds.count, 1)
        let tun = try XCTUnwrap(inbounds.first)
        XCTAssertEqual(tun["type"] as? String, "tun")
        XCTAssertEqual(tun["stack"] as? String, "gvisor")
        XCTAssertEqual(tun["auto_route"] as? Bool, true)
        XCTAssertEqual(tun["mtu"] as? Int, 9000)
        XCTAssertNotNil(tun["address"] as? [String])

        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let tags = outbounds.compactMap { $0["tag"] as? String }
        XCTAssertTrue(tags.contains(server.selectorTag))
        XCTAssertTrue(tags.contains("\(server.selectorTag)-mix"))
        XCTAssertTrue(tags.contains("\(server.selectorTag)-reality"))
        XCTAssertTrue(tags.contains("\(server.selectorTag)-hy2"))
        XCTAssertTrue(tags.contains("direct"))
        XCTAssertFalse(
            outbounds.contains { ($0["type"] as? String) == "block" },
            "block outbound 在 sing-box 1.11+ 已废弃，改用 route action reject"
        )

        let selector = try XCTUnwrap(outbounds.first { $0["tag"] as? String == server.selectorTag })
        XCTAssertEqual(selector["type"] as? String, "selector")
        let members = try XCTUnwrap(selector["outbounds"] as? [String])
        XCTAssertEqual(
            members,
            ["\(server.selectorTag)-reality", "\(server.selectorTag)-hy2", "\(server.selectorTag)-mix"]
        )

        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual(route["final"] as? String, server.selectorTag)
        XCTAssertEqual(route["auto_detect_interface"] as? Bool, true)
        XCTAssertNil(route["rule_set"], "全局模式不加载任何规则集")

        let experimental = try XCTUnwrap(root["experimental"] as? [String: Any])
        let cache = try XCTUnwrap(experimental["cache_file"] as? [String: Any])
        XCTAssertEqual(cache["path"] as? String, "/tmp/pendingnet-cache.db")
        XCTAssertNil(
            experimental["clash_api"],
            "iOS 用 libbox command server，不需要 clash_api"
        )
    }

    func testServerMaterialCannotInfluenceClientPolicy() throws {
        let server = try Self.sampleRuntimeServer()
        let data = try PendingNetTunnelConfig.make(
            runtimeServer: server,
            routeMode: .global,
            ruleSetDirectory: "/tmp/pendingnet-rulesets",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])

        // 服务端资料只能出现在协议 outbound 里，不得污染 inbound/route/dns。
        for outbound in outbounds where (outbound["tag"] as? String)?.hasPrefix(server.selectorTag + "-") == true {
            XCTAssertNil(outbound["inbounds"])
            XCTAssertNil(outbound["route"])
        }
        let tun = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)
        XCTAssertNil(tun["server"], "tun inbound 不得携带任何服务端字段")
    }

    func testUnimplementedRouteModesAreRejectedForNow() throws {
        let server = try Self.sampleRuntimeServer()
        for mode in [PendingNetRouteMode.bypassCN, .direct] {
            XCTAssertThrowsError(
                try PendingNetTunnelConfig.make(
                    runtimeServer: server,
                    routeMode: mode,
                    ruleSetDirectory: "/tmp/pendingnet-rulesets",
                    cachePath: "/tmp/pendingnet-cache.db"
                )
            )
        }
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd app/SBTallyCore && swift test --filter PendingNetTunnelConfigTests
```

Expected: 编译失败，`cannot find 'PendingNetTunnelConfig' in scope`。

- [ ] **Step 3: 写最小实现**

新建 `app/SBTallyCore/Sources/SBTallyCore/PendingNetTunnelConfig.swift`：

```swift
import Foundation

/// 客户端拥有的分流策略。服务端节点资料不参与这个选择。
public enum PendingNetRouteMode: String, Codable, Sendable, CaseIterable {
    case global
    case bypassCN
    case direct
}

/// 生成 iOS Packet Tunnel 用的完整 sing-box 配置。
///
/// 与 macOS 的 PendingNetProxyOnlyConfig 平级：inbound、route、dns、rule_set
/// 全部由本函数生成，`/v1/node` 只经由 runtimeServer 贡献协议 outbounds。
public enum PendingNetTunnelConfig {
    static let tunTag = "pendingnet-tun"
    static let tunAddresses = ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]
    static let tunMTU = 9000

    public static func make(
        runtimeServer: PendingNetRuntimeServer,
        routeMode: PendingNetRouteMode,
        ruleSetDirectory: String,
        cachePath: String
    ) throws -> Data {
        guard routeMode == .global else {
            throw PendingNetRuntimeConfigError.invalidLocalConfiguration
        }
        guard !cachePath.isEmpty, !ruleSetDirectory.isEmpty else {
            throw PendingNetRuntimeConfigError.invalidLocalConfiguration
        }

        let (proxyOutbounds, protocolTags) = try managedOutbounds(runtimeServer)
        let mixTag = runtimeServer.selectorTag + "-mix"

        var outbounds: [[String: Any]] = proxyOutbounds
        outbounds.append(["type": "urltest", "tag": mixTag, "outbounds": protocolTags])
        outbounds.append([
            "type": "selector",
            "tag": runtimeServer.selectorTag,
            "outbounds": protocolTags + [mixTag],
        ])
        outbounds.append(["type": "direct", "tag": "direct"])

        let root: [String: Any] = [
            "log": ["level": "warn", "timestamp": true],
            "inbounds": [[
                "type": "tun",
                "tag": tunTag,
                "address": tunAddresses,
                "mtu": tunMTU,
                "auto_route": true,
                "strict_route": false,
                "stack": "gvisor",
            ]],
            "outbounds": outbounds,
            "route": [
                "auto_detect_interface": true,
                "final": runtimeServer.selectorTag,
                "rules": [["action": "sniff"]],
            ],
            "experimental": [
                "cache_file": ["enabled": true, "path": cachePath],
            ],
        ]
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data([0x0a])
    }

    /// 解出受管协议 outbounds，并校验它们只带本 VPS 的 tag 前缀。
    static func managedOutbounds(
        _ runtimeServer: PendingNetRuntimeServer
    ) throws -> ([[String: Any]], [String]) {
        guard runtimeServer.selectorTag.hasPrefix("pendingnet-"),
              let managed = try JSONSerialization.jsonObject(with: runtimeServer.proxyOutbounds)
              as? [[String: Any]],
              !managed.isEmpty else {
            throw PendingNetRuntimeConfigError.invalidLocalConfiguration
        }
        let prefix = runtimeServer.selectorTag + "-"
        var tags: [String] = []
        for outbound in managed {
            guard let type = outbound["type"] as? String,
                  type == "vless" || type == "hysteria2",
                  let tag = outbound["tag"] as? String,
                  tag.hasPrefix(prefix),
                  !tags.contains(tag) else {
                throw PendingNetRuntimeConfigError.invalidLocalConfiguration
            }
            tags.append(tag)
        }
        return (managed, tags)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd app/SBTallyCore && swift test --filter PendingNetTunnelConfigTests
```

Expected: 3 个测试全部 PASS。

- [ ] **Step 5: 提交**

```bash
git add app/SBTallyCore/Sources/SBTallyCore/PendingNetTunnelConfig.swift app/SBTallyCore/Tests/SBTallyCoreTests/PendingNetTunnelConfigTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): 隧道配置骨架与全局代理模式

tun inbound、urltest/selector 组装与 cache_file 全部由客户端生成，
服务端节点资料只经 runtimeServer 贡献协议 outbounds。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: DNS 段（内存风险的正面处理）

**Files:**
- Modify: `app/SBTallyCore/Sources/SBTallyCore/PendingNetTunnelConfig.swift`
- Modify: `app/SBTallyCore/Tests/SBTallyCoreTests/PendingNetTunnelConfigTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `PendingNetTunnelConfig.make(...)`（签名不变）。
- Produces: 生成的配置新增 `dns` 键；`route.rules` 首位新增 DNS 劫持规则。无新 public API。

**为什么这个任务单独存在：** 设计文档 4.6.1 的两份实测 pprof 显示，扩展贴顶时堆只有 7–15MB，而 goroutine 栈占 19–21MB，goroutine 全部堆积在 DNS 上。其中一次是 266 个 goroutine 阻塞在 `local` transport 的 cgo 系统解析。本任务是这条风险的正面处理，不是可选优化。

- [ ] **Step 1: 写失败测试**

追加到 `PendingNetTunnelConfigTests`：

```swift
    func testDNSNeverUsesLocalTransport() throws {
        let server = try Self.sampleRuntimeServer()
        let data = try PendingNetTunnelConfig.make(
            runtimeServer: server,
            routeMode: .global,
            ruleSetDirectory: "/tmp/pendingnet-rulesets",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])

        // 实测根因：local transport 走 cgo darwinLookupSystemDNS，
        // 每个阻塞查询占住一个 OS 线程，266 个查询即撑爆内存。
        XCTAssertFalse(
            servers.contains { ($0["type"] as? String) == "local" },
            "local DNS transport 会造成 goroutine/线程堆积，禁止出现"
        )
        XCTAssertTrue(servers.allSatisfy { ($0["type"] as? String) == "https" })

        let tags = servers.compactMap { $0["tag"] as? String }
        XCTAssertEqual(Set(tags), ["dns-proxy", "dns-direct"])

        // 代理侧 DNS 必须走 selector，直连侧必须走 direct，
        // 否则隧道建立前的 DNS 查询会打进黑洞而不回收。
        let proxyServer = try XCTUnwrap(servers.first { $0["tag"] as? String == "dns-proxy" })
        XCTAssertEqual(proxyServer["detour"] as? String, server.selectorTag)
        let directServer = try XCTUnwrap(servers.first { $0["tag"] as? String == "dns-direct" })
        XCTAssertEqual(directServer["detour"] as? String, "direct")

        // ipv4_only 把每个域名的查询数从 A+AAAA 两条降到一条。
        XCTAssertEqual(dns["strategy"] as? String, "ipv4_only")
        XCTAssertEqual(dns["disable_cache"] as? Bool, false)
        XCTAssertEqual(dns["independent_cache"] as? Bool, false)
        XCTAssertEqual(dns["final"] as? String, "dns-proxy")
    }

    func testDNSTrafficIsHijackedIntoTheResolver() throws {
        let server = try Self.sampleRuntimeServer()
        let data = try PendingNetTunnelConfig.make(
            runtimeServer: server,
            routeMode: .global,
            ruleSetDirectory: "/tmp/pendingnet-rulesets",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first?["action"] as? String, "sniff")
        XCTAssertTrue(
            rules.contains {
                ($0["protocol"] as? String) == "dns" && ($0["action"] as? String) == "hijack-dns"
            },
            "未劫持 DNS 会让系统解析器绕过隧道"
        )
    }
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd app/SBTallyCore && swift test --filter PendingNetTunnelConfigTests
```

Expected: `testDNSNeverUsesLocalTransport` FAIL，`XCTUnwrap` 在 `root["dns"]` 处抛出（配置里还没有 dns 键）。

- [ ] **Step 3: 写实现**

在 `PendingNetTunnelConfig` 中新增常量与 `dnsSection`：

```swift
    /// 代理侧解析器。走 selector，随隧道一起生效。
    static let proxyDNSServer = "1.1.1.1"
    /// 直连侧解析器。走 direct，用于分流模式下的国内域名。
    static let directDNSServer = "223.5.5.5"

    static func dnsSection(selectorTag: String) -> [String: Any] {
        [
            "servers": [
                [
                    "type": "https",
                    "tag": "dns-proxy",
                    "server": proxyDNSServer,
                    "detour": selectorTag,
                ],
                [
                    "type": "https",
                    "tag": "dns-direct",
                    "server": directDNSServer,
                    "detour": "direct",
                ],
            ],
            "final": "dns-proxy",
            // A+AAAA 双查会让 goroutine 数直接翻倍，实测中这是主要放大器。
            "strategy": "ipv4_only",
            "disable_cache": false,
            "independent_cache": false,
        ]
    }
```

在 `make` 的 `root` 字典中加入 `"dns": dnsSection(selectorTag: runtimeServer.selectorTag)`，并把 `route.rules` 改为：

```swift
                "rules": [
                    ["action": "sniff"],
                    ["protocol": "dns", "action": "hijack-dns"],
                ],
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd app/SBTallyCore && swift test --filter PendingNetTunnelConfigTests
```

Expected: 5 个测试全部 PASS。

- [ ] **Step 5: 用真实 sing-box 校验 schema**

本仓库已有 `testProxyOnlyBasePassesInstalledSingBoxCheck` 这个模式——用本机安装的 sing-box 二进制跑 `check`，未安装则 `XCTSkip`。DNS schema 在 sing-box 1.12 有过破坏性变更，凭记忆写必然出错，所以这一步是必需的。追加：

```swift
    func testTunnelConfigPassesInstalledSingBoxCheck() throws {
        let candidates = ["/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"]
        guard let binary = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { throw XCTSkip("sing-box is not installed") }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-tunnel-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("config.json")
        try PendingNetTunnelConfig.make(
            runtimeServer: Self.sampleRuntimeServer(),
            routeMode: .global,
            ruleSetDirectory: directory.path,
            cachePath: directory.appendingPathComponent("cache.db").path
        ).write(to: configURL)

        let check = Process()
        check.executableURL = URL(fileURLWithPath: binary)
        check.arguments = ["check", "-c", configURL.path]
        let output = Pipe()
        check.standardOutput = output
        check.standardError = output
        try check.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0, String(decoding: data, as: UTF8.self))
    }
```

运行：

```bash
cd app/SBTallyCore && swift test --filter testTunnelConfigPassesInstalledSingBoxCheck
```

若 FAIL，失败输出即 sing-box 报的具体 schema 错误（字段名、类型、废弃提示），按它修正 `dnsSection` 与 `make` 后重跑，直到 PASS。若本机没装 sing-box，先 `brew install sing-box` 再跑——**这一步不允许跳过**，它是 Task 6 之前唯一能发现 schema 错误的地方。

- [ ] **Step 6: 提交**

```bash
git add app/SBTallyCore/Sources/SBTallyCore/PendingNetTunnelConfig.swift app/SBTallyCore/Tests/SBTallyCoreTests/PendingNetTunnelConfigTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): 隧道 DNS 段，禁用 local transport

实测 pprof 显示 DNS goroutine 堆积是扩展内存见顶的根因：
一次是 266 个 goroutine 阻塞在 local transport 的 cgo 系统解析。
改为显式 DoH + detour 分离，ipv4_only 减半查询量，开启共享缓存。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: 三档分流模式

**Files:**
- Modify: `app/SBTallyCore/Sources/SBTallyCore/PendingNetTunnelConfig.swift`
- Modify: `app/SBTallyCore/Tests/SBTallyCoreTests/PendingNetTunnelConfigTests.swift`

**Interfaces:**
- Consumes: Task 1、2 的 `PendingNetTunnelConfig.make(...)`。
- Produces:
  - `public static let requiredRuleSetNames: [String]`（值为 `["geoip-cn", "geosite-cn"]`）——Task 10 的下载器按这个清单取文件。
  - `.bypassCN` 与 `.direct` 不再抛错。

- [ ] **Step 1: 写失败测试**

追加：

```swift
    func testBypassCNRoutesDomesticTrafficDirect() throws {
        let server = try Self.sampleRuntimeServer()
        let data = try PendingNetTunnelConfig.make(
            runtimeServer: server,
            routeMode: .bypassCN,
            ruleSetDirectory: "/tmp/rs",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])

        let ruleSets = try XCTUnwrap(route["rule_set"] as? [[String: Any]])
        XCTAssertEqual(ruleSets.count, 2)
        for ruleSet in ruleSets {
            XCTAssertEqual(ruleSet["type"] as? String, "local")
            XCTAssertEqual(ruleSet["format"] as? String, "binary")
            let path = try XCTUnwrap(ruleSet["path"] as? String)
            XCTAssertTrue(path.hasPrefix("/tmp/rs/"))
            XCTAssertTrue(path.hasSuffix(".srs"))
        }
        XCTAssertEqual(
            Set(ruleSets.compactMap { $0["tag"] as? String }),
            Set(PendingNetTunnelConfig.requiredRuleSetNames)
        )

        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertTrue(rules.contains { ($0["ip_is_private"] as? Bool) == true
            && ($0["outbound"] as? String) == "direct" })
        XCTAssertTrue(rules.contains { ($0["rule_set"] as? [String]) == ["geosite-cn"]
            && ($0["outbound"] as? String) == "direct" })
        XCTAssertTrue(rules.contains { ($0["rule_set"] as? [String]) == ["geoip-cn"]
            && ($0["outbound"] as? String) == "direct" })
        XCTAssertEqual(route["final"] as? String, server.selectorTag)

        // 国内域名必须用直连解析器，否则分流判断本身要先过一次代理。
        let dnsRules = try XCTUnwrap((root["dns"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertTrue(dnsRules.contains { ($0["rule_set"] as? [String]) == ["geosite-cn"]
            && ($0["server"] as? String) == "dns-direct" })
    }

    func testDirectModeKeepsTunnelUpButSendsEverythingDirect() throws {
        let server = try Self.sampleRuntimeServer()
        let data = try PendingNetTunnelConfig.make(
            runtimeServer: server,
            routeMode: .direct,
            ruleSetDirectory: "/tmp/rs",
            cachePath: "/tmp/pendingnet-cache.db"
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual(route["final"] as? String, "direct")
        XCTAssertNil(route["rule_set"], "应急模式不依赖任何规则集文件")
        XCTAssertEqual((root["dns"] as? [String: Any])?["final"] as? String, "dns-direct")

        // 隧道仍然建立，selector 仍然在位，方便一键切回。
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertTrue(outbounds.contains { $0["tag"] as? String == server.selectorTag })
        XCTAssertEqual((root["inbounds"] as? [[String: Any]])?.first?["type"] as? String, "tun")
    }

    func testEveryRouteModePassesInstalledSingBoxCheck() throws {
        let candidates = ["/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"]
        guard let binary = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { throw XCTSkip("sing-box is not installed") }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-modes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // sing-box check 会读取 local rule_set 文件，先放占位文件。
        // 真实 .srs 由 Task 10 下载；此处只验证 schema 与路径拼装。
        for name in PendingNetTunnelConfig.requiredRuleSetNames {
            try Data().write(to: directory.appendingPathComponent("\(name).srs"))
        }

        for mode in PendingNetRouteMode.allCases {
            let configURL = directory.appendingPathComponent("config-\(mode.rawValue).json")
            try PendingNetTunnelConfig.make(
                runtimeServer: Self.sampleRuntimeServer(),
                routeMode: mode,
                ruleSetDirectory: directory.path,
                cachePath: directory.appendingPathComponent("cache-\(mode.rawValue).db").path
            ).write(to: configURL)

            let check = Process()
            check.executableURL = URL(fileURLWithPath: binary)
            check.arguments = ["check", "-c", configURL.path]
            let output = Pipe()
            check.standardOutput = output
            check.standardError = output
            try check.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            check.waitUntilExit()
            XCTAssertEqual(
                check.terminationStatus, 0,
                "\(mode.rawValue): \(String(decoding: data, as: UTF8.self))"
            )
        }
    }
```

同时删除 Task 1 写的 `testUnimplementedRouteModesAreRejectedForNow`——它的前提已经不成立。

- [ ] **Step 2: 运行测试确认失败**

```bash
cd app/SBTallyCore && swift test --filter PendingNetTunnelConfigTests
```

Expected: 两个新模式测试 FAIL（`make` 仍对非 global 抛 `invalidLocalConfiguration`）。

- [ ] **Step 3: 写实现**

在 `PendingNetTunnelConfig` 中新增：

```swift
    /// Task 10 的下载器按这个清单取 .srs 文件，两处不得各写各的。
    public static let requiredRuleSetNames = ["geoip-cn", "geosite-cn"]

    static func ruleSets(directory: String) -> [[String: Any]] {
        requiredRuleSetNames.map { name in
            [
                "type": "local",
                "tag": name,
                "format": "binary",
                "path": (directory as NSString).appendingPathComponent("\(name).srs"),
            ]
        }
    }

    static func routeRules(mode: PendingNetRouteMode) -> [[String: Any]] {
        var rules: [[String: Any]] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
        ]
        if mode == .bypassCN {
            rules.append(["ip_is_private": true, "outbound": "direct"])
            rules.append(["rule_set": ["geosite-cn"], "outbound": "direct"])
            rules.append(["rule_set": ["geoip-cn"], "outbound": "direct"])
        }
        return rules
    }
```

把 `dnsSection` 改为接受模式：

```swift
    static func dnsSection(selectorTag: String, mode: PendingNetRouteMode) -> [String: Any] {
        var section: [String: Any] = [
            "servers": [
                ["type": "https", "tag": "dns-proxy", "server": proxyDNSServer, "detour": selectorTag],
                ["type": "https", "tag": "dns-direct", "server": directDNSServer, "detour": "direct"],
            ],
            "final": mode == .direct ? "dns-direct" : "dns-proxy",
            "strategy": "ipv4_only",
            "disable_cache": false,
            "independent_cache": false,
        ]
        if mode == .bypassCN {
            section["rules"] = [["rule_set": ["geosite-cn"], "server": "dns-direct"]]
        }
        return section
    }
```

`make` 中移除 `guard routeMode == .global`，并把 route 段改为：

```swift
        var route: [String: Any] = [
            "auto_detect_interface": true,
            "final": routeMode == .direct ? "direct" : runtimeServer.selectorTag,
            "rules": routeRules(mode: routeMode),
        ]
        if routeMode == .bypassCN {
            route["rule_set"] = ruleSets(directory: ruleSetDirectory)
        }
```

`dnsSection` 换了签名，`make` 里的调用点必须同步改（不改会编译不过）：

```swift
            "dns": dnsSection(selectorTag: runtimeServer.selectorTag, mode: routeMode),
```

`route` 现在是 `var` 且分支构造，`root` 字典里要引用这个变量而不是原先的内联字面量：

```swift
            "route": route,
```

- [ ] **Step 4: 运行全部测试确认通过**

```bash
cd app/SBTallyCore && swift test
```

Expected: 全部 PASS（含既有的 `PendingNetRuntimeConfigTests`、`PendingNetPairingTests`，确认无回归）。

- [ ] **Step 5: 提交**

```bash
git add app/SBTallyCore/Sources/SBTallyCore/PendingNetTunnelConfig.swift app/SBTallyCore/Tests/SBTallyCoreTests/PendingNetTunnelConfigTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): 三档分流模式与本地规则集引用

全局代理、绕过大陆+局域网、全局直连三档；rule_set 一律 local+binary，
国内域名走直连解析器避免分流判断先过一次代理。三档均通过 sing-box check。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: App Group 目录布局

**Files:**
- Create: `app/SBTallyCore/Sources/SBTallyCore/PendingNetTunnelPaths.swift`
- Modify: `app/SBTallyCore/Tests/SBTallyCoreTests/PendingNetTunnelConfigTests.swift`

**Interfaces:**
- Produces:
  - `public enum PendingNetTunnelPaths`
  - `public static let appGroupID = "group.net.pending.PendingNet"`
  - `public static func container(fileManager:) -> URL?`
  - `public static func configURL(in base: URL) -> URL`（`<base>/config.json`）
  - `public static func snapshotURL(in base: URL) -> URL`（`<base>/start-options.json`）
  - `public static func cacheURL(in base: URL) -> URL`（`<base>/cache.db`）
  - `public static func ruleSetDirectory(in base: URL) -> URL`（`<base>/rulesets`）
  - `public static func prepare(base: URL, fileManager:) throws`
- 这些被 Task 6（Extension）、Task 7（App）、Task 10（规则集下载）共同消费。放在 SBTallyCore 是因为它是唯一同时被两个 target 依赖的模块——App 与 Extension 各写一份路径必然漂移。

- [ ] **Step 1: 写失败测试**

追加一个新的 test case 类：

```swift
final class PendingNetTunnelPathsTests: XCTestCase {
    func testLayoutIsStableRelativeToContainer() throws {
        let base = URL(fileURLWithPath: "/tmp/group-container")
        XCTAssertEqual(PendingNetTunnelPaths.appGroupID, "group.net.pending.PendingNet")
        XCTAssertEqual(PendingNetTunnelPaths.configURL(in: base).path, "/tmp/group-container/config.json")
        XCTAssertEqual(
            PendingNetTunnelPaths.snapshotURL(in: base).path,
            "/tmp/group-container/start-options.json"
        )
        XCTAssertEqual(PendingNetTunnelPaths.cacheURL(in: base).path, "/tmp/group-container/cache.db")
        XCTAssertEqual(
            PendingNetTunnelPaths.ruleSetDirectory(in: base).path,
            "/tmp/group-container/rulesets"
        )
    }

    func testPrepareCreatesRuleSetDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-paths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try PendingNetTunnelPaths.prepare(base: base)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: PendingNetTunnelPaths.ruleSetDirectory(in: base).path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testPrepareIsIdempotent() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingnet-paths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try PendingNetTunnelPaths.prepare(base: base)
        XCTAssertNoThrow(try PendingNetTunnelPaths.prepare(base: base))
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd app/SBTallyCore && swift test --filter PendingNetTunnelPathsTests
```

Expected: `cannot find 'PendingNetTunnelPaths' in scope`。

- [ ] **Step 3: 写实现**

新建 `app/SBTallyCore/Sources/SBTallyCore/PendingNetTunnelPaths.swift`：

```swift
import Foundation

/// App 与 Packet Tunnel Extension 共用的 App Group 目录布局。
///
/// 两侧必须引用同一份定义：扩展读的就是 App 写的那几个文件，
/// 各写各的路径常量会在真机上表现为「配置明明写了但扩展读不到」。
public enum PendingNetTunnelPaths {
    public static let appGroupID = "group.net.pending.PendingNet"

    public static func container(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    public static func configURL(in base: URL) -> URL {
        base.appendingPathComponent("config.json")
    }

    /// startTunnel options 的持久化快照。系统按 on-demand 规则在 App
    /// 未运行时拉起隧道时，options 为空，扩展回退读这里。
    public static func snapshotURL(in base: URL) -> URL {
        base.appendingPathComponent("start-options.json")
    }

    public static func cacheURL(in base: URL) -> URL {
        base.appendingPathComponent("cache.db")
    }

    public static func ruleSetDirectory(in base: URL) -> URL {
        base.appendingPathComponent("rulesets", isDirectory: true)
    }

    public static func prepare(
        base: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: ruleSetDirectory(in: base),
            withIntermediateDirectories: true
        )
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd app/SBTallyCore && swift test --filter PendingNetTunnelPathsTests
```

Expected: 3 个测试 PASS。

- [ ] **Step 5: 提交**

```bash
git add app/SBTallyCore/Sources/SBTallyCore/PendingNetTunnelPaths.swift app/SBTallyCore/Tests/SBTallyCoreTests/PendingNetTunnelConfigTests.swift
git commit -m "$(cat <<'EOF'
feat(ios): App Group 目录布局共享定义

配置、启动快照、缓存与规则集目录的路径由 SBTallyCore 单点定义，
避免 App 与 Extension 各写一份而漂移。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: libbox 构建脚本与工程接线

**Files:**
- Create: `scripts/build-libbox-xcframework.sh`
- Modify: `.gitignore`
- Modify: `app/project.yml`
- Modify: `app/PacketTunnel/PendingNetPacketTunnel.entitlements`

**Interfaces:**
- Produces: `app/Vendor/Libbox.xcframework`，以及 `PendingNetPacketTunnel` target 对它的链接。Task 6 依赖 `import Libbox` 能编译通过。

**此任务无单元测试**，验收标准是两个 target 能编译链接成功。

- [ ] **Step 1: 写构建脚本**

新建 `scripts/build-libbox-xcframework.sh`（逻辑照搬 `/Users/hey/Untitled/sing-box-for-apple-pd/scripts/testflight-dev.sh` 的 `--rebuild-libbox` 分支，该路径已在本机跑通并完成过 TestFlight 发布）：

```bash
#!/usr/bin/env bash
set -euo pipefail

# 构建 Libbox.xcframework 供 PendingNet iOS Packet Tunnel Extension 链接。
#
# 关键点（与直觉不符，勿自行推导）：
#   1. 必须用 SagerNet fork 的 gomobile/gobind，官方 golang.org/x/mobile 不行。
#   2. 构建入口是 sing-box 仓库自带的 cmd/internal/build_libbox，不是 gomobile bind。
#   3. 产物可能落在 sing-box 仓库根目录，也可能落在 /private/tmp/sing-box-for-apple/。

SING_BOX_REF="${SING_BOX_REF:-v1.13.13}"
CORE_DIR="${SING_BOX_DIR:-/private/tmp/pendingnet-sing-box}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/app/Vendor/Libbox.xcframework"

die() { echo "error: $*" >&2; exit 1; }

command -v go >/dev/null || die "go is required"
command -v xcodebuild >/dev/null || die "Xcode command line tools are required"

export PATH="$(go env GOPATH)/bin:$PATH"
if ! command -v gomobile >/dev/null || ! command -v gobind >/dev/null; then
  go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
  go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
  gomobile init
fi

if [[ ! -d "$CORE_DIR/.git" ]]; then
  git clone https://github.com/SagerNet/sing-box.git "$CORE_DIR"
fi
git -C "$CORE_DIR" fetch --tags origin
git -C "$CORE_DIR" checkout "$SING_BOX_REF"

( cd "$CORE_DIR" && go run ./cmd/internal/build_libbox -target apple -platform ios )

CANDIDATE=""
for path in "$CORE_DIR/Libbox.xcframework" "/private/tmp/sing-box-for-apple/Libbox.xcframework"; do
  [[ -d "$path" ]] && { CANDIDATE="$path"; break; }
done
[[ -n "$CANDIDATE" ]] || die "Libbox.xcframework was not produced"

mkdir -p "$REPO_ROOT/app/Vendor"
rm -rf "$DEST"
ditto "$CANDIDATE" "$DEST"
echo "built $DEST from sing-box $SING_BOX_REF"
```

```bash
chmod +x scripts/build-libbox-xcframework.sh
```

- [ ] **Step 2: 加 gitignore**

在 `.gitignore` 末尾追加（产物实测 358MB）：

```
/app/Vendor/
```

- [ ] **Step 3: 运行构建**

```bash
./scripts/build-libbox-xcframework.sh
```

Expected: 结尾打印 `built .../app/Vendor/Libbox.xcframework from sing-box v1.13.13`。首次运行会 clone sing-box 并编译，耗时较长。

验证产物：

```bash
du -sh app/Vendor/Libbox.xcframework && ls app/Vendor/Libbox.xcframework
```

Expected: 约 358M，包含 `ios-arm64`、`ios-arm64_x86_64-simulator`、`Info.plist`。

- [ ] **Step 4: 接线 project.yml**

在 `app/project.yml` 的 `PendingNetPacketTunnel` target 下：

`sources` 保持 `- path: PacketTunnel`；`dependencies` 追加：

```yaml
      - framework: Vendor/Libbox.xcframework
        embed: false
```

`entitlements.properties` 追加 App Group：

```yaml
        com.apple.security.application-groups:
          - group.net.pending.PendingNet
```

在 `PendingNetIOS` target 下新增 entitlements 块（该 target 目前没有）：

```yaml
    entitlements:
      path: PendingNetIOS/PendingNetIOS.entitlements
      properties:
        com.apple.developer.networking.networkextension:
          - packet-tunnel-provider
        com.apple.security.application-groups:
          - group.net.pending.PendingNet
```

- [ ] **Step 5: 生成工程并确认能编译**

```bash
cd app && xcodegen generate
```

```bash
cd app && xcodebuild -project PendingNet.xcodeproj -scheme PendingNetIOS -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

Expected: BUILD SUCCEEDED。此时 Extension 仍是占位实现，只验证 Libbox 链接成功。

若报 `framework not found Libbox`，检查 `app/Vendor/Libbox.xcframework` 是否存在、`project.yml` 里的相对路径是否相对 `app/`。

- [ ] **Step 6: 提交**

```bash
git add scripts/build-libbox-xcframework.sh .gitignore app/project.yml app/PacketTunnel/PendingNetPacketTunnel.entitlements app/PendingNetIOS/PendingNetIOS.entitlements
git commit -m "$(cat <<'EOF'
build(ios): libbox xcframework 构建脚本与工程接线

照搬已验证的 SFI 构建路径：SagerNet fork 的 gomobile v0.1.12 +
sing-box 自带的 build_libbox 入口。产物 358MB 不入 git。
两个 target 加上 App Group 与 packet-tunnel-provider entitlement。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Packet Tunnel Extension 真实实现

**Files:**
- Create: `app/PacketTunnel/PendingNetPlatformInterface.swift`
- Modify: `app/PacketTunnel/PacketTunnelProvider.swift`

**Interfaces:**
- Consumes: `PendingNetTunnelPaths`（Task 4）、`Libbox`（Task 5）。
- Produces: `PacketTunnelProvider` 可被 `NETunnelProviderManager` 启动；接受 `startTunnel` options 中的 `configContent: String`，缺失时回退读快照。

**照抄来源：** `/Users/hey/Untitled/sing-box-for-apple-pd/Library/Network/ExtensionProvider.swift` 与 `ExtensionPlatformInterface.swift`。这是平台样板代码，不要重新设计。本任务只保留 iOS 所需部分，删掉 macOS 系统扩展、tvOS、Widget、CoreLocation 相关分支。

- [ ] **Step 1: 写 PlatformInterface**

新建 `app/PacketTunnel/PendingNetPlatformInterface.swift`。核心是 `openTun`：把 `LibboxTunOptions` 翻译成 `NEPacketTunnelNetworkSettings`，应用后回传 tun 文件描述符。

```swift
import Foundation
import Libbox
import NetworkExtension

final class PendingNetPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol,
    LibboxCommandServerHandlerProtocol
{
    private unowned let tunnel: PacketTunnelProvider

    init(_ tunnel: PacketTunnelProvider) {
        self.tunnel = tunnel
    }

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options, let ret0_ else {
            throw PendingNetTunnelError.message("tun options 或返回指针为空")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var thrown: Error?
        Task {
            do { try await self.applyTunOptions(options, ret0_) } catch { thrown = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let thrown { throw thrown }
    }

    private func applyTunOptions(
        _ options: LibboxTunOptionsProtocol,
        _ ret0_: UnsafeMutablePointer<Int32>
    ) async throws {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        if options.getDNSMode()?.value != LibboxDNSModeDisabled {
            let iterator = try options.getDNSServerAddress()
            var servers: [String] = []
            while iterator.hasNext() { servers.append(iterator.next()) }
            if !servers.isEmpty {
                settings.dnsSettings = NEDNSSettings(servers: servers)
            }
        }

        var v4Addresses: [String] = []
        var v4Masks: [String] = []
        if let iterator = options.getInet4Address() {
            while iterator.hasNext() {
                guard let prefix = iterator.next() else { continue }
                v4Addresses.append(prefix.address())
                v4Masks.append(prefix.mask())
            }
        }
        let v4 = NEIPv4Settings(addresses: v4Addresses, subnetMasks: v4Masks)
        v4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = v4

        var v6Addresses: [String] = []
        var v6Prefixes: [NSNumber] = []
        if let iterator = options.getInet6Address() {
            while iterator.hasNext() {
                guard let prefix = iterator.next() else { continue }
                v6Addresses.append(prefix.address())
                v6Prefixes.append(NSNumber(value: prefix.prefix()))
            }
        }
        if !v6Addresses.isEmpty {
            let v6 = NEIPv6Settings(addresses: v6Addresses, networkPrefixLengths: v6Prefixes)
            v6.includedRoutes = [NEIPv6Route.default()]
            settings.ipv6Settings = v6
        }

        try await tunnel.setTunnelNetworkSettings(settings)

        if let fd = tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = fd
            return
        }
        let looped = LibboxGetTunnelFileDescriptor()
        guard looped != -1 else {
            throw PendingNetTunnelError.message("无法取得 tun 文件描述符")
        }
        ret0_.pointee = looped
    }

    func usePlatformAutoDetectControl() -> Bool { false }

    func autoDetectControl(_: Int32) throws {}

    func writeLog(_ message: String?) {
        guard let message else { return }
        NSLog("[PendingNet] %@", message)
    }
}

enum PendingNetTunnelError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}
```

**注意：** `LibboxPlatformInterfaceProtocol` 与 `LibboxCommandServerHandlerProtocol` 的完整方法列表以 `app/Vendor/Libbox.xcframework/ios-arm64/Libbox.framework/Versions/A/Headers/Libbox.objc.h` 为准。编译器会报缺哪个方法，按报错补空实现（返回默认值即可），参考 SFI 同名方法的处理。

- [ ] **Step 2: 改写 Provider**

替换 `app/PacketTunnel/PacketTunnelProvider.swift` 全文：

```swift
import Foundation
import Libbox
import NetworkExtension
import SBTallyCore

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var platformInterface = PendingNetPlatformInterface(self)
    private var commandServer: LibboxCommandServer?

    override func startTunnel(options: [String: NSObject]?) async throws {
        guard let base = PendingNetTunnelPaths.container() else {
            throw PendingNetTunnelError.message("无法访问 App Group 容器")
        }
        try PendingNetTunnelPaths.prepare(base: base)

        let configContent = try resolveConfigContent(options: options, base: base)

        let setup = LibboxSetupOptions()
        setup.basePath = base.path
        setup.workingPath = base.path
        setup.tempPath = NSTemporaryDirectory()
        setup.logMaxLines = 500
        // 实测扩展贴顶时 goroutine 栈占近一半内存，OOM killer 是兜底。
        setup.oomKillerEnabled = true

        var setupError: NSError?
        LibboxSetup(setup, &setupError)
        if let setupError {
            throw PendingNetTunnelError.message("libbox setup 失败：\(setupError.localizedDescription)")
        }
        LibboxPromoteOOMDraft()

        var serverError: NSError?
        let server = LibboxNewCommandServer(platformInterface, platformInterface, &serverError)
        if let serverError {
            throw PendingNetTunnelError.message("创建 command server 失败：\(serverError.localizedDescription)")
        }
        guard let server else {
            throw PendingNetTunnelError.message("创建 command server 失败")
        }
        try server.start()
        commandServer = server

        try server.startOrReloadService(configContent, options: LibboxOverrideOptions())
    }

    /// 配置来源两级：优先 startTunnel options，回退持久化快照。
    ///
    /// 系统按 on-demand 规则在 App 未运行时拉起隧道时 options 为空，
    /// 只认 options 会导致自启永远失败；只读文件则拿不到本次启动的新配置。
    private func resolveConfigContent(options: [String: NSObject]?, base: URL) throws -> String {
        if let content = options?["configContent"] as? String, !content.isEmpty {
            try Data(content.utf8).write(
                to: PendingNetTunnelPaths.snapshotURL(in: base),
                options: .atomic
            )
            return content
        }
        let snapshot = PendingNetTunnelPaths.snapshotURL(in: base)
        guard let data = try? Data(contentsOf: snapshot),
              let content = String(data: data, encoding: .utf8),
              !content.isEmpty else {
            throw PendingNetTunnelError.message("没有可用配置，请回到 PendingNet 完成配对")
        }
        return content
    }

    override func stopTunnel(with _: NEProviderStopReason) async {
        try? commandServer?.closeService()
        if let commandServer {
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            commandServer.close()
        }
        commandServer = nil
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let content = String(data: messageData, encoding: .utf8), !content.isEmpty else {
            return "空配置".data(using: .utf8)
        }
        do {
            guard let base = PendingNetTunnelPaths.container() else {
                throw PendingNetTunnelError.message("无法访问 App Group 容器")
            }
            try Data(content.utf8).write(
                to: PendingNetTunnelPaths.snapshotURL(in: base),
                options: .atomic
            )
            reasserting = true
            defer { reasserting = false }
            try commandServer?.startOrReloadService(content, options: LibboxOverrideOptions())
            return nil
        } catch {
            return error.localizedDescription.data(using: .utf8)
        }
    }

    override func sleep() async { commandServer?.pause() }

    override func wake() { commandServer?.wake() }
}
```

- [ ] **Step 3: 编译**

```bash
cd app && xcodegen generate && xcodebuild -project PendingNet.xcodeproj -scheme PendingNetIOS -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

Expected: BUILD SUCCEEDED。若报协议方法未实现，按 Step 1 的注意事项补齐。

- [ ] **Step 4: 提交**

```bash
git add app/PacketTunnel/PendingNetPlatformInterface.swift app/PacketTunnel/PacketTunnelProvider.swift
git commit -m "$(cat <<'EOF'
feat(ios): Packet Tunnel Extension 接入 libbox 内核

PlatformInterface 把 LibboxTunOptions 翻译成 NEPacketTunnelNetworkSettings
并回传 tun fd；配置来源两级——startTunnel options 优先，持久化快照兜底，
以覆盖系统 on-demand 自启时 App 未运行的场景。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: App 侧隧道控制与开关 UI

**Files:**
- Create: `app/PendingNetIOS/PendingNetTunnelController.swift`
- Modify: `app/PendingNetIOS/PendingNetIOSController.swift`
- Modify: `app/PendingNetIOS/PendingNetIOSHomeView.swift`

**Interfaces:**
- Consumes: `PendingNetTunnelPaths`（Task 4）、`PendingNetTunnelConfig.make(...)`（Task 1–3）、`PendingNetIOSController.nodeProfile` 与 `.server`（已存在）。
- Produces:
  - `@MainActor final class PendingNetTunnelController: ObservableObject`
  - `@Published private(set) var status: NEVPNStatus`
  - `@Published var routeMode: PendingNetRouteMode`
  - `func load() async`
  - `func start(profile: PendingNetNodeProfile, serverName: String, serverID: String) async throws`
  - `func stop() async`
  - `func reload(profile: PendingNetNodeProfile, serverName: String) async throws`（Task 10 切换分流模式时调用）

**两条来自设计文档第 5 节的错误处理，在本任务落实：**

- **Keychain 中无设备令牌** → `start` 直接抛错阻止启动，提示重新配对。
- **`/v1/node` 刷新失败** → 沿用上次成功写入的配置，只提示不中断。现有的 `PendingNetIOSController.refreshNodeProfile()` 已是「失败只写 `errorMessage`、不清空 `nodeProfile`」，且配置已落盘在 App Group，因此这条无需新代码——但**不要**在本任务里给它加上「刷新失败就停隧道」的逻辑，那会把一次网络抖动变成断网。

**关于 `providerConfiguration["configVersion"]`：** 设计文档 4.3 原本设想用版本号触发扩展重载。实际采用 options 下发 + `sendProviderMessage` 主动重载后，版本比对已无必要。该字段保留为占位，不参与任何判断，不要为它写比对逻辑。

- [ ] **Step 1: 写控制器**

新建 `app/PendingNetIOS/PendingNetTunnelController.swift`：

```swift
import Foundation
import NetworkExtension
import SBTallyCore

@MainActor
final class PendingNetTunnelController: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published var routeMode: PendingNetRouteMode = .global

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    private let tunnelBundleID = "net.pending.PendingNet.ios.PacketTunnel"
    private let routeModeKey = "pendingnet.ios.route-mode.v1"

    init() {
        if let raw = UserDefaults.standard.string(forKey: routeModeKey),
           let mode = PendingNetRouteMode(rawValue: raw) {
            routeMode = mode
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func load() async {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        let existing = managers.first { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == tunnelBundleID
        }
        manager = existing
        status = existing?.connection.status ?? .invalid
        observeStatus()
    }

    private func observeStatus() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        guard let connection = manager?.connection else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.status = connection.status }
        }
    }

    func setRouteMode(_ mode: PendingNetRouteMode) {
        routeMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: routeModeKey)
    }

    /// 生成配置并启动隧道。配置内容随 startTunnel options 下发，
    /// 不写进 providerConfiguration——VPN profile 由系统 preferences
    /// 数据库保存，不具备 App Group 文件同等的数据保护属性。
    ///
    /// 启动前先确认 Keychain 里有设备令牌：没有令牌意味着配对已失效，
    /// 此时隧道即使起得来也拿不到后续的节点资料刷新，应当直接拦住并
    /// 要求重新配对，而不是让用户面对一条不会自愈的连接。
    func start(
        profile: PendingNetNodeProfile,
        serverName: String,
        serverID: String
    ) async throws {
        guard try PendingNetCredentialStore.load(serverID: serverID) != nil else {
            throw PendingNetPairingError.serverRejected("此设备没有找到 VPS 访问凭据，请重新配对")
        }
        let content = try makeConfigContent(profile: profile, serverName: serverName)
        let manager = try await installedManager()
        try manager.connection.startVPNTunnel(options: [
            "configContent": content as NSString,
        ])
    }

    func stop() async {
        manager?.connection.stopVPNTunnel()
    }

    func reload(profile: PendingNetNodeProfile, serverName: String) async throws {
        let content = try makeConfigContent(profile: profile, serverName: serverName)
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected else { return }
        try session.sendProviderMessage(Data(content.utf8)) { response in
            if let response, let text = String(data: response, encoding: .utf8), !text.isEmpty {
                NSLog("[PendingNet] reload failed: %@", text)
            }
        }
    }

    private func makeConfigContent(
        profile: PendingNetNodeProfile,
        serverName: String
    ) throws -> String {
        guard let base = PendingNetTunnelPaths.container() else {
            throw PendingNetPairingError.serverRejected("无法访问 App Group 容器")
        }
        try PendingNetTunnelPaths.prepare(base: base)
        let data = try PendingNetTunnelConfig.make(
            runtimeServer: try profile.runtimeServer(name: serverName),
            routeMode: routeMode,
            ruleSetDirectory: PendingNetTunnelPaths.ruleSetDirectory(in: base).path,
            cachePath: PendingNetTunnelPaths.cacheURL(in: base).path
        )
        // 同时落盘一份，便于真机排查「App 生成的配置到底长什么样」。
        try data.write(to: PendingNetTunnelPaths.configURL(in: base), options: .atomic)
        return String(decoding: data, as: UTF8.self)
    }

    private func installedManager() async throws -> NETunnelProviderManager {
        let manager = self.manager ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol)
            ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleID
        proto.serverAddress = "PendingNet"
        // 只放版本号，任何密钥或连接材料都不进 VPN profile。
        proto.providerConfiguration = ["configVersion": 1]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "PendingNet"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager
        observeStatus()
        return manager
    }
}
```

- [ ] **Step 2: 接入现有 controller**

在 `app/PendingNetIOS/PendingNetIOSController.swift` 的 `PendingNetIOSController` 中新增：

```swift
    let tunnel = PendingNetTunnelController()
```

- [ ] **Step 3: 加开关 UI**

在 `app/PendingNetIOS/PendingNetIOSHomeView.swift` 中，于展示 `nodeProfile` 的区块下方加入隧道开关。按该文件现有的 SwiftUI 风格与 `PendingNetTheme` 用法编写：

```swift
    @ViewBuilder
    private func tunnelSection(
        profile: PendingNetNodeProfile,
        serverName: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("隧道")
                    .font(.headline)
                Spacer()
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button(isConnected ? "断开" : "连接") {
                Task {
                    if isConnected {
                        await controller.tunnel.stop()
                    } else {
                        do {
                            try await controller.tunnel.start(
                                profile: profile,
                                serverName: serverName,
                                serverID: profile.serverID
                            )
                        } catch {
                            controller.errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var isConnected: Bool {
        controller.tunnel.status == .connected || controller.tunnel.status == .connecting
    }

    private var statusText: String {
        switch controller.tunnel.status {
        case .connected: "已连接"
        case .connecting: "连接中"
        case .disconnecting: "断开中"
        case .disconnected, .invalid: "未连接"
        case .reasserting: "重连中"
        @unknown default: "未知"
        }
    }
```

在该视图的 `.task { }` 中调用 `await controller.tunnel.load()`。

- [ ] **Step 4: 编译并在模拟器确认 UI**

```bash
cd app && xcodegen generate && xcodebuild -project PendingNet.xcodeproj -scheme PendingNetIOS -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

Expected: BUILD SUCCEEDED。模拟器可确认 UI 布局与状态文案，**但无法启动 Packet Tunnel**——点击「连接」在模拟器上必然失败，这是预期行为，真机验证留给 Task 8。

- [ ] **Step 5: 提交**

```bash
git add app/PendingNetIOS/PendingNetTunnelController.swift app/PendingNetIOS/PendingNetIOSController.swift app/PendingNetIOS/PendingNetIOSHomeView.swift
git commit -m "$(cat <<'EOF'
feat(ios): 隧道控制器与开关 UI

NETunnelProviderManager 安装与启停；配置内容随 startTunnel options
下发，providerConfiguration 只留版本号，密钥不进 VPN profile。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: 真机最小闭环验收

**Files:** 无代码改动。本任务的交付物是一份验收结论；若发现缺陷，缺陷修复计入本任务。

**前置（阻塞本任务，不阻塞前面任何任务）：**
- Apple 开发者后台 App ID `net.pending.PendingNet.ios` 与 `net.pending.PendingNet.ios.PacketTunnel` 启用 Network Extension capability；
- App Group `group.net.pending.PendingNet` 注册并勾选到两个 App ID；
- 真机 provisioning profile 就绪。

均为后台自助配置，无需向 Apple 提交额外申请（同账号已有 Packet Tunnel 应用完成过 TestFlight 外部测试发布）。

- [ ] **Step 1: 真机安装**

```bash
cd app && xcodebuild -project PendingNet.xcodeproj -scheme PendingNetIOS -configuration Debug -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

用 Xcode 将 Debug 构建安装到真机（模拟器无法运行 Packet Tunnel，此步不存在自动化替代）。

- [ ] **Step 2: 走通配对**

在设备上导入一份新生成的 `.pdn`（VPS 上 `sudo pendingnet-server pair create --out /root/ios.pdn`，每台设备单独生成，默认十分钟过期且只能用一次）。确认界面显示已配对与节点资料。

- [ ] **Step 3: 启动隧道**

点击「连接」，首次会弹出系统 VPN 配置授权。确认状态变为「已连接」。

- [ ] **Step 4: 验证真实流量**

在设备上访问一个境外站点，确认可加载。在 VPS 上确认对应端口有连接：

```bash
sudo ss -tnp | grep -E ':443' | head
```

Expected: 能看到来自设备公网 IP 的连接。

- [ ] **Step 5: 验证停止**

点击「断开」，确认状态回到「未连接」，且设备网络恢复直连。

- [ ] **Step 6: 验证 on-demand 自启回退路径**

杀掉 PendingNet App（从后台划掉），在设置中手动打开 VPN 开关。确认隧道能起来——这条走的是 Task 6 的快照回退分支，若此处失败说明快照未写入或路径不一致。

- [ ] **Step 7: 记录结论**

把验收结果（含失败项与修复）追加到设计文档的实现盘点小节，提交。

```bash
git add docs/superpowers/specs/2026-08-07-pendingnet-ios-design.md
git commit -m "$(cat <<'EOF'
docs(ios): 记录真机最小闭环验收结果

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: 协议手选与自动测速

**Files:**
- Modify: `app/PendingNetIOS/PendingNetTunnelController.swift`
- Modify: `app/PendingNetIOS/PendingNetIOSHomeView.swift`

**Interfaces:**
- Consumes: Task 7 的 `PendingNetTunnelController`。
- Produces:
  - `@Published private(set) var currentOutbound: String?`
  - `@Published private(set) var outboundDelays: [String: Int]`
  - `func selectOutbound(_ tag: String) async throws`
  - `func runURLTest() async throws`

**通道分工（不要混用）：** selector 切换与 urltest 走 libbox command client 连扩展内的 command server；`sendProviderMessage` 只用于换配置（Task 7 的 `reload`）。走 command client 的好处是**协议切换不重启隧道，连接不中断**。

- [ ] **Step 1: 确认 command client API**

```bash
grep -n "CommandClient\|selectOutbound\|urlTest\|URLTest" app/Vendor/Libbox.xcframework/ios-arm64/Libbox.framework/Versions/A/Headers/Libbox.objc.h | head -40
```

以头文件为准写实现——`LibboxCommandClient` 的构造参数、handler 协议方法名以实际头文件为准，不要凭记忆。参考 SFI 中 command client 的用法：

```bash
grep -rn "LibboxCommandClient\|LibboxNewStandaloneCommandClient" /Users/hey/Untitled/sing-box-for-apple-pd/Library /Users/hey/Untitled/sing-box-for-apple-pd/ApplicationLibrary | head -20
```

- [ ] **Step 2: 实现切换与测速**

在 `PendingNetTunnelController` 中按上一步查到的 API 实现 `selectOutbound(_:)` 与 `runURLTest()`，把结果写进 `currentOutbound` 与 `outboundDelays`。selector 的 tag 是 `runtimeServer.selectorTag`，可选成员是 `<selectorTag>-<protocolID>` 与 `<selectorTag>-mix`（分别对应各协议与 urltest 自动选择），这些由 Task 1 的配置生成保证。

- [ ] **Step 3: 加 UI**

在 `PendingNetIOSHomeView` 的隧道区块内，当状态为已连接时展示协议选择器（列出 selector 成员，标注各自延迟）与「测速」按钮。

- [ ] **Step 4: 真机验证**

在真机上：连接隧道 → 切换协议 → 确认状态栏 VPN 图标未断开、网页可继续加载 → 点测速 → 确认两个协议都返回延迟数值。

- [ ] **Step 5: 提交**

```bash
git add app/PendingNetIOS/PendingNetTunnelController.swift app/PendingNetIOS/PendingNetIOSHomeView.swift
git commit -m "$(cat <<'EOF'
feat(ios): 协议手选与自动测速

经 libbox command client 切换 selector 与触发 urltest，隧道不重启、
连接不中断。sendProviderMessage 仍只用于换配置。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: 规则集下载与分流模式切换

**Files:**
- Create: `app/PendingNetIOS/PendingNetRuleSetStore.swift`
- Modify: `app/PendingNetIOS/PendingNetIOSHomeView.swift`

**Interfaces:**
- Consumes: `PendingNetTunnelConfig.requiredRuleSetNames`（Task 3）、`PendingNetTunnelPaths.ruleSetDirectory(in:)`（Task 4）、`PendingNetTunnelController.setRouteMode(_:)` 与 `reload(profile:serverName:)`（Task 7）。
- Produces:
  - `@MainActor final class PendingNetRuleSetStore: ObservableObject`
  - `@Published private(set) var isReady: Bool`
  - `func ensureAvailable() async throws`
  - `func refresh() async throws`

**约束：** 下载只在主 App 内发生，扩展绝不联网。文件名必须是 `<name>.srs`，与 Task 3 的路径拼装一致。

- [ ] **Step 1: 实现下载器**

新建 `app/PendingNetIOS/PendingNetRuleSetStore.swift`：

```swift
import Foundation
import SBTallyCore

@MainActor
final class PendingNetRuleSetStore: ObservableObject {
    @Published private(set) var isReady = false

    private static let sources: [String: URL] = [
        "geoip-cn": URL(
            string: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"
        )!,
        "geosite-cn": URL(
            string: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"
        )!,
    ]

    init() {
        isReady = Self.allPresent()
    }

    /// 已有有效文件时直接返回，不重复下载。
    func ensureAvailable() async throws {
        if Self.allPresent() {
            isReady = true
            return
        }
        try await refresh()
    }

    func refresh() async throws {
        guard let base = PendingNetTunnelPaths.container() else {
            throw PendingNetPairingError.serverRejected("无法访问 App Group 容器")
        }
        try PendingNetTunnelPaths.prepare(base: base)
        let directory = PendingNetTunnelPaths.ruleSetDirectory(in: base)

        for name in PendingNetTunnelConfig.requiredRuleSetNames {
            guard let source = Self.sources[name] else {
                throw PendingNetPairingError.serverRejected("未知规则集：\(name)")
            }
            let (temporary, response) = try await URLSession.shared.download(from: source)
            defer { try? FileManager.default.removeItem(at: temporary) }

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw PendingNetPairingError.serverRejected("规则集下载失败：\(name)")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size]
                as? Int) ?? 0
            // 空文件会让 sing-box 启动失败，宁可保留旧文件也不覆盖。
            guard (size ?? 0) > 0 else {
                throw PendingNetPairingError.serverRejected("规则集内容为空：\(name)")
            }

            // 原子替换，避免扩展读到写了一半的文件。
            let destination = directory.appendingPathComponent("\(name).srs")
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        }
        isReady = Self.allPresent()
    }

    private static func allPresent() -> Bool {
        guard let base = PendingNetTunnelPaths.container() else { return false }
        let directory = PendingNetTunnelPaths.ruleSetDirectory(in: base)
        return PendingNetTunnelConfig.requiredRuleSetNames.allSatisfy { name in
            let path = directory.appendingPathComponent("\(name).srs").path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            return (size ?? 0) > 0
        }
    }
}
```

文件名必须是 `<name>.srs`，与 Task 3 的 `ruleSets(directory:)` 路径拼装严格一致——两处不一致的表现是 sing-box 启动时报找不到规则集文件。

- [ ] **Step 2: 加分流模式 UI**

在 `PendingNetIOSHomeView` 中加入三档 `Picker`，绑定 `controller.tunnel.routeMode`。切换时：

1. 若选到 `.bypassCN`，先 `await ruleSetStore.ensureAvailable()`；
2. 调用 `controller.tunnel.setRouteMode(mode)`；
3. 若隧道已连接，调用 `controller.tunnel.reload(profile:serverName:)` 应用新配置。

按设计文档第 5 节的错误处理：规则集缺失或损坏时**降级为全局代理模式并提示，不使隧道启动失败**。

- [ ] **Step 3: 真机验证**

- 切到「绕过大陆」，确认规则集下载成功、隧道 reload 后仍连通；
- 访问一个国内站点，在 VPS 上确认**没有**对应连接（走了直连）；
- 访问一个境外站点，在 VPS 上确认**有**连接；
- 切到「全局直连」，确认 VPN 仍开启但 VPS 上无新连接；
- 手动删除一个 `.srs` 文件后切到「绕过大陆」，确认降级为全局代理且有提示，隧道未崩。

- [ ] **Step 4: 提交**

```bash
git add app/PendingNetIOS/PendingNetRuleSetStore.swift app/PendingNetIOS/PendingNetIOSHomeView.swift
git commit -m "$(cat <<'EOF'
feat(ios): 规则集下载与三档分流切换

下载只在主 App 内发生，扩展仅以 type=local 读取 App Group 内的
二进制 .srs。规则集缺失时降级为全局代理而非启动失败。

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: 内存验收

**Files:** 无必然代码改动。若不达标，优化改动计入本任务。

**这是整个计划里唯一未经验证的风险。** 设计文档 4.6 的对策来自实测 pprof 的根因分析，但对策本身的有效性只能靠真机数据收敛。

**验收线（全部必须达标）：**
- 真机承载流量 10 分钟后，扩展常驻内存 < 40MB；
- `stackInuse` < 12MB；
- `numGoroutine` 稳定，不随时间单调增长。

后两项是先行指标——内存见顶前 goroutine 数已经先涨，只盯 memoryUsage 会错过窗口。

- [ ] **Step 1: 加诊断入口**

在 `PendingNetIOSHomeView` 加一个仅 Debug 可见的按钮，经 command client 触发 libbox 的诊断导出，产出与 `docs/` 中分析过的 pprof 快照同构的数据（`metadata.json` + `heap.pb` + `goroutine.pb` + `threadcreate.pb`）。具体 API 以头文件为准：

```bash
grep -n "OOMReport\|Profile\|pprof\|Dump" app/Vendor/Libbox.xcframework/ios-arm64/Libbox.framework/Versions/A/Headers/Libbox.objc.h | head -20
```

- [ ] **Step 2: 采样**

真机连接隧道，正常使用 10 分钟（含视频播放等高连接数场景），期间在第 1、5、10 分钟各导出一次快照。

- [ ] **Step 3: 分析**

```bash
go tool pprof -top -nodecount=20 goroutine.pb
```

```bash
go tool pprof -top -sample_index=inuse_space -nodecount=20 heap.pb
```

对照三次快照的 `numGoroutine` 与 `stackInuse` 是否单调增长。重点确认 goroutine 栈顶**不再出现** `dns/transport/local.darwinLookupSystemDNS`（Task 2 的 DNS 段应已根除这条路径）。

- [ ] **Step 4: 达标则记录，不达标则处理**

不达标时按以下顺序排查，每改一项重新采样：

1. goroutine 仍堆在 DNS → 检查生成的配置里是否真的没有 `local` server（把 `config.json` 从 App Group 导出来看）；
2. goroutine 堆在连接复制 → 调低 `LibboxSetupOptions` 的日志与缓存；
3. 堆内存偏高而非栈 → 检查规则集是否误用了 JSON 格式而非二进制 `.srs`。

- [ ] **Step 5: 记录结论并提交**

把三次采样的数值与结论写进设计文档 4.6.3，提交。

```bash
git add docs/superpowers/specs/2026-08-07-pendingnet-ios-design.md
git commit -m "$(cat <<'EOF'
docs(ios): 记录内存验收采样结果

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

## 任务依赖与并行性

- Task 1 → 2 → 3 严格串行（同一文件递进）。
- Task 4 可与 1–3 并行。
- Task 5 可与 1–4 并行（不依赖任何 Swift 代码）。
- Task 6 依赖 4、5；Task 7 依赖 1–5。
- Task 8 依赖 6、7，且依赖 Apple 后台配置就绪。
- Task 9、10 依赖 8 通过。
- Task 11 最后。

**Task 1–7 全部不需要 Apple 后台配置**，可在 entitlement 与 provisioning 就绪前完成。
