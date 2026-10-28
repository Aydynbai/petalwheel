#!/usr/bin/env bash
# Builds an LGPL-only ffmpeg/ffprobe (no --enable-gpl, no x264/x265, no nonfree) for Apple Silicon
# from the official source release, linked against codec libraries built from source by
# scripts/build-deps.sh (build/deps), everything targeting macOS 14.0.
#
# Usage: scripts/build-ffmpeg.sh [--clean]
#   --clean   wipe build/ffmpeg-src and build/ffmpeg-lgpl first (and build/deps, build/deps-src)
#
# Result: build/ffmpeg-lgpl/{bin,lib} (ffmpeg, ffprobe + shared libav* dylibs). The codec libraries
# are linked statically, except LGPL libmp3lame which stays a dylib. Like FFmpeg's own LGPL libraries
# it remains user-replaceable. scripts/build-app.sh embeds the result automatically when
# build/ffmpeg-lgpl/bin/ffmpeg exists.
# H.264/HEVC encoding comes from VideoToolbox (h264_videotoolbox / hevc_videotoolbox).
#
# Prerequisites: Command Line Tools and  brew install pkgconf meson ninja cmake
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FFMPEG_VERSION="9.0.2"
TARBALL="ffmpeg-$FFMPEG_VERSION.tar.xz"
URL="https://ffmpeg.org/releases/$TARBALL"
# Pinned checksum of the official release tarball (matches Homebrew's ffmpeg formula for 9.0.2).
SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
SIZE=12040788

SRC_ROOT="$ROOT/build/ffmpeg-src"
SRC="$SRC_ROOT/ffmpeg-$FFMPEG_VERSION"
PREFIX="$ROOT/build/ffmpeg-lgpl"
DEPS="$ROOT/build/deps"
MINOS="14.0"
DEPS_ARGS=()

for arg in "$@"; do
    case "$arg" in
        --clean) rm -rf "$SRC_ROOT" "$PREFIX"; DEPS_ARGS=(--clean) ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

"$ROOT/scripts/build-deps.sh" ${DEPS_ARGS[@]+"${DEPS_ARGS[@]}"}

# Only build/deps may provide libraries: no Homebrew pkg-config files, headers or libraries.
export MACOSX_DEPLOYMENT_TARGET="$MINOS"
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
unset PKG_CONFIG_PATH CPATH C_INCLUDE_PATH LIBRARY_PATH
for pc in opus vpx dav1d SvtAv1Enc libwebp liblzma; do
    pkg-config --exists "$pc" || { echo "Missing $pc in $DEPS (scripts/build-deps.sh failed?)" >&2; exit 1; }
done
[[ -f "$DEPS/include/lame/lame.h" ]] || { echo "Missing lame in $DEPS" >&2; exit 1; }

mkdir -p "$SRC_ROOT"
if [[ ! -f "$SRC_ROOT/$TARBALL" ]]; then
    echo "==> Downloading $URL"
    curl -fL --proto '=https' --tlsv1.2 -o "$SRC_ROOT/$TARBALL.part" "$URL"
    mv "$SRC_ROOT/$TARBALL.part" "$SRC_ROOT/$TARBALL"
fi

echo "==> Verifying $TARBALL"
actual_size="$(stat -f %z "$SRC_ROOT/$TARBALL")"
actual_sha="$(shasum -a 256 "$SRC_ROOT/$TARBALL" | awk '{print $1}')"
if [[ "$actual_size" != "$SIZE" || "$actual_sha" != "$SHA256" ]]; then
    echo "Checksum mismatch: size $actual_size (want $SIZE), sha256 $actual_sha (want $SHA256)" >&2
    rm -f "$SRC_ROOT/$TARBALL"
    exit 1
fi

if [[ ! -f "$SRC/configure" ]]; then
    echo "==> Extracting"
    tar -xJf "$SRC_ROOT/$TARBALL" -C "$SRC_ROOT"
fi

