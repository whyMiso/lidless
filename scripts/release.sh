#!/usr/bin/env bash
# Build, sign (Developer ID), notarise and staple Lidless.app, then produce a zip + dmg.
#
# One-time setup (stores an app-specific password in your keychain):
#   xcrun notarytool store-credentials lidless-notary \
#       --apple-id <your Apple ID> --team-id <YOUR TEAM ID> --password <app-specific password>
#
# Usage: scripts/release.sh            (NOTARY_PROFILE overrides the keychain profile name)
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-lidless-notary}"
TEAM_ID="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Local.xcconfig 2>/dev/null)"
[ -n "$TEAM_ID" ] || { echo "Set DEVELOPMENT_TEAM in Config/Local.xcconfig (see Config/Local.xcconfig.example)"; exit 1; }
OUT=build/release
ARCHIVE="$OUT/Lidless.xcarchive"
APP="$OUT/export/Lidless.app"

rm -rf "$OUT"; mkdir -p "$OUT"

echo "==> Running core tests"
(cd Core && swift test 2>&1 | tail -3)

echo "==> Generating project"
xcodegen generate >/dev/null

echo "==> Archiving (universal, Release)"
xcodebuild -project Lidless.xcodeproj -scheme Lidless -configuration Release \
    -archivePath "$ARCHIVE" archive | xcbeautify 2>/dev/null || \
xcodebuild -project Lidless.xcodeproj -scheme Lidless -configuration Release \
    -archivePath "$ARCHIVE" archive -quiet

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST

echo "==> Exporting"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -quiet

echo "==> Verifying signatures"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP/Contents/MacOS/LidlessHelper" 2>&1 | grep -E "Identifier=|TeamIdentifier=|flags="
lipo -archs "$APP/Contents/MacOS/Lidless" "$APP/Contents/MacOS/LidlessHelper"

echo "==> Notarising"
ditto -c -k --keepParent "$APP" "$OUT/Lidless-notarize.zip"
xcrun notarytool submit "$OUT/Lidless-notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl -a -vvv -t exec "$APP"

echo "==> Packaging"
VERSION="$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)"
ditto -c -k --keepParent "$APP" "$OUT/Lidless-$VERSION.zip"
hdiutil create -volname Lidless -srcfolder "$APP" -ov -format UDZO "$OUT/Lidless-$VERSION.dmg" >/dev/null
xcrun notarytool submit "$OUT/Lidless-$VERSION.dmg" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/Lidless-$VERSION.dmg"

echo "Done: $OUT/Lidless-$VERSION.zip and $OUT/Lidless-$VERSION.dmg"
