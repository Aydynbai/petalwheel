#!/usr/bin/env bash
# Builds Petalwheel in release mode and assembles an ad-hoc signed build/Petalwheel.app.
#
# Usage: scripts/build-app.sh [--install] [--no-tools]
#   --install   also copy the app to ~/Applications
#   --no-tools  don't embed ffmpeg/ffprobe/cwebp (the app then falls back to Homebrew)
#   --lgpl      embed the LGPL ffmpeg from build/ffmpeg-lgpl, building it first if needed
#               (used automatically whenever build/ffmpeg-lgpl/bin/ffmpeg exists)
#   --homebrew-ffmpeg  embed Homebrew's (GPL) ffmpeg even if the LGPL build exists
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

INSTALL=0
TOOLS=1
LGPL=auto
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --no-tools) TOOLS=0 ;;
        --lgpl) LGPL=1 ;;
        --homebrew-ffmpeg) LGPL=0 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

APP_NAME="NurTo"
BUNDLE_ID="app.nurto.mac"
VERSION="1.3.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
APP="$ROOT/build/$APP_NAME.app"

echo "==> swift build -c release --arch arm64"
swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
BIN="$BIN_DIR/Petalwheel"
[[ -x "$BIN" ]] || { echo "Binary not found at $BIN" >&2; exit 1; }

ICON="$ROOT/Resources/NurTo.icns"
if [[ ! -f "$ICON" ]]; then
    echo "==> Generating app icon"
    swift "$ROOT/scripts/make-icon.swift" "$ICON"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
# Localizations (en, ru): Localizable/Errors/InfoPlist/ServicesMenu .strings. Checked by scripts/check-l10n.py.
for lproj in "$ROOT"/Resources/*.lproj; do
    [[ -d "$lproj" ]] || continue
    for f in "$lproj"/*.strings; do plutil -lint -s "$f"; done
    cp -R "$lproj" "$APP/Contents/Resources/"
done

if [[ $TOOLS -eq 1 ]]; then
    LGPL_DIR="$ROOT/build/ffmpeg-lgpl"
    [[ $LGPL == 1 && ! -x "$LGPL_DIR/bin/ffmpeg" ]] && "$ROOT/scripts/build-ffmpeg.sh"
    if [[ $LGPL != 0 && -x "$LGPL_DIR/bin/ffmpeg" ]]; then
        echo "==> Embedding LGPL ffmpeg, ffprobe ($LGPL_DIR) and cwebp (build/deps, else Homebrew)"
        python3 -I "$ROOT/scripts/bundle-tools.py" --ffmpeg-dir "$LGPL_DIR" "$APP/Contents/Resources/Tools"
    else
        echo "==> Embedding ffmpeg, ffprobe, cwebp (from Homebrew: brew install ffmpeg webp)"
        python3 -I "$ROOT/scripts/bundle-tools.py" "$APP/Contents/Resources/Tools"
    fi
fi

# Copy any SwiftPM resource bundles (none today, but harmless if added later).
for bundle in "$BIN_DIR"/*.bundle; do
    [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>ru</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 kipperstudio</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>NurTo reads the files selected in Finder when you press its global shortcut, so it can open the conversion wheel for them.</string>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>NurTo: Open in Wheel</string></dict>
            <key>NSMessage</key>
            <string>openInWheel</string>
            <key>NSPortName</key>
            <string>NurTo</string>
            <key>NSRequiredContext</key>
            <dict/>
            <key>NSSendTypes</key>
            <array>
                <string>NSFilenamesPboardType</string>
                <string>public.file-url</string>
            </array>
            <key>NSSendFileTypes</key>
            <array>
                <string>public.item</string>
            </array>
        </dict>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>NurTo: Convert to JPG</string></dict>
            <key>NSMessage</key>
            <string>convertToJPG</string>
            <key>NSPortName</key>
            <string>NurTo</string>
            <key>NSRequiredContext</key>
            <dict/>
            <key>NSSendTypes</key>
            <array>
                <string>NSFilenamesPboardType</string>
                <string>public.file-url</string>
            </array>
            <key>NSSendFileTypes</key>
            <array>
                <string>public.image</string>
                <string>com.adobe.pdf</string>
            </array>
        </dict>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>NurTo: Compress</string></dict>
            <key>NSMessage</key>
            <string>compress</string>
            <key>NSPortName</key>
            <string>NurTo</string>
            <key>NSRequiredContext</key>
            <dict/>
            <key>NSSendTypes</key>
            <array>
                <string>NSFilenamesPboardType</string>
                <string>public.file-url</string>
            </array>
            <key>NSSendFileTypes</key>
            <array>
                <string>public.image</string>
                <string>com.adobe.pdf</string>
                <string>public.audiovisual-content</string>
            </array>
        </dict>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>NurTo: Convert to MP4</string></dict>
            <key>NSMessage</key>
            <string>convertToMP4</string>
            <key>NSPortName</key>
            <string>NurTo</string>
            <key>NSRequiredContext</key>
            <dict/>
            <key>NSSendTypes</key>
            <array>
                <string>NSFilenamesPboardType</string>
                <string>public.file-url</string>
            </array>
            <key>NSSendFileTypes</key>
            <array>
                <string>public.movie</string>
                <string>com.compuserve.gif</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing (ad-hoc)"
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"

if [[ $INSTALL -eq 1 ]]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    echo "==> Installing to $DEST/$APP_NAME.app"
    rm -rf "$DEST/$APP_NAME.app"
    cp -R "$APP" "$DEST/"
fi

echo "Done: $APP"
