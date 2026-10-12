# shellcheck shell=sh
# sing-box 源码这一份，给所有需要它的构建脚本共用。source 进去，别单独执行。
#
# 为什么共用：iOS 的内核（Libbox.xcframework）和 macOS 内置的引擎二进制都从这个
# 仓库编。各写各的 ref 就意味着 Mac 上跑一个版本、iPhone 上跑另一个，而且这种
# 不一致谁也不会主动去查。版本号只在这里出现一次。

# All callers supply their repository root; do not infer it from Xcode's $0.
lock_root=${REPO_ROOT:-${root:-}}
if [ -z "$lock_root" ]; then echo "caller must set root or REPO_ROOT" >&2; return 1; fi
SING_BOX_VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sing_box"]["version"])' "$lock_root/internal/pnserver/upstream-lock.json")
locked_commit=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sing_box"]["commit"])' "$lock_root/internal/pnserver/upstream-lock.json")
if [ -n "${SING_BOX_REF:-}" ] && [ "$SING_BOX_REF" != "$locked_commit" ]; then
  echo "SING_BOX_REF must match the PendingNet release lock" >&2; return 1
fi
SING_BOX_REF=$locked_commit
SING_BOX_DIR="${SING_BOX_DIR:-/private/tmp/pendingnet-sing-box}"

# macOS 内置引擎的构建 tag。只覆盖本项目真正用到的东西：
#
#   with_utls      VLESS Reality 客户端。REALITY 的客户端实现（common/tls/
#                  reality_client.go）就编在这个 tag 下面，不是单独的 tag——
#                  少了它，Reality 节点的配置连 `sing-box check` 都过不去。
#   with_quic      Hysteria2（UDP 那一路）。
#   with_gvisor    TUN 的 gvisor 协议栈。默认用的是 system 栈，但配置里选得到。
#   with_clash_api 控制口。选节点、切路由模式、统计流量全走它。
#
# 上游 release 默认还带 dhcp / wireguard / acme / tailscale / ccm / ocm，本项目
# 一样都不用：带上让二进制从 25MB 涨到 39MB，纯浪费包体积。
# badlinkname / tfogo_checklinkname0 是上游自己的默认值，与 LDFLAGS 里那个
# -checklinkname=0 配套，动不得。
SING_BOX_TAGS="${SING_BOX_TAGS:-with_gvisor,with_quic,with_utls,with_clash_api,badlinkname,tfogo_checklinkname0}"

# 把 $SING_BOX_DIR 弄到 $SING_BOX_REF 上。已经在那个提交上就一次网络都不碰——
# 这个函数在每次 Xcode 构建里都会跑，不能变成「没网就构建不了」。
sing_box_checkout() {
  if [ ! -d "$SING_BOX_DIR/.git" ]; then
    git clone --branch "$SING_BOX_VERSION" --depth 1 https://github.com/SagerNet/sing-box.git "$SING_BOX_DIR" || return
  fi
  if [ "$(git -C "$SING_BOX_DIR" rev-parse HEAD)" != "$SING_BOX_REF" ]; then
    git -C "$SING_BOX_DIR" fetch --depth 1 origin "$SING_BOX_REF" || return
    git -C "$SING_BOX_DIR" checkout --detach "$SING_BOX_REF" || return
  fi
  test "$(git -C "$SING_BOX_DIR" rev-parse HEAD)" = "$SING_BOX_REF" || return 1
  test -z "$(git -C "$SING_BOX_DIR" status --porcelain --untracked-files=all)" || {
    echo "sing-box source has changes or untracked inputs; refusing release build" >&2; return 1;
  }
}
