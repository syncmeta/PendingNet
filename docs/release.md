# 怎么出一个 GitHub Release

macOS 版的日常更新走的是自建的 Sparkle appcast（见 [macos-updates.md](macos-updates.md)），装了 app 的人从 `updates.pendingname.com` 收更新，跟 GitHub 无关。GitHub Release 是给第一次打开这个仓库的人看的：到 2026-08-23 为止发过 `pendingnet/v0.3.29` 和 `pendingnet/v0.3.30`，都只挂了 macOS 的 zip。

这份文档记的是怎么发下一个。**下面的步骤没有一条被自动执行过**，因为它们要么会推东西到远端，要么会创建对外可见的对象。

## 两条发布通道的关系

| | Sparkle appcast | GitHub Release |
| --- | --- | --- |
| 给谁 | 已经装了 app 的人 | 第一次来的人 |
| 在哪 | Cloudflare R2 + `updates.pendingname.com` | GitHub |
| 谁触发 | `scripts/build-macos-update.sh` 自动做完 | 手工 |
| 缺了会怎样 | 装了的人收不到更新 | 新人下载不到 |

两条通道用**同一个产物**。不需要为了发 GitHub Release 重新构建。

## 产物从哪来

一次 Release 要挂两类东西：

| 资产 | 给谁 | 谁产的 |
| --- | --- | --- |
| `PendingNet-<版本>.zip` | 下载 macOS 客户端的人 | `scripts/build-macos-update.sh`（签名 + 公证 + staple） |
| `pendingnet-server-linux-amd64`<br>`pendingnet-server-linux-arm64`<br>`SHA256SUMS` | VPS 上的一键部署脚本 | `scripts/build-linux-server.sh` |

`deploy/vps-install.sh` 在 VPS 上第一件事就是去最新的 Release 找那三个东西：
下到二进制、用 `SHA256SUMS` 核过才敢用。**缺了不会失败**——它会退回到在 VPS 上现装
Go 工具链、clone 仓库、现场编译，能跑通，但要多花好几分钟。所以每次发 Release 都该把它们挂上。

`scripts/build-linux-server.sh` 只交叉编译，不推任何东西，产物在 `dist/server/`：

```sh
scripts/build-linux-server.sh
```

资产名是 `vps-install.sh` 按字面找的，**别改名**。arm64 那个只是编出来了，从没在真的
arm64 机器上跑过。

`scripts/build-macos-update.sh` 每次跑完，会在 `dist/updates/pendingnet/` 留下 `PendingNet-<版本>.zip`。这个 zip 是完整的发布产物：Developer ID 签名 → Apple 公证 → staple 之后重新打的包。

`dist/` 在 `.gitignore` 里，所以产物只在发布机本地。

验证一份产物能不能直接拿去发（这几条是只读的，随便跑）：

```sh
D=$(mktemp -d)
ditto -x -k dist/updates/pendingnet/PendingNet-0.3.28.zip "$D"
xcrun stapler validate "$D/PendingNet.app"      # 公证票据在不在
spctl -a -vvv -t install "$D/PendingNet.app"    # Gatekeeper 认不认
codesign -dv --verbose=2 "$D/PendingNet.app"    # 签名身份对不对
```

三条都过才算数。2026-08-21 核过 `PendingNet-0.3.28.zip`：`stapler validate` 通过、`spctl` 返回 `accepted / source=Notarized Developer ID`、签名是 Developer ID Application。**这一份现在就可以直接挂上去。**

> 解压一定要用 `ditto -x -k`。`unzip` 不保留 macOS app bundle 里的符号链接和扩展属性，解出来的 `.app` 签名会碎（`spctl` 报 `a sealed resource is missing or invalid`），那是解压方式的问题，不是包坏了。

## 版本号和 tag

`scripts/build-macos-update.sh` 发布成功后会自动打一个本地 tag `pendingnet/v<版本>`（iOS 那条是 `pendingnet-ios/v<版本>-<build>`）。

