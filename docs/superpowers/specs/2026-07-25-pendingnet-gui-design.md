# PendingNet GUI 改版设计（阶段 A：本地）

2026-07-25。阶段 B（VPS 服务端统一配置协议）另行设计；本设计不含它，但不做与它冲突的决定。

## 目标

把现有 SBTally GUI 升级为 PendingNet：

1. 改名：GUI 与全部用户可见文案 SBTally → PendingNet。
2. 启停：GUI/菜单栏一键启动、停止 sing-box 引擎，免密。
3. 接管模式三选一：**TUN** / **系统代理** / **仅本地端口**（只开 mixed 端口，不动系统设置）。
4. 规则三选一：**全局**（全部走代理）/ **白名单**（CN 直连，其余代理；即现分流）/ **黑名单**（仅 GFW 名单走代理，其余直连）。
5. 协议切换（reality / hy2）与 VPS 切换：沿用现有 Control 能力。
6. 菜单栏直达：启停、接管模式、规则、协议、VPS。

## 非目标（YAGNI）

- 不改系统服务标签（io.sbtally.\*）、CLI 名、daemon 名 —— 阶段 B 统一迁移，避免二次 cutover。
- 不做订阅、多配置文件管理、按应用规则编辑。
- 不做开机自启的 GUI 偏好设置（引擎本来就是 LaunchDaemon 自启）。

## 架构

```
PendingNet.app (GUI + MenuBarExtra)
 ├─ XPC ──> PendingNetHelper（特权助手, root, SMAppService.daemon）
 │           ├─ 启停 io.sbtally.singbox（launchctl bootstrap/bootout/kickstart）
 │           ├─ 写 /usr/local/etc/sbtally/master.json（接管模式变更时重新生成 inbounds）
 │           └─ networksetup 设置/清除系统代理（系统代理模式）
 ├─ HTTP ──> sbtally daemon :7777（统计 + Control API，现有）
 └─ daemon ──> sing-box Clash API :9090（规则/协议/VPS 切换，现有）
```

参考实现：ClashX Pro 的 privileged helper 模式（SMJobBless 的现代替代 SMAppService）。
SFM 的 NetworkExtension 路线被排除：需要 Apple 开发者网络扩展授权，且扩展内
find_process 拿不到进程名，破坏 per-app 统计这一核心功能。

## 关键决策

### 1. 规则切换 = clash_mode，零重启

sing-box clash_api 支持自定义模式名。master.json 内置三组 clash_mode 规则：

- `Global`：全部 → proxy（保留 CN DNS 与私网直连的最小例外）
- `Whitelist`：geosite-cn / geoip-cn / 私网 → direct，其余 → proxy（现行为）
- `Blacklist`：geosite-gfw → proxy，其余 → direct

切换通过 Clash API `PATCH /configs {"mode": ...}`，瞬时生效，选择由 cache.db 持久化。
`geosite-gfw.srs` 与其他规则集一样本地化存放于 /usr/local/etc/sbtally/。
生成器（internal/sbconfig）相应改为输出三模式规则 + 本地规则集路径
（吸收现在 update-config.sh 里的 python 补丁，脚本随之简化）。

### 2. 接管模式切换 = 助手改配置 + 重启引擎（1–2 秒断流）

- **TUN**：现状（tun inbound + mixed 2080）。
- **系统代理**：去掉 tun inbound；networksetup 对活动网络服务设 HTTP/HTTPS/SOCKS 代理 127.0.0.1:2080；停止或切走时清除。
- **仅本地端口**：只留 mixed 2080，不动系统设置。

模式记录在 helper 侧的小状态文件（/usr/local/etc/sbtally/mode），开机按上次模式起。
生成器增加 `--inbound tun|proxy|none` 之类参数由 helper 调用。

### 3. 特权助手：SMAppService，自签兜底 sudoers

- PendingNetHelper 以 SMAppService.daemon 注册，首次授权一次，之后 XPC 免密。
- XPC 接口最小化：`start() / stop() / setMode(tun|sysproxy|local) / status()`。
  XPC 连接校验调用方 code signing requirement。
- 风险：SMAppService 对签名有要求，自签证书预期可行；若被卡住，
  兜底方案是两条固定 launchctl/脚本命令进 sudoers NOPASSWD，GUI 走 Process 调用。
  兜底不改变 GUI 与模式语义，只换执行通道。

### 4. 改名范围

- xcodegen project.yml：app 名、bundle id（net.pending.PendingNet）、显示名、菜单栏文案。
- SwiftUI 内所有 "SBTally" 用户可见字符串。
- 安装路径 /Applications/PendingNet.app；旧 SBTally.app 由安装脚本删除。
- 不改：io.sbtally.\* 服务标签、sbtally CLI/daemon 二进制名、/usr/local/etc/sbtally/。

## 数据流（启停示例）

菜单栏开关 → GUI XPC → helper `stop()` → `launchctl bootout system/io.sbtally.singbox`
（+ 若当前是系统代理模式则清系统代理）→ GUI 轮询 daemon `/api/...` 与 helper `status()`
刷新图标状态（运行=彩色，停止=灰）。

## 错误处理

- helper 不可用/未授权：GUI 显示"需要授权"引导，一键触发 SMAppService 注册。
- 引擎启动失败：helper status() 透传最近日志尾部（/var/log/sbtally-singbox.log），GUI 弹出。
- 系统代理模式下崩溃/停止：helper 在 stop 与 setMode 路径上无条件清系统代理，避免断网残留。
- 与 SFM 冲突依旧：启动前检测 9090 占用，占用则报"SFM 未退出"。

## 测试

- 生成器三模式规则、inbound 变体：Go 单测（sing-box check 校验样例输出）。
- helper XPC 协议与状态机：单测 + 手工冒烟。
- GUI：现有 SBTallyCore 测试沿用；启停/模式切换真机冒烟（本项目惯例：真机验证为准）。
- 离线自检：selfcheck.sh 增加当前模式/规则断言。
