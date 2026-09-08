#!/usr/bin/env bash
# Builds static ffmpeg + ffprobe for macOS (Apple silicon) from pinned upstream sources.
#
#   ffmpeg/build.sh          # everything: fetch, build every library, build ffmpeg, check, package
#   ffmpeg/build.sh x265     # a single step: fetch x264 x265 libvpx dav1d ogg vorbis opus lame ffmpeg check package
#
# Output goes to dist/ffmpeg/ (see README.md); intermediate files live in work/ffmpeg/.
# Everything below the "pinned versions" block is mechanism. To upgrade anything, only that block changes.
set -euo pipefail

# ---- pinned versions ------------------------------------------------------------------
FFMPEG_VERSION="9.0.1"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
FFMPEG_SHA256="cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"

X264_GIT="https://code.videolan.org/videolan/x264.git"
X264_COMMIT="b35605ace3ddf7c1a5d67a2eb553f034aef41d55" # head of the "stable" branch, 2026-09-07

X265_VERSION="4.2"
X265_URL="https://bitbucket.org/multicoreware/x265_git/downloads/x265_$X265_VERSION.tar.gz"
X265_SHA256="40b1ea0453e0309f0eba934e0ddf533f8f6295966679e8894e8f1c1c8d5e1210"

LIBVPX_VERSION="1.17.0"
LIBVPX_GIT="https://github.com/webmproject/libvpx.git"
LIBVPX_COMMIT="6df3ec34557879fff673706f4a1d9fbd0f3a6f0e" # tag v1.17.0

DAV1D_VERSION="1.5.4"
DAV1D_URL="https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz"
DAV1D_SHA256="686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5"

OPUS_VERSION="1.6.1"
OPUS_URL="https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz"
OPUS_SHA256="6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"

OGG_VERSION="1.3.6"
OGG_URL="https://downloads.xiph.org/releases/ogg/libogg-$OGG_VERSION.tar.xz"
OGG_SHA256="5c8253428e181840cd20d41f3ca16557a9cc04bad4a3d04cce84808677fa1061"

VORBIS_VERSION="1.3.7"
VORBIS_URL="https://downloads.xiph.org/releases/vorbis/libvorbis-$VORBIS_VERSION.tar.xz"
VORBIS_SHA256="b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b"

LAME_VERSION="3.100"
LAME_URL="https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
LAME_SHA256="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"

MACOS_MIN="12.0" # oldest macOS the binaries run on; keep in sync with the app's LSMinimumSystemVersion
ARCH="arm64"
# ---------------------------------------------------------------------------------------

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/work/ffmpeg"
DOWNLOADS="$WORK/downloads"
SRC="$WORK/src"
PREFIX="$WORK/prefix" # static libraries land here
OUT="$WORK/out"       # ffmpeg's own install prefix
LOGS="$WORK/logs"
DIST="$ROOT/dist/ffmpeg"
JOBS="$(sysctl -n hw.ncpu)"
mkdir -p "$DOWNLOADS" "$SRC" "$PREFIX" "$LOGS"

export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"
export CC=clang CXX=clang++
export CFLAGS="-arch $ARCH -mmacosx-version-min=$MACOS_MIN -O2 -fPIC -I$PREFIX/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-arch $ARCH -mmacosx-version-min=$MACOS_MIN -L$PREFIX/lib"
# Only our own prefix is visible to pkg-config, so nothing installed by Homebrew can leak in.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH

FFMPEG_CONFIGURE=(
  --prefix="$OUT"
  --arch="$ARCH" --cc=clang
  --enable-gpl
  --enable-static --disable-shared
  --pkg-config-flags=--static
  --extra-cflags="-I$PREFIX/include"
  --extra-ldflags="-L$PREFIX/lib"
  --extra-libs=-lc++ # x265 is C++
  --enable-libx264 --enable-libx265 --enable-libvpx --enable-libdav1d
  --enable-libopus --enable-libvorbis --enable-libmp3lame
  --enable-videotoolbox --enable-audiotoolbox
  --disable-sdl2 --disable-ffplay --disable-doc --disable-debug
)

# ---- helpers ---------------------------------------------------------------------------

