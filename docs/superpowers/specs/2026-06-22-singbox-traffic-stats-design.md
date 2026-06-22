# sing-box 流量统计 + 控制面板 — 设计 Spec

- **日期:** 2026-06-22
- **状态:** 草稿(第 2 版,待评审)
- **暂用名:** `sbtally`(占位,易改)

## 1. 目标

在 macOS 上做一个针对**经过 sing-box 的流量**的工具,两大块:

**A. 流量统计(类 Little Snitch)**
- **按应用**记账(核心)、按域名记账、可查任意时间段的历史,外加实时监控。

**B. sing-box 控制面板**
针对**自建 VPS**(无机场/订阅)的便捷切换,5 个开关:
1. **VPS 选择**(A / B / …)
2. **协议选择**(reality / hy2 / 以及任意其它出站,统称"协议")
3. **路由模式**(规则 / 全局 / 直连)
4. **TUN 开关**
5. **系统代理开关**

外加 **按应用分流**配置(指定某应用走直连/代理/某 VPS/拦截)。

GUI 用 **SwiftUI**(菜单栏 + 窗口)。**不做 iOS**(已确认放弃:iOS 无法拿到进程身份、无独立 CLI、架构完全不同,投入产出比差)。

非目标:机场订阅;防火墙式拦截(广告拦截除外,那是路由 block,不是逐连接审批)。

## 2. 驱动架构的几个硬约束

1. **按应用归因要求 sing-box 能把 socket 映射到进程**,只有**独立 root TUN CLI** + `route.find_process: true` 才可靠。文档明确:**非 App Store/TestFlight 版**才支持 `process_name` 匹配 → **用 CLI 版替换 SFM**(已确认)。
2. **数据/控制接口 = Clash API**。`/connections` WS 每秒推活跃连接快照(累计字节 + 进程/域名/链路/规则);`selector` 出站与 `clash_mode` 都可经 Clash API **运行时即时切换**,无需重启、无需权限。
3. **采集必须常驻、与 GUI 解耦** → 后台守护进程持有数据源与存储。
4. **TUN 与系统代理需要特权**:TUN 建 utun + 路由要 root;macOS 改系统代理要管理员。→ 引入**一次性授权的特权助手**(`SMAppService`)。
5. **5 个开关里 3 个免权限即时切**(VPS/协议/模式 走 Clash API),**2 个需特权**(TUN/系统代理 走助手)。**改应用分流规则**也走助手(reload,静态规则)。

## 3. 切换机制总表

| 开关 | 机制 | 是否需权限/重启 |
|---|---|---|
| VPS 选择 | `selector`(顶层),Clash API `PUT /proxies/{name}` | ❌ 即时 |
| 协议选择 | 嵌套 `selector`(每 VPS 一组),Clash API | ❌ 即时 |
| 路由模式(规则/全局/直连) | 原生 `clash_mode`,Clash API `PATCH /configs` | ❌ 即时 |
| TUN 开关 | 重新生成 config(含/不含 tun 入站)→ 助手重启 sing-box | ✅ 特权 |
| 系统代理开关 | 助手执行 `networksetup` 指向混合入站 | ✅ 特权(管理员) |
| 增删/改应用分流规则 | 重新生成 config → 助手 reload | ✅ 特权(不频繁) |

选择器选择会被 sing-box 写入 cache 文件,重启后记忆。

## 4. 组件

| # | 组件 | 语言 | 运行身份 | 职责 |
|---|------|------|---------|------|
| 1 | **sing-box** | — | root LaunchDaemon | 跑生成的主配置(TUN + find_process + clash_api + selectors + 规则集) |
| 2 | **`sbtally` 特权助手** | Go | root,`SMAppService` 一次性授权 | 仅 3 件特权事:应用/重启配置、TUN 开关、系统代理开关 |
| 3 | **`sbtally` 统计守护** | Go | user LaunchAgent | Clash WS → 增量记账 → SQLite;提供统计 JSON/SSE |
| 4 | **配置生成器** | Go | 库 + `sbtally config` 子命令 | 从用户的出站定义 + 选项生成主配置;App 与助手都复用,可无头测试 |
| 5 | **SBTally.app** | SwiftUI(macOS 13+) | GUI | 菜单栏控制面板(5 开关 + 应用分流)+ 统计仪表盘 |

2/3/4 是**同一个 Go 二进制**的不同子命令/模式。**统计(A)与控制(B)互相独立**,可分别开发与测试。

## 5. 架构与数据流

