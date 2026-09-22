#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Opt-in full image encryption/decryption test using a temporary synthetic key.
Outputs are test material, never console-ready packages, and are removed after each case.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

SEG=16384
CASES=[('4x4 Evo 2 (Europe).iso',1),('Xenosaga Episode 1.iso',1),
       ('Xenosaga Episode 2 (Disc 1).iso',1),('Xenosaga Episode 2 (Disc 2).iso',2)]

def digest(path,limit=None):
    sha=hashlib.sha256()
    with path.open('rb') as f:
        while limit is None or limit>0:
            part=f.read(8*1024*1024 if limit is None else min(limit,8*1024*1024))
            if not part: break
            sha.update(part)
            if limit is not None: limit-=len(part)
    if limit is not None and limit: raise RuntimeError('Truncated recovered payload')
    return sha.hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project',type=Path,default=Path(__file__).resolve().parents[1])
    parser.add_argument('--helper',type=Path)
    args=parser.parse_args();root=args.project.resolve();helper=args.helper or root/'dist/ps2-convert'
    out=root/'test-results';out.mkdir(exist_ok=True)
    report={'recorded_at_utc':datetime.now(timezone.utc).isoformat(),
            'scope':'Local CEX image preparation/encryption/decryption only. Synthetic key. No PKG or console validation.',
            'helper_sha256':digest(helper),'cases':[]}
    for name,disc in CASES:
        source=root/'ROMS'/name;size=source.stat().st_size
        if shutil.disk_usage(out).free < size*2+256*1024*1024: raise RuntimeError('Insufficient test workspace storage')
        print(f'{name}: source fingerprint',file=sys.stderr,flush=True)
        start=time.monotonic();before=digest(source)
        with tempfile.TemporaryDirectory(prefix='conversion-check-',dir=out) as directory:
            d=Path(directory);key=d/'synthetic.key';key.write_bytes(hashlib.sha256(b'PS2 Classics synthetic integration fixture').digest()[:16])
            encrypted=d/'ISO.BIN.ENC';decrypted=d/'recovered.iso'
            for command in [
                ['encrypt-iso',source,encrypted,key,'2P0001-PS2U10000_00-0000111122223333',disc],
                ['decrypt',encrypted,decrypted,key,disc]]:
                print(f'{name}: {command[0]}',file=sys.stderr,flush=True)
                result=subprocess.run([str(helper),*map(str,command)],capture_output=True,text=True,timeout=3600)
                if result.returncode: raise RuntimeError(result.stderr)
                events=[json.loads(line) for line in result.stdout.splitlines()]
                assert events[-1].get('locallyVerified') is True
            recovered=digest(decrypted,size)
            padded=(size+SEG-1)//SEG*SEG
            with source.open('rb') as f:
                # The supplied fixtures all have their primary descriptor at sector 16.
                f.seek(16*2048+84);logical_blocks=int.from_bytes(f.read(4),'big')
            with decrypted.open('rb') as f:
                f.seek(size);tail=f.read()
            expected=bytes(padded-size)+b'LIMG'+(1).to_bytes(4,'big')+logical_blocks.to_bytes(4,'big')+(2048).to_bytes(4,'big')+bytes(SEG-16)
            checks={'recovered_source_sha256_matches':recovered==before,'correct_padding_and_limg':tail==expected,
                    'full_prepared_length':decrypted.stat().st_size==padded+SEG}
            encrypted_bytes=encrypted.stat().st_size
        print(f'{name}: verify original unchanged',file=sys.stderr,flush=True)
        after=digest(source);checks['source_sha256_unchanged']=after==before
        report['cases'].append({'filename':name,'disc_number':disc,'source_bytes':size,
                                'encrypted_bytes':encrypted_bytes,'source_sha256_before':before,
                                'source_sha256_after':after,'recovered_source_sha256':recovered,
                                'seconds':round(time.monotonic()-start,2),'checks':checks,'passed':all(checks.values())})
        assert all(checks.values()),checks
    report['passed']=all(case['passed'] for case in report['cases'])
    print(json.dumps(report,indent=2))

if __name__=='__main__': main()
