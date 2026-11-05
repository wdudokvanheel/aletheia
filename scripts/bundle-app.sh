#!/bin/zsh
set -eu
cd "${0:A:h:h}"
configuration="${1:-release}"
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    print -u2 'Usage: scripts/bundle-app.sh [debug|release]'
    exit 2
fi
swift build -c "$configuration" --arch arm64
binary_dir="$(swift build -c "$configuration" --arch arm64 --show-bin-path)"
app="$PWD/build/Aletheia.app"
mkdir -p "$app/Contents/MacOS"
cp "$binary_dir/Aletheia" "$app/Contents/MacOS/Aletheia"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Aletheia</string>
<key>CFBundleIdentifier</key><string>local.aletheia.editor</string>
<key>CFBundleName</key><string>Aletheia</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
print "Built $app"
