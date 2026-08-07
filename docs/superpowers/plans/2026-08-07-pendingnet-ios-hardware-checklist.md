# PendingNet iOS 真机验收清单

- **日期：** 2026-08-07
- **对应：** [实施计划](2026-08-07-pendingnet-ios.md) 的 Task 8 与 Task 11
- **状态：** 待执行

Tasks 1–7、9、10 已完成并通过审查。本清单是剩余工作的全部内容。

**为什么需要这份清单：** iOS 模拟器无法运行 Packet Tunnel，因此扩展与 App 侧隧道控制的所有代码**从未被执行过**，只通过了编译。下面每一条都是只能靠硬件回答的问题。

## 0. 前置配置（阻塞一切）

- [ ] Apple 开发者后台：App ID `net.pending.PendingNet.ios` 与 `net.pending.PendingNet.ios.PacketTunnel` 启用 Network Extension capability
- [ ] App Group `group.net.pending.PendingNet` 注册并勾选到两个 App ID
- [ ] 真机 provisioning profile

均为后台自助配置，无需向 Apple 提交申请。

## 1. 先验证诊断通道本身

**这一步必须排在最前面。** 后面每一条出问题时都要靠它定位；如果它本身是坏的，你会在盲区里排查。

扩展侧诊断分三条独立通道，互不替代（设计文档 §5.1）：

| 通道 | 内容 | 位置 |
|---|---|---|
| `stderr.log` | 扩展自身的诊断输出（Swift 侧 `freopen` 重定向 fd 2） | App Group |
| `LibboxCommandLog` 订阅 | sing-box 内核日志 | App 内日志页 |
| `go-crash.log` | Go 崩溃栈（`LibboxRedirectStderr`） | App Group |

- [ ] 启动隧道后，App 的日志页能看到内容
- [ ] `stderr.log` 与 `go-crash.log` 都存在且互不覆盖
- [ ] 内核日志（非扩展自身输出）确实出现在日志页

## 2. 最小闭环

- [ ] 导入 `.pdn` 完成配对（VPS 上 `sudo pendingnet-server pair create --out /root/ios.pdn`，每台设备单独生成，十分钟过期且只能用一次）
- [ ] 点「连接」，系统弹出 VPN 授权，状态变为已连接
- [ ] 访问境外站点可加载
- [ ] VPS 上 `sudo ss -tnp | grep ':443'` 能看到来自设备公网 IP 的连接
- [ ] 点「断开」，状态回到未连接，设备网络恢复直连

## 3. 只能靠硬件 settle 的具体风险

按出问题的可能性排序。每条都标了失败时的症状，便于对号入座。

- [ ] **`openTun` 的 `runBlocking` 桥接**（`Task.detached` + 信号量）。症状：隧道卡在「连接中」，无报错。
- [ ] **`startDefaultInterfaceMonitor` 会阻塞一个 libbox 线程直到 `NWPathMonitor` 首次触发。** 用**开着飞行模式**启动隧道来验证。
- [ ] **`base::ios::ScopedCriticalAction` 调用 `[UIApplication sharedApplication]`**，该 API 在 App Extension 运行时不可用。大概率是 Libbox 内 Chromium net blob 里的死代码。症状：崩溃栈出现 `ScopedCriticalAction` 或 `sharedApplication`。
- [ ] **`send(_:)` 会从 libbox 线程同步调用 `requestAuthorization`。**
- [ ] **`readWIFIState()` 返回 nil** —— 已确认配置里没有任何 `wifi_ssid` 规则，理论上不会被调用。确认日志里没有相关噪声即可。
- [ ] **App 能否连上扩展的 `command.sock`。** 症状：App 日志出现 `command client disconnected`，协议选择器一直不出现。
- [ ] **`saveToPreferences()` → `loadFromPreferences()` → `startVPNTunnel()` 连续调用**。首次保存后立刻启动时出现 `NEVPNErrorConfigurationStale` / `ConfigurationInvalid` 是经典问题；若出现，加一次重试即可。
- [ ] **`startOrReloadService` 作用在已打开的 tun 上**：切换分流模式时 libbox 会再次调用 `openTun` 与 `setTunnelNetworkSettings`。确认切换不会掐断 tun 或已有连接。

## 4. 协议切换与测速

