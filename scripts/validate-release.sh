#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# All synthetic gates are required. Set FFMPEG_TEST_TOOL and CHDMAN_TEST_TOOL
# when those independent tools are not on PATH. --with-roms adds local ISOs.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/validate-release.py "$@"
