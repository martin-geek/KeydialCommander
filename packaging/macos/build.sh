#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

python="${PYTHON:-$PWD/.venv/bin/python}"
work="${KEYDIAL_BUILD_DIR:-$PWD/build/macos}"
output="$PWD/dist"
staging="$work/image"
app="$staging/Keydial Commander.app"
setup="$staging/Keydial Commander Setup.app"
arch="$(uname -m)"
app_id="io.github.martin-geek.keydial-commander"
version="$(cat packaging/macos/VERSION)"
signing_identity="${KEYDIAL_SIGNING_IDENTITY:--}"
notary_profile="${KEYDIAL_NOTARY_PROFILE:-}"
signing_flags=()
engine_signing_flags=()
if [[ "$signing_identity" != "-" ]]; then
    signing_flags=(--options runtime --timestamp)
    engine_signing_flags=(--codesign-identity "$signing_identity")
elif [[ -n "$notary_profile" ]]; then
    echo "Set KEYDIAL_SIGNING_IDENTITY to a Developer ID Application identity for notarization." >&2
    exit 1
fi

mkdir -p "$work" "$output"
"$python" -m pip install --no-deps --no-build-isolation -e .
PYINSTALLER_CONFIG_DIR="$work/cache" "$python" -m PyInstaller --noconfirm --onedir \
    --name keydial-engine --distpath "$work/frozen" --workpath "$work/pyinstaller" \
    --specpath "$work" --target-arch "$arch" --exclude-module evdev \
    ${engine_signing_flags[@]+"${engine_signing_flags[@]}"} packaging/macos/engine.py

rm -rf "$staging"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" \
    "$setup/Contents/MacOS" "$setup/Contents/Resources"
ditto "$work/frozen/keydial-engine" "$app/Contents/Resources/keydial-engine"
assets="$PWD/packaging/macos/assets"
iconset="$work/CommanderIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$assets/CommanderIcon.heic" \
        --out "$iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -s format png -z "$doubled" "$doubled" "$assets/CommanderIcon.heic" \
        --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/CommanderIcon.icns"
cp "$app/Contents/Resources/CommanderIcon.icns" "$setup/Contents/Resources/"
cp "$assets/Keydial.heic" "$app/Contents/Resources/"
swift_flags=(-O -target "$arch-apple-macosx14.0" -module-cache-path "$work/swift-cache")
swiftc "${swift_flags[@]}" packaging/macos/{Layout,Preferences,BatteryReader,CommanderModel,CommanderApp,CommanderMenu,BindingEditor}.swift \
    -o "$app/Contents/MacOS/Commander"
swiftc "${swift_flags[@]}" packaging/macos/{AppInstallation,Setup}.swift \
    -o "$setup/Contents/MacOS/Setup"

plist() {
    local bundle="$1" executable="$2" identifier="$3" name="$4"
    cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$executable</string>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleDisplayName</key><string>$name</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>CommanderIcon.icns</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Read the battery level from your connected Huion Keydial Mini.</string>
<key>CFBundleVersion</key><string>$version</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
}
plist "$app" Commander "$app_id" "Keydial Commander"
plist "$setup" Setup "$app_id.setup" "Keydial Commander Setup"
cp LICENSE "$staging/License.txt"
codesign --force --sign "$signing_identity" ${signing_flags[@]+"${signing_flags[@]}"} "$app"
codesign --force --sign "$signing_identity" ${signing_flags[@]+"${signing_flags[@]}"} "$setup"
codesign --verify --deep --strict "$app"
codesign --verify --strict "$setup"
dmg="$output/Keydial Commander-$version-macOS-$arch.dmg"
hdiutil create -ov -format UDZO -volname "Keydial Commander" -srcfolder "$staging" "$dmg"
if [[ "$signing_identity" != "-" ]]; then
    codesign --force --sign "$signing_identity" --timestamp "$dmg"
fi
if [[ -n "$notary_profile" ]]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
fi
