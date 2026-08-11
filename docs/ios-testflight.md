# iOS 发 TestFlight

macOS 那条发版链（Developer ID + 公证 + Sparkle，见 `docs/macos-updates.md`）和这条
毫无关系：Mac 版自己发自己的更新，iPhone 版只能走苹果的商店通道。两条互不影响，
改一条不用管另一条。

命令行这边能自动的都自动了，剩下**四处只能在浏览器里点**，下面第一节按顺序写清了。

---

## 一、只能主人在浏览器里点的（按顺序）

### 第 1 步：确认协议已签

<https://appstoreconnect.apple.com> →「业务」（协议、税务和银行业务）。

「免费 App」那份协议状态必须是**生效中**。没生效的话下一步建不了 App 记录，
而且报错含糊。第一次用这个账号发 App 时最容易卡在这里。

### 第 2 步：新建 App 记录

App Store Connect 的接口不提供「新建 App」，这一步只能手点，一次就够。

1. <https://appstoreconnect.apple.com/apps> → 左上角 **+** →「新建 App」
2. 平台勾 **iOS**
3. **名称**：`PendingNet`（全 App Store 唯一；被占了就换一个，这个名字只影响商店
   展示，不影响 bundle id，也不影响代码）
4. **主要语言**：简体中文
5. **套装 ID**：下拉里选 `com.pendingname.pendingnet`
   - 下拉里**找不到**它 → 说明开发者门户里还没有这个标识符。先在命令行跑一次
     `scripts/build-ios-testflight.sh`（带 `-allowProvisioningUpdates`，Xcode 会
     自动去门户建），再回来刷新这个页面。
6. **SKU**：`pendingnet-ios`（内部编号，随便填，不对外）
7. **用户访问权限**：完全访问
8. 点「创建」

### 第 3 步：核对 App ID 的能力

<https://developer.apple.com/account/resources/identifiers/list>

这两个标识符都要看：

| 标识符 | 必须打开的能力 |
| --- | --- |
| `com.pendingname.pendingnet` | App Groups、iCloud（含 Key-value storage）、Network Extensions |
| `com.pendingname.pendingnet.extension` | App Groups、Network Extensions |

外加 Identifiers → App Groups 里要有 `group.com.pendingname.pendingnet`，并且上面
两个标识符都勾中了它。

> Network Extensions 现在是自助能力，付费开发者账号直接勾就行，不用再向苹果申请。
>
> 钥匙串共享（`keychain-access-groups`）不是门户里的能力项，它跟着描述文件走，
> 这里看不到也是正常的。

想省事的话直接跑 `scripts/asc-api.py preflight`，缺什么它会指名道姓地列出来。

### 第 4 步：构建传上去之后 —— 答出口合规问卷

**每个新构建都要答一次**，不答就只是挂在那里，连内部测试员都收不到，而且没有
任何报错，只有一个黄色叹号。

TestFlight 页面 → 找到刚上传的构建 → 「管理」/「提供出口合规信息」：

- 「你的 App 是否使用加密？」→ **是**
  （`ITSAppUsesNonExemptEncryption` 已经在 `app/project.yml` 里写死成 `true`。
  这是如实申报：本 App 内嵌 sing-box，自己实现了 shadowsocks / VMess / TLS 这些
  加密协议，不属于「只用系统 HTTPS」那类豁免。写 `false` 省事，但那是假申报。）
- 后面几问按实际情况答。这类「大众市场加密软件」通常走 **5D992.c 自分类**，需要
  每年向美国 BIS 报一次自分类清单；拿到 ERN 编号之后，可以把它作为
  `ITSEncryptionExportComplianceCode` 写进 `project.yml` 的 `info.properties`，
  以后就不再弹问卷了。
- 法国另有一份加密声明，App Store Connect 会单独问。

> 这一问涉及法律申报，不是技术选择。真要改成别的答法，得主人自己定。

### 第 5 步（发内部测试）

TestFlight →「内部测试」→ 新建群组 → 把人加进去（内部测试员必须是这个 App Store
Connect 账号下的用户）→ 勾上构建。**不需要**审核，答完第 4 步几分钟内就到。

### 第 6 步（发外部测试，可选）

外部测试要过 Beta App 审核，另外还要填：

- 测试信息：反馈邮箱、演示账号（VPN 类 App 审核多半会要一个能连通的 VPS 配置）、
  审核备注（说清这是什么、为什么要 Network Extension）
- 隐私政策网址（必填）
- App 隐私（数据收集）问卷 —— 本 App 不采集任何数据，全选「不收集」即可，和
  `PrivacyInfo.xcprivacy` 里的声明一致

内部测试不需要这些。

---

## 二、命令行这边（不用手点）

