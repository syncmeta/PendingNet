#!/bin/sh
# 用法: PENDING_NOTARY_PROFILE=<notarytool profile> \
#       PENDINGNET_PROVISION_PROFILE=<Developer ID 描述文件.provisionprofile> \
#       [PENDING_PUBLISH_R2=1] scripts/build-macos-update.sh
#
# PENDINGNET_PROVISION_PROFILE 是 0.3.19 起的新要求：app 带了 iCloud 键值存储与
# 共享钥匙串组，这类受限 entitlement 要描述文件背书才作数。描述文件从开发者门户
# 下（App ID com.pendingname.pendingnet 开 iCloud + Keychain Sharing，配置类型
# Developer ID）。不带着发会被下面的断言拦住。注意这就是 iOS 版用的同一个
# App ID —— 2026-08-08 起 macOS 的 bundle id 也归一到它了。
#
# 与 PendingBot 单仓 `scripts/release/build-macos-update.sh` 同构（2026-08-06 收口）：
# 干净快照（钉 main HEAD）里构建 Release → Developer ID 签名（Sparkle 内嵌件 +
# 特权 helper，见 sign-macos-development.sh）→ 公证 → staple → 生成签名 appcast
# → 打 tag →（可选）发 R2。工作区脏不脏都不影响「所见即所装」。
#
# 与单仓的唯一实质差异：**build 号不自动算**。单仓用 `git rev-list --count HEAD`，
# 这里不能照抄 —— 本仓 commit 数(100) 远小于已装机的 CURRENT_PROJECT_VERSION(310)，
# 切过去会让版本号倒退，Sparkle 判定新版更旧、更新永远不出现。所以这里继续手工
# 维护 app/project.yml 里的 MARKETING_VERSION + CURRENT_PROJECT_VERSION 一对，
# 由下面的「不许倒退」断言兜底。
set -eu

product=pendingnet
app_name=PendingNet
# 发布 Mac 本机钥匙串里存 Sparkle EdDSA 私钥的那条 item 的 account，**不是**
# bundle id。2026-08-08 归一 bundle id 时故意没跟着改：改了就取不到私钥，直接发
# 不了版。真要改名得先把钥匙串里那条 item 一起改，且只影响这一台发布机。
key_account=net.pending.PendingNet
: "${PENDING_NOTARY_PROFILE:?set the notarytool Keychain profile}"

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
feed_url="https://updates.pendingname.com/$product/appcast.xml"
download_prefix="https://updates.pendingname.com/$product/"
sibling="$root/../PendingBot/dev"

# 发布层脚本与 PendingBot 单仓对账 —— 两份必须 byte-identical，漂移即拒绝发布。
# （对方仓不在本机时跳过：没得比，比不了不算过错。）
pb_pub="$sibling/scripts/release/publish-macos-update-r2.sh"
if [ -f "$pb_pub" ]; then
  ours=$(shasum -a 256 "$root/scripts/publish-macos-update-r2.sh" | cut -d' ' -f1)
  theirs=$(shasum -a 256 "$pb_pub" | cut -d' ' -f1)
  if [ "$ours" != "$theirs" ]; then
    echo "publish-macos-update-r2.sh 与 PendingBot 单仓不一致 —— 先把两份同步成相同内容再发布" >&2
    exit 2
  fi
fi

# 干净快照：钉 main HEAD，构建不受工作区脏状态影响
snap=$(mktemp -d "/tmp/$product-release.XXXXXX")
git -C "$root" worktree add --detach "$snap/src" main
cleanup() {
  git -C "$root" worktree remove --force "$snap/src" 2>/dev/null || true
  git -C "$root" worktree prune
  rm -rf "$snap"
}
trap cleanup EXIT HUP INT TERM

snap_yml="$snap/src/app/project.yml"
# tail -n 1：project.yml 里 base 和 target 各有一份，要的是 target 那份
version=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*//p' "$snap_yml" | tail -n 1 | tr -d '"')
build_number=$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*//p' "$snap_yml" | tail -n 1 | tr -d '"')
test -n "$version" || { echo "取不到 MARKETING_VERSION" >&2; exit 2; }
test -n "$build_number" || { echo "取不到 CURRENT_PROJECT_VERSION" >&2; exit 2; }

# 不许倒退：build 号必须严格大于线上 feed 里的最大值，否则已装机的用户永远
# 收不到这次更新（Sparkle 比的是 CFBundleVersion）。手工维护版本号最容易犯
# 的错就是忘了改或改小，这里拦住。首发时 feed 还不存在，跳过。
live_max=$(curl -fsS --max-time 20 "$feed_url" 2>/dev/null \
  | sed -n 's/.*<sparkle:version>\([0-9][0-9]*\)<\/sparkle:version>.*/\1/p' \
  | sort -n | tail -n 1 || true)
if [ -n "${live_max:-}" ]; then
  if [ "$build_number" -le "$live_max" ]; then
    echo "CURRENT_PROJECT_VERSION=$build_number 不大于线上已发布的 $live_max —— 已装机的用户收不到这次更新，先把 app/project.yml 的版本号往上调" >&2
    exit 2
  fi
else
  echo "note: 线上 feed 还没有已发布版本（首发），跳过版本号不许倒退的检查"
fi

derived="$snap/derived"
release_dir="$root/dist/updates/$product"
app="$snap/$app_name.app"
archive="$release_dir/$app_name-$version.zip"
mkdir -p "$release_dir"

