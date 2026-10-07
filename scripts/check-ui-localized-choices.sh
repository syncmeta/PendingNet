#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The production server deliberately rejects configuration writes until an
# offline Hysteria validator and health-checked restart are available. The
# management screen must say so instead of implying the revision is editable.
if ! rg -Fq 'Text("服务端配置目前只读；在线修改尚未开放。")' \
    "$repo_dir/app/PendingUI/PendingNetManagementView.swift"; then
    echo "Management screen does not disclose read-only server configuration" >&2
    exit 1
fi

# Text's StringProtocol initializer displays a computed String verbatim. A
# conditional of Chinese literals must pass LocalizedStringKey values instead.
if rg -n 'Text\([^)]*\?[[:space:]]*"[^"]+"[[:space:]]*:[[:space:]]*"[^"]+"' \
    "$repo_dir/app/PendingUI" --glob '*.swift'; then
    echo "Computed Text choice contains unlocalized string literals" >&2
    exit 1
fi

# The connection header receives an already selected title as String. Its
# authorization action must still resolve that title through the app strings.
if rg -n 'Button\(title\)' "$repo_dir/app/PendingUI" --glob '*.swift'; then
    echo "Dynamic connection button title bypasses localization" >&2
    exit 1
fi

# Import and VPS-switch results are composed by the platform controllers and
# shown verbatim in the UI. Keep their templates in Localizable.strings.
if rg -n 'if selectedServerID == server\.serverID \{ errorMessage = error\.localizedDescription \}' \
    "$repo_dir/app/PendingUI/PendingNetManagementView.swift"; then
    echo "Stale management request error may appear after server selection changes" >&2
    exit 1
fi

if rg -n 'return "\\\(urlError\.localizedDescription\).*URL 错误' \
    "$repo_dir/app/SBTally/VPSPairingController.swift"; then
    echo "Mac VPS import URL error detail bypasses localization" >&2
    exit 1
fi

if rg -n '(lastMessage|message|errorMessage) = "(已导入|切换 VPS 失败)' \
    "$repo_dir/app/SBTally/VPSPairingController.swift" \
    "$repo_dir/app/PendingNetIOS/PendingNetIOSController.swift"; then
    echo "User-facing controller result bypasses localization" >&2
    exit 1
fi

# Route-mode notices are stored as String and displayed verbatim. Catch the
# literal paths in both clients, including the conditional helper failures.
if rg -n '(modeNote|errorMessage|degradeNotice|reason) = "[^\"]*[一-龥]|^[[:space:]]*\? "(引擎|后台服务|已记住)' \
    "$repo_dir/app/SBTally/PendingNetRoutingWorkflow.swift" \
    "$repo_dir/app/PendingNetIOS/PendingNetIOSHomeView.swift" \
    "$repo_dir/app/PendingNetIOS/PendingNetTunnelController.swift"; then
    echo "Route-mode feedback bypasses localization" >&2
    exit 1
fi

# iOS download and tunnel-control errors propagate through localizedDescription
# to settings and connection screens; raw Chinese strings bypass the app locale.
if rg -n '^[[:space:]]*"隧道正在跑，但这会儿拿不到当前 VPS' \
    "$repo_dir/app/PendingNetIOS/PendingNetTunnelController.swift"; then
    echo "iOS live inbound-change error bypasses localization" >&2
    exit 1
fi

if rg -n 'serverRejected\("[^\"]*[一-龥]|\.setup\("[^\"]*[一-龥]|case \.[[:alnum:]]+(\(let [[:alnum:]]+\))?: "[^\"]*[一-龥]|^[[:space:]]*"规则集内容不是有效|\?\? "未知原因"' \
    "$repo_dir/app/PendingNetIOS/PendingNetRuleSetStore.swift" \
    "$repo_dir/app/PendingNetIOS/PendingNetTunnelController.swift" \
    "$repo_dir/app/PendingNetIOS/PendingNetCommandClient.swift"; then
    echo "iOS tunnel or rule-set error bypasses localization" >&2
    exit 1
fi

# macOS startup and VPS-apply failures are Strings rendered as-is, not SwiftUI
# localized keys. Guard both direct assignments and fallback expressions.
if rg -n 'lastError = "[^\"]*[一-龥]|^[[:space:]]*[?:] "(开机自启|后台服务)|reportApplyError\("[^\"]*[一-龥]|lastError \?\? "[^\"]*[一-龥]' \
    "$repo_dir/app/SBTally/PendingNetStartupController.swift" \
    "$repo_dir/app/SBTally/PendingNetConnectionWorkflow.swift"; then
    echo "macOS startup or VPS feedback bypasses localization" >&2
    exit 1
fi

# Helper authorization errors also feed the macOS toast and connection page.
if rg -n 'lastError = "[^\"]*[一-龥]|^[[:space:]]*[?:] "后台服务|return "(请在系统设置|旧版后台服务|后台服务尚未连接)|lastError \?\? "后台服务' \
    "$repo_dir/app/SBTally/EngineController.swift"; then
    echo "macOS helper feedback bypasses localization" >&2
    exit 1
fi