```sh
# 一次性：把 Issuer ID 存下来（不进仓库）
echo '<你的 Issuer ID>' > ~/.appstoreconnect/issuer_id

# 看看还差什么
scripts/asc-api.py preflight

# 打包（导出 .ipa，不上传）
scripts/build-ios-testflight.sh

# 确认无误后再上传
PENDINGNET_IOS_UPLOAD=1 scripts/build-ios-testflight.sh
```

### 凭据放哪

| 东西 | 位置 |
| --- | --- |
| API 私钥 | `~/.appstoreconnect/private_keys/AuthKey_9PS6Y7K4X9.p8` |
| Issuer ID | `~/.appstoreconnect/issuer_id`，或环境变量 `PENDINGNET_ASC_ISSUER_ID` |

两样都**不进仓库**。私钥必须是那个目录下的**真文件**，不能是指向「文稿」文件夹的
软链 —— 系统隐私保护不让后台进程读「文稿」，而 xcodebuild 撞上只会含糊地报一句
签名失败。

### 证书和描述文件不用手动准备

本机现在只有一张 Apple Development 证书，够用。缺的 **Apple Distribution 证书**和
两份 **App Store 描述文件**（主 App + 隧道扩展）由导出那一步的
`-allowProvisioningUpdates` + 同一把 API 密钥自动建，不用去网页上点。

分工是这样的：`archive` 用开发签名（和真机调试同一套），`-exportArchive` 再拿
分发身份**重签**一遍。这是 Xcode 的既定流程，不是将就。

### 版本号

`app/project.yml` 里 base 和 macOS target 各写了一份 `MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION`，iOS 用的是 base 那份。脚本会先要求两份相等，再去
App Store Connect 查这个 build 号是不是已经传过 —— 重号苹果会原样退回，而这个
查询发生在长构建**之前**，不会让人白等。

### 脚本会拦下什么

`scripts/build-ios-testflight.sh` 一路 fail-loud，任何一条不满足就报错退出：

- 缺 xcodegen / 缺 `Libbox.xcframework` / 私钥读不了 / 没有 Issuer ID
- `project.yml` 里两处版本号漂移
- 这个 build 号在 App Store Connect 上已经用过
- 产物版本号和仓库里的对不上（主 App 和扩展都查）
- 缺 `ITSAppUsesNonExemptEncryption`
- 主 App 或扩展缺 `PrivacyInfo.xcprivacy`
- `Assets.car` 里没有 1024×1024 的商店图标
- 重签后不是 Apple Distribution 签的 / 没有描述文件
- entitlements 里还有没展开的构建变量（`$(AppIdentifierPrefix)` 这种）
- 带着 `get-task-allow`（那是开发包）
- 缺 `beta-reports-active`（说明用的不是 App Store 描述文件）
- 缺网络扩展 / 共享组 / iCloud 键值存储 / 钥匙串组 entitlement
- `application-identifier` 和预期的 bundle id 对不上
- 最后再跑一遍 `altool --validate-app`，让苹果服务端先过一遍收件检查

只想本地打个包看看，不碰网络：`PENDINGNET_IOS_ARCHIVE_ONLY=1 scripts/build-ios-testflight.sh`。

---

## 三、隐私清单

`app/PendingNetIOS/PrivacyInfo.xcprivacy` 和 `app/PacketTunnel/PrivacyInfo.xcprivacy`
各一份（扩展是独立 bundle，主 App 那份盖不到它）。

声明的三类是按实际链进去的符号来的，不是拍脑袋：

| 类别 | 理由码 | 依据 |
| --- | --- | --- |
| UserDefaults | `CA92.1` | 控制器和 SBTallyCore 都在读写 `UserDefaults.standard` |
| 文件时间戳 | `C617.1` | `Libbox.xcframework` 引用 `stat` / `fstat` / `lstat` |
| 系统启动时间 | `35F9.1` | 同一个库引用 `sysctl` / `sysctlbyname`（Go 运行时的单调时钟） |

复核办法：`nm -u app/Vendor/Libbox.xcframework/ios-arm64/Libbox.framework/Versions/A/Libbox`。

真上传之后如果还收到 ITMS-91053 退信，信里会点名缺哪一类，照着往
`NSPrivacyAccessedAPITypes` 里补即可。

不采集任何数据，所以 `NSPrivacyCollectedDataTypes` 是空的。

---

## 四、几个已知会踩的坑

- **构建传上去了但测试员收不到** —— 九成是第 4 步的出口合规问卷没答。
- **上传报重号** —— `CURRENT_PROJECT_VERSION` 往上加，两处一起改。
- **导出时说找不到描述文件** —— Issuer ID 或私钥不对，先跑 `scripts/asc-api.py apps`
  验一下凭据通不通。
- **TestFlight 构建 90 天后过期** —— 正常，重新传一个。
