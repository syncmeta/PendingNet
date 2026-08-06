# PendingNet macOS 更新发布

PendingNet 0.3.9 起使用 Sparkle 2。更新链包含四层：HTTPS 传输、签名 appcast、EdDSA 更新包签名、Apple Developer ID + notarization。任何一层失败都不安装更新。

三产品统一策略：自动检查开、自动安装关（`SUAutomaticallyUpdate: false`）——发现新版弹窗，装不装由人点。PendingBot / PendingCrew 的发布脚本在 PendingBot 仓 `scripts/release/`，其中 `publish-macos-update-r2.sh` 与本仓那份必须逐字节一致（对方构建脚本发布前校验 sha256）。

## 一次性准备

1. 统一更新源使用 Cloudflare R2 bucket `pending-updates-prod` 与生产域名 `https://updates.pendingname.com`。PendingNet 固定使用 `pendingnet/`，PendingCrew 固定使用 `pendingcrew/`，PendingBot 固定使用 `pendingbot/`；三个产品共用发布规范，各自持有独立 EdDSA 私钥。更新 feed 启用 `SURequireSignedFeed` 与 `SUVerifyUpdateBeforeExtraction`，不得手工修改生成后的 appcast。
2. PendingNet 的 Sparkle 私钥保存在发布 Mac 的 Keychain，account 为 `net.pending.PendingNet`；仓库和服务器只保存 Info.plist 中的公钥。必须单独备份这项钥匙串密钥。
3. 使用 `xcrun notarytool store-credentials` 创建专用 Keychain profile。Apple ID 的 app-specific password 不进入脚本或仓库。
4. 记录发布参数：
   - `PENDINGNET_UPDATE_FEED_URL`：`https://updates.pendingname.com/pendingnet/appcast.xml`
   - `PENDINGNET_UPDATE_DOWNLOAD_PREFIX`：`https://updates.pendingname.com/pendingnet/`
   - `PENDINGNET_NOTARY_PROFILE`：notarytool Keychain profile
   - `PENDINGNET_PUBLISH_R2=1`：公证成功后发布到 R2；未设置时只在本地生成发布物
   - `PENDING_UPDATES_WRANGLER`：可选，Wrangler 不在 PATH 时指向它的可执行文件

## 每次发布

版本号必须同时递增：

- `MARKETING_VERSION`：用户看到的版本，例如 `0.3.10`
- `CURRENT_PROJECT_VERSION`：只增不减的整数，例如 `310`

运行 `scripts/build-macos-update.sh`。脚本会构建 Release、Developer ID 签名、压缩、提交 notarization、staple、公证后重新压缩，并调用 Sparkle `generate_appcast` 生成签名 feed。设置 `PENDINGNET_PUBLISH_R2=1` 后，脚本调用 `scripts/publish-macos-update-r2.sh`：先上传带永久缓存的版本文件，最后上传禁止陈旧缓存的 `appcast.xml`，并从生产域名回读验证。

R2 不存放任何私钥、Apple 凭据或 Wrangler token。Sparkle 私钥和公证凭据只保存在发布 Mac 的 Keychain；Cloudflare 凭据由 Wrangler 自己管理。

发布前必须在一台安装旧版本的 Mac 上验证：手动“检查更新”、后台自动检查、下载签名失败拒绝、正常替换重启、代理子进程退出和恢复。