```
 App sockets ─(TUN)→ sing-box(root, 主配置) ── Clash API 127.0.0.1:9090
                          ▲    │                      ▲        │ ws /connections
        helper 重启/应用 ──┘    │ networksetup         │        ▼
                                ▼ (系统代理)     ┌──────────────────────────────┐
   ┌──── sbtally 助手(root) ────┐               │ sbtally 统计守护(user)       │
   │ 应用配置 / TUN / 系统代理   │               │ source→accumulator→SQLite     │
   └──────────▲─────────────────┘               │      └→ live → SSE            │
              │ 本地 IPC(unix socket)           └───────┬──────────┬───────────┘
              │                                   /api/* JSON   /api/live SSE
   ┌──────────┴───────────────────────────────────────┴──────────┴──────────┐
   │ SBTally.app(SwiftUI)                                                     │
   │  控制面板: 直连 Clash API 切 VPS/协议/模式; 调助手 切 TUN/系统代理/应用规则 │
   │  仪表盘:  StatsProvider ← 统计守护 API                                    │
   └──────────────────────────────────────────────────────────────────────────┘
   sbtally CLI ──直接读──→ SQLite
```

一个 Clash-API WS 订阅,同时喂"持久记账"和"实时速率"。

## 6. 仓库结构

```
sbtally/                            # Go module: "sbtally"
  cmd/sbtally/main.go               # 子命令分发: daemon / helper / config / apps / domains / app / live
  internal/core/                    # 统计核心
    dto.go  accumulator.go  store.go  query.go  (+ *_test.go)
  internal/source/
    source.go                       # ConnectionsSource 接口 + Connection/Snapshot
    clashws.go                      # coder/websocket 客户端
  internal/daemon/daemon.go         # source→accumulator→store + live + 统计 server
  internal/server/                  # 统计 JSON + SSE
  internal/helper/                  # 特权操作: 应用配置/重启、TUN、系统代理;本地 IPC server
  internal/sbconfig/                # 配置生成器: outbounds + selectors + clash_mode 规则 + 规则集 + DNS
    generate.go  rules.go  (+ *_test.go)
  internal/clashapi/                # Clash API 客户端(切 selector/mode、读 proxies)
  internal/cli/                     # apps/domains/app/live + 字节格式化
  deploy/
    launchd/io.sbtally.singbox.plist   # root: sing-box run
    launchd/io.sbtally.daemon.plist    # user: sbtally daemon
    install.sh
  app/                              # SBTally.app — Xcode 工程(SwiftUI)
    SBTally/
      SBTallyApp.swift  (App + MenuBarExtra + Window)
      ControlPanel/                 # VPS/协议/模式 选择器 + TUN/系统代理 开关 + 应用分流编辑
      Dashboard/                    # 统计视图(Swift Charts)
      Services/{ClashAPIClient,StatsProvider,HelperClient}.swift
      Models.swift                  # 与 Go DTO 对应的 Codable
  docs/superpowers/specs/2026-06-22-singbox-traffic-stats-design.md
  README.md
```

`internal/core` 不再要求"可移植/gomobile"(iOS 已砍),但仍保持无宿主依赖、便于无头测试。

## 7. 统计核心(`internal/core`)

### 7.1 连接模型与数据源接口

```go
type Connection struct {
    ID       string
    Process  string // metadata.process     (可能为空)
    ProcessPath string
    Host     string // metadata.host (嗅探域名, 可能为空)
    DestIP   string
    DestPort string
    Network  string
    Chains   []string
    Rule     string
    Upload   int64  // 该连接累计字节
    Download int64
}
type Snapshot struct { At int64; Connections []Connection }

type ConnectionsSource interface { Snapshots(ctx context.Context) (<-chan Snapshot, error) }
```

### 7.2 增量累加器(正确性关键,必须单测)

快照给的是**累计值**,连接关闭即从快照消失。按连接 ID 算增量、累进小时桶:

状态:`last[connID]{up,down}`、`pending[(hourStart,app,host)]{up,down}`。

每份快照 `S`:
- 对每条连接 `c`:`du=c.Upload-prev.up; dd=c.Download-prev.down`;若为负(UUID 几乎不会复用)→ 钳 0 并重置基线,绝不加负;
  - `app = firstNonEmpty(Process, basename(ProcessPath), Host, "unknown")`
  - `host = firstNonEmpty(Host, DestIP, "unknown")`
  - `pending[(hourFloor(S.At), app, host)] += (du,dd)`;`last[c.ID]=current`
- `S` 中不存在的 ID = 已关闭,从 `last` 删(此前已全部计入)。

**落库:** 每约 10s + 退出时,把 `pending` UPSERT 进 SQLite 并清空。小时边界由桶键天然处理。

**已知局限:** 两次快照之间"开了又关"的连接会漏(字节极小,可接受;README 注明)。

### 7.3 存储(SQLite)

