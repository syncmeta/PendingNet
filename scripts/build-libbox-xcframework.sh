#!/usr/bin/env bash
set -euo pipefail

# 构建 Libbox.xcframework 供 PendingNet iOS Packet Tunnel Extension 链接。
#
# 逻辑照搬 sing-box-for-apple（SFI）自带构建脚本里 --rebuild-libbox 那条已验证的路径。
#
# 关键点（与直觉不符，勿自行推导）：
#   1. 必须用 SagerNet fork 的 gomobile/gobind（v0.1.12），官方 golang.org/x/mobile 不行。
#   2. 构建入口是 sing-box 仓库自带的 cmd/internal/build_libbox，不是 gomobile bind。
#   3. 产物可能落在 sing-box 仓库根目录，也可能落在 /private/tmp/sing-box-for-apple/。

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ref 与 checkout 位置在这一份里，和 macOS 内置引擎（scripts/embed-singbox.sh）
# 共用 —— 两个版本源意味着 Mac 与 iPhone 跑着不同版本的内核而没人发现。
# shellcheck source=scripts/sing-box-source.sh
source "$REPO_ROOT/scripts/sing-box-source.sh"
CORE_DIR="$SING_BOX_DIR"
DEST="$REPO_ROOT/app/Vendor/Libbox.xcframework"

die() { echo "error: $*" >&2; exit 1; }

command -v go >/dev/null || die "go is required"
command -v xcodebuild >/dev/null || die "Xcode command line tools are required"

export PATH="$(go env GOPATH)/bin:$PATH"

# 校验的是身份，不只是存在性：官方 golang.org/x/mobile 的 gomobile/gobind 也会满足
# "command -v" 检查，但会用错误的工具链构建出坏的产物（见文件顶部关键点 1）。
is_sagernet_fork() {
  command -v "$1" >/dev/null 2>&1 && go version -m "$(command -v "$1")" 2>/dev/null | grep -q 'sagernet/gomobile'
}

needs_install=0
for tool in gomobile gobind; do
  is_sagernet_fork "$tool" || needs_install=1
done

if [[ "$needs_install" -eq 1 ]]; then
  go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
  go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
  gomobile init
fi

sing_box_checkout

( cd "$CORE_DIR" && go run ./cmd/internal/build_libbox -target apple -platform ios )

CANDIDATE=""
for path in "$CORE_DIR/Libbox.xcframework" "/private/tmp/sing-box-for-apple/Libbox.xcframework"; do
  [[ -d "$path" ]] && { CANDIDATE="$path"; break; }
done
[[ -n "$CANDIDATE" ]] || die "Libbox.xcframework was not produced"

mkdir -p "$REPO_ROOT/app/Vendor"
# 原地写入前先落到临时目录再原子替换：ditto 中途失败不能先删掉旧的好产物，
# 否则会留下一个"看起来存在"但半成品的 300MB xcframework。
STAGING="$REPO_ROOT/app/Vendor/.Libbox.xcframework.tmp"
rm -rf "$STAGING"
ditto "$CANDIDATE" "$STAGING"
rm -rf "$DEST"
mv "$STAGING" "$DEST"
echo "built $DEST from sing-box $SING_BOX_REF"
