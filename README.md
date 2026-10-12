<p align="center">
  <img src="docs/app-icon.png" width="128" alt="PendingNet 应用图标" />
</p>
<h1 align="center">PendingNet</h1>

<p align="center">
  和 VPS 搭配使用的 Sing-box 部署方案 配套 Mac/iOS 客户端
</p>


<p align="center">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-blue" /></a>
  <img alt="Go" src="https://img.shields.io/badge/lang-Go%201.26-00ADD8?logo=go&logoColor=white" />
  <img alt="Swift" src="https://img.shields.io/badge/lang-Swift%206-F05138?logo=swift&logoColor=white" />
  <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%20%C2%B7%20iOS%20%C2%B7%20Debian-lightgrey" />
  <img alt="Version" src="https://img.shields.io/badge/version-0.3.39-informational" />
</p>
苹果生态用 VPS 搭自建节点的一整套解决方案

部署脚本 + Mac/iOS 客户端（iCloud 同步）+ 流量统计（分应用、域名统计）

<p align="center">
  <img src="docs/screenshots/macos-connect.png" width="820" alt="PendingNet macOS 连接页" />
</p>


协议：默认 TCP 走 Xray Reality，UDP 走 Hysteria2

## 快速开始

- **macOS** ： [Releases](../../releases)。安装包已经内置从源码构建并签名的 sing-box，
  不需要 Homebrew，也不用先运行 `deploy/install.sh`。只用「仅端口」可直接连接；
  第一次选择 TUN / 系统代理时，按系统提示允许 PendingNet 后台项目即可。
- **iPhone / iPad** ： [TestFlight](https://testflight.apple.com/join/g9jrafTR)
- **VPS 部署**：`curl -fsSL https://raw.githubusercontent.com/syncmeta/PendingNet/main/deploy/vps-install.sh | sudo bash `

### 导入服务器管理权限

安装脚本最后生成普通连接链接，在连接页导入。管理页需要单独的管理员链接；安装新版服务端后，在对应 VPS 上运行：

```sh
sudo pendingnet-server pair create --admin --ttl 10m --out /root/pendingnet-admin.txt
sudo cat /root/pendingnet-admin.txt
```

复制完整链接到客户端「管理 → 导入管理链接」。链接十分钟有效、只能导入一次，每台管理设备单独签发；输出文件已有时不会覆盖，请改用新文件名。管理员凭据只保存在导入设备本机，不经 iCloud 同步。管理页支持用户查询、撤销、链接签发和配置导出；在线修改服务器配置尚未开放。

### 导出 Android / Windows sing-box 配置

已配置 Reality 节点的 PendingNet Server 可在 VPS 本地导出独立配置文件（需使用包含 `client export` 的新版服务端）：

```sh
sudo pendingnet-server client export --platform android --out /root/pendingnet-android.json
sudo pendingnet-server client export --platform windows --out /root/pendingnet-windows.json
```

Android 文件供 sing-box for Android 以 VPN 模式导入，TUN 出站启用自动识别底层网络，以规避流量回到自身 VPN 的路由回环；Windows 文件使用本机系统代理。导出文件含节点凭据，权限为 `0600`，已有文件不会被覆盖；请通过可信的本地方式传给目标设备，不要贴进群聊或公开分享。生成与 `sing-box check` 不等于目标设备连通性实测。

## 仓库结构

```
cmd/pendingnet-server/   VPS 端：安装、部署、接管、配对、状态
cmd/sbtally/             本机统计的命令行
internal/pnserver/       服务端核心：状态、HTTP API、Release 下载校验、systemd
internal/pairing/        .pdn 的生成与严格校验
internal/source/         Clash API 的 WebSocket 连接流订阅
internal/core/           流量累加、SQLite 存储、查询
internal/daemon/         统计守护进程 + 本地 HTTP/SSE 接口
internal/sbconfig/       sing-box 配置的导入与生成
app/SBTallyCore/         Swift 共享层（模型、配置生成、Keychain、控制协议）+ 全部 Swift 测试
app/SBTally/             macOS app
app/PendingNetHelper/    macOS 特权助手（root，按代码签名校验 XPC 调用方）
app/PendingNetIOS/       iOS app
app/PacketTunnel/        iOS Packet Tunnel Extension（内嵌 libbox）
scripts/                 构建、签名、公证、发布、App Store Connect 查询
deploy/                  vps-install.sh（VPS 一键部署）+ 本机 launchd 部署脚本（早期的自用统计服务）
```

**技术栈**：Go 1.26（`modernc.org/sqlite` 纯 Go 实现，不用 cgo；`github.com/coder/websocket`）·
Swift 6 / SwiftUI · NetworkExtension · sing-box libbox · XcodeGen · Sparkle 2 · systemd · Xray-core · Hysteria2

## 许可

[MIT](LICENSE)

第三方运行时 / 库：sing-box · Xray-core · Hysteria2 · Sparkle 2 · `modernc.org/sqlite` 等，各遵其原协议。
