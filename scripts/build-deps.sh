#!/usr/bin/env bash
# Builds every third-party library the embedded toolchain needs from pinned, checksum-verified
# official source releases, for arm64 with a macOS 14.0 deployment target, into build/deps.
# Homebrew is only used for build tools (pkgconf, meson, ninja, cmake), never for libraries.
#
# Usage: scripts/build-deps.sh [--clean]
#   --clean   wipe build/deps and build/deps-src first
#
# Result: build/deps/{include,lib,lib/pkgconfig} with static libraries (opus, vpx, dav1d, SvtAv1Enc,
# webp, sharpyuv, png16, jpeg, lzma), libmp3lame as the only shared library (LGPL, kept replaceable),
# build/deps/bin/cwebp (self-contained) and build/deps/licenses/<project>/.
# zlib, bzip2 and iconv come from the macOS SDK. Called by scripts/build-ffmpeg.sh.
#
# Prerequisites: Command Line Tools and  brew install pkgconf meson ninja cmake
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/build/deps"
SRC_ROOT="$ROOT/build/deps-src"
MINOS="14.0"

for arg in "$@"; do
    case "$arg" in
        --clean) rm -rf "$DEPS" "$SRC_ROOT" ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

for tool in pkg-config meson ninja cmake; do
    command -v "$tool" >/dev/null || { echo "$tool missing: brew install pkgconf meson ninja cmake" >&2; exit 1; }
done

# name | version | official release URL | SHA-256 of the tarball
PACKAGES=(
    "xz|5.8.4|https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.gz|0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9"
    "lame|4.0|https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz|3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb"
    "opus|1.6.1|https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz|6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
    "libvpx|1.17.0|https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz|1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a"
    "dav1d|1.5.4|https://code.videolan.org/videolan/dav1d/-/archive/1.5.4/dav1d-1.5.4.tar.bz2|2abfb0c89212e6e4733a54e0ae509ec00a5b845a6360946f918806e14aedb011"
    "svt-av1|4.2.0|https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v4.2.0/SVT-AV1-v4.2.0.tar.bz2|512f2ea5649e3e76c2dddcc25c2556fb67a9582baaab207c9c96161c94659dad"
    "libpng|1.6.59|https://downloads.sourceforge.net/project/libpng/libpng16/1.6.59/libpng-1.6.59.tar.xz|d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389"
    "libjpeg-turbo|3.2.0|https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz|6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e"
    "libwebp|1.6.0|https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz|e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564"
)

# Toolchain: arm64, macOS 14.0, no Homebrew headers/libraries/pkg-config files.
export MACOSX_DEPLOYMENT_TARGET="$MINOS"
export CC=clang CXX=clang++
export CFLAGS="-arch arm64 -mmacosx-version-min=$MINOS -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-arch arm64 -mmacosx-version-min=$MINOS"
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
unset PKG_CONFIG_PATH CPATH C_INCLUDE_PATH LIBRARY_PATH
JOBS="$(sysctl -n hw.ncpu)"
CMAKE_COMMON=(
    -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINOS"
    -DCMAKE_PREFIX_PATH="$DEPS" -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
    -DCMAKE_FIND_FRAMEWORK=LAST -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
)

mkdir -p "$DEPS/lib/pkgconfig" "$DEPS/licenses" "$DEPS/.stamps" "$SRC_ROOT"

# fetch <name> -> sets SRC to the extracted, verified source directory
fetch() {
    local name="$1" spec ver url sha file dir
    for spec in "${PACKAGES[@]}"; do [[ "${spec%%|*}" == "$name" ]] && break; done
    IFS='|' read -r _ ver url sha <<<"$spec"
    file="$SRC_ROOT/$name-$ver.tarball"   # tar auto-detects gz/bz2/xz
    if [[ ! -f "$file" ]]; then
        echo "==> Downloading $url"
        curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 30 --retry 5 --retry-all-errors -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    local actual; actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [[ "$actual" != "$sha" ]]; then
        echo "Checksum mismatch for $file: $actual (want $sha)" >&2; rm -f "$file"; exit 1
    fi
    echo "==> $name $ver (sha256 $sha OK)"
    dir="$SRC_ROOT/$name-$ver"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir.tmp"
        tar -xf "$file" -C "$dir.tmp" --strip-components 1
        mv "$dir.tmp" "$dir"
    fi
    SRC="$dir"; VER="$ver"
}

# stamp <name>: marker that this exact version is installed (delete it to force a rebuild)
stamp() { echo "$DEPS/.stamps/$1-$VER"; }
licenses() { local name="$1"; shift; mkdir -p "$DEPS/licenses/$name"; for f in "$@"; do cp "$SRC/$f" "$DEPS/licenses/$name/"; done; }

build_xz() {
    fetch xz; [[ -f "$(stamp xz)" ]] && return
    rm -rf "$SRC/_build"; mkdir "$SRC/_build"; cd "$SRC/_build"
    ../configure --prefix="$DEPS" --disable-shared --enable-static --disable-xz --disable-xzdec \
        --disable-lzmadec --disable-lzmainfo --disable-lzma-links --disable-scripts --disable-doc --disable-nls
    make -j"$JOBS" && make install
    licenses xz COPYING COPYING.0BSD; touch "$(stamp xz)"
}

