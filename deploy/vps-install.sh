#!/usr/bin/env bash
# PendingNet VPS 一键部署。
#
#   curl -fsSL https://raw.githubusercontent.com/syncmeta/PendingNet/main/deploy/vps-install.sh | sudo bash
#
# 跑完会在屏幕上打印一条 pendingnet:// 配对链接，客户端点一下（或整条粘进
# App 的粘贴框）就能连上。脚本做的事：装 pendingnet-server（优先下预编译的
# Release 资产并校验 sha256，没有就现场装 Go 工具链从源码编译）、install、
# provision、pair create。
#
# 管道执行下没法传命令行参数，所有可覆盖项都同时认环境变量：
#
#   curl -fsSL .../vps-install.sh | sudo PENDINGNET_SERVER_IP=203.0.113.10 bash
#   sudo bash vps-install.sh --server-ip 203.0.113.10 --reality-sni www.microsoft.com
#
# 防火墙脚本一律不改（见结尾的提示）。第二次跑默认只补一条新链接，要重做
# 部署得显式 --force-provision——那会让已经配对的客户端立刻失效。
set -Eeuo pipefail

readonly STATE_DIR=/etc/pendingnet
readonly INSTALLED_BIN=/usr/local/bin/pendingnet-server
readonly XRAY_BIN=/usr/local/bin/xray
readonly HYSTERIA_BIN=/usr/local/bin/hysteria

REPO="${PENDINGNET_REPO:-syncmeta/PendingNet}"
REF="${PENDINGNET_REF:-main}"
SERVER_IP="${PENDINGNET_SERVER_IP:-}"
REALITY_SNI="${PENDINGNET_REALITY_SNI:-www.cloudflare.com}"
DISPLAY_NAME="${PENDINGNET_NAME:-}"
CONTROL_PORT="${PENDINGNET_CONTROL_PORT:-7443}"
XRAY_PORT="${PENDINGNET_XRAY_PORT:-443}"
HY2_PORT="${PENDINGNET_HY2_PORT:-443}"
PAIR_TTL="${PENDINGNET_PAIR_TTL:-10m}"
GO_VERSION="${PENDINGNET_GO_VERSION:-1.26.4}"
# 内网镜像 / 私有 fork 用这两个改取件地址，默认都指向 GitHub 上的 $REPO。
RELEASE_BASE_URL="${PENDINGNET_RELEASE_BASE_URL:-}"
REPO_URL="${PENDINGNET_REPO_URL:-}"
GITHUB_TOKEN="${PENDINGNET_GITHUB_TOKEN:-}"
FORCE_PROVISION="${PENDINGNET_FORCE_PROVISION:-0}"
SOURCE_ONLY="${PENDINGNET_SOURCE_ONLY:-0}"

WORK_DIR=""
ARCH=""
GOARCH=""
BINARY_SOURCE=""

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""
fi

