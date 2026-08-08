# PendingNet

PendingNet 正在从本机 sing-box 统计与控制工具，升级为一套统一的 VPS 服务端、macOS 客户端和 iOS 客户端。

核心约定：VPS 生成的 `*.pdn` 是一次性配对文件，不是 sing-box 配置文件。它只包含 VPS 身份、控制端点、TLS 证书指纹和短期令牌；Reality/Hysteria2 连接材料在配对后通过认证 API 获取，路由、TUN 和应用规则始终由客户端管理。

## 当前实现

- `pendingnet-server`：VPS 身份与 TLS 初始化、systemd 自安装、一次性配对文件、设备令牌、认证状态与节点 API。
- 全新 VPS 数据面：直接下载并校验官方 Xray/Hysteria2 Release，生成 Reality/Hysteria2 密钥、证书、配置和 systemd 服务，不执行外部安装脚本。
- 旧 `singbox-script-for-vps` 迁移：安全读取 `/etc/singb/config.env` 和 `/etc/singb/state.env`，保留现有密钥，不执行 shell 文件。
- macOS：导入或双击 `.pdn`、证书固定、实际注册设备、Keychain 保存令牌、读取 VPS 协议能力，并安全生成本机配置；“仅端口”由应用直接运行，不需要后台服务授权。
- iOS：独立 App target、同一套配对/认证/节点模型、Packet Tunnel Extension target。
- 共享运行时转换：把节点资料生成 Reality/Hysteria2 sing-box outbounds，不混入路由或 TUN 策略。
- 本机数据面：现有 sing-box 配置生成、VPS/协议/路由模式控制、统计面板继续可用。

目前仍是开发里程碑：Debian 12 amd64 的安装、旧服务切换、macOS 配对与安全应用配置，以及 Reality/Hysteria2 真实流量已经通过端到端验证；arm64 VPS、iOS 代理内核和真实隧道尚未完成。完整清单见[统一设计](docs/superpowers/specs/2026-07-31-pendingnet-server-client-design.md)。

macOS 0.3.9 可以直接导入或双击 `.pdn`。应用只把 VPS 下发的协议 outbounds 合并到客户端自己生成的运行配置；`.pdn` 不包含 DNS、路由、TUN、规则集或应用规则。“仅端口”由应用以当前用户身份运行，通过 `sing-box check` 后写入 `~/Library/Application Support/PendingNet/engine/`，默认监听 `127.0.0.1:2080`，不会修改系统代理，也不需要后台服务授权。系统代理与 TUN 仍保留为后续公证版本的特权模式。配对和节点 API 使用独立的直连通道，不依赖或改写系统中已有的代理；该通道只信任 `.pdn` 中固定的 SHA-256 服务端证书指纹，不需要全局放宽 ATS。

0.3.9 起内置 Sparkle 2 更新器。PendingNet 与 PendingCrew 共用 `updates.pendingname.com` + Cloudflare R2 的发布基础设施，并分别使用 `pendingnet/`、`pendingcrew/` 产品目录和独立签名密钥。客户端会按计划检查更新、验证 appcast、更新包签名与 Developer ID 身份，并原子替换应用。发布包还必须完成 Apple notarization，具体流程见 `docs/macos-updates.md`。

## 全新 VPS 试用

构建 Linux 二进制并上传到 VPS 后：

```sh
sudo ./pendingnet-server install \
  --name "My VPS" \
  --endpoint "https://203.0.113.10:7443"

sudo pendingnet-server provision \
  --server-ip "203.0.113.10" \
  --reality-sni "www.cloudflare.com"

sudo pendingnet-server pair create --out /root/my-vps.pdn
sudo pendingnet-server status
```

默认使用 TCP/443 运行 Reality、UDP/443 运行 Hysteria2、TCP/7443 运行 PendingNet 控制服务。VPS 防火墙和云厂商安全组必须允许这三个入口；`provision` 不会擅自修改防火墙。

## 迁移已有 VPS

已有 `singbox-script-for-vps` 服务时，可以先只接管控制面而不打断现有代理服务：

