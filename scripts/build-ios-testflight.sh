#!/bin/sh
# 用法: [PENDINGNET_IOS_UPLOAD=1] scripts/build-ios-testflight.sh
#
# 把 iOS 版打成 App Store 分发包并（可选）传上 TestFlight。
#
# 与 macOS 那条发版链（build-macos-update.sh：Developer ID + 公证 + Sparkle）
# 完全无关，两边互不影响 —— macOS 是自己发自己的更新，iOS 走苹果的商店通道。
# 共同点只有作风：干净快照构建 + 每一道前置条件都显式断言，宁可停在这里，
# 也不让一个「六道全绿、装上去是废包」的构建流出去。
#
# 凭据（两样都要，都不在仓库里）:
#   ~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8   私钥
#   $PENDINGNET_ASC_ISSUER_ID 或 ~/.appstoreconnect/issuer_id
# Key ID 默认 9PS6Y7K4X9，可用 PENDINGNET_ASC_KEY_ID 覆盖。
#
# 开关:
#   PENDINGNET_IOS_UPLOAD=1        真往 TestFlight 传（默认只导出 .ipa 不传）
#   PENDINGNET_IOS_ARCHIVE_ONLY=1  只构建 archive 并做断言，不导出、不碰网络
#
# 证书和描述文件不用事先准备：导出那一步带 -allowProvisioningUpdates 和同一把
# API 密钥，Xcode 会自己去门户建 Apple Distribution 证书和两份 App Store 描述
# 文件（主 App + 隧道扩展）。本机现在只有开发证书也没关系。
set -eu

app_name=PendingNet
scheme=PendingNetIOS
bundle_id=com.pendingname.pendingnet
extension_bundle_id=com.pendingname.pendingnet.extension
team_id=M42BKJN82S

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
archive_only=${PENDINGNET_IOS_ARCHIVE_ONLY:-0}
upload=${PENDINGNET_IOS_UPLOAD:-0}

command -v xcodegen >/dev/null || { echo "缺 xcodegen（brew install xcodegen）" >&2; exit 2; }
test -d "$root/app/Vendor/Libbox.xcframework" \
  || { echo "缺 app/Vendor/Libbox.xcframework —— 先跑 scripts/build-libbox-xcframework.sh" >&2; exit 2; }

# --- 凭据 -------------------------------------------------------------------
key_id=${PENDINGNET_ASC_KEY_ID:-9PS6Y7K4X9}
key_path="$HOME/.appstoreconnect/private_keys/AuthKey_$key_id.p8"
issuer=${PENDINGNET_ASC_ISSUER_ID:-}
if [ -z "$issuer" ] && [ -f "$HOME/.appstoreconnect/issuer_id" ]; then
  issuer=$(tr -d '[:space:]' < "$HOME/.appstoreconnect/issuer_id")
fi
if [ "$archive_only" != "1" ]; then
  test -f "$key_path" || { echo "找不到 App Store Connect 私钥 $key_path" >&2; exit 2; }
  # 软链到「文稿」文件夹的话，后台进程会被系统隐私保护挡住（读出来是空的），
  # 而 xcodebuild 只会含糊地报一句签名失败。在这里先摸一下。
  head -c 1 "$key_path" >/dev/null 2>&1 \
    || { echo "读不了 $key_path —— 如果它是指向「文稿」的软链，把真文件挪进 private_keys/" >&2; exit 2; }
  test -n "$issuer" \
    || { echo "缺 Issuer ID —— 设 PENDINGNET_ASC_ISSUER_ID 或写进 ~/.appstoreconnect/issuer_id" >&2; exit 2; }
fi

# --- 版本号 -----------------------------------------------------------------
yml="$root/app/project.yml"
# project.yml 里 base 和 macOS target 各写了一份同样的版本号。iOS target 继承的是
# base 那份（head），macOS 用的是 target 那份（tail）。两份漂移过一次就再也说不清
# 「这个包到底是哪个版本」，所以先要求它们相等。
base_version=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*//p' "$yml" | head -n 1 | tr -d '"')
base_build=$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*//p' "$yml" | head -n 1 | tr -d '"')
tail_version=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*//p' "$yml" | tail -n 1 | tr -d '"')
tail_build=$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*//p' "$yml" | tail -n 1 | tr -d '"')
test -n "$base_version" || { echo "取不到 MARKETING_VERSION" >&2; exit 2; }
test -n "$base_build" || { echo "取不到 CURRENT_PROJECT_VERSION" >&2; exit 2; }
if [ "$base_version" != "$tail_version" ] || [ "$base_build" != "$tail_build" ]; then
  echo "project.yml 里两处版本号不一致：base $base_version($base_build) vs macOS target $tail_version($tail_build) —— 先改成一样" >&2
  exit 2
