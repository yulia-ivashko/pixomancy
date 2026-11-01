#!/bin/zsh
# Builds build/Pixomancy.app from the Swift package.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Pixomancy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Pixomancy "$APP/Contents/MacOS/Pixomancy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Layered icon (light, dark, tinted, clear); actool needs absolute paths.
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist "$PWD/$APP/Contents/Resources/.icon-partial.plist" >/dev/null
rm -f "$APP/Contents/Resources/.icon-partial.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
# Ad hoc for a local build; the release passes the Developer ID certificate, with the hardened runtime notarisation needs.
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
# The bundle was deleted and recreated; without this Finder keeps showing a blank icon for it.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$PWD/$APP"
# Release only: notarise, staple the ticket so the app opens offline too, and zip it.
if [[ -n "${APPLE_ID:-}" ]]; then
  ditto -c -k --keepParent "$APP" build/Pixomancy.zip
  xcrun notarytool submit build/Pixomancy.zip --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
  xcrun stapler staple "$APP"
  rm build/Pixomancy.zip
  ditto -c -k --keepParent "$APP" build/Pixomancy.zip
fi
echo "$PWD/$APP"
