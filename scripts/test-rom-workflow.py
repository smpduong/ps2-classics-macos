#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Opt-in local integration check. Never writes inside ROMS or invokes conversion."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from datetime import datetime, timezone

CASES = [
    ('4x4 Evo 2 (Europe).iso', 'CD-sized image; physical medium not inferred', 501731328, 501731328, '4X4_EVOLUTION_2'),
    ('Xenosaga Episode 1.iso', 'User-supplied double-layer DVD case', 8468299776, 4254367744, ''),
    ('Xenosaga Episode 2 (Disc 1).iso', 'Multi-disc game, disc 1 (user/filename order)', 4682121216, 4682121216, 'XENOSAGA_II'),
    ('Xenosaga Episode 2 (Disc 2).iso', 'Multi-disc game, disc 2 (user/filename order)', 4693164032, 4693164032, 'XENOSAGA_II'),
]

def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(8 * 1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.project.resolve()
    roms = root / 'ROMS'
    expected = {case[0] for case in CASES}
    actual = {p.name for p in roms.iterdir() if p.is_file() and p.suffix.lower() == '.iso'}
    if actual != expected:
        raise RuntimeError(f'Fixture set changed. Missing: {sorted(expected-actual)}; extra: {sorted(actual-expected)}')
    binary = root / 'dist/ps2-inspect'
    report = {
        'recorded_at_utc': datetime.now(timezone.utc).isoformat(),
        'scope': 'This script checks read-only ISO descriptors, boot IDs and source preservation. It does not test conversion, layer behavior, disc switching or console operation; see VALIDATION.md for separate checks.',
        'inspector_sha256': sha256(binary),
        'cases': [],
    }
    for name, role, expected_size, expected_volume, expected_label in CASES:
        source = roms / name
        print(f'Checking {name}: hashing original…', file=sys.stderr, flush=True)
        stat_before = source.stat()
        before = sha256(source)
        process = subprocess.run([str(binary), str(source)], capture_output=True, text=True, timeout=30)
        print(f'Checking {name}: verifying original remains unchanged…', file=sys.stderr, flush=True)
        after = sha256(source)
        stat_after = source.stat()
        inspection = json.loads(process.stdout) if process.returncode == 0 else None
        checks = {
            'inspector_exited_successfully': process.returncode == 0,
            'source_sha256_unchanged': before == after,
            'source_size_and_mtime_unchanged': (stat_before.st_size, stat_before.st_mtime_ns) == (stat_after.st_size, stat_after.st_mtime_ns),
            'expected_file_size': stat_after.st_size == expected_size,
        }
        if inspection is not None:
            checks.update({
                'iso_descriptor_recognized': inspection.get('format') == 'ISO 9660 descriptor (2048-byte sectors)',
                'full_file_size_reported': inspection.get('byteCount') == expected_size,
                'expected_first_volume_size': inspection.get('declaredVolumeBytes') == expected_volume,
                'expected_volume_label': inspection.get('volumeLabel') == expected_label,
                'expected_boot_id': inspection.get('gameID') == dict(zip([case[0] for case in CASES],['SLES51199','SLUS20469','SLUS20892','SLUS21133']))[name],
                'media_uncertainty_disclosed': any('cannot be established' in n for n in inspection.get('notes', [])),
                'trailing_bytes_note_correct': any('Bytes follow' in n for n in inspection.get('notes', [])) == (expected_size > expected_volume),
            })
        report['cases'].append({
            'filename': name, 'test_role': role, 'sha256_before': before,
            'sha256_after': after, 'checks': checks, 'passed': all(checks.values()),
            'inspection': inspection,
            'error': process.stderr if process.returncode else None,
        })
    report['passed'] = all(case['passed'] for case in report['cases'])
    print(json.dumps(report, indent=2))
    return 0 if report['passed'] else 1

if __name__ == '__main__':
    sys.exit(main())
