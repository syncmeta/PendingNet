#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d /private/tmp/pendingnet-ui-check.XXXXXX)"
output="${PENDINGNET_UI_ARTIFACTS_DIR:-$scratch/results}"
mkdir -p "$scratch/lib" "$scratch/ModuleCache" "$output"
compiler=(swiftc -module-cache-path "$scratch/ModuleCache")
"${compiler[@]}" -module-name SBTallyCore -emit-module -emit-library \
    "$repo_root/app/SBTallyCore/Sources/SBTallyCore/PendingNetHelperRecovery.swift" \
    -o "$scratch/lib/libSBTallyCore.dylib"
flags=(-I "$scratch/lib" -L "$scratch/lib" -lSBTallyCore -Xlinker -rpath -Xlinker "$scratch/lib")
if [[ "${1:-}" == "--baseline" ]]; then
    git -C "$repo_root" show pendingnet/v0.3.41:app/SBTally/PendingNetAppDelegate.swift > "$scratch/OldDelegate.swift"
    "${compiler[@]}" "${flags[@]}" "$scratch/OldDelegate.swift" "$repo_root/tests/macos/TerminationFixture.swift" -o "$scratch/termination-red"
    code=0
    "$scratch/termination-red" > "$output/termination-red.log" 2>&1 || code=$?
    [[ "$code" == 42 ]] || { echo "Expected original delegate to veto exit (42), got $code"; exit 1; }
fi
"${compiler[@]}" "${flags[@]}" "$repo_root/app/SBTally/PendingNetAppDelegate.swift" "$repo_root/tests/macos/TerminationFixture.swift" -o "$scratch/termination-green"
"$scratch/termination-green" > "$output/termination-green.log" 2>&1
"$scratch/termination-green" --no-reply > "$output/termination-timeout-green.log" 2>&1
"${compiler[@]}" "$repo_root/app/PendingUI/PendingNetTheme.swift" \
    "$repo_root/app/SBTally/PendingNetNavigation.swift" "$repo_root/app/SBTally/Views/PendingNetSidebar.swift" \
    "$repo_root/tests/macos/SidebarFixture.swift" -o "$scratch/sidebar"
PENDINGNET_SIDEBAR_SCREENSHOT="$output/sidebar.png" "$scratch/sidebar" > "$output/sidebar.log" 2>&1
if [[ -n "${PENDINGNET_SPARKLE_FRAMEWORK:-}" ]]; then
    framework_parent="$(dirname "$PENDINGNET_SPARKLE_FRAMEWORK")"
    cat "$repo_root/app/SBTally/PendingNetUpdateController.swift" "$repo_root/tests/macos/UpdateFixture.swift" > "$scratch/Update.swift"
    "${compiler[@]}" -parse-as-library "${flags[@]}" -F "$framework_parent" -framework Sparkle \
        -Xlinker -rpath -Xlinker "$framework_parent" "$scratch/Update.swift" -o "$scratch/update"
    "$scratch/update" > "$output/update-green.log" 2>&1
    "$scratch/update" --no-reply > "$output/update-timeout-green.log" 2>&1
fi
printf 'PASS: exit error, exit timeout, native row click, theme selection pixels. Evidence: %s\n' "$output"
# Keep failed artifacts for diagnosis; successful callers can remove this folder.
echo "Temporary fixture build: $scratch"