# Remaining helper fallbacks surface as stats-state failures, latency errors,
# and connection failures. They must be resolved before entering String APIs.
if rg -n '^[[:space:]]*"(后台服务还不是这一版|后台服务未就绪)|\(-1, "后台服务未就绪"|withCompatibleHelper\("(助手连接失败|特权助手尚未就绪)"|\?\? "代理访问测试未通过"' \
    "$repo_dir/app/SBTally/EngineController.swift"; then
    echo "macOS helper stats or latency feedback bypasses localization" >&2
    exit 1
fi

# Statistics daemon failures are passed through DaemonState to the traffic
# empty state, which renders their String payload verbatim.
if rg -n '^[[:space:]]*PendingNetEngineBinary\.missingEngineMessage$|^[[:space:]]*"(还没有可运行的节点配置|本机代理配置校验失败|本机代理启动失败)' \
    "$repo_dir/app/SBTally/PendingNetUserEngine.swift"; then
    echo "macOS local engine errors bypass localization" >&2
    exit 1
fi

if rg -n 'pairing\.reportApplyError\(engine\.lastError' \
    "$repo_dir/app/SBTally/PendingNetConnectionWorkflow.swift"; then
    echo "Connection workflow bypasses localized engine error text" >&2
    exit 1
fi

if rg -n 'return EmptyMessage\(title: "|title: "(还没有连接|这段时间没有流量|统计服务没能启动)|reason: "统计服务' \
    "$repo_dir/app/SBTallyCore/Sources/SBTallyCore/PendingNetStatsService.swift"; then
    echo "Shared statistics empty-state feedback bypasses localization" >&2
    exit 1
fi

if rg -n '\.failed\("[^"\n]*[一-龥]|^[[:space:]]*[?:] "(统计服务|统计接口|腾出其中)' \
    "$repo_dir/app/SBTally/PendingNetStatsDaemon.swift"; then
    echo "macOS statistics daemon failure bypasses localization" >&2
    exit 1
fi

# Rule-set refresh returns failure text to the Settings toast as a plain
# String, so SwiftUI does not localize literals produced by the downloader.
if rg -n 'failure = failure \?\? "规则集' \
    "$repo_dir/app/SBTally/PendingNetRouteRuleSets.swift"; then
    echo "macOS rule-set refresh feedback bypasses localization" >&2
    exit 1
fi

# Core port-validation errors are surfaced verbatim in the shared Settings
# toast on both platforms; package-side literals do not get SwiftUI lookup.
if rg -n '^[[:space:]]*"(端口只能|端口要在|[^"[:space:]]+ 是 PendingNet 自己的控制端口|端口 .*已经被别的程序占用)' \
    "$repo_dir/app/SBTallyCore/Sources/SBTallyCore/PendingNetLocalInbound.swift"; then
    echo "Shared port-validation feedback bypasses localization" >&2
    exit 1
fi

# Import parse errors cross the Core/app boundary as LocalizedError and are
# displayed verbatim in both clients' import forms.
if rg -n '^[[:space:]]*"(请粘贴至少|第 .*行不是支持的节点链接|第 .*行是管理链接)' \
    "$repo_dir/app/SBTallyCore/Sources/SBTallyCore/PendingNetSharedNode.swift"; then
    echo "Shared node-import feedback bypasses localization" >&2
    exit 1
fi

# Pairing validation and HTTP fallback errors reach both import screens through
# LocalizedError.localizedDescription; Core must resolve them in the app bundle.
if rg -n 'case \.(unsupportedFormat|unsupportedVersion|missingIdentity|invalidEndpoint|invalidFingerprint|invalidToken|expired|unexpectedFields|invalidLink|invalidServerResponse|keychain|transport)[^:]*: "|\?\? "(读取 VPS 节点资料失败|PendingNet Server 拒绝配对)' \
    "$repo_dir/app/SBTallyCore/Sources/SBTallyCore/PendingNetPairing.swift"; then
    echo "Pairing feedback bypasses localization" >&2
    exit 1
fi

# AppState stores this Core-generated plain String in lastError. SwiftUI does
# not localize it after the fact, so the Core helper must use the app bundle.
if rg -n 'return "代理(控制失败|引擎没有响应|引擎返回了)|return "找不到代理控制凭据' \
    "$repo_dir/app/SBTallyCore/Sources/SBTallyCore/PendingNetControlFailureMessage.swift"; then
    echo "Proxy control feedback bypasses localization" >&2
    exit 1
fi

# Runtime configuration errors are passed through localizedDescription into
# Mac import/apply feedback and iOS tunnel setup errors.
if rg -n 'case \.(unsupportedProtocol|malformedProtocol|invalidLocalConfiguration|missingProxySelector)[^:]*: "' \
    "$repo_dir/app/SBTallyCore/Sources/SBTallyCore/PendingNetRuntimeConfig.swift"; then
    echo "Runtime configuration feedback bypasses localization" >&2
    exit 1
fi

# Latency strings are rendered verbatim in both VPS lists and detail views.
if rg -n 'case \.(proxyEntry|controlPort|proxyAccess|failed|measuring): "|^[[:space:]]*"(代理入口|控制端口|经所选代理访问)|return "(这台 VPS 的地址|连接超时|代理访问测试|连接被拒绝|网络到不了|连接被对方|域名解析不了|连不上这台 VPS)' \
    "$repo_dir/app/SBTallyCore/Sources/SBTallyCore/PendingNetLatency.swift"; then
    echo "Latency feedback bypasses localization" >&2
    exit 1
fi
