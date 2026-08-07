# PendingNet for iOS 设计

- **日期：** 2026-08-07
- **状态：** 待实施
- **前置：** [PendingNet Server / Client 统一设计（阶段 B）](2026-07-31-pendingnet-server-client-design.md) 第 6 节「iOS 能力边界」

## 1. 问题

iOS 的配对链路已经跑通：`.pdn` 导入、设备注册、Keychain 保存令牌、`/v1/node` 读取节点资料都已实现，Packet Tunnel Extension 的工程骨架也已建好。缺的是唯一一件事——扩展里没有代理内核，`PacketTunnelProvider.startTunnel` 直接返回 `proxyCoreNotInstalled`。

macOS 用 `Process` 拉起独立的 sing-box 二进制。iOS 不允许 fork 子进程，代理内核必须以库的形式链接进 Network Extension 内部。因此 iOS 版的全部工作收敛为：选定一个可内嵌的内核，把共享层的节点资料转成它的运行配置，并在 50MB 内存上限内跑起来。

## 2. 范围

**v1 包含：** 配对（已完成）、单 VPS、启动/停止 VPN、全局代理、协议手选与自动测速、规则分流。

**v1 不包含：** 流量统计面板、多 VPS 并存、按进程/按应用规则（iOS 平台不支持）。

## 3. 分发与内核选型

分发方式为 **TestFlight 小范围内测**。这排除了正式上架 App Store，因而 sing-box 的 GPL-3.0 与 App Store 条款的冲突不构成阻塞。

选定 **sing-box `libbox`**：gomobile 将 `github.com/sagernet/sing-box/experimental/libbox` 打包为 `Libbox.xcframework`，链接进 Packet Tunnel Extension。

理由：Reality、Hysteria2、rule-set、urltest 全部原生支持，一次覆盖 v1 全部范围；其配置格式正是共享层 [`PendingNetRuntimeConfig`](../../../app/SBTallyCore/Sources/SBTallyCore/PendingNetRuntimeConfig.swift) 已在产出的 sing-box JSON，macOS 与 iOS 自此共用同一套配置语义。

已评估并否决的方案：

- **Xray-core + hysteria 客户端库分别链接**：License 更干净（MPL-2.0 / MIT），但 Xray 不支持 Hysteria2，两个内核各管一半流量，路由与分流需在 Swift 侧自行调度，规则分流基本需要重写。仅当目标改为正式上架 App Store 时才值得付出这一代价。
- **纯 Swift 自研**：Reality 的 uTLS 指纹与 Hysteria2 的 QUIC + Brutal 拥塞控制自研不现实。

## 4. 架构

### 4.1 内核构建

构建流程直接照搬 `sing-box-for-apple-pd/scripts/testflight-dev.sh` 的 `--rebuild-libbox` 分支——该脚本已在本机跑通并完成过 TestFlight 发布，属于已验证路径，不需要重新试错。

关键点（均与常见直觉不符，照抄即可，勿自行推导）：

- 依赖的是 **SagerNet fork 的 gomobile**，不是官方 `golang.org/x/mobile`：
  `go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12`、
  `go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12`，随后 `gomobile init`。
- 实际构建入口是 sing-box 仓库自带的 `go run ./cmd/internal/build_libbox -target apple -platform ios`，**不是手写 `gomobile bind`**。gomobile/gobind 只是它的前置依赖。
- 产物落在 sing-box 仓库根目录或 `/private/tmp/sing-box-for-apple/`，需两处都探测。

产出以 `ditto` 复制到 `app/Vendor/Libbox.xcframework`。**实测体积 358MB**，必然不纳入 git；`.gitignore` 增加 `app/Vendor/`。可复现性由脚本中锁定的 sing-box tag 保证。`project.yml` 中 `PendingNetPacketTunnel` target 增加本地 framework 依赖。

### 4.2 配置生成

在 `SBTallyCore` 中新增 `PendingNetTunnelConfig`，与现有 `PendingNetProxyOnlyConfig` 平级。它生成 iOS 隧道所需的完整 sing-box JSON：

- `inbounds`：单个 `tun` inbound，stack 使用 gvisor；地址与 MTU 由该函数固定，不可由服务端影响。
- `outbounds`：复用 `PendingNetNodeProfile.runtimeServer(name:)` 产出的协议 outbounds，其上挂 `urltest` 与 `selector`，另加 `direct`、`block`。
- `route`：按分流模式组装规则，`rule_set` 一律为 `type: local`，指向 App Group 内的 `.srs` 文件。
- `dns`：显式配置的 DoH/UDP server，带超时与缓存，**不使用 `local` transport**。理由见 4.6。
- `experimental`：`cache_file` 指向 App Group 容器；command server 监听供 App 侧控制。