build_lame() {
    # LGPL: kept as a shared library so the bundled copy stays replaceable by the user.
    fetch lame; [[ -f "$(stamp lame)" ]] && return
    rm -rf "$SRC/_build"; mkdir "$SRC/_build"; cd "$SRC/_build"
    ../configure --prefix="$DEPS" --enable-shared --disable-static --disable-frontend --disable-decoder \
        --disable-gtktest --disable-nasm
    make -j"$JOBS" && make install
    licenses lame COPYING LICENSE; touch "$(stamp lame)"
}

build_opus() {
    fetch opus; [[ -f "$(stamp opus)" ]] && return
    rm -rf "$SRC/_build"; mkdir "$SRC/_build"; cd "$SRC/_build"
    ../configure --prefix="$DEPS" --disable-shared --enable-static --disable-doc --disable-extra-programs
    make -j"$JOBS" && make install
    licenses opus COPYING; touch "$(stamp opus)"
}

build_libvpx() {
    fetch libvpx; [[ -f "$(stamp libvpx)" ]] && return
    rm -rf "$SRC/_build"; mkdir "$SRC/_build"; cd "$SRC/_build"
    # libvpx's darwin targets inject their own -mmacosx-version-min; the generic one + extra flags keeps ours.
    ../configure --prefix="$DEPS" --target=arm64-darwin23-gcc --enable-static --disable-shared --enable-pic \
        --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth --disable-examples --disable-tools --disable-docs \
        --disable-unit-tests --disable-install-bins --disable-install-docs \
        --extra-cflags="-mmacosx-version-min=$MINOS" --extra-cxxflags="-mmacosx-version-min=$MINOS"
    make -j"$JOBS" && make install
    licenses libvpx LICENSE PATENTS AUTHORS; touch "$(stamp libvpx)"
}

build_dav1d() {
    fetch dav1d; [[ -f "$(stamp dav1d)" ]] && return
    rm -rf "$SRC/_build"; cd "$SRC"
    meson setup _build --prefix="$DEPS" --libdir=lib --buildtype=release --default-library=static \
        -Denable_tools=false -Denable_tests=false -Denable_examples=false
    ninja -C _build && ninja -C _build install
    licenses dav1d COPYING; touch "$(stamp dav1d)"
}

build_svtav1() {
    fetch svt-av1; [[ -f "$(stamp svt-av1)" ]] && return
    rm -rf "$SRC/_build"; cd "$SRC"
    cmake -S . -B _build "${CMAKE_COMMON[@]}" -DBUILD_APPS=OFF -DBUILD_TESTING=OFF -DBUILD_DEC=OFF
    cmake --build _build -j"$JOBS" && cmake --install _build
    licenses svt-av1 LICENSE.md PATENTS.md; touch "$(stamp svt-av1)"
}

build_libpng() {
    fetch libpng; [[ -f "$(stamp libpng)" ]] && return
    rm -rf "$SRC/_build"; mkdir "$SRC/_build"; cd "$SRC/_build"
    ../configure --prefix="$DEPS" --disable-shared --enable-static --disable-tools
    make -j"$JOBS" && make install
    licenses libpng LICENSE; touch "$(stamp libpng)"
}

build_jpeg() {
    fetch libjpeg-turbo; [[ -f "$(stamp libjpeg-turbo)" ]] && return
    rm -rf "$SRC/_build"; cd "$SRC"
    cmake -S . -B _build "${CMAKE_COMMON[@]}" -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF
    cmake --build _build -j"$JOBS" && cmake --install _build
    licenses libjpeg-turbo LICENSE.md README.ijg; touch "$(stamp libjpeg-turbo)"
}

build_libwebp() {
    fetch libwebp; [[ -f "$(stamp libwebp)" ]] && return
    rm -rf "$SRC/_build"; cd "$SRC"
    cmake -S . -B _build "${CMAKE_COMMON[@]}" -DWEBP_BUILD_CWEBP=ON -DWEBP_BUILD_DWEBP=OFF \
        -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF \
        -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_LIBWEBPMUX=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_TIFF=ON -DCMAKE_DISABLE_FIND_PACKAGE_GIF=ON \
        -DPNG_PNG_INCLUDE_DIR="$DEPS/include" -DPNG_LIBRARY="$DEPS/lib/libpng16.a" \
        -DJPEG_INCLUDE_DIR="$DEPS/include" -DJPEG_LIBRARY="$DEPS/lib/libjpeg.a"
    cmake --build _build -j"$JOBS" && cmake --install _build
    licenses libwebp COPYING PATENTS; touch "$(stamp libwebp)"
}

build_xz
build_lame
build_opus
build_libvpx
build_dav1d
build_svtav1
build_libpng
build_jpeg
build_libwebp

# Nothing in the prefix may depend on Homebrew or target a newer macOS than $MINOS.
echo "==> Verifying build/deps"
fail=0
check_macho() {
    local f="$1" v
    for v in $(otool -l "$f" | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; b=0}' | sort -u); do
        [[ "$(printf '%s\n%s\n' "$v" "$MINOS" | sort -V | tail -1)" == "$MINOS" ]] || { echo "  $f: minos $v > $MINOS" >&2; fail=1; }
    done
}
for f in "$DEPS"/lib/*.a "$DEPS"/lib/*.dylib "$DEPS/bin/cwebp"; do [[ -L "$f" ]] || check_macho "$f"; done
if otool -L "$DEPS/bin/cwebp" "$DEPS"/lib/*.dylib | grep -E '/(opt/homebrew|usr/local)/'; then
    echo "Homebrew library referenced" >&2; fail=1
fi
[[ $fail -eq 0 ]] || exit 1
otool -L "$DEPS/bin/cwebp" | tail -n +2
echo "Done: $DEPS"
