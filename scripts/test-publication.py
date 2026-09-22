#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Force unsupported exclusive publication against the real native helper.
Only temporary synthetic files are used. No production test hooks are added.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, default=Path(__file__).resolve().parents[1] / 'dist/ps2-convert')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='ps2-publication-') as d:
        root = Path(d)
        shim = root / 'unsupported.c'
        shim.write_text(r'''
#include <errno.h>
#include <sys/stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
static int no_rename(const char *a, const char *b, unsigned int flags) {
    (void)a; (void)b; (void)flags; errno = ENOTSUP; return -1;
}
static int no_link(const char *a, const char *b) {
    if (getenv("PS2_TEST_REPLACEMENT")) {
        int fd = open(b, O_CREAT | O_EXCL | O_WRONLY, 0600);
        if (fd >= 0) { write(fd, "OTHER WRITER", 12); close(fd); }
        errno = EEXIST;
    } else { errno = ENOTSUP; }
    (void)a; return -1;
}
#define INTERPOSE(new, old) \
__attribute__((used)) static struct { const void *replacement; const void *replacee; } \
i_##old __attribute__((section("__DATA,__interpose"))) = {(const void *)&new, (const void *)&old};
INTERPOSE(no_rename, renamex_np)
INTERPOSE(no_link, link)
''')
        library = root / 'unsupported.dylib'
        subprocess.run(['clang', '-dynamiclib', str(shim), '-o', str(library)], check=True, capture_output=True)
        source = root / 'source'; source.write_bytes(bytes(range(256)))
        key = root / 'key'; key.write_bytes(bytes(16))
        env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(library))
        checks = []
        for replacement in [False, True]:
            output = root / ('raced.enc' if replacement else 'unsupported.enc')
            case_env = dict(env)
            if replacement: case_env['PS2_TEST_REPLACEMENT'] = '1'
            result = subprocess.run([str(args.helper), 'encrypt-raw', str(source), str(output), str(key),
                                     '2P0001-PS2U10000_00-0000111122223333', '1'], env=case_env,
                                    capture_output=True, text=True)
            assert result.returncode != 0, 'unsupported publication must fail closed'
            assert 'cannot publish output safely' in result.stderr, result.stderr
            if replacement:
                assert output.read_bytes() == b'OTHER WRITER', 'another writer must never be replaced or deleted'
            else:
                assert not output.exists(), 'no empty final placeholder may be published'
            assert source.read_bytes() == bytes(range(256))
            assert not list(root.glob('*.partial.*')), 'ordinary failure must clean private temporary output'
            checks.append('competing writer preserved' if replacement else 'unsupported filesystem leaves no final placeholder')
        print(json.dumps({'passed': True, 'checks': checks}, indent=2))


if __name__ == '__main__':
    main()