cd "$snap/src/app"
xcodegen generate
xcodebuild -project "$app_name.xcodeproj" -scheme "$app_name" -configuration Release \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build

/usr/bin/ditto "$derived/Build/Products/Release/$app_name.app" "$app"

# 无公钥的包 = 永远收不到更新的死包。generate_appcast 对缺钥静默跳过签名，
# 客户端对缺钥静默不启动 —— 两端都安静，只能在这里拦。
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist" >/dev/null \
  || { echo "产物 Info.plist 缺 SUPublicEDKey" >&2; exit 2; }
# SUFeedURL 在 project.yml 里是 $(PENDINGNET_UPDATE_FEED_URL) 变量，没解析出来
# 就是个空串/字面量，app 会当成「未配置更新源」静默不检查。
built_feed=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app/Contents/Info.plist" 2>/dev/null || echo "")
case "$built_feed" in
  https://*) ;;
  *) echo "产物 Info.plist 的 SUFeedURL 不是 https 地址（拿到的是 '$built_feed'）—— 构建变量没解析" >&2; exit 2 ;;
esac

# Developer ID 签名。helper 和 app 都要显式 --identifier（Service Management 靠
# 稳定的 designated requirement 认出新旧版本是同一对），这套门道在 sign 脚本里。
PENDINGNET_SIGN_IDENTITY="${PENDING_SIGN_IDENTITY:-Developer ID Application: Yanze Tan (M42BKJN82S)}" \
  "$snap/src/scripts/sign-macos-development.sh" "$app"

# 展开断言：签完的 app 里不许残留未展开的构建变量。单仓就是栽在这上面（手工
# codesign 不认 $(AppIdentifierPrefix)，把字面量签进 keychain access group，登录态
# 静默丢失，而签名有效、公证通过、Gatekeeper 放行，全程零报错）。
if codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q '[$](' ; then
  echo "签名后的 entitlements 仍含未展开的构建变量 —— 会让 keychain 组等失效" >&2
  codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert xml1 -o - - >&2
  exit 2
fi

# 同步断言：app 带 iCloud 键值存储 + 共享钥匙串组（已配对 VPS 与设备令牌要在
# Mac 和 iPhone 之间同步），这两项要描述文件背书才作数。签完的包里没有它们，
# 装机后就是「一切正常但两台设备各配各的」—— 又一个全程零报错的静默失败，
# 所以在这里拦。确实要发一个不带同步的包，设 PENDINGNET_ALLOW_NO_PROFILE=1。
if [ "${PENDINGNET_ALLOW_NO_PROFILE:-0}" != "1" ]; then
  signed_ents=$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)
  case "$signed_ents" in
    *ubiquity-kvstore-identifier*) ;;
    *) echo "签完的 app 没有 iCloud 键值存储 entitlement —— 装机后 Mac 与 iPhone 不会同步已配对 VPS。给 PENDINGNET_PROVISION_PROFILE=<Developer ID 描述文件>，或显式 PENDINGNET_ALLOW_NO_PROFILE=1" >&2; exit 2 ;;
  esac
  test -f "$app/Contents/embedded.provisionprofile" \
    || { echo "包里没有 embedded.provisionprofile —— 受限 entitlement 没人背书，等于没有" >&2; exit 2; }
fi

# dyld 断言：每个 @rpath 依赖都要能在包内解析出真实文件。上面那些查的全是签名和
# entitlement，没有一道查 dyld 能不能把库找着 —— 单仓 2026-08-06 就是这么发出一个
# **编译/链接/签名/公证/Gatekeeper/stapler 六道全绿、一双击就 SIGABRT** 的包
# （XcodeGen 给多端 target 生成的是 iOS 约定的 rpath，而 macOS 的嵌入式框架在
# Contents/Frameworks）。本仓当前 target 不受那个成因影响（0.3.11 产物已核通过），
# 这道门是防将来加嵌入式框架或改 target 形态时无声退化。
"$snap/src/scripts/verify-rpath-resolvable.sh" "$app" "$app_name"

/usr/bin/ditto -c -k --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$PENDING_NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
/usr/bin/ditto -c -k --keepParent "$app" "$archive"

gen="${SPARKLE_GENERATE_APPCAST:-$derived/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast}"
test -x "$gen"
"$gen" --account "$key_account" --download-url-prefix "$download_prefix" "$release_dir"

codesign --verify --deep --strict --verbose=2 "$app"
xcrun stapler validate "$app"
spctl -a -vvv -t install "$app"
git -C "$root" tag "$product/v$version" main 2>/dev/null \
  || echo "tag $product/v$version 已存在，沿用"
echo "Update ready: $archive"

if [ "${PENDING_PUBLISH_R2:-0}" = "1" ]; then
  # 本仓没装 node 依赖，wrangler 通常不在 PATH 上；发布层脚本与单仓逐字节一致、
  # 不能为本仓的目录结构改动，所以在这里补默认值（外部显式指定优先）。
  if [ -z "${PENDING_UPDATES_WRANGLER:-}" ] && [ -x "$sibling/node_modules/.bin/wrangler" ]; then
    PENDING_UPDATES_WRANGLER="$sibling/node_modules/.bin/wrangler"
    export PENDING_UPDATES_WRANGLER
  fi
  "$root/scripts/publish-macos-update-r2.sh" "$product" "$release_dir"
fi
