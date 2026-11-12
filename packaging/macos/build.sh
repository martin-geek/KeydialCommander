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
version="1.3.0"

mkdir -p "$work" "$output"
"$python" -m pip install --no-deps --no-build-isolation -e .
PYINSTALLER_CONFIG_DIR="$work/cache" "$python" -m PyInstaller --noconfirm --onedir \
    --name keydial-engine --distpath "$work/frozen" --workpath "$work/pyinstaller" \
    --specpath "$work" --target-arch "$arch" --exclude-module evdev packaging/macos/engine.py

rm -rf "$staging"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$setup/Contents/MacOS"
ditto "$work/frozen/keydial-engine" "$app/Contents/Resources/keydial-engine"
swift_flags=(-O -target "$arch-apple-macosx14.0" -module-cache-path "$work/swift-cache")
swiftc "${swift_flags[@]}" packaging/macos/{Layout,CommanderModel,CommanderApp,BindingEditor}.swift \
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
codesign --force --sign - "$app"
codesign --force --sign - "$setup"
codesign --verify --deep --strict "$app"
codesign --verify --strict "$setup"
hdiutil create -ov -format UDZO -volname "Keydial Commander" \
    -srcfolder "$staging" "$output/Keydial Commander-macOS-$arch.dmg"