fi
version=$base_version
build_number=$base_build

# --- 重号预检（放在长构建之前，别让人白等二十分钟）-------------------------
if [ "$archive_only" != "1" ]; then
  echo "==> 查 App Store Connect：$version ($build_number) 这个 build 号用过没有"
  PENDINGNET_ASC_KEY_ID="$key_id" PENDINGNET_ASC_ISSUER_ID="$issuer" \
    "$root/scripts/asc-api.py" check-build --version "$version" --build "$build_number"
fi

# --- 干净快照 ---------------------------------------------------------------
# 钉 main HEAD 构建，工作区脏不脏都不影响「所见即所装」。和 macOS 那条一样。
snap=$(mktemp -d "/tmp/pendingnet-ios-release.XXXXXX")
git -C "$root" worktree add --detach "$snap/src" main
cleanup() {
  git -C "$root" worktree remove --force "$snap/src" 2>/dev/null || true
  git -C "$root" worktree prune
  rm -rf "$snap"
}
trap cleanup EXIT HUP INT TERM
# Libbox.xcframework 不进仓库（.gitignore），快照里得自己补一份。
mkdir -p "$snap/src/app/Vendor"
/usr/bin/ditto "$root/app/Vendor/Libbox.xcframework" "$snap/src/app/Vendor/Libbox.xcframework"

derived="$snap/derived"
archive="$snap/$app_name.xcarchive"
export_dir="$snap/export"
out_dir="$root/dist/ios"
mkdir -p "$out_dir"

# --- archive ----------------------------------------------------------------
echo "==> archive $version ($build_number)"
cd "$snap/src/app"
xcodegen generate
xcodebuild -project "$app_name.xcodeproj" -scheme "$scheme" -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" -derivedDataPath "$derived" \
  archive

app="$archive/Products/Applications/$app_name.app"
appex="$app/PlugIns/${app_name}PacketTunnel.appex"
test -d "$app" || { echo "archive 里没有 $app_name.app" >&2; exit 2; }
test -d "$appex" || { echo "archive 里没有内嵌隧道扩展 —— 装上去就是个不能连的壳" >&2; exit 2; }

plist() { /usr/libexec/PlistBuddy -c "Print $2" "$1/Info.plist" 2>/dev/null; }

# 版本号：产物里的必须就是仓库里那一对。target 的 postBuildScript 已经查过主 App，
# 这里补查扩展 —— 主 App 与扩展版本对不上，苹果在处理阶段直接退回。
for b in "$app" "$appex"; do
  v=$(plist "$b" :CFBundleShortVersionString || echo "<读不到>")
  n=$(plist "$b" :CFBundleVersion || echo "<读不到>")
  if [ "$v" != "$version" ] || [ "$n" != "$build_number" ]; then
    echo "$(basename "$b") 的版本是 $v($n)，仓库里是 $version($build_number)" >&2
    exit 2
  fi
done

# 出口合规。规则不是「这个键必须在」，而是「申报了 true 就必须同时给出 ERN 编号」——
# 只写 true 不给码，苹果在上传前的服务端校验直接以 90592 拒收，而且报错文字
# （「key value [] 与文档不匹配」）指不到真正的原因上。键不写是合法状态：构建
# 传得上去，之后在 TestFlight 页面按构建答一次问卷。缘由见 app/project.yml。
# `|| true` 不能省：这个键**正常情况下就是不存在**，而 PlistBuddy 读不到键会
# 非零退出，在 set -e 下会把整个脚本静默带走（连下面那句报错都轮不到打印）。
enc=$(plist "$app" :ITSAppUsesNonExemptEncryption || true)
if [ "$enc" = "true" ]; then
  plist "$app" :ITSEncryptionExportComplianceCode >/dev/null \
    || { echo "Info.plist 里 ITSAppUsesNonExemptEncryption=true 却没有 ITSEncryptionExportComplianceCode —— 苹果会以 90592 拒收。要么补上 ERN 编号，要么把这个键整个去掉" >&2; exit 2; }