**配置归属边界与 macOS 完全一致，不放宽**：`/v1/node` 只贡献协议 outbounds，`tun`、`route`、`rule_set`、DNS 策略一律由客户端生成。服务端无法通过节点资料影响客户端的路由行为。

该函数为纯函数，可由 `swift test` 完整覆盖，测试结构与现有 `PendingNetRuntimeConfigTests` 同构。

### 4.3 App 与 Extension 的边界

共享通道：

- **App Group** `group.net.pending.PendingNet`：存放生成好的 `config.json`、规则集 `.srs`、以及 sing-box 的 cache 文件。
- **Keychain Access Group**：共享设备令牌。

**扩展不联网。** `/v1/node` 刷新、规则集下载、配置生成与写盘全部由主 App 负责，扩展只读取 App Group 内的本地文件。这样扩展内不存在 HTTP 栈、不存在令牌刷新的时序问题，内存占用也显著更低。

`NETunnelProviderManager` 的 `providerConfiguration` 只携带配置版本号。**任何密钥或连接材料都不写入 VPN profile**——VPN 配置由系统 preferences 数据库保存，不具备与 App Group 文件同等的数据保护属性。

配置传递采用 SFI 已验证的两级方式：

1. App 启动隧道时，把配置内容作为 `startTunnel` 的 `options["configContent"]` 字符串传入；
2. 扩展收到后**立即持久化一份快照**到 App Group。当系统在 App 未运行时按 on-demand 规则自行拉起隧道，`startTunnel` 的 options 为空，此时回退读取该快照。

单靠 App Group 文件读取会漏掉第 2 种场景，单靠 options 传递则无法应对系统自启——两级缺一不可。

隧道启动流程：解析配置 → `LibboxSetup` → `LibboxNewCommandServer(platformInterface, ...)` 并 `start()` → `commandServer.startOrReloadService(configContent, options:)`。tun 的建立由 libbox 回调 `PlatformInterface.openTun` 完成：把 `LibboxTunOptions` 翻译成 `NEPacketTunnelNetworkSettings`（含地址、路由、MTU、DNS）并 `setTunnelNetworkSettings`，再回传 tun 文件描述符。

参考实现：`sing-box-for-apple-pd` 的 `Library/Network/ExtensionProvider.swift` 与 `ExtensionPlatformInterface.swift`。这两处是平台样板代码，照抄即可，不必重新设计。

### 4.4 协议切换与状态回传

扩展内运行 libbox command server（`LibboxNewCommandServer`）。两条通道分工不同，不要混用：

- **selector 切换与 urltest 测速**走 libbox command client 连接 command server。协议切换因此**不需要重启隧道**，连接不中断。
- **`sendProviderMessage` 只用于换配置**：扩展收到后更新持久化快照并 `startOrReloadService`。SFI 的 `handleAppMessage` 就是这个用途。

状态回传 v1 只包含 `{state, lastError, currentOutbound, delay}`，以 JSON 编码返回。

### 4.5 规则分流

三档模式，保存在客户端本地策略中：

1. **全局代理**：`route.final` 指向 selector。
2. **绕过大陆 + 局域网**：私有地址段与大陆 IP/域名走 `direct`，其余走 selector。
3. **全局直连**：应急模式，全部走 `direct`，隧道保持开启。

规则集使用二进制 `.srs` 而非 JSON，由主 App 预先下载至 App Group。扩展以 `type: local` 引用，**离线可用**，且不在扩展内产生下载行为。

### 4.6 内存约束

iOS Packet Tunnel Provider 的内存上限约为 50MB，超出即被系统终止。这是本设计最可能失败的环节，必须作为显式验收项处理，而非事后调优。

#### 4.6.1 实测依据

两份来自 sing-box 1.13.13 iOS 扩展（go1.26.3, ios/arm64）的现场 pprof 快照，均抓取于贴顶时刻：

| | A (2026-07-07) | B (2026-07-16) |
|---|---|---|
| memoryUsage / availableMemory | 45MB / 4.9MB | 45MB / 4.0MB |
| 堆存活（heapAlloc） | 7.4MB | 14.6MB |
| goroutine 栈（stackInuse） | 21MB | 19MB |
| goroutine 数 | 430 | 2160 |
| OS 线程数 | 283 | 29 |

结论：**堆不是瓶颈，goroutine 栈才是**，占用接近总量的一半。两次的 goroutine 都堆积在 DNS：

- A：266 个 goroutine 阻塞在 `dns/transport/local.darwinLookupSystemDNS` 的 cgo 调用中。cgo 阻塞调用每个占住一个 OS 线程，因而线程数达到 283。
- B：2083 个 goroutine（96%）阻塞在 `dns.(*Client).Exchange`。线程仅 29，为纯 Go 侧 park；2160 × 8KB ≈ 17MB，与 stackInuse 19MB 吻合。查询发出后既未返回也未超时回收。

