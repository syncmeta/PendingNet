# PendingNet Server / Client 统一设计（阶段 B）

- **日期：** 2026-07-31
- **状态：** 实施中（Debian 12 amd64 服务端切换与 macOS 双协议端到端流量已验证）

## 1. 产品边界

PendingNet 由三个产品组成：

1. **PendingNet Server**：运行在 Debian/Ubuntu VPS，负责安装和管理代理服务、密钥、升级、状态与配对。
2. **PendingNet for macOS**：负责 VPS 配对、本机 TUN/系统代理、路由、统计与控制。
3. **PendingNet for iOS**：负责 VPS 配对，并通过 Packet Tunnel Extension 接管网络。

现有 `singbox-script-for-vps` 的服务端生命周期能力迁入 PendingNet Server。最终用户不再下载八份 sing-box 客户端 JSON，也不再把完整 sing-box 配置当作 PendingNet 的配置源。

## 2. 配对文件不是代理配置

VPS 生成唯一的 `*.pdn` 配对文件。文件只用于第一次建立受信任的控制关系：

- 格式版本；
- VPS ID 与显示名；
- PendingNet Server 控制端点；
- 控制端 TLS 证书 SHA-256 指纹；
- 有有效期的一次性配对令牌。

配对文件**不包含** Reality/Hysteria2 参数、路由规则、TUN 设置、应用分流或完整 sing-box JSON。

导入成功后，一次性令牌失效；客户端取得独立设备令牌并保存到系统安全存储。客户端通过控制 API 获取服务端当前能力与连接材料，再自行生成本平台的运行配置。

## 3. 配置归属

| 数据 | 归属 |
|---|---|
| VPS 身份、控制端点、设备授权 | PendingNet Server / 客户端安全存储 |
| Reality、Hysteria2 服务端密钥与监听 | PendingNet Server |
| 当前可用协议与连接材料 | PendingNet Server 控制 API |
| VPS/协议选择 | PendingNet 客户端状态 |
| 全局/白名单/黑名单、应用规则 | PendingNet 客户端策略 |
| TUN/系统代理/仅端口 | 平台本地设置 |
| sing-box 最终 JSON | 各平台按上述状态自动生成的产物 |

## 4. 第一版配对协议

### 4.1 配对文件

```json
{
  "format": "pendingnet-pairing",
  "version": 1,
  "server_id": "pn_...",
  "name": "VPS 154",
  "control": {
    "endpoint": "https://203.0.113.10:7443",
    "certificate_sha256": "sha256:..."
  },
  "enrollment": {
    "token": "...",
    "expires_at": "2026-08-01T00:00:00Z"
  }
}
```

### 4.2 控制 API

- `POST /v1/enroll`：消费一次性令牌，为一个客户端设备签发设备令牌。
- `GET /v1/status`：使用 `Authorization: Bearer <device-token>` 读取服务器身份与能力。
- `GET /v1/node`：使用设备令牌读取当前协议连接材料；返回值不包含客户端策略。

第一版设备令牌通过证书指纹固定的 HTTPS 通道签发。后续协议版本可升级为客户端证书/mTLS，不改变配对文件的产品语义。

## 5. VPS 安装

主要流程由 macOS PendingNet 经一次性 SSH 会话完成：上传 `pendingnet-server` 静态二进制并执行 `pendingnet-server install`。SSH 凭据不进入配对文件，也不由控制 API 长期保存。

同时保留手工上传二进制后执行 `pendingnet-server install` 的恢复入口。它是服务端程序自身的安装子命令，不再依赖生成和维护一份大型 shell 管理脚本。

## 6. iOS 能力边界

iOS 使用 Network Extension Packet Tunnel Provider，不能复用 macOS 的 root LaunchDaemon、特权助手或独立 CLI 进程。配对模型、服务端 API、VPS/协议/规则数据模型可以共享；隧道运行时必须独立实现。

iOS 第一阶段包含：配对、单 VPS、启动/停止 VPN、全局代理。多 VPS、协议选择和规则模式随后接入。macOS 的按进程统计不作为 iOS 对等能力。

