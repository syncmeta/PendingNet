#!/bin/sh
# 拒绝“外层 App 看似支持 Intel，内嵌工具仍是 arm64-only”的半通用 macOS 包。
# 用法：scripts/verify-macos-universal.sh /path/to/PendingNet.app
set -eu

app="${1:?usage: scripts/verify-macos-universal.sh /path/to/PendingNet.app}"
test -d "$app" || { echo "不是 app bundle：$app" >&2; exit 2; }

found=0
failed=0
while IFS= read -r candidate; do
  description=$(file -b "$candidate")
  case "$description" in
    Mach-O*) ;;
    *) continue ;;
  esac
  found=$((found + 1))
  architectures=$(lipo -archs "$candidate" 2>/dev/null || true)
  case " $architectures " in
    *" arm64 "*) ;;
    *) echo "缺 arm64：${candidate}（${architectures}）" >&2; failed=1 ;;
  esac
  case " $architectures " in
    *" x86_64 "*) ;;
    *) echo "缺 x86_64：${candidate}（${architectures}）" >&2; failed=1 ;;
  esac
done <<EOF
$(find "$app" -type f -print)
EOF

test "$found" -gt 0 || { echo "包里没找到 Mach-O：$app" >&2; exit 2; }
test "$failed" -eq 0 || exit 2
echo "Universal macOS bundle verified: $found Mach-O files (arm64 + x86_64)"