log()  { printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
info() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
warn() { printf '%s警告:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s错误:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: sudo bash vps-install.sh [选项]
      curl -fsSL <脚本地址> | sudo bash

选项（每一项都有同名环境变量，管道执行时用环境变量）:
  --server-ip <IP>        本机公网 IP。默认自动探测，探不到就必须手传。
                          环境变量 PENDINGNET_SERVER_IP
  --reality-sni <域名>    Reality 伪装域名，默认 www.cloudflare.com
                          环境变量 PENDINGNET_REALITY_SNI
  --name <名字>           这台 VPS 在客户端里显示的名字，默认取主机名
                          环境变量 PENDINGNET_NAME
  --control-port <端口>   控制 API 端口，默认 7443
                          环境变量 PENDINGNET_CONTROL_PORT
  --xray-port <端口>      Reality 的 TCP 端口，默认 443
                          环境变量 PENDINGNET_XRAY_PORT
  --hy2-port <端口>       Hysteria2 的 UDP 端口，默认 443
                          环境变量 PENDINGNET_HY2_PORT
  --pair-ttl <时长>       配对链接有效期，默认 10m（最长 24h）
                          环境变量 PENDINGNET_PAIR_TTL
  --force-provision       重做部署。会重新生成全部密钥，
                          已经配对的客户端立刻失效。
                          环境变量 PENDINGNET_FORCE_PROVISION=1
  --source-only           跳过预编译资产，直接从源码编译
                          环境变量 PENDINGNET_SOURCE_ONLY=1
  --repo <owner/name>     源码仓库，默认 syncmeta/PendingNet
  --ref <分支或 tag>      源码分支，默认 main
  --go-version <版本>     源码编译用的 Go 版本，默认 1.26.4
  --release-base-url <URL> 从别处取预编译资产（内网镜像），默认取
                          https://github.com/<repo>/releases/latest/download
                          环境变量 PENDINGNET_RELEASE_BASE_URL
  --repo-url <URL>        源码 clone 地址（内网镜像 / 私有 fork），
                          默认 https://github.com/<repo>.git
                          环境变量 PENDINGNET_REPO_URL
  -h, --help              打印这段

私有仓库把 PENDINGNET_GITHUB_TOKEN 设成有 repo 读权限的 token，
下载 Release 资产和 clone 源码都会带上它。
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server-ip)      SERVER_IP="${2:?--server-ip 后面要跟 IP}"; shift 2 ;;
            --reality-sni)    REALITY_SNI="${2:?--reality-sni 后面要跟域名}"; shift 2 ;;
            --name)           DISPLAY_NAME="${2:?--name 后面要跟名字}"; shift 2 ;;
            --control-port)   CONTROL_PORT="${2:?--control-port 后面要跟端口}"; shift 2 ;;
            --xray-port)      XRAY_PORT="${2:?--xray-port 后面要跟端口}"; shift 2 ;;
            --hy2-port)       HY2_PORT="${2:?--hy2-port 后面要跟端口}"; shift 2 ;;
            --pair-ttl)       PAIR_TTL="${2:?--pair-ttl 后面要跟时长}"; shift 2 ;;
            --repo)           REPO="${2:?--repo 后面要跟 owner/name}"; shift 2 ;;
            --ref)            REF="${2:?--ref 后面要跟分支名}"; shift 2 ;;
            --go-version)     GO_VERSION="${2:?--go-version 后面要跟版本号}"; shift 2 ;;
            --release-base-url) RELEASE_BASE_URL="${2:?--release-base-url 后面要跟 URL}"; shift 2 ;;
            --repo-url)       REPO_URL="${2:?--repo-url 后面要跟 URL}"; shift 2 ;;
            --force-provision) FORCE_PROVISION=1; shift ;;
            --source-only)    SOURCE_ONLY=1; shift ;;
            -h|--help)        usage; exit 0 ;;
            *) usage >&2; die "不认识的参数: $1" ;;
        esac
    done
}

on_error() {
    local code=$1 line=$2
    printf '\n%s部署没走完%s（第 %s 行，退出码 %s）。查这几处:\n' "$C_RED$C_BOLD" "$C_RESET" "$line" "$code" >&2
    cat >&2 <<EOF

  journalctl -u pendingnet-server -n 50 --no-pager     控制服务的日志
  journalctl -u pendingnet-xray -n 50 --no-pager       Reality 的日志
  journalctl -u pendingnet-hysteria -n 50 --no-pager   Hysteria2 的日志
  systemctl status pendingnet-server

改完之后原样再跑一遍这个脚本就行——已经装好的部分会跳过。
要把部署整个重做（重新生成密钥，已配对的客户端立刻失效）加 --force-provision。
EOF
}
trap 'on_error $? $LINENO' ERR

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "要用 root 跑：curl -fsSL <脚本地址> | sudo bash"
}

