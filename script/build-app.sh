#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
destination="${1:-"$PWD/dist"}"
mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
app="$destination/FFmpegFreeUI_macOS.app"
stage="$(mktemp -d "$destination/.3fui-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/FFmpegFreeUI_macOS.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

arm="$(swift build -c release --scratch-path .build/arm64 --arch arm64 --show-bin-path)"
swift build -c release --scratch-path .build/arm64 --arch arm64
intel="$(swift build -c release --scratch-path .build/x86_64 --arch x86_64 --show-bin-path)"
swift build -c release --scratch-path .build/x86_64 --arch x86_64
lipo -create "$arm/FFmpegFreeUI_macOS" "$intel/FFmpegFreeUI_macOS" \
    -output "$bundle/Contents/MacOS/FFmpegFreeUI_macOS"
cp LICENSE.txt "$bundle/Contents/Resources/"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>FFmpegFreeUI_macOS</string>
    <key>CFBundleIdentifier</key><string>io.github.leafall903.FFmpegFreeUI-macOS</string>
    <key>CFBundleName</key><string>FFmpegFreeUI_macOS</string>
    <key>CFBundleDisplayName</key><string>FFmpegFreeUI</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$bundle/Contents/Info.plist"
/usr/bin/xattr -cr "$bundle"

codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
if [[ -e "$app" ]]; then mv "$app" "$stage/previous.app"; fi
if ! mv "$bundle" "$app"; then
    if [[ -e "$stage/previous.app" ]]; then mv "$stage/previous.app" "$app"; fi
    exit 1
fi
printf '%s\n' "$app"
