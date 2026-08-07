#!/usr/bin/env bash
set -euo pipefail

# 构建 Libbox.xcframework 供 PendingNet iOS Packet Tunnel Extension 链接。
#
# 逻辑照搬已验证的 SFI fork 构建路径：
#   /Users/hey/Untitled/sing-box-for-apple-pd/scripts/testflight-dev.sh 的 --rebuild-libbox 分支。
#
# 关键点（与直觉不符，勿自行推导）：
#   1. 必须用 SagerNet fork 的 gomobile/gobind（v0.1.12），官方 golang.org/x/mobile 不行。
#   2. 构建入口是 sing-box 仓库自带的 cmd/internal/build_libbox，不是 gomobile bind。
#   3. 产物可能落在 sing-box 仓库根目录，也可能落在 /private/tmp/sing-box-for-apple/。

SING_BOX_REF="${SING_BOX_REF:-v1.13.13}"
CORE_DIR="${SING_BOX_DIR:-/private/tmp/pendingnet-sing-box}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

if [[ ! -d "$CORE_DIR/.git" ]]; then
  # 浅克隆到指定 tag，节省磁盘（本机磁盘紧张）；产物与全量克隆等价。
  git clone --branch "$SING_BOX_REF" --depth 1 https://github.com/SagerNet/sing-box.git "$CORE_DIR"
else
  git -C "$CORE_DIR" fetch --tags origin
  git -C "$CORE_DIR" checkout "$SING_BOX_REF"
fi

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
