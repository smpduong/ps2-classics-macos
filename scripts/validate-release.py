#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Strict local release gate. Missing prerequisites or skipped required tests fail."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--with-roms', action='store_true', help='Also run the local read-only four-ISO workflow.')
    args = parser.parse_args()
    settings = json.loads((ROOT/'release.json').read_text())
    results = ROOT/'test-results'
    results.mkdir(exist_ok=True)
    receipt = {'version': settings, 'passed': False, 'checks': []}
    receipt_path = results/f"v{settings['build']}-release-checks.json"
    def save():
        receipt_path.write_text(json.dumps(receipt, indent=2)+'\n')
    save()
    ffmpeg = os.environ.get('FFMPEG_TEST_TOOL') or shutil.which('ffmpeg')
    chdman = os.environ.get('CHDMAN_TEST_TOOL') or shutil.which('chdman')
    for name, path in [('FFMPEG_TEST_TOOL', ffmpeg), ('CHDMAN_TEST_TOOL', chdman)]:
        if not path or not os.access(path, os.X_OK):
            receipt['error'] = f'Strict release requires {name} to name an executable test tool.'
            save()
            raise SystemExit(receipt['error'])
    env = dict(os.environ, PS2_TEST_HELPER=str(ROOT/'dist/ps2-convert'), PS2_TEST_AT3_HELPER=str(ROOT/'dist/ps2-at3'))
    prefix = f"v{settings['build']}"
    def check(name, command, extra_env=None):
        print(f'Checking {name}…', flush=True)
        log = results/f'{prefix}-{name}.log'
        started = time.monotonic()
        with log.open('w') as stream:
            process = subprocess.run(list(map(str, command)), cwd=ROOT, env=extra_env or env, stdout=stream, stderr=subprocess.STDOUT)
        entry = {'name': name, 'passed': process.returncode == 0, 'log': log.name, 'seconds': round(time.monotonic()-started, 2)}
        receipt['checks'].append(entry); save()
        if process.returncode:
            raise RuntimeError(f'{name} failed; see {log.name}')
    mounted = False
    try:
        check('universal-build', ['bash', 'scripts/build-app.sh'])
        with tempfile.TemporaryDirectory(prefix='ps2-release-fixtures-') as tmp:
            folder = Path(tmp)
            spec = importlib.util.spec_from_file_location('package_test', ROOT/'scripts/test-package-workflow.py')
            fixtures = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixtures)
            (folder/'source.iso').write_bytes(fixtures.synthetic_iso())
            check('chd-fixture', [chdman, 'createdvd', '-i', folder/'source.iso', '-o', folder/'source.chd', '-c', 'zstd', '-np', '2'])
            mount = folder/'volume'; mount.mkdir()
            check('volume-create', ['hdiutil', 'create', '-size', '128m', '-fs', 'APFS', '-volname', 'PS2ReleaseTest', folder/'volume.dmg'])
            check('volume-attach', ['hdiutil', 'attach', '-nobrowse', '-mountpoint', mount, folder/'volume.dmg'])
            mounted = True
            try:
                full_env = dict(env, PS2_TEST_CHD=str(folder/'source.chd'), PS2_TEST_VOLUME=str(mount))
                check('swift-and-audio', ['python3', 'scripts/test-audio-formats.py', '--ffmpeg', ffmpeg, '--all-swift-tests', '--report', results/f'{prefix}-audio-formats.json'], full_env)
                log = (results/f'{prefix}-audio-formats.swift.log').read_text()
                if 'Test skipped' in log or '0 failures' not in log:
                    raise RuntimeError('Strict Swift gate contains a skipped test or lacks a successful XCTest result.')
            finally:
                detached = subprocess.run(['hdiutil', 'detach', str(mount)], capture_output=True)
                mounted = detached.returncode != 0
                if mounted: raise RuntimeError('Could not detach the disposable test volume.')
        for name, command in [
            ('backend', ['python3','scripts/test-backend.py']),
            ('extra-formats', ['python3','scripts/test-extra-formats.py']),
            ('publication', ['python3','scripts/test-publication.py','--helper',ROOT/'dist/ps2-convert']),
            ('recovery', ['python3','scripts/test-recovery-workflow.py']),
            ('chd-matrix', ['python3','scripts/test-chd.py','--chdman',chdman,'--helper',ROOT/'dist/ps2-convert','--builder',ROOT/'dist/ps2-build']),
            ('filesystems', ['python3','scripts/test-external-volume.py'])]:
            check(name, command)
        if args.with_roms or os.environ.get('BUILD_REAL_ROMS') == '1':
            check('real-packages', ['python3','scripts/test-package-workflow.py','--roms',ROOT/'ROMS','--report',results/f'{prefix}-real-packages.json'])
        else:
            receipt['localROMs'] = 'Not requested; separate from required synthetic release checks.'
        check('app-archive', ['bash','scripts/make-archive.sh',settings['version'],settings['label']])
        check('source-archive', ['python3','scripts/make-source-baseline.py','--version',settings['version'],'--label',settings['label']])
        archive = ROOT/'dist'/f"source-baseline-{settings['version']}-{settings['label']}.tar.gz"
        check('clean-source-rebuild', ['python3','scripts/test-clean-source.py','--archive',archive,'--report',results/f'{prefix}-clean-source.json'])
        check('manifest', ['python3','scripts/release-manifest.py','--version',settings['version'],'--build',str(settings['build']),'--label',settings['label']])
        manifest = json.loads((ROOT/'dist'/f"release-manifest-{settings['version']}-{settings['label']}.json").read_text())
        receipt['archiveSHA256'] = manifest['archiveSHA256']
        receipt['sourceArchiveSHA256'] = manifest['sourceArchiveSHA256']
        receipt['passed'] = True; save()
        print(f'Strict release checks passed. Receipt: {receipt_path.name}')
    except BaseException as error:
        receipt['error'] = str(error); save()
        raise


if __name__ == '__main__': main()
