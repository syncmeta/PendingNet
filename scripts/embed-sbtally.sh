#!/bin/sh
# 把统计程序 sbtally 编进 app bundle 的 Contents/MacOS。
#
# 由 macOS target 的构建阶段调用（见 app/project.yml 的 Embed sbtally），
# 也可以手工跑：ARCHS=arm64 BUILT_PRODUCTS_DIR=... PRODUCT_NAME=PendingNet 本脚本
#
# 为什么非编不可、不许悄悄跳过：这个二进制不在包里，统计页就是永远的空白，
# 而且界面上没有任何地方能补救。装不上就让构建当场失败，别发一个「一切正常
# 但统计永远不工作」的包出去。
set -eu

: "${BUILT_PRODUCTS_DIR:?}"
: "${PRODUCT_NAME:?}"
# shellcheck disable=SC1007  # CDPATH= 是清空它，不是笔误
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="$BUILT_PRODUCTS_DIR/$PRODUCT_NAME.app"
dest="$app/Contents/MacOS/sbtally"

# Xcode 的 PATH 里通常没有 Homebrew。
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin"
export PATH
if ! command -v go >/dev/null 2>&1; then
  echo "error: 找不到 go —— 统计程序 sbtally 编不出来，装上去的 App 统计页会永远空白。装一个 Go（brew install go）再构建。" >&2
  exit 1
fi

mkdir -p "$app/Contents/MacOS"
staging=$(mktemp -d "${TMPDIR:-/tmp}/sbtally-embed.XXXXXX")
trap 'rm -rf "$staging"' EXIT HUP INT TERM

# 跟着 Xcode 的 ARCHS 走：现在发的是 arm64-only，哪天转通用二进制这里自动跟上，
# 不会剩一个只有一半架构的统计程序。
slices=""
count=0
for arch in ${ARCHS:-arm64}; do
  case "$arch" in
    arm64) goarch=arm64 ;;
    x86_64) goarch=amd64 ;;
    *) echo "error: 不认识的架构 $arch" >&2; exit 1 ;;
  esac
  # 纯 Go 的 SQLite（modernc）—— 关掉 cgo 就能干净地交叉编译，产物也不带
  # 对本机 libSystem 之外任何东西的依赖。
  ( cd "$root" && CGO_ENABLED=0 GOOS=darwin GOARCH="$goarch" \
      go build -trimpath -o "$staging/sbtally-$arch" ./cmd/sbtally )
  slices="$slices $staging/sbtally-$arch"
  count=$((count + 1))
done

# slices 是刻意不加引号的：它是一串路径，要按空格拆成多个参数。
# shellcheck disable=SC2086
if [ "$count" -gt 1 ]; then
  lipo -create $slices -output "$staging/sbtally"
else
  cp $slices "$staging/sbtally"
fi
chmod 755 "$staging/sbtally"

# 原样搬进去。内容没变就不动，省得每次构建都让签名和公证重新跑一遍。
if ! cmp -s "$staging/sbtally" "$dest" 2>/dev/null; then
  cp "$staging/sbtally" "$dest.new"
  mv "$dest.new" "$dest"
fi
