#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Minimal CHD v5 (uncompressed DVD) fixture builder.

Builds structurally genuine parent/child pairs from the pinned libchdr layout
(ThirdParty/libchdr/include/libchdr/chd.h: v5 header fields, uncompressed map
entries as absolute-offset/hunkbytes, 16-byte metadata blobs). Used to prove
the helper rejects real parent-dependent images with its precise message, not
just byte-flipped proxies.

Combined-header-sha1 recipe caveat: nothing in the local pipeline reads the
overall header sha1 (only rawsha1 is verified on extraction), so these
fixtures set it to SHA1(rawsha1) and bind the child to that stated value.
The verified properties are: the parent passes inspect/extract byte-exact
through the bundled decoder, and the child differs only in a nonzero
parentsha1, which the pinned library treats as "requires parent"
(src/libchdr_chd.c chd_open) and the helper rejects explicitly.
"""
import hashlib
import struct
from pathlib import Path

HUNK = 16384
UNIT = 2048


def _header(logical: bytes, parentsha1: bytes, metaoffset: int, mapoffset: int = 124) -> bytes:
    assert len(parentsha1) == 20
    rawsha1 = hashlib.sha1(logical).digest()
    combined = hashlib.sha1(rawsha1).digest()
    return (b'MComprHD' + struct.pack('>I', 124) + struct.pack('>I', 5)
            + struct.pack('>IIII', 0, 0, 0, 0)
            + struct.pack('>Q', len(logical)) + struct.pack('>Q', mapoffset)
            + struct.pack('>Q', metaoffset) + struct.pack('>I', HUNK)
            + struct.pack('>I', UNIT) + rawsha1 + combined + parentsha1)


def write_dvd_parent(path: Path, logical: bytes) -> bytes:
    """Write a valid uncompressed DVD CHD. Returns its combined header sha1."""
    assert len(logical) > 0 and len(logical) % HUNK == 0, 'pad logical to whole hunks'
    hunks = len(logical) // HUNK
    data_start = ((124 + hunks * 4 + HUNK - 1) // HUNK) * HUNK
    metaoffset = data_start + len(logical)
    header = _header(logical, bytes(20), metaoffset)
    out = bytearray(header)
    for i in range(hunks):
        out += struct.pack('>I', (data_start + i * HUNK) // HUNK)
    out += bytes(data_start - len(out))
    out += logical
    out += b'DVD ' + struct.pack('>I', 0) + struct.pack('>Q', 0)
    path.write_bytes(bytes(out))
    return header[84:104]


def write_dvd_child(path: Path, parent: Path, parentsha1: bytes) -> None:
    """Clone a CHD, declaring the given parent hash. Nothing else changes.
    Cloning a child (rather than a parent) builds deeper chains for testing
    the single-level nesting refusal."""
    raw = bytearray(parent.read_bytes())
    assert raw[:8] == b'MComprHD'
    raw[104:124] = parentsha1
    path.write_bytes(bytes(raw))


if __name__ == '__main__':
    import importlib.machinery
    import json
    import subprocess
    import sys
    import tempfile
    wf = importlib.machinery.SourceFileLoader(
        'workflow', str(Path(__file__).with_name('test-package-workflow.py'))).load_module()
    root = Path(__file__).resolve().parents[1]
    helper = root / 'dist' / 'ps2-convert'
    logical = bytes(wf.synthetic_iso())
    assert len(logical) % HUNK == 0, len(logical)
    with tempfile.TemporaryDirectory(prefix='ps2-parent-chd-') as tmp:
        d = Path(tmp)
        parent, child = d / 'parent.chd', d / 'child.chd'
        combined = write_dvd_parent(parent, logical)
        probe = json.loads(subprocess.run(
            [str(helper), 'inspect-chd', str(parent)],
            capture_output=True, text=True, check=True).stdout)
        assert probe['gameID'] == 'SLUS12345' and probe['expandedByteCount'] == len(logical), probe
        out = d / 'parent.image'
        subprocess.run([str(helper), 'extract-chd', str(parent), str(out)], check=True,
                       capture_output=True, text=True)
        assert out.read_bytes() == logical, 'parent must expand byte-exact'
        write_dvd_child(child, parent, combined)
        assert child.read_bytes()[104:124] == combined != bytes(20)
        for command in (['inspect-chd', str(child)], ['extract-chd', str(child), str(d / 'child.image')]):
            run = subprocess.run([str(helper)] + command, capture_output=True, text=True)
            assert run.returncode != 0 and 'Parent-dependent CHDs must be flattened' in run.stderr, (command, run.stderr[-500:])
        assert not (d / 'child.image').exists()
        print(json.dumps(dict(passed=True, parentBytes=parent.stat().st_size,
                              logicalBytes=len(logical), gameID=probe['gameID'])))