log() { printf '\n==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required: brew install $2"; }
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Download (if needed) and verify one tarball; prints its path.
fetch_tarball() { # url expected-sha256
  local url=$1 expected=$2 file="$DOWNLOADS/$(basename "$1")" actual
  [ -n "$expected" ] || die "no SHA-256 pinned for $url"
  if [ ! -f "$file" ] || [ "$(sha256 "$file")" != "$expected" ]; then
    log "downloading $(basename "$url")"
    curl -fL --retry 3 -o "$file.tmp" "$url"
    mv "$file.tmp" "$file"
  fi
  actual=$(sha256 "$file")
  [ "$actual" = "$expected" ] || die "SHA-256 mismatch for $file: expected $expected, got $actual"
  echo "$file"
}

# Fresh extraction of a tarball into a directory, dropping the top-level folder.
extract() { # tarball dest
  rm -rf "$2"
  mkdir -p "$2"
  tar -xf "$1" -C "$2" --strip-components=1
}

# Check out exactly one commit (no branch or tag can move it later).
fetch_git() { # name url commit
  local name=$1 url=$2 commit=$3 dir="$SRC/$1"
  [ -n "$commit" ] || die "no commit pinned for $name"
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ]; then
    return
  fi
  log "cloning $name @ $commit"
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$url"
  git -C "$dir" fetch -q --depth 1 origin "$commit"
  git -C "$dir" checkout -q FETCH_HEAD
  [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || die "$name: checked-out commit is not $commit"
}

# Run a build function in a subshell with its output in a log file; show the tail on failure.
run_logged() { # name function
  local name=$1 status
  log "building $name  (log: work/ffmpeg/logs/$name.log)"
  set +e
  ( set -e; "$2" ) >"$LOGS/$name.log" 2>&1
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    echo "--- $name failed (exit $status); last 60 lines of $LOGS/$name.log ---" >&2
    tail -60 "$LOGS/$name.log" >&2
    if [ "$name" = ffmpeg ] && [ -f "$SRC/ffmpeg/ffbuild/config.log" ]; then
      echo "--- last 40 lines of ffbuild/config.log ---" >&2
      tail -40 "$SRC/ffmpeg/ffbuild/config.log" >&2
    fi
    exit 1
  fi
}

built() { [ -f "$PREFIX/.built-$1" ]; }

# Build one library unless a stamp says this exact version is already in $PREFIX.
lib() { # name version build-function
  [ -d "$SRC/$1" ] || die "no source for $1 in work/ffmpeg/src: run 'ffmpeg/build.sh fetch' first"
  if built "$1-$2"; then
    log "$1 $2 already built, skipping"
    return
  fi
  run_logged "$1" "$3"
  touch "$PREFIX/.built-$1-$2"
}

# ---- steps ------------------------------------------------------------------------------

step_fetch() {
  need cmake cmake; need meson meson; need ninja ninja; need pkg-config pkgconf
  extract "$(fetch_tarball "$FFMPEG_URL" "$FFMPEG_SHA256")" "$SRC/ffmpeg"
  extract "$(fetch_tarball "$X265_URL" "$X265_SHA256")" "$SRC/x265"
  extract "$(fetch_tarball "$DAV1D_URL" "$DAV1D_SHA256")" "$SRC/dav1d"
  extract "$(fetch_tarball "$OPUS_URL" "$OPUS_SHA256")" "$SRC/opus"
  extract "$(fetch_tarball "$OGG_URL" "$OGG_SHA256")" "$SRC/ogg"
  extract "$(fetch_tarball "$VORBIS_URL" "$VORBIS_SHA256")" "$SRC/vorbis"
  extract "$(fetch_tarball "$LAME_URL" "$LAME_SHA256")" "$SRC/lame"
  fetch_git x264 "$X264_GIT" "$X264_COMMIT"
  fetch_git libvpx "$LIBVPX_GIT" "$LIBVPX_COMMIT"
  log "all sources fetched and verified"
}

build_x264() {
  cd "$SRC/x264"
  ./configure --prefix="$PREFIX" --enable-static --disable-shared --enable-pic \
    --disable-cli --disable-lavf --disable-swscale --disable-avs --disable-ffms --disable-gpac --disable-lsmash \
    --bit-depth=all --chroma-format=all
  make -j"$JOBS"
  make install
}

build_x265() {
  cd "$SRC/x265"
  # 8-bit only for now; 10/12-bit needs x265's three-way multilib build.
  cmake -S source -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_PIC=ON \
    -DENABLE_SVE=OFF -DENABLE_SVE2=OFF
  ninja -C build
  ninja -C build install
}

build_libvpx() {
  cd "$SRC/libvpx"
  ./configure --prefix="$PREFIX" --target=arm64-darwin21-gcc \
    --disable-shared --enable-static --enable-pic \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests \
    --enable-vp9-highbitdepth
  make -j"$JOBS"
  make install
}

build_dav1d() {
  cd "$SRC/dav1d"
  meson setup build --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static \
    -Denable_tools=false -Denable_tests=false -Denable_examples=false
  ninja -C build
  ninja -C build install
}

build_ogg() {
  cd "$SRC/ogg"
  ./configure --prefix="$PREFIX" --disable-shared --enable-static
  make -j"$JOBS"
  make install
}

build_vorbis() {
  cd "$SRC/vorbis"
  # Its configure adds -force_cpusubtype_ALL on Darwin; Xcode 26's linker rejects that flag.
  find . \( -name configure -o -name Makefile.in \) -exec sed -i '' 's/-force_cpusubtype_ALL//g' {} +
  ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-docs --disable-examples --disable-oggtest
  make -j"$JOBS"
  make install
}

build_opus() {
  cd "$SRC/opus"
  ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-doc --disable-extra-programs
  make -j"$JOBS"
  make install
}

build_lame() {
  cd "$SRC/lame"
  # The export list names lame_init_old, which no longer exists; it breaks the link on macOS.
  sed -i '' '/lame_init_old/d' include/libmp3lame.sym
  ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-frontend --disable-gtktest --disable-decoder
  make -j"$JOBS"
  make install
}

build_ffmpeg() {
  cd "$SRC/ffmpeg"
  rm -rf "$OUT"
  ./configure "${FFMPEG_CONFIGURE[@]}"
  make -j"$JOBS"
  make install
}

step_check() {
  local bin deps bad tmp
  log "checking the binaries"
  for bin in ffmpeg ffprobe; do
    deps=$(otool -L "$OUT/bin/$bin" | tail -n +2 | awk '{print $1}')
    bad=$(printf '%s\n' "$deps" | grep -vE '^(/usr/lib/|/System/Library/)' || true)
    [ -z "$bad" ] || die "$bin links libraries that are not part of macOS:
$bad"
    printf '  %s %s, %s dynamic libraries, all from macOS\n' "$bin" \
      "$("$OUT/bin/$bin" -version | head -1 | cut -d' ' -f3)" "$(printf '%s\n' "$deps" | wc -l | tr -d ' ')"
  done
  local encoders decoders e d
  encoders=$("$OUT/bin/ffmpeg" -hide_banner -encoders 2>/dev/null)
  decoders=$("$OUT/bin/ffmpeg" -hide_banner -decoders 2>/dev/null)
  for e in libx264 libx265 libvpx libvpx-vp9 libopus libvorbis libmp3lame aac h264_videotoolbox hevc_videotoolbox; do
    printf '%s\n' "$encoders" | grep -qw "$e" || die "encoder $e is missing"
  done
  for d in libdav1d h264 hevc vp9 aac mp3 opus vorbis; do
    printf '%s\n' "$decoders" | grep -qw "$d" || die "decoder $d is missing"
  done
  echo "  all expected encoders and decoders present"
  # Smoke test: one second of test video + tone through x264/aac, probe it, then x265 and vp9.
  tmp=$(mktemp -d)
  "$OUT/bin/ffmpeg" -hide_banner -loglevel error -y \
    -f lavfi -i testsrc2=size=320x240:rate=30:duration=1 -f lavfi -i sine=frequency=440:duration=1 \
    -c:v libx264 -preset ultrafast -c:a aac "$tmp/test.mp4"
  printf '  probe: %s\n' "$("$OUT/bin/ffprobe" -v error -show_entries stream=codec_name -of csv=p=0 "$tmp/test.mp4" | tr '\n' ' ')"
  "$OUT/bin/ffmpeg" -hide_banner -loglevel error -i "$tmp/test.mp4" -c:v libx265 -preset ultrafast -f null -
  "$OUT/bin/ffmpeg" -hide_banner -loglevel error -i "$tmp/test.mp4" -c:v libvpx-vp9 -deadline realtime -f null -
  rm -rf "$tmp"
  echo "  smoke test passed"
}

write_build_info() {
  cat <<INFO
ffmpeg $FFMPEG_VERSION, static build for macOS $ARCH (runs on macOS $MACOS_MIN and newer)
built $(date -u +%Y-%m-%dT%H:%M:%SZ) on macOS $(sw_vers -productVersion), $(xcodebuild -version 2>/dev/null | head -1 | tr -d '\n'), $(clang --version | head -1)
license: GPL v2 or later (--enable-gpl; no nonfree components)

libraries (all statically linked):
  x264     git $X264_COMMIT (stable branch)
  x265     $X265_VERSION (8-bit)
  libvpx   $LIBVPX_VERSION (git $LIBVPX_COMMIT)
  dav1d    $DAV1D_VERSION
  opus     $OPUS_VERSION
  libogg   $OGG_VERSION
  libvorbis $VORBIS_VERSION
  lame     $LAME_VERSION
  VideoToolbox / AudioToolbox from the macOS SDK

configure:
  ./configure ${FFMPEG_CONFIGURE[*]}
INFO
}

step_package() {
  local name="ffmpeg-$FFMPEG_VERSION-macos-$ARCH" stage="$WORK/stage" url
  rm -rf "$DIST" "$stage"
  mkdir -p "$DIST/sources" "$stage"
  cp "$OUT/bin/ffmpeg" "$OUT/bin/ffprobe" "$SRC/ffmpeg/COPYING.GPLv2" "$stage/"
  write_build_info > "$stage/BUILD-INFO.txt"
  cp "$stage/BUILD-INFO.txt" "$DIST/"
  tar -czf "$DIST/$name.tar.gz" -C "$stage" ffmpeg ffprobe COPYING.GPLv2 BUILD-INFO.txt
  # Ship exactly the sources that were built, as the GPL asks.
  for url in "$FFMPEG_URL" "$X265_URL" "$DAV1D_URL" "$OPUS_URL" "$OGG_URL" "$VORBIS_URL" "$LAME_URL"; do
    cp "$DOWNLOADS/$(basename "$url")" "$DIST/sources/"
  done
  git -C "$SRC/x264" archive --format=tar.gz --prefix="x264-$X264_COMMIT/" -o "$DIST/sources/x264-$X264_COMMIT.tar.gz" HEAD
  git -C "$SRC/libvpx" archive --format=tar.gz --prefix="libvpx-$LIBVPX_VERSION/" -o "$DIST/sources/libvpx-$LIBVPX_VERSION.tar.gz" HEAD
  (cd "$DIST" && shasum -a 256 "$name.tar.gz" sources/* > SHA256SUMS)
  log "done: $DIST"
  ls -la "$DIST" | tail -n +2 | awk '{print "  " $NF, $5}'
  cat "$DIST/SHA256SUMS" | head -1
}

# ---- main --------------------------------------------------------------------------------

ALL_STEPS="fetch x264 x265 libvpx dav1d ogg vorbis opus lame ffmpeg check package"
for step in ${*:-$ALL_STEPS}; do
  case $step in
    fetch)   step_fetch ;;
    x264)    lib x264   "$X264_COMMIT"    build_x264 ;;
    x265)    lib x265   "$X265_VERSION"   build_x265 ;;
    libvpx)  lib libvpx "$LIBVPX_VERSION" build_libvpx ;;
    dav1d)   lib dav1d  "$DAV1D_VERSION"  build_dav1d ;;
    ogg)     lib ogg    "$OGG_VERSION"    build_ogg ;;
    vorbis)  lib vorbis "$VORBIS_VERSION" build_vorbis ;;
    opus)    lib opus   "$OPUS_VERSION"   build_opus ;;
    lame)    lib lame   "$LAME_VERSION"   build_lame ;;
    ffmpeg)  run_logged ffmpeg build_ffmpeg ;;
    check)   step_check ;;
    package) step_package ;;
    *) die "unknown step: $step (valid: $ALL_STEPS)" ;;
  esac
done
