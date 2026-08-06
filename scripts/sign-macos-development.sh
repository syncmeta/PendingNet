#!/bin/sh
set -eu

app="${1:?usage: scripts/sign-macos-development.sh /path/to/PendingNet.app}"
helper="$app/Contents/MacOS/PendingNetHelper"
identity="${PENDINGNET_SIGN_IDENTITY:--}"
sparkle="$app/Contents/Frameworks/Sparkle.framework"

test -x "$helper"

if test "$identity" = "-"; then
  # A plain `codesign -s -` uses a CDHash-only designated requirement, which
  # changes on every build. Stable explicit requirements let Service
  # Management recognize a locally built PendingNet update as the same pair.
  /usr/bin/codesign --force --sign - \
    --identifier net.pending.PendingNet.helper \
    --requirements '=designated => identifier "net.pending.PendingNet.helper"' \
    "$helper"
  /usr/bin/codesign --force --sign - \
    --identifier net.pending.PendingNet \
    --requirements '=designated => identifier "net.pending.PendingNet"' \
    "$app"
else
  if test -d "$sparkle"; then
    sparkle_version="$sparkle/Versions/B"
    if test -d "$sparkle_version/XPCServices/Installer.xpc"; then
      /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp \
        "$sparkle_version/XPCServices/Installer.xpc"
    fi
    if test -d "$sparkle_version/XPCServices/Downloader.xpc"; then
      /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp \
        --preserve-metadata=entitlements "$sparkle_version/XPCServices/Downloader.xpc"
    fi
    /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp \
      "$sparkle_version/Autoupdate"
    /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp \
      "$sparkle_version/Updater.app"
    /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp "$sparkle"
  fi
  /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp \
    --identifier net.pending.PendingNet.helper "$helper"
  /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp \
    --identifier net.pending.PendingNet "$app"
fi
/usr/bin/codesign --verify --deep --strict "$app"
