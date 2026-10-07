#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
view="$repo_dir/app/PendingUI/PendingNetManagementView.swift"

# Switching away from Management must forget the previous server's user/IP
# snapshot as well as one-time links. The SwiftUI tab may stay alive offscreen.
if ! rg -Uq 'func clearTransientLink\(\) \{[^}]*issuedLink = nil[^}]*users = \[\][^}]*configRevision = nil' "$view"; then
    echo "Management tab retains user/IP state after leaving" >&2
    exit 1
fi
if ! rg -Uq '\.onDisappear \{[^}]*controller\.clearTransientLink\(\)' "$view"; then
    echo "Management tab does not clear transient state on disappearance" >&2
    exit 1
fi

# An in-flight export must not leave credential-bearing JSON or completion
# feedback attached to a different server (or to a tab visited later).
if ! rg -Uq '\.onDisappear \{[^}]*showExporter = false[^}]*exportDocument = nil[^}]*exportServerID = nil' "$view"; then
    echo "Management tab retains an export after leaving" >&2
    exit 1
fi
if ! rg -Uq 'set: \{ id in[^}]*controller\.selectServer\(id\)[^}]*showExporter = false[^}]*exportDocument = nil[^}]*exportServerID = nil' "$view"; then
    echo "Management tab retains an export after switching servers" >&2
    exit 1
fi
if ! rg -Uq 'func selectServer\(_ id: String\?\) \{\n\s*guard[^\n]*\n\s*clearTransientLink\(\)\n\s*selectedServerID = id' "$view"; then
    echo "Management tab retains stale user data on server selection" >&2
    exit 1
fi
if ! rg -Uq 'let matchesCurrentServer = exportServerID != nil && exportServerID == controller\.selectedServerID[^}]*exportServerID = nil[^}]*if matchesCurrentServer \{[^}]*controller\.exportFinished\(result\)' "$view"; then
    echo "Management tab accepts stale export completion" >&2
    exit 1
fi

# Enrollment consumes its one-time grant before returning. A late result must
# still save metadata, but must not select a server or show a message in a
# tab that has since been left or switched to another server.
if ! rg -Uq 'func importLink\(_ link: String\) async -> Bool \{\n\s*guard !working, !enrollmentInFlight else \{ return false \}[^}]*let generation = refreshGeneration' "$view"; then
    echo "Management enrollment can overlap or lacks a view generation" >&2
    exit 1
fi
if ! rg -Uq 'try store\.upsert\(server\)\n\s*servers = store\.servers\n\s*guard refreshGeneration == generation else \{ return false \}\n\s*selectedServerID = server\.serverID' "$view"; then
    echo "Late enrollment overwrites the currently selected server" >&2
    exit 1
fi
if ! rg -q '\.disabled\(controller\.working \|\| controller\.enrollmentInFlight \|\|' "$view"; then
    echo "Management import may discard another pasted link during enrollment" >&2
    exit 1
fi

# Confirmation alerts can outlive a picker change. A destructive action must
# keep the server it was originally offered for, not target the new selection.
if ! rg -Uq 'if let id = revokeUserID,\n\s*let serverID = revokeServerID,\n\s*controller\.selectedServerID == serverID \{' "$view"; then
    echo "Management revoke confirmation can target a different server" >&2
    exit 1
fi
if ! rg -Uq 'Task \{\n\s*guard controller\.selectedServerID == serverID else \{ return \}\n\s*await controller\.revokeUser\(id: id\)' "$view"; then
    echo "Management revoke task can start after switching servers" >&2
    exit 1
fi
if ! rg -Uq 'if let serverID = adminIssueServerID, controller\.selectedServerID == serverID \{' "$view"; then
    echo "Management link confirmation can target a different server" >&2
    exit 1
fi
if ! rg -Uq 'Task \{\n\s*guard controller\.selectedServerID == serverID else \{ return \}\n\s*await controller\.issuePairing\(role: \.admin\)' "$view"; then
    echo "Management link issue task can start after switching servers" >&2
    exit 1
fi
