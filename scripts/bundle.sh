#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
BIN="$(swift build -c release --show-bin-path)/PasteApp"
APP="build/CommandV.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CommandV"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.commandv.app</string>
    <key>CFBundleName</key><string>CommandV</string>
    <key>CFBundleDisplayName</key><string>CommandV</string>
    <key>CFBundleExecutable</key><string>CommandV</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.commandv.clip-id</string>
            <key>UTTypeDescription</key><string>CommandV clip identifier</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"
echo "Built $APP"
