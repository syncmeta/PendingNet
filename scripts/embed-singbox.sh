#!/bin/sh
# 把代理引擎 sing-box 从源码编进 app bundle 的 Contents/MacOS。
#
# 由 macOS target 的构建阶段调用（见 app/project.yml 的 Embed sing-box），
# 也可以手工跑：ARCHS=arm64 BUILT_PRODUCTS_DIR=... PRODUCT_NAME=PendingNet 本脚本
#
# 为什么非编不可、不许悄悄跳过：这个二进制不在包里，App 就必须靠机器上先
# `brew install sing-box` 才能连——而 PendingNet 是配合 VPS 用的独立客户端，
# 不是 sing-box 的图形外壳。装不上就让构建当场失败，别发一个「装上却报找不到
# 引擎」的包出去。（同 embed-sbtally.sh 的纪律。）
set -eu

: "${BUILT_PRODUCTS_DIR:?}"
: "${PRODUCT_NAME:?}"
# shellcheck disable=SC1007  # CDPATH= 是清空它，不是笔误
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="$BUILT_PRODUCTS_DIR/$PRODUCT_NAME.app"
dest="$app/Contents/MacOS/sing-box"

# ref、checkout 位置、构建 tag 都在这一份里，和 iOS 的 libbox 共用。
# shellcheck source=scripts/sing-box-source.sh
. "$root/scripts/sing-box-source.sh"

# Xcode 的 PATH 里通常没有 Homebrew。
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin"
export PATH
if ! command -v go >/dev/null 2>&1; then
  echo "error: 找不到 go —— 代理引擎 sing-box 编不出来，装上去的 App 一连接就说找不到引擎。装一个 Go（brew install go）再构建。" >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "error: 找不到 git —— 取不到 sing-box 源码。" >&2
  exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
  echo "error: 找不到 swift —— 无法用项目真实生成的配置验收刚编出的 sing-box。" >&2
  exit 1
fi

sing_box_checkout
version=$(git -C "$SING_BOX_DIR" describe --tags --always | sed 's/^v//')

mkdir -p "$app/Contents/MacOS"
staging=$(mktemp -d "${TMPDIR:-/tmp}/singbox-embed.XXXXXX")
trap 'rm -rf "$staging"' EXIT HUP INT TERM

# 跟着 Xcode 的 ARCHS 走：现在发的是 arm64-only，哪天转通用二进制这里自动跟上，
# 不会剩一个只有一半架构的引擎。
slices=""
count=0
for arch in ${ARCHS:-arm64}; do
  case "$arch" in
    arm64) goarch=arm64 ;;
    x86_64) goarch=amd64 ;;
    *) echo "error: 不认识的架构 $arch" >&2; exit 1 ;;
  esac
  # 关掉 cgo 才能干净地交叉编译，产物也不带对本机 libSystem 之外任何东西的依赖。
  # ldflags 照抄上游 release/LDFLAGS + Makefile：-checklinkname=0 与 tag 里的
  # badlinkname/tfogo_checklinkname0 配套，少一半都编不过。
  ( cd "$SING_BOX_DIR" && GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=darwin GOARCH="$goarch" \
      go build -trimpath -tags "$SING_BOX_TAGS" \
      -ldflags "-X 'github.com/sagernet/sing-box/constant.Version=$version' -X internal/godebug.defaultGODEBUG=multipathtcp=0 -checklinkname=0 -s -w -buildid=" \
      -o "$staging/sing-box-$arch" ./cmd/sing-box )
  slices="$slices $staging/sing-box-$arch"
  count=$((count + 1))
done

# slices 是刻意不加引号的：它是一串路径，要按空格拆成多个参数。
# shellcheck disable=SC2086
if [ "$count" -gt 1 ]; then
  lipo -create $slices -output "$staging/sing-box"
else
  cp $slices "$staging/sing-box"
fi
chmod 755 "$staging/sing-box"

# 不靠「这些 tag 看起来应该够」做推断：调用 SBTallyCore 自己的配置生成器，产出
# Reality + Hysteria2 + root TUN/system-proxy + iOS gvisor TUN 三份真实配置，再让刚编
# 出来的这一颗二进制逐份 `check`。任一能力没编进去，构建就在这里失败。
fixture_dir="$staging/config-fixtures"
fixture_build="${DERIVED_FILE_DIR:-$staging}/PendingNetConfigFixture.build"
mkdir -p "$fixture_dir" "$fixture_build/ModuleCache"
CLANG_MODULE_CACHE_PATH="$fixture_build/ModuleCache" \
  swift run --disable-sandbox --package-path "$root/app/SBTallyCore" \
    --scratch-path "$fixture_build" -c release PendingNetConfigFixture "$fixture_dir"
for config in "$fixture_dir/root-tun.json" \
              "$fixture_dir/root-notun.json" \
              "$fixture_dir/gvisor-tun.json"; do
  "$staging/sing-box" check -c "$config"
done

# 原样搬进去。内容没变就不动，省得每次构建都让签名和公证重新跑一遍。
if ! cmp -s "$staging/sing-box" "$dest" 2>/dev/null; then
  cp "$staging/sing-box" "$dest.new"
  mv "$dest.new" "$dest"
fi