detect_os() {
    local id="" id_like="" pretty="未知系统"
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id="${ID:-}"; id_like="${ID_LIKE:-}"; pretty="${PRETTY_NAME:-$id}"
    fi
    log "系统: $pretty"
    if [[ "$id" != "debian" && "$id" != "ubuntu" && "$id_like" != *debian* ]]; then
        warn "这个脚本只在 Debian / Ubuntu 上验证过。$pretty 上它会照样用 apt-get 和 systemd 的方式走，很可能失败。"
        warn "要继续的话，请自己确认 apt-get 和 systemd 都在。"
    fi
    command -v apt-get >/dev/null 2>&1 || die "没有 apt-get——这个脚本装依赖只会用 apt-get。请手工装好 curl / ca-certificates / iproute2 / git 再改用手工部署（见 README「一、VPS 端」）。"
    [[ -d /run/systemd/system ]] || die "systemd 没在跑。PendingNet 的服务全部由 systemd 托管，这台机器没法用这个脚本。"
}

detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64) ARCH=amd64; GOARCH=amd64 ;;
        aarch64|arm64)
            ARCH=arm64; GOARCH=arm64
            warn "arm64：服务端代码里有这条分支，但从没在真的 arm64 机器上跑过。出问题请回退到 amd64。"
            ;;
        *) die "不支持的 CPU 架构 $machine，只支持 x86_64 / aarch64。" ;;
    esac
    log "架构: $machine → $ARCH"
}

