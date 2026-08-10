#!/bin/bash
# Cross-compile mpv for Windows inside the ci/docker image, so no toolchain has
# to be installed on the host. See DOCS/compile-windows.md for how to run it.
#
# Expects three mounts:
#   /src    the mpv source tree, read-only
#   /out    where mpv.exe and its DLLs are written
#   /build  a persistent volume for the working tree and the ccache
#
# /build is what makes a second attempt cheap: ci/build-mingw64.sh marks each
# finished dependency in the prefix, so a re-run resumes instead of rebuilding
# ffmpeg from scratch.
set -eo pipefail

export TARGET=${TARGET:-x86_64-w64-mingw32}
export RUST_TARGET=${RUST_TARGET:-x86_64-pc-windows-gnu}
export DOWNLOAD_CACHE=/build/cache
export CCACHE_DIR=/build/ccache
# subrandr renders SRV3 and WebVTT subtitles and is an optional "auto" feature.
# Its upstream xtask currently fails to produce an import library when
# cross-compiling; set SKIP_SUBRANDR=0 once that is fixed upstream.
SKIP_SUBRANDR=${SKIP_SUBRANDR:-1}
mkdir -p "$DOWNLOAD_CACHE" "$CCACHE_DIR"

echo "=== [1/5] source tree ==="
if [ -d /build/mpv/.git ]; then
    echo "reusing the existing build tree"
    rsync -a --exclude=mingw_prefix --exclude=mingw_build /src/ /build/mpv/
else
    cp -a /src /build/mpv
fi
cd /build/mpv

# A checkout made on Windows with core.autocrlf=true arrives with CRLF endings,
# which turns "#!/bin/bash -e" into an invalid "-e\r" option. The index holds
# LF, so check everything out again with the conversion turned off.
git -c core.autocrlf=false -c core.eol=lf checkout -f -- .
if head -1 ci/build-mingw64.sh | grep -q $'\r'; then
    echo "Error: build script still has CRLF line endings" >&2
    exit 1
fi
git log --oneline -3

echo "=== [2/5] tool versions ==="
meson --version && cmake --version | head -1 && rustc --version
$TARGET-gcc-posix --version | head -1

echo "=== [3/5] meson subprojects ==="
mkdir -p subprojects
meson wrap install mujs || true
meson subprojects download

echo "=== [4/5] dependencies (ffmpeg, libplacebo, libass, ...) ==="
if [ "$SKIP_SUBRANDR" = 1 ]; then
    sed -i 's|^    build_if_missing subrandr$|    : # skipped by build-windows.sh|' \
        ci/build-mingw64.sh
    sed -i 's|^    -Dlua=luajit$|    -Dlua=luajit\n    -Dsubrandr=disabled|' \
        ci/build-mingw64.sh
    grep -q -- '-Dsubrandr=disabled' ci/build-mingw64.sh || {
        echo "Error: subrandr patch did not apply" >&2; exit 1; }
    # A partial install from an earlier attempt would be half-detected by meson.
    rm -rf mingw_prefix/lib/libsubrandr* mingw_prefix/bin/subrandr*.dll \
           mingw_prefix/include/subrandr* mingw_prefix/lib/pkgconfig/subrandr* \
           subrandr
fi
./ci/build-mingw64.sh

echo "=== [5/5] mpv itself ==="
./ci/build-mingw64.sh meson pack

mkdir -p /out
cp -a artifact/. /out/
ls -la /out
echo "=== BUILD OK ==="