fi

# 隐私清单。2024-05 起是硬要求，缺了先收 ITMS-91053 退信。主 App 和扩展是两个
# 独立 bundle，各要一份，主 App 那份盖不到扩展。
for b in "$app" "$appex"; do
  test -f "$b/PrivacyInfo.xcprivacy" \
    || { echo "$(basename "$b") 里没有 PrivacyInfo.xcprivacy" >&2; exit 2; }
done

# 图标：App Store 要 1024×1024 的商店图标，它在 Assets.car 里而不是散文件，
# 所以只查 CFBundleIconName 不够 —— 分层 .icon 编译失败时那个键照样在。
plist "$app" :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName >/dev/null \
  || { echo "产物 Info.plist 没有 CFBundleIconName —— 图标没编进去" >&2; exit 2; }
test -f "$app/Assets.car" || { echo "产物里没有 Assets.car" >&2; exit 2; }
xcrun assetutil --info "$app/Assets.car" 2>/dev/null \
  | grep -q '"PixelWidth" : 1024' \
  || { echo "Assets.car 里没有 1024×1024 的商店图标 —— 苹果会以 ITMS-90713 退回" >&2; exit 2; }

echo "==> archive 断言全过：$archive"
if [ "$archive_only" = "1" ]; then
  /usr/bin/ditto "$archive" "$out_dir/$app_name-$version.xcarchive"
  echo "Archive ready: $out_dir/$app_name-$version.xcarchive（只构建，没导出）"
  exit 0
fi

# --- export -----------------------------------------------------------------
# 这一步才是「换成分发身份」：archive 用的是开发签名（和真机调试同一套），
# -exportArchive 拿 App Store 描述文件重签一遍。-allowProvisioningUpdates 配上
# API 密钥，缺的证书和描述文件由 Xcode 现建。
echo "==> export（App Store 分发签名）"
xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportPath "$export_dir" \
  -exportOptionsPlist "$root/scripts/ios-appstore-exportoptions.plist" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$key_path" \
  -authenticationKeyID "$key_id" \
  -authenticationKeyIssuerID "$issuer"

ipa=$(find "$export_dir" -maxdepth 1 -name '*.ipa' | head -n 1)
test -n "$ipa" || { echo "导出目录里没有 .ipa" >&2; exit 2; }

# --- 对导出的包本身做断言 ---------------------------------------------------
# 查 archive 不算数：重签发生在导出这一步，签错了只有这里看得出来。
peek="$snap/peek"
mkdir -p "$peek"
/usr/bin/unzip -qq "$ipa" -d "$peek"
signed_app="$peek/Payload/$app_name.app"
signed_appex="$signed_app/PlugIns/${app_name}PacketTunnel.appex"
test -d "$signed_app" || { echo ".ipa 里没有 Payload/$app_name.app" >&2; exit 2; }
test -d "$signed_appex" || { echo ".ipa 里的扩展不见了 —— 重签把它丢了" >&2; exit 2; }

