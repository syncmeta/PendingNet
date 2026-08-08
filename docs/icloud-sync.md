# 已配对 VPS 在 Mac 与 iPhone 之间同步

导入一次 `.pdn`，两台设备都能用。做法是**两台设备共用同一份设备凭据**（方案 A）：

- **已配对 VPS 名单**走 iCloud 键值存储（`NSUbiquitousKeyValueStore`），本地
  `UserDefaults` 是镜像兼离线兜底。按 `serverID` 合并，`updatedAt` 新的那份赢。
- **设备令牌**走 iCloud 钥匙串（数据保护钥匙串 + `kSecAttrSynchronizable` +
  共享 access group + `AfterFirstUnlock`）。

服务端一行没改。配对码是一次性的（`internal/pnserver/state.go` 校验 `UsedAt == nil`），
所以能同步的只有凭据本身，`.pdn` 文件本身同步过去也用不了第二次。

**不同步的东西**：「当前选中哪一台 VPS」是本机状态，两台设备各连各的。

**没有删除语义**：合并是并集。两端目前都没有删除已配对 VPS 的入口；将来要加，
得在记录里加墓碑位，不能靠「云端那份里没有它」来表达删除。

## 用不了 iCloud 时会怎样

一切照旧纯本地工作，不弹错、不刷红字：

- 键值存储：启动时用 `synchronize()` 探一次，返回 false 就当 iCloud 不存在
  （实测未签名进程里就是 false，且不崩）。
- 钥匙串：三个存放位置从好到差依次试 —— ①同步 + 共享组 ②同步 + App 默认组
  ③老的本地条目（0.3.18 及以前的形状）。没有 entitlement 时前两个回
  `-34018`，自动落到第三个，也就是今天的行为。
- 老条目在读到时会顺手搬到当前能用的最好位置；**搬不上去就原地不动**，老条目
  留着，配对不会丢。

本地 ad-hoc 签名的开发构建（`scripts/sign-macos-development.sh` 不带描述文件）
永远走的是这条降级路径 —— 开发流程不受影响，但也**验证不了同步本身**。

## 人类要在 Apple 开发者门户做的事

代码和构建配置已经就位，下面这几步必须由人在门户 / Xcode 里点，之后才能真跑：

1. App ID `com.pendingname.pendingnet`（iOS）：开 **iCloud**（Key-value storage）
   和 **Keychain Sharing**，钥匙串组填 `com.pendingname.pendingnet`。
2. App ID `net.pending.PendingNet`（macOS）：同样开 **iCloud** 和
   **Keychain Sharing**，钥匙串组同样填 `com.pendingname.pendingnet`
   —— 两端必须逐字相同，bundle id 不同不要紧。
3. 给 macOS 的 App ID 生成一份 **Developer ID** 类型的描述文件（含上面两项），
   下下来，发版时经 `PENDINGNET_PROVISION_PROFILE` 传给构建脚本。
4. iOS 侧自动签名会自己拉描述文件，Xcode 里确认两个 capability 都亮着即可。
5. 两台设备登同一个 Apple ID，且**「设置 → Apple ID → iCloud → 钥匙串」要打开**
   —— 钥匙串同步没开的话，VPS 名单会同步、令牌不会，列表上的 VPS 连不上。

## 对发版脚本的影响

iCloud 键值存储和钥匙串共享组都是**受限 entitlement**：光用 `codesign
--entitlements` 签进去不作数，必须有一份包含它们的描述文件放进
`Contents/embedded.provisionprofile` 背书。

- `scripts/sign-macos-development.sh`：新增 `PENDINGNET_PROVISION_PROFILE`。给了
  就把描述文件拷进包里，按描述文件里的 team 展开 `$(AppIdentifierPrefix)` /
  `$(TeamIdentifierPrefix)`（手工 codesign 不认构建变量），再带 `--entitlements`
  签。ad-hoc 那条路一个字没动。
- `scripts/build-macos-update.sh`：没描述文件直接拦下 —— 否则发出去的是一个
  签名有效、公证通过、Gatekeeper 放行、**但两台设备各配各的**静默失败包。
  确实要发不带同步的版本，显式 `PENDINGNET_ALLOW_NO_PROFILE=1`。