```sql
PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS traffic (
  bucket INTEGER, app TEXT, host TEXT, upload INTEGER, download INTEGER,
  PRIMARY KEY (bucket, app, host)
);
-- UPSERT: ON CONFLICT(bucket,app,host) DO UPDATE SET upload=upload+excluded.upload, download=download+excluded.download
```

主键以 bucket 起头 → 时间范围查询高效。库路径 `~/Library/Application Support/sbtally/sbtally.db`(WAL 并发读)。用 `modernc.org/sqlite`(纯 Go,免 cgo)。

### 7.4 查询与 DTO

```go
type AppStat struct { App string; Upload, Download, Total int64 }
type DomainStat struct { Host string; Upload, Download, Total int64 }
type AppDetail struct { App string; Domains []DomainStat }
type Point struct { Bucket int64; Upload, Download int64 }
type Summary struct { Since int64; Upload, Download, Total int64; Apps, Hosts int }
type LiveAppGroup struct { App string; UpRate, DownRate int64; Conns int; TopHost string }
```

查询:`Apps/Domains/AppDetail/Series/Summary`,均带 `since/until`,列表带 `top`。`since` 接受时长(`24h`/`7d`)或绝对时间。

## 8. 统计守护:数据源 + 实时 + HTTP

- **WS 客户端**(`coder/websocket`):`ws://127.0.0.1:9090/connections`,`Authorization: Bearer <secret>`;断线指数退避重连,重连前 flush `pending`、重置 `last`。
- **实时速率**:同一批快照算每连接 Δ/Δt,按 app 聚合 → `LiveAppGroup`,SSE 广播。无第二条 WS。
- **HTTP(仅 127.0.0.1)**:`/api/summary` `/api/apps` `/api/domains` `/api/app/{name}` `/api/series` `/api/live`(SSE)。默认无鉴权(本机);可选 `SBTALLY_TOKEN`。

## 9. 控制面板与配置生成(`internal/sbconfig`)

### 9.1 出站模型与选择器

用户只有自建 VPS。模型:**每个 VPS = 一组带标签的出站**——reality、hy2,外加 **mix**(= 对该 VPS 的 reality+hy2 做 `urltest` 自动选优,由生成器**自动合成**,无需用户提供)。

- 顶层 `selector` **`proxy`** = 选 VPS:其 `outbounds` 指向各 VPS 的子选择器。
- 每 VPS 一个子 `selector`(如 `vpsA`)= 选协议:`outbounds` = [reality, hy2, **mix**(urltest)]。

切 VPS = 设 `proxy`;切协议 = 设对应 VPS 子选择器。两个独立下拉,每 VPS 记忆各自协议。皆 Clash API 即时。

### 9.2 出站从哪来

**导入用户现有 sing-box 配置**(可多份/拖文件夹)→ 生成器**提取 `outbounds`** → 用户标注归属 VPS + 协议(reality/hy2)→ 生成主配置,并为每个 VPS 自动合成 mix urltest。**无机场/订阅;不做填凭据表单。**

### 9.3 路由(参考成熟方案,非白/黑名单二选一)