for b in "$signed_app" "$signed_appex"; do
  name=$(basename "$b")
  codesign --verify --strict "$b" \
    || { echo "$name 签名校验不过" >&2; exit 2; }
  codesign -dvvv "$b" 2>&1 | grep -q 'Authority=Apple Distribution' \
    || { echo "$name 不是 Apple Distribution 签的 —— TestFlight 不收开发签名的包" >&2;
         codesign -dvvv "$b" 2>&1 | grep '^Authority' >&2; exit 2; }
  test -f "$b/embedded.mobileprovision" \
    || { echo "$name 里没有描述文件 —— 网络扩展这类受限 entitlement 等于没有" >&2; exit 2; }

  ents_plist="$snap/$name.entitlements.plist"
  codesign -d --entitlements - --xml "$b" 2>/dev/null | plutil -convert xml1 -o "$ents_plist" - \
    || { echo "$name 的 entitlements 读不出来" >&2; exit 2; }
  ents=$(cat "$ents_plist")
  # 未展开的构建变量。macOS 那条就栽过：$(AppIdentifierPrefix) 被原样签进钥匙串
  # 组，签名有效、一切正常，只是两端再也读不到对方的数据。
  case "$ents" in
    *'$('*) echo "$name 的 entitlements 里还有没展开的构建变量" >&2; cat "$ents_plist" >&2; exit 2 ;;
  esac
  # get-task-allow=true 就是可被调试的开发包，苹果以 ITMS-90339 退回。
  # 注意查的是**值**不是键的有无：分发包里这个键照样在，只不过是 false。
  if [ "$(/usr/libexec/PlistBuddy -c 'Print :get-task-allow' "$ents_plist" 2>/dev/null || echo false)" = "true" ]; then
    echo "$name 的 get-task-allow 是 true —— 这是开发签名，不是分发签名" >&2
    exit 2
  fi
  case "$ents" in
    *networking.networkextension*) ;;
    *) echo "$name 的 entitlements 里没有 networkextension —— 装上去连不了" >&2; exit 2 ;;
  esac
  case "$ents" in
    *group.com.pendingname.pendingnet*) ;;
    *) echo "$name 缺共享组 group.com.pendingname.pendingnet —— App 与扩展互相看不到对方的数据" >&2; exit 2 ;;
  esac
  # beta-reports-active 是 App Store 描述文件才有的键，TestFlight 靠它收崩溃与
  # 测试反馈。它不在就说明重签用的不是 App Store 那份描述文件。
  case "$ents" in
    *beta-reports-active*) ;;
    *) echo "$name 的描述文件不是 App Store 类型（没有 beta-reports-active）" >&2; exit 2 ;;
  esac
done

# 主 App 独有的两把钥匙：iCloud 键值存储 + 共享钥匙串组。少了它们，装机后就是
# 「一切正常但 iPhone 和 Mac 各配各的」—— 又一个零报错的静默失败。
main_ents=$(codesign -d --entitlements - --xml "$signed_app" 2>/dev/null || true)
case "$main_ents" in
  *ubiquity-kvstore-identifier*) ;;
  *) echo "主 App 没有 iCloud 键值存储 entitlement —— 已配对 VPS 不会和 Mac 同步" >&2; exit 2 ;;
esac
case "$main_ents" in
  *keychain-access-groups*) ;;
  *) echo "主 App 没有共享钥匙串组 —— 设备令牌不会和 Mac 同步" >&2; exit 2 ;;
esac
case "$main_ents" in
  *"$team_id.$bundle_id"*) ;;
  *) echo "主 App 的 application-identifier 不是 $team_id.$bundle_id" >&2; exit 2 ;;
esac
ext_ents=$(codesign -d --entitlements - --xml "$signed_appex" 2>/dev/null || true)
case "$ext_ents" in
  *"$team_id.$extension_bundle_id"*) ;;
  *) echo "扩展的 application-identifier 不是 $team_id.$extension_bundle_id" >&2; exit 2 ;;
esac

out_ipa="$out_dir/$app_name-$version-$build_number.ipa"
/bin/cp -f "$ipa" "$out_ipa"
echo "==> 导出断言全过：$out_ipa"

# --- 提交前校验 -------------------------------------------------------------
# altool 的 --validate-app 跑的是苹果服务端那套收件检查（除了不真的收下包），
# 能在上传前把大部分 ITMS-9xxxx 提前暴露出来。
echo "==> 服务端预校验"
xcrun altool --validate-app -f "$out_ipa" -t ios \
  --apiKey "$key_id" --apiIssuer "$issuer"

if [ "$upload" != "1" ]; then
  echo
  echo "包已就绪但**没有上传**：$out_ipa"
  echo "确认要发 TestFlight 时，重跑一遍并带上 PENDINGNET_IOS_UPLOAD=1。"
  exit 0
fi

echo "==> 上传 TestFlight"
xcrun altool --upload-app -f "$out_ipa" -t ios \
  --apiKey "$key_id" --apiIssuer "$issuer"

git -C "$root" tag "pendingnet-ios/v$version-$build_number" main 2>/dev/null \
  || echo "tag pendingnet-ios/v$version-$build_number 已存在，沿用"
echo
echo "已上传：$version ($build_number)。"
echo "苹果那边处理要几分钟到半小时；处理完还要在 App Store Connect 的 TestFlight"
echo "页面答一次出口合规问卷，构建才会真正发给测试员（见 docs/ios-testflight.md）。"