ensure_packages() {
    local missing=()
    local pkg
    for pkg in "$@"; do
        case "$pkg" in
            curl)           command -v curl >/dev/null 2>&1        || missing+=(curl) ;;
            iproute2)       command -v ss >/dev/null 2>&1          || missing+=(iproute2) ;;
            git)            command -v git >/dev/null 2>&1         || missing+=(git) ;;
            tar)            command -v tar >/dev/null 2>&1         || missing+=(tar) ;;
            coreutils)      command -v sha256sum >/dev/null 2>&1   || missing+=(coreutils) ;;
            ca-certificates) [[ -e /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates) ;;
            *)              missing+=("$pkg") ;;
        esac
    done
    [[ ${#missing[@]} -gt 0 ]] || return 0
    log "装依赖: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}" </dev/null
}

# port_holder <tcp|udp> <端口> —— 打印占用者，没人占就打印空。
port_holder() {
    local proto="$1" port="$2" flag out
    [[ "$proto" == tcp ]] && flag=t || flag=u
    out="$(ss -H -ln -"$flag" -p "sport = :$port" 2>/dev/null || true)"
    printf '%s' "$out" | tr -s ' ' | sed 's/^ //' | head -1
}

check_ports() {
    local blocked=0 holder
    local -a checks=()
    # 自己的服务在监听不算「被占」——重跑脚本时它们本来就该在那儿。
    local -a own=(
        "pendingnet-xray.service tcp $XRAY_PORT Reality"
        "pendingnet-hysteria.service udp $HY2_PORT Hysteria2"
        "pendingnet-server.service tcp $CONTROL_PORT 控制 API"
    )
    local row unit
    for row in "${own[@]}"; do
        unit="${row%% *}"
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            info "${row#* } 上是 PendingNet 自己的 $unit 在监听，跳过占用检查"
        else
            checks+=("${row#* }")
        fi
    done
    [[ ${#checks[@]} -gt 0 ]] || return 0
    local entry proto port role
    for entry in "${checks[@]}"; do
        read -r proto port role <<<"$entry"
        holder="$(port_holder "$proto" "$port")"
        if [[ -n "$holder" ]]; then
            blocked=1
            warn "${proto^^}/$port（$role 要用）已经被占了: $holder"
        fi
    done
    if [[ $blocked -eq 0 ]]; then
        local -a checked=()
        for entry in "${checks[@]}"; do
            read -r proto port role <<<"$entry"
            checked+=("${proto^^}/$port")
        done
        info "${checked[*]} 都是空的"
        return 0
    fi
    cat >&2 <<EOF

上面这些端口得先腾出来。两条路，挑一条:

  1. 停掉占用的服务（先用 ss -lntup 看清是谁），再重跑这个脚本。
  2. 换端口跑，比如把 Reality 挪到 8443、Hysteria2 挪到 8443:

       sudo bash vps-install.sh --xray-port 8443 --hy2-port 8443

     控制口冲突就加 --control-port <别的端口>。换了端口记得防火墙也放行新的。

已经在跑别的代理（singb 之类）又想保住它的话，别用这个脚本——
README「二、接管已有的 sing-box 部署」那条路是专门为这种情况写的。
EOF
    die "端口被占，没往下走。机器上什么都没改。"
}

valid_ipv4() {
    local ip="$1" octet
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    for octet in ${ip//./ }; do
        (( octet <= 255 )) || return 1
    done
    return 0
}

# 多个源交叉验证：至少两个源给出同一个地址才认。只有一个源答得上来
# 不算数——探错了公网 IP，配对链接会指向一台连不上的机器。
detect_public_ip() {
    local -a sources=(
        https://api.ipify.org
        https://ifconfig.me/ip
        https://icanhazip.com
        https://ipinfo.io/ip
    )
    local -a answers=()
    local source answer
    log "探测公网 IP"
    for source in "${sources[@]}"; do
        answer="$(curl -fsS --max-time 8 "$source" 2>/dev/null | tr -d '[:space:]' || true)"
        if valid_ipv4 "$answer"; then
            info "$source → $answer"
            answers+=("$answer")
        else
            info "$source → 没答上来"
        fi
    done
    local candidate count
    for candidate in "${answers[@]}"; do
        count="$(printf '%s\n' "${answers[@]}" | grep -cxF "$candidate" || true)"
        if (( count >= 2 )); then
            SERVER_IP="$candidate"
            log "公网 IP: $SERVER_IP（$count 个源一致）"
            return 0
        fi
    done
    cat >&2 <<'EOF'

探不到公网 IP，或者几个源给的地址对不上（NAT、多网卡、CDN 前置都可能）。
自己填一个再跑:

    curl -fsSL <脚本地址> | sudo PENDINGNET_SERVER_IP=203.0.113.10 bash

填的必须是客户端能连上的那个地址——机器上 ip addr 看到的内网地址不算。
EOF
    die "公网 IP 没定下来，机器上什么都没改。"
}

curl_auth() {
    if [[ -n "$GITHUB_TOKEN" ]]; then
        curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "$@"
    else
        curl -fsSL "$@"
    fi
}

# 从 Release 下预编译资产，带 sha256 校验。下不到 / 校验不过都返回非 0，
# 由调用方回退到源码编译——绝不放行一个没校验过的二进制。
download_release_binary() {
    local asset="pendingnet-server-linux-$ARCH"
    local dest="$WORK_DIR/pendingnet-server"
    local sums="$WORK_DIR/SHA256SUMS"
    log "找预编译的服务端二进制（资产名 $asset）"
    if [[ -n "$RELEASE_BASE_URL" ]]; then
        curl -fsSL --max-time 300 -o "$dest" "$RELEASE_BASE_URL/$asset" </dev/null || { info "下不到 $RELEASE_BASE_URL/$asset"; return 1; }
        curl -fsSL --max-time 60 -o "$sums" "$RELEASE_BASE_URL/SHA256SUMS" </dev/null || { info "下不到 $RELEASE_BASE_URL/SHA256SUMS"; return 1; }
    elif [[ -n "$GITHUB_TOKEN" ]]; then
        local release_json asset_id sums_id
        release_json="$(curl_auth "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || true)"
        [[ -n "$release_json" ]] || { info "Release API 读不到"; return 1; }
        asset_id="$(printf '%s' "$release_json" | tr '{' '\n' | grep -F "\"$asset\"" | grep -oE '"id": ?[0-9]+' | head -1 | grep -oE '[0-9]+' || true)"
        sums_id="$(printf '%s' "$release_json" | tr '{' '\n' | grep -F '"SHA256SUMS"' | grep -oE '"id": ?[0-9]+' | head -1 | grep -oE '[0-9]+' || true)"
        [[ -n "$asset_id" && -n "$sums_id" ]] || { info "最新 Release 里没有 $asset 或 SHA256SUMS"; return 1; }
        curl_auth -H "Accept: application/octet-stream" -o "$dest" \
            "https://api.github.com/repos/$REPO/releases/assets/$asset_id" </dev/null || return 1
        curl_auth -H "Accept: application/octet-stream" -o "$sums" \
            "https://api.github.com/repos/$REPO/releases/assets/$sums_id" </dev/null || return 1
    else
        local base="https://github.com/$REPO/releases/latest/download"
        curl -fsSL --max-time 300 -o "$dest" "$base/$asset" </dev/null || { info "下不到 $asset"; return 1; }
        curl -fsSL --max-time 60 -o "$sums" "$base/SHA256SUMS" </dev/null || { info "下不到 SHA256SUMS"; return 1; }
    fi
    local expected
    expected="$(grep -E "[[:space:]]\*?$asset\$" "$sums" | head -1 | awk '{print $1}' || true)"
    [[ -n "$expected" ]] || { warn "SHA256SUMS 里没有 $asset 这一行，不敢用这个二进制"; return 1; }
    local actual
    actual="$(sha256sum "$dest" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        warn "sha256 对不上（期望 $expected，实际 $actual），扔了不用"
        return 1
    fi
    chmod 0755 "$dest"
    info "sha256 校验通过: $expected"
    BINARY_SOURCE="Release 预编译资产 $asset"
    return 0
}

install_go_toolchain() {
    local go_bin=/usr/local/go/bin/go
    if [[ -x "$go_bin" ]] && "$go_bin" version 2>/dev/null | grep -qF "go$GO_VERSION"; then
        info "/usr/local/go already at go$GO_VERSION，直接用"
        return 0
    fi
    ensure_packages tar
    local tarball="go${GO_VERSION}.linux-${GOARCH}.tar.gz"
    log "装 Go 工具链 $GO_VERSION 到 /usr/local/go（官方 tarball，约 80 MB）"
    curl -fsSL --max-time 600 -o "$WORK_DIR/$tarball" "https://go.dev/dl/$tarball" </dev/null \
        || die "Go 工具链下不下来（https://go.dev/dl/$tarball）。这台机器连不上 go.dev 的话，改用 README「一、VPS 端」的手工路径：在本机交叉编译好再 scp 上来。"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$WORK_DIR/$tarball"
    [[ -x "$go_bin" ]] || die "Go 装完了但 $go_bin 不在，tarball 可能是坏的。"
    info "$("$go_bin" version)"
}

build_from_source() {
    log "回退到源码编译（下预编译资产这条没走通）"
    info "要装 Go 工具链、clone 仓库、编译一遍，网络正常的话大约 3-6 分钟。"
    ensure_packages git ca-certificates
    install_go_toolchain
    local src="$WORK_DIR/src"
    local clone_url="${REPO_URL:-https://github.com/$REPO.git}"
    if [[ -z "$REPO_URL" && -n "$GITHUB_TOKEN" ]]; then
        clone_url="https://x-access-token:$GITHUB_TOKEN@github.com/$REPO.git"
    fi
    log "clone ${REPO_URL:-$REPO}（$REF）"
    git clone --quiet --depth 1 --branch "$REF" "$clone_url" "$src" </dev/null \
        || die "clone 不下来。私有仓库要设 PENDINGNET_GITHUB_TOKEN；分支名不对就用 --ref 指定。"
    log "编译 ./cmd/pendingnet-server"
    (
        cd "$src"
        GOTOOLCHAIN=auto \
        GOCACHE="$WORK_DIR/gocache" \
        GOPATH="$WORK_DIR/gopath" \
        GOFLAGS=-buildvcs=false \
        /usr/local/go/bin/go build -o "$WORK_DIR/pendingnet-server" ./cmd/pendingnet-server </dev/null
    ) || die "编译失败。上面是 go build 的原始输出。"
    chmod 0755 "$WORK_DIR/pendingnet-server"
    BINARY_SOURCE="源码编译（${REPO_URL:-$REPO}@$REF）"
}

obtain_binary() {
    if [[ "$SOURCE_ONLY" == "1" ]]; then
        build_from_source
    elif ! download_release_binary; then
        build_from_source
    fi
    log "服务端二进制就绪：$BINARY_SOURCE"
}

already_provisioned() { [[ -f "$STATE_DIR/node.json" ]]; }
already_installed()   { [[ -x "$INSTALLED_BIN" && -f "$STATE_DIR/state.json" ]]; }

warn_endpoint_drift() {
    local recorded
    recorded="$(grep -oE '"control_endpoint": *"[^"]+"' "$STATE_DIR/state.json" 2>/dev/null | head -1 | sed 's/.*"\(https[^"]*\)"/\1/' || true)"
    [[ -n "$recorded" ]] || return 0
    if [[ "$recorded" != "https://$SERVER_IP:$CONTROL_PORT" ]]; then
        warn "这台机器登记的控制地址是 $recorded，和现在这次的 https://$SERVER_IP:$CONTROL_PORT 不一样。"
        warn "配对链接里带的是登记的那个地址。IP 真的变了的话，用 --force-provision 重做一次部署。"
    fi
}

do_install() {
    [[ -n "$DISPLAY_NAME" ]] || DISPLAY_NAME="$(hostname 2>/dev/null || echo PendingNet VPS)"
    log "安装并启动控制服务（名字「$DISPLAY_NAME」，控制地址 https://$SERVER_IP:$CONTROL_PORT）"
    "$WORK_DIR/pendingnet-server" install \
        --name "$DISPLAY_NAME" \
        --endpoint "https://$SERVER_IP:$CONTROL_PORT" </dev/null
}

do_provision() {
    local -a args=(
        --server-ip "$SERVER_IP"
        --reality-sni "$REALITY_SNI"
        --xray-port "$XRAY_PORT"
        --hy2-port "$HY2_PORT"
    )
    if [[ "$FORCE_PROVISION" == "1" ]] && already_provisioned; then
        args+=(--force)
        if [[ -x "$XRAY_BIN" && -x "$HYSTERIA_BIN" ]]; then
            args+=(--skip-download)
            info "沿用机器上已经校验过的 xray / hysteria 二进制"
        fi
    fi
    log "部署节点：Reality (TCP/$XRAY_PORT, SNI $REALITY_SNI) + Hysteria2 (UDP/$HY2_PORT)"
    if [[ " ${args[*]} " == *" --skip-download "* ]]; then
        info "跳过引擎下载"
    else
        info "会从 GitHub 下载并校验官方 Xray / Hysteria2 的 Release，慢的话是在下这个"
    fi
    "$INSTALLED_BIN" provision "${args[@]}" </dev/null
}

firewall_notes() {
    printf '\n%s还要放行这三个入口%s（脚本不替你改防火墙，云厂商的安全组也得自己开）:\n\n' "$C_BOLD" "$C_RESET"
    printf '    TCP/%s    Reality\n    UDP/%s    Hysteria2\n    TCP/%s   PendingNet 控制 API\n' \
        "$XRAY_PORT" "$HY2_PORT" "$CONTROL_PORT"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -1 | grep -q active; then
        printf '\n  ufw 正在跑，对应的命令是:\n\n'
        printf '    sudo ufw allow %s/tcp && sudo ufw allow %s/udp && sudo ufw allow %s/tcp\n' \
            "$XRAY_PORT" "$HY2_PORT" "$CONTROL_PORT"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        printf '\n  firewalld 正在跑，对应的命令是:\n\n'
        printf '    sudo firewall-cmd --permanent --add-port=%s/tcp --add-port=%s/udp --add-port=%s/tcp\n    sudo firewall-cmd --reload\n' \
            "$XRAY_PORT" "$HY2_PORT" "$CONTROL_PORT"
    fi
}

print_link() {
    local link="$1"
    printf '\n%s%s配对链接（就是下面这一整条）%s\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
    printf '%s\n' "$link"
    cat <<EOF

$C_BOLD怎么用$C_RESET
  在装了 PendingNet 的 Mac / iPhone 上$C_BOLD点一下这条链接$C_RESET，App 会自己起来开始配对；
  链接被聊天软件吞掉的话，$C_BOLD整条复制$C_RESET，粘进 App 连接页的「粘贴链接导入」框里。

$C_BOLD三条规矩$C_RESET
  · 默认 $PAIR_TTL 过期，只能用一次，一台设备一份。
  · 它跟密码等价——谁拿到谁就能连上这台 VPS，别往公开地方贴。
  · 再要一条（换设备、过期了、用掉了）就在这台机器上跑:

        sudo pendingnet-server pair create

EOF
}

main() {
    parse_args "$@"
    require_root
    detect_os
    detect_arch
    ensure_packages curl ca-certificates iproute2 coreutils

    # 快路径：装过了就只补一条链接。第二次跑这个脚本的人多半只是想再要一条
    # 配对链接，不该顺手把在用的服务重做一遍。
    if already_installed && already_provisioned && [[ "$FORCE_PROVISION" != "1" ]]; then
        log "这台机器已经部署过了，只生成一条新的配对链接"
        info "要重做部署（重新生成密钥、已配对的客户端立刻失效）加 --force-provision"
        if [[ -n "$SERVER_IP" ]]; then
            warn_endpoint_drift
        fi
        local quick_link
        quick_link="$("$INSTALLED_BIN" pair create --ttl "$PAIR_TTL" </dev/null)"
        if ! systemctl is-active --quiet pendingnet-server.service; then
            warn "pendingnet-server.service 没在跑，客户端会连不上：systemctl status pendingnet-server"
        fi
        print_link "$quick_link"
        firewall_notes
        exit 0
    fi

    if [[ "$FORCE_PROVISION" == "1" ]] && already_provisioned; then
        printf '\n%s--force-provision：这台机器上已经有一份部署了。%s\n' "$C_YELLOW$C_BOLD" "$C_RESET" >&2
        printf '%s要重新生成 Reality / Hysteria2 的全部密钥，已经配对的客户端会立刻失效，\n' "$C_YELLOW" >&2
        printf '每台设备都得拿新链接重新配一次。密钥不可回滚。%s\n\n' "$C_RESET" >&2
        printf '五秒后开始，不想做现在按 Ctrl-C。\n' >&2
        sleep 5
    fi

    WORK_DIR="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$WORK_DIR'" EXIT

    [[ -n "$SERVER_IP" ]] || detect_public_ip
    valid_ipv4 "$SERVER_IP" || die "--server-ip 得是一个 IPv4 地址，收到的是「$SERVER_IP」。"

    check_ports

    if already_installed && ! already_provisioned; then
        log "控制服务已经装过（上次大概停在部署节点这一步），跳过下载和安装"
    else
        obtain_binary
        do_install
    fi

    if already_provisioned && [[ "$FORCE_PROVISION" != "1" ]]; then
        log "节点已经部署过，跳过"
    else
        do_provision
    fi

    log "生成配对链接"
    local link
    link="$("$INSTALLED_BIN" pair create --ttl "$PAIR_TTL" </dev/null)"

    printf '\n%s部署完成%s  服务端: %s\n' "$C_GREEN$C_BOLD" "$C_RESET" "$BINARY_SOURCE"
    "$INSTALLED_BIN" status </dev/null || true
    print_link "$link"
    firewall_notes
}

main "$@"
