# PendingNet macOS 更新发布

PendingNet 0.3.9 起使用 Sparkle 2。更新链包含四层：HTTPS 传输、签名 appcast、EdDSA 更新包签名、Apple Developer ID + notarization。任何一层失败都不安装更新。

三产品统一策略：自动检查开、自动安装关（`SUAutomaticallyUpdate: false`）——发现新版弹窗，装不装由人点。PendingBot / PendingCrew 的发布脚本在 PendingBot 仓 `scripts/release/`，其中 `publish-macos-update-r2.sh` 与本仓那份必须逐字节一致（对方构建脚本发布前校验 sha256）。

## 一次性准备

1. 统一更新源使用 Cloudflare R2 bucket `pending-updates-prod` 与生产域名 `https://updates.pendingname.com`。PendingNet 固定使用 `pendingnet/`，PendingCrew 固定使用 `pendingcrew/`，PendingBot 固定使用 `pendingbot/`；三个产品共用发布规范，各自持有独立 EdDSA 私钥。更新 feed 启用 `SURequireSignedFeed` 与 `SUVerifyUpdateBeforeExtraction`，不得手工修改生成后的 appcast。
2. PendingNet 的 Sparkle 私钥保存在发布 Mac 的 Keychain，account 为 `net.pending.PendingNet`；仓库和服务器只保存 Info.plist 中的公钥。必须单独备份这项钥匙串密钥。
3. 使用 `xcrun notarytool store-credentials` 创建专用 Keychain profile。Apple ID 的 app-specific password 不进入脚本或仓库。
4. 记录发布参数（2026-08-06 与 PendingBot 单仓收口成同一套名字，旧的 `PENDINGNET_*` 前缀已废弃）：
   - `PENDING_NOTARY_PROFILE`：notarytool Keychain profile（必填）
   - `PENDING_PUBLISH_R2=1`：公证成功后发布到 R2；未设置时只在本地生成发布物
   - `PENDING_SIGN_IDENTITY`：可选，覆盖默认的 Developer ID 签名身份
   - `PENDING_UPDATES_WRANGLER`：可选。本仓没装 node 依赖，脚本默认回落到相邻
     PendingBot 仓的 `node_modules/.bin/wrangler`；两个仓都不在时才需要显式指定
   - `PENDINGNET_PROVISION_PROFILE`：Developer ID 描述文件（必填）。app 带
     iCloud 键值存储与共享钥匙串组，这类受限 entitlement 只有描述文件背书才
     作数，不给会被脚本拦下。怎么申请见 [icloud-sync.md](icloud-sync.md)

   feed 地址与下载前缀不再从环境变量传入 —— 它们由产品名推导（`.../pendingnet/`），
   构建产物里的 `SUFeedURL` 解析不出 https 地址时脚本直接拒绝发布。

## 每次发布

版本号必须同时递增（本仓**不能**像 PendingBot 单仓那样用 commit 数自动算 build 号 ——
本仓 commit 数远小于已发出去的 `CURRENT_PROJECT_VERSION`，切过去会让版本号倒退、
Sparkle 判定新版更旧、更新永远不出现）：

- `MARKETING_VERSION`：用户看到的版本，例如 `0.3.11`
- `CURRENT_PROJECT_VERSION`：只增不减的整数，例如 `311`

漏改或改小由脚本拦住：发布前会拉线上 appcast，新 build 号必须严格大于已发布的最大值。

运行 `PENDING_NOTARY_PROFILE=<profile> PENDING_PUBLISH_R2=1 scripts/build-macos-update.sh`。
脚本先用 `git worktree` 取一份钉死 main HEAD 的**干净快照**（工作区脏不脏都不影响
「所见即所装」），在快照里构建 Release、Developer ID 签名（Sparkle 内嵌件 + 特权
helper）、压缩、提交 notarization、staple、公证后重新压缩，调用 Sparkle
`generate_appcast` 生成签名 feed，打 `pendingnet/v<版本>` tag。设置 `PENDING_PUBLISH_R2=1`
后调用 `scripts/publish-macos-update-r2.sh`：先上传带永久缓存的版本文件，最后上传
禁止陈旧缓存的 `appcast.xml`，并从生产域名回读验证。

发布前的 fail-loud 闸门（任何一条不过就拒绝发布，不留静默失败）：

- 发布层脚本与 PendingBot 单仓那份必须逐字节一致（sha256 对账）
- 新 build 号必须大于线上已发布的最大值
- 产物 Info.plist 必须有 `SUPublicEDKey`（缺钥的包 = 永远收不到更新的死包，而
  `generate_appcast` 对此静默跳过签名、客户端静默不启动，两端都不报错）
- 产物 `SUFeedURL` 必须是 https 地址（构建变量没解析就会是空串）
- 签名后的 entitlements 里不许残留未展开的 `$(...)` 构建变量（PendingBot 单仓
  2026-08-06 首发就栽在这上面：`codesign` 不认 Xcode 构建变量，把字面量签进
  keychain access group，登录态静默丢失，而签名有效、公证通过、Gatekeeper 放行）

R2 不存放任何私钥、Apple 凭据或 Wrangler token。Sparkle 私钥和公证凭据只保存在发布 Mac 的 Keychain；Cloudflare 凭据由 Wrangler 自己管理。

发布前必须在一台安装旧版本的 Mac 上验证：手动“检查更新”、后台自动检查、下载签名失败拒绝、正常替换重启、代理子进程退出和恢复。
