#!/usr/bin/env python3
"""Super Slim / HEN batch export: read-only preflight and optional real conversion.

Runs the Swift `HENBatchROMTests` against the user's own images with synthetic
support files (a 16-byte key and a matching 36-character content ID that no
console has), and independently re-hashes every source around the run.

This establishes local structural preflight, conversion, verification and
publication only. It does NOT establish console playability, console folder
recognition, or multi-disc switching. Sources are opened read-only and are
expected to be byte-identical afterwards.

    python3 scripts/test-hen-batch.py --roms ROMS --report test-results/hen.json
    python3 scripts/test-hen-batch.py --roms ROMS --convert --report test-results/hen.json
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

# Fixture roles and sizes as already recorded by scripts/test-rom-workflow.py.
CASES = [
    ('4x4 Evo 2 (Europe).iso', 'CD-sized image', 501731328, 'SLES51199'),
    ('Xenosaga Episode 1.iso', 'User-supplied double-layer DVD', 8468299776, 'SLUS20469'),
    ('Xenosaga Episode 2 (Disc 1).iso', 'Multi-disc game, disc 1', 4682121216, 'SLUS20892'),
    ('Xenosaga Episode 2 (Disc 2).iso', 'Multi-disc game, disc 2', 4693164032, 'SLUS21133'),
]

EXPECTED = {name for name, _, _, _ in CASES}


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def run_tests(helper, roms, convert, timeout):
    env = dict(os.environ,
               PS2_TEST_ROM_DIR=str(roms),
               PS2_TEST_HELPER=str(helper))
    if convert:
        env['PS2_TEST_HEN_CONVERT'] = '1'
    else:
        env.pop('PS2_TEST_HEN_CONVERT', None)
    result = subprocess.run(['swift', 'test', '--filter', 'HENBatchROMTests'],
                            cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--roms', type=Path, default=ROOT / 'ROMS')
    parser.add_argument('--helper', type=Path, default=ROOT / 'dist/ps2-convert')
    parser.add_argument('--report', type=Path)
    parser.add_argument('--convert', action='store_true',
                        help='Also run the real encrypt/verify/publicate pass. Slow: '
                             'encodes about 18 GB of images.')
    parser.add_argument('--timeout', type=int, default=14400)
    args = parser.parse_args()
    args.helper = args.helper.resolve()

    roms = args.roms.resolve()
    report = args.report.resolve() if args.report else None
    if report is not None:
        # A typo in --report must never turn a private game image (or any
        # existing file) into a JSON receipt. Resolve parents and symlinks
        # before the expensive test, then create the report exclusively.
        if report == roms or roms in report.parents:
            parser.error('--report must be outside the ROMS folder')
        if report.suffix.lower() != '.json':
            parser.error('--report must name a new .json file')
        if report.exists() or report.is_symlink():
            parser.error('--report already exists; choose a new filename')
    if not roms.is_dir():
        print(f'ROMS folder not found: {roms}', file=sys.stderr)
        return 2
    if not args.helper.is_file() or not os.access(args.helper, os.X_OK):
        print(f'Conversion helper missing or not executable: {args.helper}. '
              'Run scripts/build-app.sh first.', file=sys.stderr)
        return 2

    actual = {p.name for p in roms.iterdir() if p.is_file() and p.suffix.lower() == '.iso'}
    if actual != EXPECTED:
        print(f'Fixture set changed. Missing: {sorted(EXPECTED - actual)}; '
              f'extra: {sorted(actual - EXPECTED)}', file=sys.stderr)
        return 2

    before, stats_before = {}, {}
    for name, _, size, _ in CASES:
        path = roms / name
        before[name] = sha256(path)
        stat = path.stat()
        stats_before[name] = (stat.st_size, stat.st_mtime_ns)
        if stat.st_size != size:
            print(f'{name} is {stat.st_size} bytes, expected {size}', file=sys.stderr)
            return 2

    print(f'preflight-only' if not args.convert else 'preflight + real conversion')
    print('hashed 4 sources before run; this reads about 17 GB')
    try:
        result = run_tests(args.helper, roms, args.convert, args.timeout)
    except subprocess.TimeoutExpired:
        print(f'swift test exceeded {args.timeout}s', file=sys.stderr)
        return 1

    cases = []
    for name, role, size, game_id in CASES:
        path = roms / name
        after = sha256(path)
        stat = path.stat()
        cases.append({
            'filename': name,
            'test_role': role,
            'expected_game_id': game_id,
            'bytes': size,
            'sha256_before': before[name],
            'sha256_after': after,
            'source_sha256_unchanged': before[name] == after,
            'source_size_and_mtime_unchanged':
                stats_before[name] == (stat.st_size, stat.st_mtime_ns),
        })

    # `swift test` writes its per-case log to stderr, so both streams are
    # inspected. A filter that matches nothing, or a build/test failure, must
    # never be reported as a pass.
    combined = result.stdout + '\n' + result.stderr
    ran = [line for line in combined.splitlines()
           if line.startswith('Test Case') and 'HENBatchROMTests' in line
           and "' passed (" in line]
    failed = [line for line in combined.splitlines()
              if line.startswith('Test Case') and 'HENBatchROMTests' in line
              and "' failed (" in line]
    def marker(name):
        for line in combined.splitlines():
            if name in line:
                try:
                    return json.loads(line.partition(name)[2])
                except json.JSONDecodeError:
                    return None
        return None

    preflight_result = marker('HEN-BATCH-PREFLIGHT ')
    real_result = marker('HEN-BATCH-REAL ')
    preflight_proven = (isinstance(preflight_result, dict)
                        and preflight_result.get('cases') == len(CASES)
                        and preflight_result.get('sourceHashesBound') is True)
    conversion_proven = (isinstance(real_result, dict)
                         and real_result.get('cases') == len(CASES)
                         and real_result.get('profile') == 'ISO.BIN.ENC'
                         and real_result.get('layout') == 'dev_hdd0/PS2ISO'
                         and real_result.get('consoleTested') is False)
    passed = (result.returncode == 0
              and 'No matching test cases were run' not in combined
              and 'error:' not in combined
              and not failed
              and bool(ran)
              and preflight_proven
              and (not args.convert or conversion_proven)
              and all(c['source_sha256_unchanged'] and c['source_size_and_mtime_unchanged']
                      for c in cases))

    summary = {
        'recorded_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'scope': 'Super Slim / HEN batch export over the user-supplied images',
        'helper': str(args.helper),
        'helper_sha256': sha256(args.helper),
        'real_conversion': bool(args.convert),
        'support_files': 'synthetic 16-byte klicensee and matching 36-character content ID; '
                         'no console has these',
        'consoleTested': False,
        'multiDiscTested': False,
        'note': ('Establishes local conversion, verification and publication only. '
                 if args.convert else 'Establishes read-only preflight only. ')
                + 'Console launch, folder recognition and disc switching are untested.',
        'swift_test_returncode': result.returncode,
        'swift_test_cases_passed': len(ran),
        'swift_test_cases_failed': len(failed),
        'preflight_result': preflight_result,
        'conversion_result': real_result,
        'cases': cases,
        'passed': passed,
    }

    if report:
        report.parent.mkdir(parents=True, exist_ok=True)
        with report.open('x', encoding='utf-8') as stream:
            stream.write(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    if not passed:
        print('--- swift test output (tail) ---', file=sys.stderr)
        print(result.stdout[-4000:], file=sys.stderr)
        print(result.stderr[-2000:], file=sys.stderr)
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