```sh
sudo ./pendingnet-server install \
  --name "My VPS" \
  --endpoint "https://203.0.113.10:7443"

sudo pendingnet-server import-singb
sudo pendingnet-server pair create --out /root/my-vps.pdn
sudo pendingnet-server status
```

`install` 是前置步骤：它初始化状态目录并启动控制服务，`import-singb` 需要已初始化的状态才能写入节点资料。这一步只新增 TCP/7443，不碰现有的 TCP/443 与 UDP/443。

`import-singb` 默认读取现有 `/etc/singb/config.env` 和 `/etc/singb/state.env`。它只导入客户端连接所需字段，不导入 Xray 私钥、完整服务端配置或任何路由规则。

确认没有客户端正在使用旧服务后，可以让 PendingNet 生成新凭据并接管 TCP/443 与 UDP/443：

```sh
sudo pendingnet-server provision \
  --server-ip "203.0.113.10" \
  --reality-sni "www.cloudflare.com" \
  --replace-existing \
  --skip-download
```

`--replace-existing` 必须与 `--skip-download` 同时使用，否则命令直接报错退出：接管已有 VPS 时沿用机器上已验证过的 Xray/Hysteria2 二进制，不重新下载引擎。

切换过程会先验证新配置；若启动失败，会尝试恢复原有 `xray.service` 和 `hysteria-server.service`。旧配置不会被删除。

只接管控制面本身就是一个**可以长期保持的终态**，不是必须往下走的中间步骤。两种终态对客户端完全等价：`.pdn`、配对、节点下发和 app 里的使用体验都一样，区别只在底层由谁扛流量、密钥由谁生成。

| | 只接管控制面（`import-singb`） | 完全接管（`provision --replace-existing`） |
| --- | --- | --- |
| TCP/443、UDP/443 | 原有 `xray.service` / `hysteria-server.service` | `pendingnet-xray.service` / `pendingnet-hysteria.service` |
| 连接密钥 | 沿用旧服务已有的 | PendingNet 重新生成 |
| 对旧客户端 | 不受影响 | **立即失效，需要重新配置** |

因为完全接管会让仍在使用旧节点的设备立刻断线，且密钥不可回滚，所以只在确认没有客户端还在用旧服务之后再做。拿不准就停在只接管控制面，随时可以补做后面这一步。

将 `/root/my-vps.pdn` 安全复制到 Mac 或 iPhone 后导入。文件默认十分钟过期且只能使用一次；每台设备应单独生成一份。

## 开发与验证

```sh
go test ./...
go build ./cmd/pendingnet-server

cd app/SBTallyCore
swift test

# 可选：使用一份专门生成的短期配对文件，验证真实配对和双协议流量
PENDINGNET_LIVE_PAIRING_FILE=/tmp/test.pdn \
PENDINGNET_LIVE_SING_BOX=/path/to/sing-box \
swift test --filter PendingNetPairingTests/testLivePendingNetServerWhenPairingFileIsProvided

cd ..
xcodegen generate
xcodebuild -project PendingNet.xcodeproj -scheme PendingNet build
xcodebuild -project PendingNet.xcodeproj -scheme PendingNetIOS \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

## 原有本机能力

PendingNet 的统计服务从 sing-box Clash API 读取连接数据；sing-box 需要启用 `experimental.clash_api` 和 `route.find_process`。

```sh
go build ./cmd/sbtally
SBTALLY_SECRET=<clash-secret> ./sbtally daemon \
  --clash-api 127.0.0.1:9090 --listen 127.0.0.1:7777

./sbtally apps --since 7d --top 20
./sbtally domains --since 24h
./sbtally app Safari --since 7d
```

旧的完整 sing-box JSON 导入/生成仍作为过渡入口保留：

```sh
sbtally config import path/to/config.json
sbtally config generate --vps vpsA=vpsA.json --vps vpsB=vpsB.json --out master.json
```

后续主流程不再要求用户导入或维护完整 sing-box JSON。
