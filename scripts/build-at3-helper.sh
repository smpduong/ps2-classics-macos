#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Builds the optional ATRAC3 encoding helper (`ps2-at3`) as a Universal
# (arm64 + x86_64) macOS 12 binary, from the pinned source vendored under
# ThirdParty. The helper statically links libsndfile, so it has no runtime
# dependency beyond the system libraries and needs no end-user tooling.
#
#   ThirdParty/atracdenc  dcherednik/atracdenc @ cb170709f836cb43dc0312455188c791159d81dc (LGPL-2.1)
#     including its src/lib/libgha submodule @ 00a95243254cfb1e43b05888ebc68e9aa401507a (BSD-2-Clause)
#   ThirdParty/libsndfile libsndfile @ 72f6af15e8f85157bd622ed45b979025828b7001 (LGPL-2.1)
#
# The ATRAC3 encoder is a separate executable invoked with structured
# arguments, so the LGPL components are not linked into the app itself. Their
# notices and the corresponding source travel with the distribution.
set -euo pipefail
cd "$(dirname "$0")/.."

SNDFILE_SRC="ThirdParty/libsndfile"
ATRACDEN_SRC="ThirdParty/atracdenc"
for required in "$SNDFILE_SRC/CMakeLists.txt" "$ATRACDEN_SRC/CMakeLists.txt" "$ATRACDEN_SRC/src/lib/libgha/CMakeLists.txt"; do
    [[ -f "$required" ]] || { echo "Missing vendored source: $required" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

echo "Building libsndfile (static, Universal, WAV-capable, no external codecs)..."
cmake -S "$SNDFILE_SRC" -B "$WORK/sndfile" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
    -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF \
    -DENABLE_EXTERNAL_LIBS=OFF -DENABLE_MPEG=OFF -DENABLE_CPACK=OFF \
    -DINSTALL_MANPAGES=OFF >/dev/null
cmake --build "$WORK/sndfile" -j"$JOBS" >/dev/null

echo "Building atracdenc (Universal, macOS 12)..."
cmake -S "$ATRACDEN_SRC" -B "$WORK/atracdenc" \
    -DCMAKE_BUILD_TYPE=Release \
    -DATRACDENC_PCM_IO_BACKEND=libsndfile \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
    -DLIBSNDFILE_INCLUDE_DIR="$PWD/$SNDFILE_SRC/include" \
    -DSNDFILE_LIBRARY="$WORK/sndfile/libsndfile.a" >/dev/null
cmake --build "$WORK/atracdenc" -j"$JOBS" >/dev/null

mkdir -p dist
install -m 755 "$WORK/atracdenc/src/atracdenc" dist/ps2-at3
codesign --force --sign - dist/ps2-at3
printf 'Built dist/ps2-at3 (%s)\n' "$(lipo -archs dist/ps2-at3)"