- [ ] 切换协议时 VPN 图标不闪断、状态不进入 `.reasserting`、进行中的页面加载不中断
- [ ] 两个协议都能返回延迟数值
- [ ] `-mix` 行显示的是当前选中成员的延迟（已静态确认会显示，不会永远空白）
- [ ] 首次连接与重连（`cache_file` 开启）后 `selected` 的初值是否合理
- [ ] 前后台切换一轮后订阅能恢复
- [ ] `.reasserting` 期间选择器仍可用
- [ ] 测速的 spinner 是在延迟真的变化时结束，而不是每次都撞到 8 秒上限

**不必再验证的**（已通过读 libbox 源码静态确认）：
- `urlTest` 在 selector 分组上可用，不需要退回到 `-mix`
- `SubscribeGroups` 是独立的流式 RPC，不受 status tick 驱动

## 5. 规则集与分流

**注意顺序：** 规则集从 `raw.githubusercontent.com` 下载，该域名在大陆网络不可达。正确流程是 **配对 → 先用全局代理连上 → 再切绕过大陆**，此时下载走隧道。先切模式再连接会下载失败并正确降级回全局代理。

- [ ] 全局代理、全局直连在没有任何 `.srs` 文件时都能正常工作
- [ ] 连上后切到绕过大陆，规则集下载成功
- [ ] 访问国内站点：VPS 上**看不到**对应连接（走了直连）
- [ ] 访问境外站点：VPS 上**能看到**连接
- [ ] 手动删掉一个 `.srs` 后切到绕过大陆：降级为全局代理并提示，隧道不崩
- [ ] 断开状态下切换模式，然后**从系统设置**打开 VPN：扩展跑的应该是新选的模式（验证快照重写）

## 6. 内存验收（Task 11）

**这是整个 iOS 版最可能翻车的地方。** 依据是两份真机 pprof：贴顶时堆只占 7.4/14.6MB，而 goroutine 栈占 19–21MB，goroutine 全部堆积在 DNS 上。设计文档 §4.6 是针对这个根因的处理。

验收线（全部必须达标）：

- [ ] 承载流量 10 分钟后常驻内存 < 40MB
- [ ] `stackInuse` < 12MB
- [ ] `numGoroutine` 稳定，不随时间单调增长

后两项是**先行指标**——内存见顶前 goroutine 数已经先涨，只盯内存会错过窗口。

采样方式：第 1、5、10 分钟各导出一次，用 `go tool pprof -top` 对比。

```bash
go tool pprof -top -nodecount=20 goroutine.pb
```

```bash
go tool pprof -top -sample_index=inuse_space -nodecount=20 heap.pb
```

重点确认 goroutine 栈顶**不再出现** `dns/transport/local.darwinLookupSystemDNS`——Task 2 的 DNS 段应该已经根除这条路径。

- [ ] 额外场景：保持一条 group 订阅流打开时的内存表现，以及 App 退到后台后的表现

不达标时的排查顺序：

1. goroutine 仍堆在 DNS → 把 App Group 里的 `config.json` 导出来，确认真的没有 `local` 类型 server
2. goroutine 堆在连接复制 → 调低日志与缓存设置
3. 堆内存偏高而非栈 → 确认规则集用的是二进制 `.srs` 而非 JSON

**不要去找 DNS 超时配置项**——sing-box 1.13.13 没有任何配置层的 DNS 超时或并发开关，该路径由内核内置的 10 秒超时兜底（设计文档 §4.6.2）。

## 7. 已知的遗留项（不阻塞验收）

- `PendingNetTunnelPaths.prepare(base:)` 若抛错，不会被记进 `last-error.txt`。一行的修复，触发概率极低。
- `stderr.log` 在单次隧道会话内无上限。10 分钟验收无影响，长期运行前需要加轮转。
- 扩展内 `configContent` / `networkSettings` / `nwMonitor` 是无同步保护的可变状态，逐字继承自已在真机验证过的参考实现。真机跑通后再决定是否处理。
- appex 未设置 `APPLICATION_EXTENSION_API_ONLY`。现在扩展链接了 UIKit，开启它有价值，但可能影响 Libbox 链接。真机验收**之后**再花时间尝试。
- 构建脚本用的是浅克隆，未验证过 bump `SING_BOX_REF` 的情形。届时会明确报错而非产出错误产物，加 `--unshallow` 即可。
