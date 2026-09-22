#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Create a reviewable source baseline without local media, outputs or session state."""
import argparse
import gzip
import hashlib
import os
from pathlib import Path
import re
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
INCLUDE = ('LICENSE', 'LICENSING.md', 'release.json', 'Package.swift', 'README.md', 'AGENTS.md', '.gitignore', 'Sources', 'Tests', 'ThirdParty', 'scripts', 'docs')
EXCLUDE = {'.git', '.build', '__pycache__', '.DS_Store'}


def source_files():
    files = []
    for name in INCLUDE:
        base = ROOT/name
        if not base.exists():
            raise FileNotFoundError(f'Required source root is missing: {name}')
        for path in ([base] if base.is_file() else base.rglob('*')):
            relative = path.relative_to(ROOT)
            if any(part in EXCLUDE or part.startswith("._") for part in relative.parts):
                continue
            if 'HANDOFF' in path.name or path.name == 'RC2_PRIORITIES_AND_FEATURES_2026-09-22.md':
                continue
            if path.is_symlink():
                raise ValueError(f'Source baseline refuses symbolic link: {relative}')
            if path.is_file():
                files.append(path)
    return sorted(files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--label', required=True)
    args = parser.parse_args()
    assert all(re.fullmatch(r'[A-Za-z0-9._-]+', value) for value in (args.version, args.label))
    destination = ROOT/'dist'/f'source-baseline-{args.version}-{args.label}.tar.gz'
    destination.parent.mkdir(parents=True, exist_ok=True)
    files = source_files()
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix='.source-', delete=False) as staged:
        temporary = Path(staged.name)
        try:
            with gzip.GzipFile(fileobj=staged, mode='wb', mtime=0, filename='') as compressed:
                with tarfile.open(fileobj=compressed, mode='w') as archive:
                    for path in files:
                        info = archive.gettarinfo(str(path), str(path.relative_to(ROOT)))
                        info.uid = info.gid = info.mtime = 0
                        info.uname = info.gname = ''
                        with path.open('rb') as stream:
                            archive.addfile(info, stream)
            staged.flush()
            os.fsync(staged.fileno())
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
    checksum = hashlib.sha256(destination.read_bytes()).hexdigest()
    Path(str(destination)+'.sha256').write_text(f'{checksum}  {destination.name}\n')
    print(f'Wrote {destination.name}: {len(files)} source files, SHA-256 {checksum}')


if __name__ == '__main__':
    main()
