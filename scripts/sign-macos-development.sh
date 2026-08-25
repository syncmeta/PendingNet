#!/bin/sh
# 用法: [PENDINGNET_SIGN_IDENTITY=<identity>] [PENDINGNET_PROVISION_PROFILE=<file>]
#       scripts/sign-macos-development.sh /path/to/PendingNet.app
#
# 关于 entitlements：app 现在带 iCloud 键值存储 + 共享钥匙串组（已配对 VPS 与
# 设备令牌要在 Mac 和 iPhone 之间同步）。这两项是**受限 entitlement**，光用
# codesign 签进去不算数 —— 必须有一份包含它们的 Developer ID 描述文件放进
# Contents/embedded.provisionprofile 背书，否则系统会当成没有。
#
# 所以：
#   - ad-hoc（identity 为 `-`，本地开发构建）：照旧不带 entitlements。App 里
#     那套存储探不到 iCloud 就退回纯本地，不报错 —— 本地开发不受影响。
#   - Developer ID：必须给 PENDINGNET_PROVISION_PROFILE。硬要不带着发，得显式
#     PENDINGNET_ALLOW_NO_PROFILE=1（发出去的包不会同步，只是不会崩）。
set -eu

app="${1:?usage: scripts/sign-macos-development.sh /path/to/PendingNet.app}"
helper="$app/Contents/MacOS/PendingNetHelper"
# 统计程序。和 helper 一样是包内的第二个可执行文件，必须先于外层 app 单独签名 ——
# 漏签的话外层 `codesign --verify --deep --strict` 直接失败，公证也过不去。
tally="$app/Contents/MacOS/sbtally"
identity="${PENDINGNET_SIGN_IDENTITY:--}"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
profile="${PENDINGNET_PROVISION_PROFILE:-}"
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
entitlements_src="$root/app/SBTally/PendingNet.entitlements"

test -x "$helper"
test -x "$tally" || { echo "包里没有 sbtally —— 统计页装上去会永远空白。构建阶段 Embed sbtally 没跑成？" >&2; exit 2; }

# 描述文件在手：把它放进包里，并把 entitlements 里的 $(AppIdentifierPrefix) /
# $(TeamIdentifierPrefix) 展开成描述文件里那个 team —— 手工 codesign 不认构建
# 变量，字面量签进去等于把钥匙串组签废（而且全程零报错）。
prepare_entitlements() {
  cp "$profile" "$app/Contents/embedded.provisionprofile"
  team=$(security cms -D -i "$profile" | plutil -extract TeamIdentifier.0 raw -o - -)
  test -n "$team" || { echo "描述文件里取不到 TeamIdentifier" >&2; exit 2; }
  expanded="$app.entitlements.expanded.plist"
  sed -e "s/[$](AppIdentifierPrefix)/$team./g" \
      -e "s/[$](TeamIdentifierPrefix)/$team./g" "$entitlements_src" > "$expanded"
  if grep -q '[$](' "$expanded"; then
    echo "entitlements 里还有没展开的构建变量：$(grep -o '[$]([A-Za-z]*)' "$expanded" | sort -u | tr '\n' ' ')" >&2
    exit 2
  fi
}

if test "$identity" = "-"; then
  # A plain `codesign -s -` uses a CDHash-only designated requirement, which
  # changes on every build. Stable explicit requirements let Service
  # Management recognize a locally built PendingNet update as the same pair.
  /usr/bin/codesign --force --sign - \
    --identifier com.pendingname.pendingnet.helper \
    --requirements '=designated => identifier "com.pendingname.pendingnet.helper"' \
    "$helper"
  /usr/bin/codesign --force --sign - \
    --identifier com.pendingname.pendingnet.sbtally \
    --requirements '=designated => identifier "com.pendingname.pendingnet.sbtally"' \
    "$tally"
  /usr/bin/codesign --force --sign - \
    --identifier com.pendingname.pendingnet \
    --requirements '=designated => identifier "com.pendingname.pendingnet"' \
    "$app"
else
  if test -d "$sparkle"; then
    sparkle_version="$sparkle/Versions/B"
    if test -d "$sparkle_version/XPCServices/Installer.xpc"; then
      /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp \
        "$sparkle_version/XPCServices/Installer.xpc"
    fi
    if test -d "$sparkle_version/XPCServices/Downloader.xpc"; then
      /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp \
        --preserve-metadata=entitlements "$sparkle_version/XPCServices/Downloader.xpc"
    fi
    /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp \
      "$sparkle_version/Autoupdate"
    /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp \
      "$sparkle_version/Updater.app"
    /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp "$sparkle"
  fi
  /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp \
    --identifier com.pendingname.pendingnet.helper "$helper"
  /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp \
    --identifier com.pendingname.pendingnet.sbtally "$tally"
  if test -n "$profile"; then
    prepare_entitlements
    /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp \
      --identifier com.pendingname.pendingnet --entitlements "$expanded" "$app"
    rm -f "$expanded"
  elif test "${PENDINGNET_ALLOW_NO_PROFILE:-0}" = "1"; then
    echo "warning: 没给描述文件，这个包不带 iCloud/钥匙串 entitlement —— 装上去以后 Mac 与 iPhone 不会同步已配对 VPS" >&2
    /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp \
      --identifier com.pendingname.pendingnet "$app"
  else
    echo "Developer ID 签名需要 PENDINGNET_PROVISION_PROFILE=<Developer ID 描述文件>（含 iCloud 键值存储与钥匙串共享组）；确实要发一个不带同步的包就设 PENDINGNET_ALLOW_NO_PROFILE=1" >&2
    exit 2
  fi
fi
/usr/bin/codesign --verify --deep --strict "$app"