## 7. 迁移策略

1. PendingNet Server 先能读取现有 `/etc/singb/config.env` 与 `/etc/singb/state.env`，保留已有密钥。
2. 第一版可继续管理现有 Xray + Hysteria2 服务，避免同时更换管理面与数据面。
3. 单独验证 sing-box VLESS Reality/Hysteria2 服务端兼容性后，再决定是否收敛为一个 sing-box 进程。
4. 旧 `sbtally config import/generate --vps` 保留为迁移入口，不再作为主要添加 VPS 流程。

## 8. 配置导入与更改方式

配置分成三层，避免再把一份巨大 JSON 当作所有状态的真相来源：

1. **添加 VPS**：每台客户端导入一份短期、一次性的 `.pdn`。成功后文件使命结束，长期设备令牌进入 Keychain。
2. **服务端协议参数**：PendingNet Server 保存节点资料。旧服务由 `import-singb` 迁移，新 VPS 由 `provision` 创建；后续轮换和升级命令继续维护。客户端通过 `/v1/node` 刷新。
3. **客户端策略**：路由模式、规则集、应用规则、TUN/系统代理选择保存在本机，通过 UI 修改；修改服务端协议时不覆盖这些设置。

客户端每次检测到节点资料版本变化后重新生成本平台的运行配置，并在 `sing-box check` 或平台等价校验通过后原子替换。旧完整 sing-box JSON 仅保留一次性迁移入口。

## 9. 2026-08-02 实现盘点

### 已完成

- Go 与 Swift 的 `.pdn` v1 模型和严格校验。
- 服务端自签 TLS 身份、证书指纹固定、一次性配对与独立设备令牌。
- `/healthz`、`/v1/enroll`、`/v1/status`、`/v1/node`。
- 旧 `singb` 环境文件的受限解析和无损节点迁移；服务端私钥与规则不会泄漏到节点资料。
- `pendingnet-server install` 的 systemd 服务安装基础。
- `pendingnet-server provision` 的全新 Reality/Hysteria2 部署：官方 Release SHA-256 校验、密钥/证书生成、配置验证、systemd 启动与失败停服。
- `provision --replace-existing` 可在明确允许中断后停用旧 Xray/Hysteria 服务；新服务失败时尝试恢复旧服务，旧配置原样保留。
- macOS 实际导入、注册、Keychain 和节点读取。
- macOS 可双击或导入 `.pdn`，将节点资料安全合并到现有 TUN/非 TUN 配置；保留客户端策略，校验、备份、原子写入后重启并自动选择新 VPS。
- iOS App、实际导入/注册/节点读取，以及 Packet Tunnel Extension 工程骨架。
- Swift 共享层可把节点资料转换为仅含协议的 sing-box outbounds；不生成或覆盖路由、DNS、TUN 与应用规则。
- Debian 12 amd64 实机已完成 PendingNet Server、Xray Reality、Hysteria2 切换；macOS 通过一次性配对文件注册后，Reality 与 Hysteria2 均已承载真实 HTTPS 流量。

### P0：下一里程碑必须完成

1. **VPS 生命周期补齐**：补 Debian/Ubuntu arm64 实机验证，以及升级、凭据轮换、卸载和完整回滚；amd64 主流程已经通过实机验收。
2. **iOS 真正联网**：集成可在 Network Extension 内运行的代理内核，把节点资料转换成隧道运行配置，完成启动、停止和全局代理。
3. **Mac 到 VPS 的安装体验**：在 macOS 客户端加入一次性 SSH 上传/安装流程；SSH 凭据不落盘。

### P1：可用性与安全闭环

- 设备列表、吊销、令牌轮换和节点资料版本/刷新通知。
- VPS 日志、服务状态、端口冲突、防火墙提示、备份恢复和升级回滚。
- 多 VPS、协议手选/自动选择、规则编辑在 macOS/iOS 的统一状态模型。
- 正式签名、App Group/Keychain Group、真机 Packet Tunnel 权限与发布验证。
- 阶段 A 遗留的 `sbtally`/`io.sbtally.*` 名称和 XPC 调用方校验统一迁移。
