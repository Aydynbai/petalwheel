#!/bin/bash
# Builds Kumquat and packages it as build/Kumquat-<version>.dmg (app + /Applications symlink, UDZO).
#
# Usage: scripts/release.sh [--skip-build] [--no-verify]
#   --skip-build  package the existing build/Kumquat.app instead of running build-app.sh
#   --no-verify   don't mount the finished DMG to verify the app signature inside it
#
# Environment (both required for a distributable build, see docs/RELEASE.md):
#   DEVELOPER_ID    codesign identity, e.g. "Developer ID Application: Jane Doe (TEAMID1234)"
#   NOTARY_PROFILE  notarytool keychain profile created with `xcrun notarytool store-credentials`
# Without them the DMG contains the ad-hoc signed app (fine for local use, Gatekeeper will block it
# on other Macs) and the script prints what is missing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
APP_NAME="Kumquat"
APP="$ROOT/build/$APP_NAME.app"
ENTITLEMENTS="$ROOT/scripts/Kumquat.entitlements"

BUILD=1; VERIFY=1
for arg in "$@"; do
    case "$arg" in
        --skip-build) BUILD=0 ;;
        --no-verify) VERIFY=0 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

step() { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- build ---------------------------------------------------------------------------------
if [[ $BUILD -eq 1 ]]; then
    step "Building with scripts/build-app.sh"
    "$ROOT/scripts/build-app.sh"
fi
[[ -d "$APP" ]] || die "$APP not found (run without --skip-build)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
DMG="$ROOT/build/$APP_NAME-$VERSION.dmg"
echo "Version $VERSION ($BUILD_NUMBER)"

# --- signing mode ----------------------------------------------------------------------------
MODE=adhoc; missing=()
[[ -n "${DEVELOPER_ID:-}" ]] || missing+=("DEVELOPER_ID (codesign identity, e.g. \"Developer ID Application: Name (TEAMID)\")")
[[ -n "${NOTARY_PROFILE:-}" ]] || missing+=("NOTARY_PROFILE (keychain profile from: xcrun notarytool store-credentials)")
if [[ ${#missing[@]} -eq 0 ]]; then
    MODE=developer-id
    security find-identity -v -p codesigning | grep -qF "$DEVELOPER_ID" \
        || die "codesign identity not found in the keychain: $DEVELOPER_ID"
    xcrun --find notarytool >/dev/null 2>&1 || die "xcrun notarytool not found (needs Xcode 13+ or Command Line Tools 13+)"
    xcrun --find stapler >/dev/null 2>&1 || die "xcrun stapler not found"
fi

is_macho() { file -b "$1" | grep -q 'Mach-O'; }

sign_developer_id() {
    step "Signing with Developer ID (hardened runtime, secure timestamp)"
    local tools="$APP/Contents/Resources/Tools" f n=0
    # Inside-out: libraries first, then the helper executables, then the app itself.
    if [[ -d "$tools" ]]; then
        while IFS= read -r -d '' f; do
            is_macho "$f" || continue
            codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$f"; n=$((n + 1))
        done < <(find "$tools" -type f -name '*.dylib' -print0)
        while IFS= read -r -d '' f; do
            [[ "$f" == *.dylib ]] && continue
            is_macho "$f" || continue
            codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
                --sign "$DEVELOPER_ID" "$f"; n=$((n + 1))
        done < <(find "$tools" -type f -perm -u+x -print0)
    fi
    echo "Signed $n bundled Mach-O files"
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
        --sign "$DEVELOPER_ID" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    # Every nested Mach-O must carry the hardened runtime flag or notarization rejects the upload.
    while IFS= read -r -d '' f; do
        is_macho "$f" || continue
        codesign -dv "$f" 2>&1 | grep -q 'flags=.*runtime' || die "missing hardened runtime: $f"
    done < <(find "$APP/Contents" -type f -print0)
}

if [[ $MODE == developer-id ]]; then
    sign_developer_id
else
    step "Ad-hoc build (not notarized)"
    for m in "${missing[@]}"; do warn "missing $m"; done
    warn "the DMG will open on this Mac, but Gatekeeper blocks it elsewhere. See docs/RELEASE.md."
    codesign --verify --deep --strict "$APP" || { codesign --force --deep -s - "$APP"; codesign --verify --deep --strict "$APP"; }
fi

# --- DMG -----------------------------------------------------------------------------------------
step "Creating $DMG"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/kumquat-dmg.XXXXXX")"
MOUNT=""
cleanup() {
    [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
    rm -rf "$STAGE"
}
trap cleanup EXIT

ditto "$APP" "$STAGE/$APP_NAME.app"      # ditto keeps signatures, xattrs and symlinks intact
ln -s /Applications "$STAGE/Applications"
if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then   # custom volume icon
    cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
    SetFile -a C "$STAGE" 2>/dev/null || true
fi
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 -ov "$DMG" -quiet
hdiutil verify "$DMG" -quiet

if [[ $MODE == developer-id ]]; then
    step "Signing the DMG"
    codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
    step "Notarizing (xcrun notarytool submit --wait)"
    LOG="$ROOT/build/notarytool-$VERSION.json"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json | tee "$LOG"
    if ! grep -q '"status" *: *"Accepted"' "$LOG"; then
        id="$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' "$LOG" | head -1)"
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
        die "notarization was not accepted (see log above)"
    fi
    step "Stapling"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" || warn "spctl assessment failed"
fi

# --- verify --------------------------------------------------------------------------------------
if [[ $VERIFY -eq 1 ]]; then
    step "Verifying the DMG contents"
    MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/kumquat-mnt.XXXXXX")"
    hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" -quiet
    [[ -L "$MOUNT/Applications" ]] || die "Applications symlink missing in the DMG"
    codesign --verify --deep --strict --verbose=1 "$MOUNT/$APP_NAME.app"
    "$MOUNT/$APP_NAME.app/Contents/MacOS/$APP_NAME" --list >/dev/null || die "app inside the DMG doesn't run"
    [[ $MODE == developer-id ]] && spctl --assess --type execute --verbose=2 "$MOUNT/$APP_NAME.app"
    hdiutil detach "$MOUNT" -quiet
    rmdir "$MOUNT" 2>/dev/null || true
    MOUNT=""
fi

SIZE="$(du -h "$DMG" | cut -f1)"
step "Done: $DMG ($SIZE, $MODE)"
shasum -a 256 "$DMG"
