#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-release}"
identity="${SIGN_IDENTITY:--}"
team="${TEAM_ID:-}"
bundle_id="${BUNDLE_ID:-org.glassstats.app}"
destination="$PWD/dist"
sdk="$(xcrun --show-sdk-path)"
swift_flags=(--manifest-cache local)
if [[ "${GLASSSTATS_BUILD_WORKSPACE_CACHE:-0}" == 1 ]]; then
    export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
    export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
    mkdir -p "$CLANG_MODULE_CACHE_PATH"
    swift_flags+=(--disable-sandbox)
fi
if [[ -n "$team" && ( "$identity" == "-" || ! "$team" =~ ^[A-Z0-9]{10}$ ) ]]; then
    echo "TEAM_ID requires a distribution or development signing identity and a valid Apple Team ID." >&2
    exit 1
fi
if [[ ! "$bundle_id" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+$ ]]; then
    echo "BUNDLE_ID must be a valid reverse-DNS identifier." >&2
    exit 1
fi

architectures=( "${ARCHS:-$(uname -m)}" )
read -r -a architectures <<< "${architectures[0]}"
work="$(mktemp -d "${TMPDIR:-/tmp}/glassstats-package.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT
name=GlassStats
app="$work/$name.app"
widget="$app/Contents/PlugIns/GlassStatsWidgets.appex"
mkdir -p "$app/Contents/"{MacOS,Resources} "$widget/Contents/MacOS" "$destination"
cp Resources/App-Info.plist "$app/Contents/Info.plist"
cp Resources/Widget-Info.plist "$widget/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$bundle_id.widgets" "$widget/Contents/Info.plist"
app_bins=()
widget_bins=()
widget_optimization=-O
if [[ "$configuration" == debug ]]; then widget_optimization=-Onone; fi
for arch in "${architectures[@]}"; do
    if [[ "$arch" != arm64 && "$arch" != x86_64 ]]; then
        echo "Unsupported architecture $arch" >&2
        exit 1
    fi
    swift build "${swift_flags[@]}" -c "$configuration" --arch "$arch" --product GlassStats
    bin="$(swift build "${swift_flags[@]}" -c "$configuration" --arch "$arch" --show-bin-path)"
    app_bins+=("$bin/GlassStats")
    swiftc -swift-version 6 -parse-as-library -application-extension "$widget_optimization" \
        -target "$arch-apple-macosx14.0" -sdk "$sdk" -module-name GlassStatsWidgets \
        Sources/WidgetSnapshot/WidgetSnapshot.swift Sources/GlassStatsWidget/GlassStatsWidgets.swift \
        -o "$work/GlassStatsWidgets-$arch"
    widget_bins+=("$work/GlassStatsWidgets-$arch")
done

xcrun lipo -create "${app_bins[@]}" -output "$app/Contents/MacOS/GlassStats"
xcrun lipo -create "${widget_bins[@]}" -output "$widget/Contents/MacOS/GlassStatsWidgets"
cp Resources/GlassStats.icns LICENSE "$app/Contents/Resources/"
plutil -create xml1 "$work/app-entitlements.plist"
plutil -create xml1 "$work/widget-entitlements.plist"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$work/widget-entitlements.plist"

if [[ -n "$team" ]]; then
    group="$team.$bundle_id"
    for path in "$app" "$widget"; do
        plutil -insert GlassStatsAppGroup -string "$group" "$path/Contents/Info.plist"
    done
    for entitlements in "$work/app-entitlements.plist" "$work/widget-entitlements.plist"; do
        /usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' \
            -c "Add :com.apple.security.application-groups:0 string $group" "$entitlements"
    done
fi

sign_flags=(--force --sign "$identity")
if [[ "$identity" != "-" ]]; then
    sign_flags+=(--options runtime)
    if [[ "$identity" == "Developer ID Application:"* ]]; then sign_flags+=(--timestamp); fi
fi
codesign "${sign_flags[@]}" --entitlements "$work/widget-entitlements.plist" "$widget"
codesign "${sign_flags[@]}" --entitlements "$work/app-entitlements.plist" "$app"
codesign --verify --deep --strict "$app"

rm -rf "$destination/GlassStats.app"
mv "$app" "$destination/"
ditto -c -k --sequesterRsrc --keepParent "$destination/GlassStats.app" "$work/GlassStats.zip"
mv -f "$work/GlassStats.zip" "$destination/GlassStats.zip"
(cd "$destination" && shasum -a 256 GlassStats.zip > GlassStats.zip.sha256)
echo "Packaged $destination/GlassStats.zip"
