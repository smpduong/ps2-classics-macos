#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Rebuild an extracted source baseline with no checkout or prior build directory."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--report', required=True, type=Path)
    args = parser.parse_args()
    report = {'passed': False, 'sourceArchiveSHA256': hashlib.sha256(args.archive.read_bytes()).hexdigest()}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    log_path = args.report.with_suffix('.log')
    try:
        with tempfile.TemporaryDirectory(prefix='ps2-clean-source-') as tmp, log_path.open('w') as log:
            root = Path(tmp)/'source'; root.mkdir()
            with tarfile.open(args.archive, 'r:gz') as archive:
                seen = set()
                for member in archive.getmembers():
                    parts = PurePosixPath(member.name).parts
                    if not member.isfile() or not parts or '..' in parts or PurePosixPath(member.name).is_absolute() or member.name in seen:
                        raise ValueError(f'Unsafe source archive member: {member.name}')
                    seen.add(member.name)
                    target = root.joinpath(*parts); target.parent.mkdir(parents=True, exist_ok=True)
                    with archive.extractfile(member) as src, target.open('xb') as dst:
                        while data := src.read(1024*1024): dst.write(data)
                    target.chmod(member.mode & 0o777)
            assert not (root/'.build').exists() and not (root/'dist').exists()
            env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(Path(tmp)/'clang-cache'), SWIFTPM_MODULECACHE_OVERRIDE=str(Path(tmp)/'swift-cache'))
            def run(*command):
                subprocess.run(list(map(str,command)),cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
            run('bash','scripts/build-app.sh')
            settings=json.loads((root/'release.json').read_text())
            spec=importlib.util.spec_from_file_location('release_manifest',root/'scripts/release-manifest.py')
            validator=importlib.util.module_from_spec(spec);spec.loader.exec_module(validator)
            validator.check_bundle(root/'dist/PS2 Classics for Mac.app',settings['shortVersion'],str(settings['build']),report,'rebuilt')
            run('python3','scripts/test-backend.py','--helper',root/'dist/ps2-convert')
            run('python3','scripts/test-package-workflow.py','--builder',root/'dist/ps2-build','--helper',root/'dist/ps2-convert')
            with tempfile.TemporaryDirectory(dir=tmp) as scratch:
                report['audioSmokeBytes']=validator.at3_encode_smoke(root/'dist/ps2-at3',Path(scratch),'rebuilt')
            report['checks']=['fresh directory from archive only','Universal macOS 12 build','licenses/resources/signatures','backend regression','single/multi synthetic packages','native audio encode']
            report['passed']=True
    except BaseException as error:
        report['error']=str(error)
        raise
    finally:
        args.report.write_text(json.dumps(report,indent=2)+'\n')
    print('Clean-source rebuild and functional smoke checks passed.')


if __name__ == '__main__': main()
