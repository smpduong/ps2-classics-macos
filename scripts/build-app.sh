#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=12.0
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
APP="dist/PS2 Classics for Mac.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
# Publish a new inode so a running developer tool keeps its original code pages.
# Universal SwiftPM products also need explicit ad hoc signing for direct execution.
install_binary() {
    local staged
    staged="$(mktemp "$2.tmp.XXXXXX")"
    cp "$1" "$staged"
    chmod 755 "$staged"
    codesign --force --sign - "$staged"
    mv -f "$staged" "$2"
}
install_binary "$BIN_DIR/PS2ClassicsApp" "$APP/Contents/MacOS/PS2ClassicsApp"
install_binary "$BIN_DIR/ps2-inspect" dist/ps2-inspect
install_binary "$BIN_DIR/ps2-build" dist/ps2-build
install_binary "$BIN_DIR/ps2-convert" dist/ps2-convert
install_binary "$BIN_DIR/ps2-convert" "$APP/Contents/Helpers/ps2-convert"
# Optional ATRAC3 encoder (separate LGPL executable, no runtime deps beyond the
# system libraries). Built from pinned vendored source for both architectures.
bash scripts/build-at3-helper.sh
install_binary dist/ps2-at3 "$APP/Contents/Helpers/ps2-at3"
cp ThirdParty/PS2Classic/COPYING "$APP/Contents/Resources/PS2Classic-COPYING.txt"
cp ThirdParty/PS2Classic/NOTICE.md "$APP/Contents/Resources/PS2Classic-NOTICE.txt"
cp ThirdParty/atracdenc/LICENSE "$APP/Contents/Resources/atracdenc-LICENSE.txt"
cp ThirdParty/atracdenc/src/lib/libgha/LICENSE "$APP/Contents/Resources/libgha-LICENSE.txt"
cp ThirdParty/libsndfile/COPYING "$APP/Contents/Resources/libsndfile-COPYING.txt"
cp ThirdParty/ATRAC_SOURCES.md "$APP/Contents/Resources/ATRAC-SOURCES.txt"
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/generate-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp LICENSING.md "$APP/Contents/Resources/Licensing.md"
# Retain every embedded copyright/license notice, including nested codecs.
mkdir -p "$APP/Contents/Resources/Audio Sources"
cp -R ThirdParty/atracdenc ThirdParty/libsndfile "$APP/Contents/Resources/Audio Sources/"
cp docs/USER_GUIDE.md "$APP/Contents/Resources/User Guide.md"
cp -R ThirdParty/PSL1GHT "$APP/Contents/Resources/"
cp -R ThirdParty/NPData "$APP/Contents/Resources/"
cp -R ThirdParty/libchdr "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PS2ClassicsApp</string>
<key>CFBundleIdentifier</key><string>local.ps2classics.mac.preview</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>PS2 Classics for Mac</string>
<key>CFBundleDisplayName</key><string>PS2 Classics for Mac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>15</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>PS2 Classics project</string>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>CFBundleTypeExtensions</key><array><string>ps2project</string></array>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Helpers/ps2-convert"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
for BINARY in "$APP/Contents/MacOS/PS2ClassicsApp" dist/ps2-inspect dist/ps2-build "$APP/Contents/Helpers/ps2-convert"; do
    codesign --verify --strict "$BINARY"
    ARCHS="$(lipo -archs "$BINARY")"
    for REQUIRED in arm64 x86_64; do
        case " $ARCHS " in
            *" $REQUIRED "*) ;;
            *) printf 'Missing architecture %s in %s\n' "$REQUIRED" "$BINARY" >&2; exit 1 ;;
        esac
    done
done
printf 'Built local development preview: %s\n' "$APP"