规则集用**远程 rule-set**(`.srs`,sing-box 自动定时更新);来源默认官方 [sing-geoip](https://github.com/SagerNet/sing-geoip)/[sing-geosite](https://github.com/SagerNet/sing-geosite),可选增强版 [lyc8503/sing-box-rules](https://github.com/lyc8503/sing-box-rules)。

**三个运行时模式 = 原生 `clash_mode`(Global/Rule/Direct,标准值、必支持,Clash API 即时切):**
- **规则(默认)** / **全局**(全代理)/ **直连**(全直连)。

**"规则"模式分流顺序:**
1. **按应用分流**(§9.4,`process_name`,最高优先级)
2. **广告拦截**:`geosite-category-ads-all` → block
3. **直连**:私有/局域网 + `geoip-cn` + `geosite-cn` → direct
4. **境外**:`geosite-geolocation-!cn` → `proxy`
5. **兜底** → `proxy`

默认即「绕过大陆 + 广告拦截」(比 gfwlist 黑名单耐用)。激进/保守、流媒体/AI 指定节点等做成规则设置里的可选项,不写死。

**DNS 分流**:按成熟默认配好(国内域名走国内 DNS、其余走代理 DNS,防污染/泄漏),非面板开关。

### 9.4 按应用分流

`process_name` 规则,优先级最高。每条:**应用 → 目标** ∈ {直连 / 代理(跟随 `proxy` 选择器)/ 指定某 VPS·节点(钉死)/ 拦截}。UI 与统计打通:从**已观测应用列表**直接挑,免手敲。增删改 → 重新生成 config → 助手 reload(短暂重连;设置类操作,不频繁)。

### 9.5 TUN / 系统代理

- **TUN 开关**:生成含/不含 `tun` 入站(及 `auto_route`)的主配置 → 助手重启 sing-box。关 TUN 时靠系统代理捕获。
- **系统代理**:主配置含一个**混合入站**(如 `127.0.0.1:2080`);助手用 `networksetup` 对当前网络服务设/清代理。

## 10. 特权助手(`internal/helper`)

- 经 `SMAppService`(macOS 13+)一次性授权安装为 root LaunchDaemon。
- 仅暴露三类操作,经**本地 IPC**(root 拥有的 unix socket,App 持令牌):
  1. `ApplyConfig(configJSON)`:校验 → 写入 root 配置路径 → `launchctl kickstart -k` 重启 sing-box(用于 TUN 切换、出站/应用规则变更)。
  2. `SetTun(bool)` / `SetSystemProxy(bool)`。
- sing-box 仍是独立 root LaunchDaemon(KeepAlive 常驻);助手只在需要时重启它。
- 配置生成在 Go 内(`internal/sbconfig`),App 预览与助手落地复用同一份逻辑。

## 11. SwiftUI App

- macOS 13+(Swift Charts)。`MenuBarExtra`:实时 ↑/↓ + 当前 VPS/模式 + 快捷切换;`Window`:控制面板(VPS/协议/模式/TUN/系统代理/应用分流)+ 统计仪表盘(实时/应用/域名/应用详情)。
- 三个服务客户端:`ClashAPIClient`(切 selector/mode、读 proxies/连接)、`StatsProvider`(统计守护 API,SSE 实时)、`HelperClient`(特权操作)。`Models.swift` 对应 Go DTO。
- **构建/验证说明:** Go(统计核心、配置生成、Clash/Helper 逻辑)可在本机**无头完整测试**;SwiftUI 用 `xcodebuild` 编译检查,GUI 跑起来与用户一起迭代。

## 12. 部署 — 替换 SFM

- 安装:`SMAppService` 注册助手(用户在系统设置批准);助手安装 sing-box 的 root LaunchDaemon;`sbtally daemon` 装为 user LaunchAgent。
- 迁移:先退出/禁用 SFM(两个 TUN 提供者冲突)。README 注明。

## 13. 测试

- `accumulator_test`:增长、关闭不重复计、新连接、缺 process→unknown、空 host→DestIP、负增量钳零、跨小时分桶。
- `store_test`:UPSERT 累加、WAL 并发读。
- `query_test`:内存 SQLite 塞已知数据,断言聚合 / since / top-N。
- `sbconfig` 测试:给定出站 + 选项,生成的 config 含正确的嵌套 selector、clash_mode 规则、规则集引用、应用分流规则、TUN/混合入站变体;JSON 通过 `sing-box check`(若可用)。
- 字节格式化单测。
- Go 数据/配置路径**全程可无头验证**;SwiftUI 编译检查。

## 14. 错误处理

- WS 断线 → 退避重连(flush + 重置 last)。
- Clash API 401 → 明确日志(secret 不符)。
- SQLite busy → WAL + busy_timeout + 限次重试。
- 助手不可用/未授权 → App 提示去系统设置授权;统计与即时切换不受影响(只挡 TUN/系统代理/规则变更)。
- 统计守护离线 → CLI 仍可读库;App 显示"离线"并禁用实时。
- 远程规则集下载失败 → sing-box 用上次缓存;App 提示。

## 15. 不做(YAGNI)

iOS;机场订阅;逐连接拦截审批(广告拦截除外);多机聚合;Web UI;Prometheus/OTel;App 公证分发(本机自建);除可选 loopback 令牌外的鉴权。

## 16. 已定默认 / 待定

- 名字:`sbtally`(占位,可改)。
- 规则集来源:默认官方 sing-geoip/sing-geosite(可换 lyc8503 增强版)。
- TUN 协议栈:默认 gVisor(在意吞吐可换 system)。
- mix = 每 VPS 的 reality+hy2 `urltest` 自动选优(已定)。
- 出站来源 = 导入现有 config(已定)。
- 「规则」模式默认 = 智能分流(绕过大陆 + 广告拦截)(已定)。

## 17. 实现阶段(先统计仪表盘)

1. **Go 统计核心** — 累加器 / 存储 / 查询 + 数据源(Clash WS)+ 统计守护 + CLI + 统计 JSON/SSE。先让数据链路在本机跑通、可无头验证。
2. **SwiftUI 仪表盘** — 实时 / 应用 / 域名 / 应用详情。
3. **配置生成器 + Clash API 客户端** — 出站 / 嵌套选择器 / mix urltest / clash_mode / 规则集 / DNS;切 VPS/协议/模式。
4. **特权助手 + 控制面板 UI + 按应用分流** — TUN / 系统代理 / 配置应用。

先交付 1+2(统计仪表盘可用),再做 3+4(控制面板)。