**这些 tag 大部分只在本地**——到 2026-08-21 为止，远端只有 `pendingnet/v0.3.27` 和 `pendingnet-ios/v0.3.27-327` 两个，本地则有 v0.3.11 到 v0.3.28 共二十个。GitHub Release 必须挂在远端存在的 tag 上，所以发之前得先把对应的 tag 推上去。

版本号的规矩（`docs/macos-updates.md` 里有完整说明，这里只记要点）：`MARKETING_VERSION` 是给人看的（`0.3.28`），`CURRENT_PROJECT_VERSION` 是只增不减的整数（`328`），两个都在 `app/project.yml` 里，发布前脚本会拉线上 appcast 比对，build 号没变大就直接拒绝发布。

## 发一个 Release

以 0.3.28 为例。**这三条命令都会改远端，要人自己按。**

```sh
# 1. 把 tag 推上去（Release 必须挂在远端 tag 上）
git push origin pendingnet/v0.3.28

# 2. 编出 Linux 服务端的三个资产（macOS 的 zip 打包时已经有了）
scripts/build-linux-server.sh

# 3. 创建 Release 并挂上全部产物
gh release create pendingnet/v0.3.28 \
  dist/updates/pendingnet/PendingNet-0.3.28.zip \
  dist/server/pendingnet-server-linux-amd64 \
  dist/server/pendingnet-server-linux-arm64 \
  dist/server/SHA256SUMS \
  --title "PendingNet 0.3.28" \
  --notes-file /tmp/release-notes.md
```

Release 已经发出去了才想起来补 Linux 那三个：`gh release upload pendingnet/v0.3.28 dist/server/*`。

想先看看效果再决定，加 `--draft`。

补历史版本的话，把要补的 tag 一起推上去，然后对每个 tag 各跑一次 `gh release create`。**没必要全补**——从最新的一个开始，往回补两三个就够了。

## 发布说明写什么

现在没有 CHANGELOG，Sparkle 的 appcast 里也没写发布说明。第一个 Release 建议手写，至少包含：

- 这是什么、给谁用（一句话，链回 README）
- **系统要求和硬性前提**：macOS 版本下限、需要 Developer ID 公证过的包（已经是了）、装完要去「系统设置 → 通用 → 登录项与扩展」里给后台项目打开开关——不打开，TUN 和系统代理两种模式都用不了
- **要连上还需要一台自己的 VPS**，装了 `pendingnet-server` 并生成一份 `.pdn`。这个前提要写在最前面，不然下载的人打开 app 会一脸茫然。VPS 那头现在有一键脚本了（`deploy/vps-install.sh`），这里可以直接把那条 `curl ... | sudo bash` 贴上去
- 这一版改了什么。没有 CHANGELOG 的话，`git log --oneline pendingnet/v0.3.27..pendingnet/v0.3.28` 能凑出一份

## iOS 那边

iOS 不能通过 GitHub Release 分发——安装包只能从 App Store 或 TestFlight 装。`dist/ios/` 下的 `.ipa` **不要挂上去**：别人下载了也装不了，而 ipa 里带着完整的分发描述文件和签名身份。iOS 的分发流程见 [ios-testflight.md](ios-testflight.md)。

## 还缺的

- **没有 CHANGELOG。** 现在只能靠 commit 日志凑发布说明。
- **发 Release 这一步没有自动化。** `build-macos-update.sh` 管到 Sparkle appcast 为止，GitHub 这条是纯手工。真要自动化，在那个脚本里加一段 `gh release create` 就行，但那意味着一次发布同时推两个远端，出错的面变大——现在是故意分开的。
- **Linux 服务端那三个资产还一次都没挂过。** `scripts/build-linux-server.sh` 编得出来，但至今没发过带它们的 Release——所以 `deploy/vps-install.sh` 现在在真机上一定走的是「回退到源码编译」那条路（能跑通，只是慢几分钟）。下一次发 Release 挂上就好。
