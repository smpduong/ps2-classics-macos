#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Standard local release checks for PS2 Classics for Mac.
#
# Runs the Swift unit tests, builds the Universal app plus standalone tools,
# runs every helper-dependent Swift test and the Python suites against the
# freshly built helper, runs the optional CHD gate, then assembles and
# validates the exact release archive and writes a machine-readable manifest.
#
# Optional: set CHDMAN_TEST_TOOL=/path/to/chdman and BUILD_REAL_ROMS=1 to add
# the compressed-format gate and the read-only four-ROM workflow.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p test-results

echo "== 1/6 Swift unit tests (no release helper required) =="
swift test 2>&1 | tee test-results/v15-swift-unit.log | tail -n 3

echo "== 2/6 Universal release build (app + standalone tools) =="
bash scripts/build-app.sh

echo "== 3/6 Swift helper-dependent tests against the freshly built helper =="
PS2_TEST_HELPER="$PWD/dist/ps2-convert" PS2_TEST_AT3_HELPER="$PWD/dist/ps2-at3" swift test 2>&1 | tee test-results/v15-swift-helper.log | tail -n 3

echo "== 4/6 Python backend / formats / package / recovery suites =="
# Synthetic and opt-in real-image results have separate reports.
python3 scripts/test-publication.py --helper "$PWD/dist/ps2-convert" | tee test-results/v15-publication.json
python3 scripts/test-backend.py | tee test-results/v15-backend.json
python3 scripts/test-extra-formats.py | tee test-results/v15-extra-formats.json
python3 scripts/test-package-workflow.py --report test-results/v15-package-workflow.json > /dev/null
python3 scripts/test-recovery-workflow.py --builder "$PWD/dist/ps2-build" --helper "$PWD/dist/ps2-convert" | tee test-results/v15-recovery.json

if [[ "${BUILD_REAL_ROMS:-0}" == "1" ]]; then
    python3 scripts/test-package-workflow.py --roms "$PWD/ROMS" --builder "$PWD/dist/ps2-build" --helper "$PWD/dist/ps2-convert" --report test-results/v15-real-packages.json
else
    echo "Four-ROM gate SKIPPED (optional): set BUILD_REAL_ROMS=1."
fi

if [[ -n "${FFMPEG_TEST_TOOL:-}" ]]; then
    python3 scripts/test-audio-formats.py --ffmpeg "$FFMPEG_TEST_TOOL" --report test-results/v15-audio-formats.json
else
    echo "Independent audio format gate SKIPPED (optional): set FFMPEG_TEST_TOOL=/path/to/ffmpeg."
fi

echo "== 5/6 CHD gate =="
if [[ -n "${CHDMAN_TEST_TOOL:-}" ]]; then
    python3 scripts/test-chd.py --chdman "$CHDMAN_TEST_TOOL" --helper "$PWD/dist/ps2-convert" --builder "$PWD/dist/ps2-build"
    # Exercise the Swift CHD image-utility branch (workspace claim + expanded-source override).
    FIXTURE_DIR="$(mktemp -d)"
    python3 - "$FIXTURE_DIR" <<'PY'
import struct, sys
from pathlib import Path
d = Path(sys.argv[1])
data = bytearray(24*2048); p = 16*2048
data[p] = 1; data[p+1:p+6] = b'CD001'; data[p+6] = 1
data[p+80:p+88] = struct.pack('<I', 24) + struct.pack('>I', 24)
data[p+128:p+132] = b'\0\x08\x08\0'; data[p+156] = 34
data[p+158:p+162] = struct.pack('<I', 20); data[p+166:p+170] = struct.pack('<I', 2048)
cnf = b'BOOT2 = cdrom0:\\SLUS_123.45;1\r\n'; r = 20*2048; name = b'SYSTEM.CNF;1'
data[r] = 46; data[r+2:r+6] = struct.pack('<I', 21); data[r+10:r+14] = struct.pack('<I', len(cnf))
data[r+32] = len(name); data[r+33:r+33+len(name)] = name; data[21*2048:21*2048+len(cnf)] = cnf
(d/'source.iso').write_bytes(data)
PY
    "$CHDMAN_TEST_TOOL" createdvd -i "$FIXTURE_DIR/source.iso" -o "$FIXTURE_DIR/fixture.chd" -c zstd -np 2 >/dev/null
    PS2_TEST_HELPER="$PWD/dist/ps2-convert" PS2_TEST_CHD="$FIXTURE_DIR/fixture.chd" \
        swift test --filter CHDOrchestrationTests
    rm -rf "$FIXTURE_DIR"
else
    echo "CHD gate SKIPPED (optional): set CHDMAN_TEST_TOOL=/path/to/chdman to run CHD extraction/package/orchestration checks."
fi

echo "== 5b/6 Real external-volume gate (optional) =="
if [[ "${PS2_TEST_EXTERNAL_VOLUME:-0}" == "1" ]]; then
    python3 scripts/test-external-volume.py
else
    echo "External-volume gate SKIPPED (optional): set PS2_TEST_EXTERNAL_VOLUME=1 to run real exFAT/FAT32 builds, the FAT32 per-file cap and a forced mid-build disconnection on disposable disk images."
fi

echo "== 6/6 Assemble and validate the exact release archive =="
bash scripts/make-archive.sh 1.0 RC6
python3 scripts/make-source-baseline.py --version 1.0 --label RC6
python3 scripts/release-manifest.py --version 1.0 --build 15 --label RC6

echo
echo "Release checks passed. The manifest distinguishes local evidence from the external gates."
