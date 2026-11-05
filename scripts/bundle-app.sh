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
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# Bundle.module searches the main application resource directory first.
ditto "$binary_dir/Aletheia_Aletheia.bundle" "$app/Contents/Resources/Aletheia_Aletheia.bundle"
cp "$binary_dir/Aletheia" "$app/Contents/MacOS/Aletheia"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Aletheia</string>
<key>CFBundleIdentifier</key><string>local.aletheia.editor</string>
<key>CFBundleName</key><string>Aletheia</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDisplayName</key><string>Aletheia</string>
<key>CFBundleIconFile</key><string>Aletheia</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
metadata="$PWD/Sources/Aletheia/Resources/AppMetadata.plist"
for key in CFBundleShortVersionString CFBundleVersion ApplicationDescription; do
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$metadata")"
    plutil -insert "$key" -string "$value" "$app/Contents/Info.plist"
done
# Finder's descriptive version information; About uses the same metadata.
plutil -insert CFBundleGetInfoString -string "Aletheia $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$metadata") — $(/usr/libexec/PlistBuddy -c 'Print :ApplicationDescription' "$metadata")" "$app/Contents/Info.plist"
cp assets/Aletheia.icns "$app/Contents/Resources/Aletheia.icns"
printf 'APPL????' > "$app/Contents/PkgInfo"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
print "Built $app"
