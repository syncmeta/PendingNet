#!/bin/sh
set -eu

: "${PENDINGNET_UPDATE_FEED_URL:?set the HTTPS appcast URL}"
: "${PENDINGNET_UPDATE_DOWNLOAD_PREFIX:?set the HTTPS release directory}"
: "${PENDINGNET_NOTARY_PROFILE:?set the notarytool Keychain profile}"

case "$PENDINGNET_UPDATE_FEED_URL" in https://*) ;; *) echo "feed URL must use HTTPS" >&2; exit 2 ;; esac
case "$PENDINGNET_UPDATE_DOWNLOAD_PREFIX" in https://*) ;; *) echo "download prefix must use HTTPS" >&2; exit 2 ;; esac

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_dir="$root/app"
version=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*//p' "$app_dir/project.yml" | tail -n 1 | tr -d '"')
test -n "$version"

derived="/tmp/pendingnet-release-$version"
release_dir="$root/dist/updates"
staging=$(mktemp -d "/tmp/pendingnet-update-$version.XXXXXX")
trap 'rm -rf "$staging"' EXIT HUP INT TERM
app="$staging/PendingNet.app"
archive="$release_dir/PendingNet-$version.zip"

mkdir -p "$release_dir" "$staging"
cd "$app_dir"
xcodegen generate
xcodebuild -project PendingNet.xcodeproj -scheme PendingNet -configuration Release \
  -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
  PENDINGNET_UPDATE_FEED_URL="$PENDINGNET_UPDATE_FEED_URL" build

sparkle_generate_appcast="${SPARKLE_GENERATE_APPCAST:-$derived/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast}"
test -x "$sparkle_generate_appcast"

/usr/bin/ditto "$derived/Build/Products/Release/PendingNet.app" "$app"
PENDINGNET_SIGN_IDENTITY="${PENDINGNET_SIGN_IDENTITY:-Developer ID Application: Yanze Tan (M42BKJN82S)}" \
  "$root/scripts/sign-macos-development.sh" "$app"

/usr/bin/ditto -c -k --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$PENDINGNET_NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
/usr/bin/ditto -c -k --keepParent "$app" "$archive"

"$sparkle_generate_appcast" \
  --account net.pending.PendingNet \
  --download-url-prefix "$PENDINGNET_UPDATE_DOWNLOAD_PREFIX" \
  "$release_dir"

/usr/bin/codesign --verify --deep --strict "$app"
xcrun stapler validate "$app"
echo "Update ready: $archive"

if [ "${PENDINGNET_PUBLISH_R2:-0}" = "1" ]; then
  "$root/scripts/publish-macos-update-r2.sh" pendingnet "$release_dir"
fi
