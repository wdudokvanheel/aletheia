#!/bin/zsh
# Build locally and stage a complete verified bundle before replacing the install.
set -eu
cd "${0:A:h:h}"
scripts/bundle-app.sh release
applications="$HOME/Applications"
mkdir -p "$applications"
staging="$(mktemp -d "$applications/.aletheia-install.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto build/Aletheia.app "$staging/Aletheia.app"
codesign --verify --strict "$staging/Aletheia.app"
plutil -lint "$staging/Aletheia.app/Contents/Info.plist"
destination="$applications/Aletheia.app"
if [[ -e "$destination" ]]; then
    mv "$destination" "$staging/previous.app"
fi
if ! mv "$staging/Aletheia.app" "$destination"; then
    [[ ! -e "$staging/previous.app" ]] || mv "$staging/previous.app" "$destination"
    exit 1
fi
print "Installed $destination ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$destination/Contents/Info.plist"))"
print 'Open the installed app when ready; an already running copy keeps running until you quit it.'
