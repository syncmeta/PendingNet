#!/usr/bin/env bash
# 交叉编译 Linux 版的 pendingnet-server，产物是 GitHub Release 要挂的资产。
#
#   scripts/build-linux-server.sh
#
# 出 dist/server/：
#   pendingnet-server-linux-amd64
#   pendingnet-server-linux-arm64
#   SHA256SUMS
#
# deploy/vps-install.sh 在 VPS 上第一件事就是找这三个东西：下到二进制、
# 用 SHA256SUMS 核一遍才敢用，缺一个就退回到在 VPS 上现装 Go 编译（能跑，
# 但要多花好几分钟）。所以每次发 Release 都该把它们一起挂上去。
#
# 这个脚本只编译，不推任何东西。挂上去的命令在最后打印出来，自己按。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/dist/server"
targets=(amd64 arm64)

command -v go >/dev/null 2>&1 || { echo "没找到 go——交叉编译要本机的 Go 工具链" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"

for arch in "${targets[@]}"; do
    name="pendingnet-server-linux-$arch"
    echo "==> 编译 $name"
    # CGO_ENABLED=0：产物要能扔进任何一台 Debian，不依赖目标机的 libc 版本。
    # -trimpath 把发布机的绝对路径从二进制里去掉。
    CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
        go build -trimpath -ldflags "-s -w" -o "$out/$name" "$root/cmd/pendingnet-server"
    chmod 0755 "$out/$name"
done

echo "==> 写 SHA256SUMS"
(
    cd "$out"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum pendingnet-server-linux-* > SHA256SUMS
    else
        # macOS 上没有 sha256sum，shasum -a 256 的输出格式一样。
        shasum -a 256 pendingnet-server-linux-* > SHA256SUMS
    fi
    cat SHA256SUMS
)

version="$(sed -n 's/.*MARKETING_VERSION: *//p' "$root/app/project.yml" | head -1 | tr -d '"'"'"' ')"
cat <<EOF

==> 产物在 $out

挂到 Release 上（tag 得先推上去，见 docs/release.md）:

  gh release upload pendingnet/v${version:-<版本>} \\
    "$out/pendingnet-server-linux-amd64" \\
    "$out/pendingnet-server-linux-arm64" \\
    "$out/SHA256SUMS"

创建新 Release 的话就把这三个路径接在 gh release create 后面。
资产名不要改——deploy/vps-install.sh 是按这三个名字去找的。

arm64 那个从没在真的 arm64 机器上跑过，只是编出来了。
EOF
