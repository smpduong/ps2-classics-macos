#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Assembles the release ZIP from the already-built Universal app bundle.
# Run scripts/build-app.sh first so resources and signatures are final.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-1.0}"
LABEL="${2:-RC}"
APP="dist/PS2 Classics for Mac.app"
ZIP="dist/PS2 Classics for Mac $VERSION $LABEL.zip"
if [[ ! -d "$APP" ]]; then
    echo "Build the app first: bash scripts/build-app.sh" >&2
    exit 1
fi
rm -f "$ZIP" "$ZIP.sha256"
# ditto preserves symlinks and signatures; --norsrc/--noextattr keep the archive
# free of __MACOSX resource-fork cruft so the extracted bundle is what we signed.
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
(
    cd dist
    shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256"
)
printf 'Wrote %s\n' "$ZIP"
