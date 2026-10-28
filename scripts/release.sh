#!/usr/bin/env bash
# Builds, signs, notarizes and packages freeside as a DMG in dist/. Adapted
# from flatline's; the Sparkle feed steps (releases/, site/appcast.xml) come
# with M8.
#
#   scripts/release.sh                  full release
#   scripts/release.sh --skip-notarize  signed but not notarized (dry run)
#
# Notarization reads credentials from a keychain profile (default "freeside",
# override with NOTARY_PROFILE; flatline's profile holds the same team's
# credentials). Create it once with:
#   xcrun notarytool store-credentials freeside --team-id F87BNUZAVJ
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID=F87BNUZAVJ
PROFILE=${NOTARY_PROFILE:-freeside}
NOTARIZE=1
[[ ${1:-} == --skip-notarize ]] && NOTARIZE=0

VERSION=$(awk '/MARKETING_VERSION:/ { print $2; exit }' project.yml)
BUILD=$(awk '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' project.yml)
DIST=dist
ARCHIVE=$DIST/freeside.xcarchive
EXPORT=$DIST/export
APP=$EXPORT/freeside.app
DMG=$DIST/freeside-$VERSION.dmg

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Submits a file for notarization and waits; prints Apple's log on rejection.
notarize() {
    local result id status
    result=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format plist)
    id=$(plutil -extract id raw - <<<"$result")
    status=$(plutil -extract status raw - <<<"$result")
    echo "    submission $id: $status"
    if [[ $status != Accepted ]]; then
        xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
        fail "notarization of $1 was not accepted"
    fi
}

IDENTITY=$(security find-identity -v -p codesigning | sed -nE "s/.*\"(Developer ID Application: .*\($TEAM_ID\))\"/\1/p" | head -1)
[[ -n $IDENTITY ]] || fail "no Developer ID Application certificate for team $TEAM_ID in the keychain"
if (( NOTARIZE )); then
    xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
        || fail "no notary credentials in keychain profile '$PROFILE'; run: xcrun notarytool store-credentials $PROFILE --team-id $TEAM_ID (or set NOTARY_PROFILE=flatline)"
fi

step "freeside $VERSION ($BUILD), signing as $IDENTITY"
rm -rf "$DIST"
mkdir -p "$DIST"

step "Generating Xcode project"
xcodegen generate --quiet

step "Testing FreesideKit"
swift test --package-path Packages/FreesideKit --quiet

step "Archiving"
xcodebuild -project Freeside.xcodeproj -scheme Freeside -configuration Release \
    -destination generic/platform=macOS -derivedDataPath build -archivePath "$ARCHIVE" archive -quiet

step "Exporting for Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist scripts/ExportOptions.plist -quiet

step "Verifying signature"
codesign --verify --deep --strict "$APP"
details=$(codesign -dv --verbose=4 "$APP" 2>&1)
grep -q "Authority=Developer ID Application" <<<"$details" || fail "app is not signed with Developer ID"
grep -q "TeamIdentifier=$TEAM_ID" <<<"$details" || fail "app is signed by the wrong team"
grep -q "flags=0x10000(runtime)" <<<"$details" || fail "hardened runtime is off"
grep -q "^Timestamp=" <<<"$details" || fail "signature has no secure timestamp"
[[ $(lipo -archs "$APP/Contents/MacOS/freeside") == arm64 ]] || fail "binary is not arm64-only"
echo "    Developer ID, team $TEAM_ID, hardened runtime, timestamped, arm64"

if (( NOTARIZE )); then
    # Notarize and staple the app itself, so a copy dragged out of the DMG
    # (and later, Sparkle updates) pass Gatekeeper offline.
    step "Notarizing the app"
    ditto -c -k --keepParent "$APP" "$DIST/freeside-notarize.zip"
    notarize "$DIST/freeside-notarize.zip"
    rm "$DIST/freeside-notarize.zip"
    xcrun stapler staple -q "$APP"
fi

step "Building DMG"
STAGING=$DIST/dmg
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/freeside.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname freeside -srcfolder "$STAGING" -fs APFS -format ULFO -ov "$DMG"
rm -rf "$STAGING"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if (( NOTARIZE )); then
    step "Notarizing the DMG"
    notarize "$DMG"
    xcrun stapler staple -q "$DMG"

    step "Checking Gatekeeper"
    spctl --assess --type execute "$APP"
    spctl --assess --type open --context context:primary-signature "$DMG"
    echo "    app and DMG accepted (notarized, stapled)"
fi

step "Done"
echo "    $DMG"
echo "    $(du -h "$DMG" | cut -f1)  sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
if (( ! NOTARIZE )); then
    echo "    not notarized: run without --skip-notarize for a shippable build"
fi