CONFIGURE_FLAGS=(
    --prefix="$PREFIX"
    --cc=clang
    --arch=arm64
    # FFmpeg's own libraries stay shared (LGPL: user-replaceable); codec deps are static archives.
    --enable-shared --disable-static
    --pkg-config-flags=--static
    --enable-pthreads
    --disable-autodetect
    # Licensing: LGPL only. (No --enable-gpl, --enable-nonfree, x264 or x265.)
    --disable-gpl --disable-nonfree
    # Programs and docs
    --disable-ffplay --disable-doc
    --disable-indevs --enable-indev=lavfi --disable-outdevs
    # No network: only local file and pipe I/O
    --disable-network --disable-protocols --enable-protocol=file,pipe
    # Apple frameworks
    --enable-videotoolbox --enable-audiotoolbox
    --enable-zlib --enable-bzlib --enable-lzma --enable-iconv
    # Codec libraries from build/deps (scripts/build-deps.sh)
    --enable-libmp3lame --enable-libopus --enable-libvpx --enable-libdav1d
    --enable-libsvtav1 --enable-libwebp
    --extra-cflags="-I$DEPS/include -mmacosx-version-min=$MINOS"
    --extra-ldflags="-L$DEPS/lib -mmacosx-version-min=$MINOS"
    --extra-libs=-liconv
    --extra-version=petalwheel-lgpl
)

echo "==> Configuring ffmpeg $FFMPEG_VERSION"
cd "$SRC"
./configure "${CONFIGURE_FLAGS[@]}" | tee "$SRC_ROOT/configure.log"

echo "==> Building"
make -j"$(sysctl -n hw.ncpu)"
rm -rf "$PREFIX"
make install

# Licenses travel with the build so bundle-tools.py can embed them.
mkdir -p "$PREFIX/licenses"
cp "$SRC/COPYING.LGPLv2.1" "$SRC/COPYING.LGPLv3" "$SRC/LICENSE.md" "$PREFIX/licenses/"

echo "==> Verifying license"
export DYLD_LIBRARY_PATH="$PREFIX/lib:$DEPS/lib"
LICENSE_TEXT="$("$PREFIX/bin/ffmpeg" -hide_banner -L | head -3)"
echo "$LICENSE_TEXT"
if "$PREFIX/bin/ffmpeg" -hide_banner -buildconf | grep -Eq -- '--enable-(gpl|nonfree|libx264|libx265)'; then
    echo "GPL/nonfree option found in -buildconf" >&2; exit 1
fi
echo "$LICENSE_TEXT" | grep -q "Lesser General Public" || { echo "ffmpeg -L is not LGPL" >&2; exit 1; }
"$PREFIX/bin/ffmpeg" -hide_banner -loglevel error -f lavfi -i anullsrc=d=0.1 -f null - || { echo "lavfi input missing" >&2; exit 1; }
for enc in h264_videotoolbox hevc_videotoolbox aac_at libmp3lame libopus libvpx-vp9 libsvtav1 libwebp flac gif; do
    "$PREFIX/bin/ffmpeg" -hide_banner -h encoder="$enc" | grep -q "^Encoder $enc" || { echo "Encoder $enc missing" >&2; exit 1; }
done
for dec in libdav1d; do
    "$PREFIX/bin/ffmpeg" -hide_banner -h decoder="$dec" | grep -q "^Decoder $dec" || { echo "Decoder $dec missing" >&2; exit 1; }
done
for flt in palettegen paletteuse loudnorm silencedetect showwaves anullsrc; do
    "$PREFIX/bin/ffmpeg" -hide_banner -h filter="$flt" | grep -q "^Filter $flt" || { echo "Filter $flt missing" >&2; exit 1; }
done
# Only system libraries, libav* and libmp3lame may be linked dynamically.
if otool -L "$PREFIX"/bin/ff* "$PREFIX"/lib/*.dylib | grep -E '^\s' | grep -vE '(/usr/lib/|/System/|/libav|/libsw|/libmp3lame)'; then
    echo "Unexpected dynamic dependency (see above)" >&2; exit 1
fi
echo "Done: $PREFIX/bin/ffmpeg ($("$PREFIX/bin/ffmpeg" -version | head -1))"