两项被实测否定的既有假设：

- **规则集不是负担。** `srs.Read` 全链路仅占 1.2MB，二进制 `.srs` 的成本比预期低一个量级。
- **裁剪 build tags 无效。** 堆中 grpc、protobuf、tailscale、quic-go 均在场，说明该 build 未经裁剪且能正常运行。裁剪省下的是代码段与少量堆，无法缓解 20MB 的栈占用。

#### 4.6.2 对策

按实测根因，对策集中在 DNS 侧：

- **不使用 `local` DNS transport。** 显式配置 DoH 或 UDP DNS server，避免走 Apple 系统解析的 cgo 路径，从根上消除 A 类线程膨胀。
- **DNS 查询必须设置超时并限制并发。** 上游黑洞时查询需被回收，不得无限堆积。
- **开启 DNS 缓存**，减少重复查询产生的 goroutine。
- tun stack 使用 gvisor；rule-set 使用二进制 `.srs`；关闭非必要的 cache 与日志缓冲。
- 兜底机制用 libbox 自带的 OOM killer：`LibboxSetupOptions.oomKillerEnabled` / `oomMemoryLimit`，配合 `LibboxPromoteOOMDraft()`；诊断用 `triggerOOMReport:`。

**注意兜底不等于解决。** SFI 在 iOS 上是无条件 `oomKillerEnabled = true` 的，而 4.6.1 的两份快照正是在 OOM killer 已开启的前提下产生的。也就是说 DNS 治理是必需项而非优化项——兜底只能在见顶时杀连接，不能阻止 goroutine 堆积本身。

#### 4.6.3 验收

真机开启隧道并持续承载流量 10 分钟后：

- 常驻内存稳定低于 40MB；
- **`numGoroutine` 稳定且不随时间单调增长**；
- `stackInuse` 低于 12MB。

后两项是先行指标——内存见顶前 goroutine 数已经先涨，只盯 memoryUsage 会错过窗口。任一项不达标即视为验收不通过，需在进入下一步前处理。扩展需暴露一个诊断入口，能在真机上导出与上述同构的 pprof 快照。

## 5. 错误处理

| 情况 | 行为 |
|---|---|
| App Group 中无 `config.json` | 扩展以明确错误终止，提示用户回到 App 完成配对 |
| 配置版本号与扩展已加载的不一致 | 扩展重新读取并重启 `BoxService` |
| Keychain 中无设备令牌 | 主 App 阻止启动隧道，提示重新配对 |
| `/v1/node` 刷新失败 | 沿用上次成功写入的配置，仅提示，不中断已有连接 |
| 规则集缺失或损坏 | 降级为全局代理模式并提示，不使隧道启动失败 |
| libbox 启动失败 | 通过 `lastError` 回传，App 展示原始错误文本 |

## 6. 测试策略

- **单元测试（`swift test`）**：`PendingNetTunnelConfig` 的配置生成，覆盖三种分流模式、双协议 outbounds、以及「服务端资料不得影响 route/tun」的边界断言。
- **模拟器**：App 侧的配对、节点刷新、规则集下载、配置写入 App Group。
- **真机（必需）**：Packet Tunnel 启停、实际流量、协议切换不断线、内存占用。模拟器无法运行 Packet Tunnel，这部分不存在自动化替代。

## 7. 前置闸门

以下配置阻塞真机验收，但不阻塞编码与单元测试：

- Apple 开发者后台的 App ID 启用 Network Extension capability（`packet-tunnel-provider`）；
- App Group `group.net.pending.PendingNet` 与 Keychain Access Group 注册并写入两个 target 的 entitlements；
- 真机 provisioning profile。

均为后台自助配置，**无需向 Apple 提交额外申请**；同类 Packet Tunnel 应用已用同一开发者账号完成 TestFlight 外部测试发布，审核不构成风险。此前将 entitlement 审批列为未知风险的判断已由实践排除。

## 8. 实施顺序

1. `PendingNetTunnelConfig` 与其单元测试（无需任何 Apple 后台配置即可完成）。
2. libbox 构建脚本与 `project.yml` 接线，确认扩展能编译链接。
3. App 侧：配置生成、写入 App Group、`NETunnelProviderManager` 安装与启停。
4. 扩展侧：读配置、应用网络设置、交出 tun fd、启动 `BoxService`。
5. 真机验证最小闭环（全局代理跑通真实流量）。
6. 协议切换与 urltest 的 command server 通道。
7. 规则集下载与三档分流模式。
8. 内存占用验收。
