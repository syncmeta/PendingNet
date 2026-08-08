# PendingNet macOS 更新发布

PendingNet 0.3.9 起使用 Sparkle 2。更新链包含四层：HTTPS 传输、签名 appcast、EdDSA 更新包签名、Apple Developer ID + notarization。任何一层失败都不安装更新。

三产品统一策略：自动检查开、自动安装关（`SUAutomaticallyUpdate: false`）——发现新版弹窗，装不装由人点。PendingBot / PendingCrew 的发布脚本在 PendingBot 仓 `scripts/release/`，其中 `publish-macos-update-r2.sh` 与本仓那份必须逐字节一致（对方构建脚本发布前校验 sha256）。

## 一次性准备

1. 统一更新源使用 Cloudflare R2 bucket `pending-updates-prod` 与生产域名 `https://updates.pendingname.com`。PendingNet 固定使用 `pendingnet/`，PendingCrew 固定使用 `pendingcrew/`，PendingBot 固定使用 `pendingbot/`；三个产品共用发布规范，各自持有独立 EdDSA 私钥。更新 feed 启用 `SURequireSignedFeed` 与 `SUVerifyUpdateBeforeExtraction`，不得手工修改生成后的 appcast。
2. PendingNet 的 Sparkle 私钥保存在发布 Mac 的 Keychain，account 为 `net.pending.PendingNet`；仓库和服务器只保存 Info.plist 中的公钥。必须单独备份这项钥匙串密钥。
   （这个 account 名是 2026-08-08 bundle id 归一时**故意**留下的旧名字 —— 它只是本机钥匙串里一条 item 的名字，改了就取不到私钥、直接发不了版。见 `scripts/build-macos-update.sh`。）
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

## 换 bundle id 那一版：`net.pending.PendingNet` → `com.pendingname.pendingnet`

2026-08-08 把 macOS 的 bundle id 归一到了 iOS 那个（`app/project.yml`）。**这是装机
用户唯一一次会撞上换身份的升级**，下面三条只对「从 0.3.18 及更早升上来」成立。

### Sparkle 能不能跨 bundle id 装过去：能，不用手动装

读的是本仓钉死的 Sparkle 2.9.2 源码，不是猜的：

- `SUUpdateValidator` 全程**不比较新旧 bundle id**。本仓开了
  `SUVerifyUpdateBeforeExtraction`，所以解包前就用**旧 app 里的** EdDSA 公钥验过
  压缩包（`_prevalidatedSignature = YES`）。EdDSA 密钥这次没换，这一关直接过。
- 走到这条路径之后，那句「新包的代码签名必须和旧 app 的对得上」
  （`codeSignatureIsValidAtBundleURL:andMatchesSignatureAtBundleURL:`）根本不会执行
  —— 它只在**没有**预校验的分支里。而 designated requirement 里带着 identifier，
  真跑到那句才是会被 bundle id 卡住的地方。
- `SUInstaller installSourcePathInUpdateFolder:` 是**按文件名**在解开的包里找新 app
  （`PendingNet.app`），bundle id 只是文件名对不上时的兜底匹配。app 名字没变。
- `AppInstaller` 里那处 bundle id 断言比的是**旧 app 和旧 app**（安装数据里的宿主
  路径 vs 启动参数），跟新包无关。

结论：正常的「检查更新 → 安装」就能过去，发版说明里不需要写「请手动下载」。

**但仍然要在装着 0.3.18 的机器上真跑一次再发。** 上面是代码阅读的结论，跨 id 这条
路径以前从没走过。

### 用户的本地设置：自动搬，不用管

换 bundle id 等于换 `UserDefaults` 域。App 启动时会做一次性搬迁
（`PendingNetLegacyDefaultsMigration`）：已配对 VPS、代理端口、局域网开关、路由模式
从旧域搬进新域，搬完打标记不再重复搬，**旧域原样保留**（装回旧版还能用）。

搬不过去的只有框架自己维护的那些键（窗口位置、Sparkle 的上次检查时间）—— 故意不搬。

### 旧的后台助手：会被自动踢掉，但「登录项与扩展」里可能留个空壳

这是这次升级唯一需要**跟用户交代**的一件事。

旧版注册的是 `net.pending.PendingNet.helper`，新版注册的是
`com.pendingname.pendingnet.helper` —— 两个不同的守护进程。旧的那个不会自己消失：
launchd 让它常驻，而新 app 够不着它（Mach 服务名不同，且旧助手只接受签名为
`net.pending.PendingNet` 的调用方）。这不只是不整洁：两版共用
`/usr/local/etc/sbtally`，残留的 root 守护进程可能**仍占着系统代理**，而新 app 以为
什么都没设 —— 正是「所有走代理的连接都被拒绝」那个状态。

`SMAppService` 在这里使不上劲，试过也没用：它只认本 bundle 里的 plist，而 Background
Task Management 的注册记录绑在**旧 app 的代码身份**上。所以做法是：**新助手一启动就
`launchctl bootout` 掉旧 job**（`retireLegacyHelperJob()`，它是 root，这是唯一的杠杆）。

用户实际要做的：

1. 装上新版，打开 App，在「系统设置 → 通用 → 登录项与扩展」里**给 PendingNet 的后台
   项目打开开关**。这一步跑不掉 —— 新的守护进程是新身份，旧的批准不算数。
2. 批准之后旧 job 会被自动踢掉，不用敲命令。
3. 「登录项与扩展」里如果还剩一条 PendingNet 的旧条目，把它关掉/删掉即可。那条记录属于
   旧 app bundle，新助手无权删；原地覆盖安装的话它一般会随旧 bundle 一起消失。

万一在批准新助手之前网络就是不通（旧守护进程还占着系统代理），这条命令能立刻救回来：

```sh
sudo launchctl bootout system/net.pending.PendingNet.helper
sudo networksetup -setwebproxystate Wi-Fi off
sudo networksetup -setsecurewebproxystate Wi-Fi off
sudo networksetup -setsocksfirewallproxystate Wi-Fi off
sudo rm -f /usr/local/etc/sbtally/pendingnet-system-proxy-owned
```
