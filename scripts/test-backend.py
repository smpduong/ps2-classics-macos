#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic backend regression tests; optional pinned upstream executable comparison."""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import subprocess
import sys
import tempfile

CID = '2P0001-PS2U10000_00-0000111122223333'
SEG = 16384

def binary_info(path):
    version = subprocess.run([str(path), '--version'], capture_output=True, text=True).stdout.strip()
    return dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest(), version=version)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper',type=Path,default=Path(__file__).resolve().parents[1]/'dist/ps2-convert')
    parser.add_argument('--reference',type=Path)
    args=parser.parse_args()
    passed=[]
    with tempfile.TemporaryDirectory(prefix='ps2-backend-tests-') as directory:
        d=Path(directory); key=d/'test.key'; key.write_bytes(bytes(16))
        def run(*parts, ok=True, **kw):
            p=subprocess.run([str(args.helper),*map(str,parts)],capture_output=True,text=True,**kw)
            assert (p.returncode==0)==ok,(parts,p.returncode,p.stderr)
            return p
        def encrypt(source,output,disc=1,mode='encrypt-raw'):
            return run(mode,source,output,key,CID,disc)
        for size in [1,SEG-1,SEG,SEG+1,SEG*512+123]:
            source=d/f'raw-{size}'; source.write_bytes((bytes(range(256))*((size+255)//256))[:size])
            enc=d/f'cipher-{size}'; dec=d/f'plain-{size}'
            encrypt(source,enc)
            run('decrypt',enc,dec,key,1)
            assert dec.read_bytes()==source.read_bytes()
        passed.append('partial, exact and cross-group payload round trips')
        source=d/'raw-16384'; enc=d/'cipher-16384'
        # Derived independently from pinned upstream C output, excluding its randomized header.
        assert hashlib.sha256(enc.read_bytes()[SEG:]).hexdigest() == '726a5513c73468f9bd6316e3d46c88a1c1954048d71cddc2e720868121a4f3ff'
        passed.append('pinned upstream known-answer ciphertext digest')
        # Resume design evidence, measured not inferred: two encryptions of
        # identical inputs differ only in the 16-byte header nonce (0x40)
        # and the authentication MAC covering it (0x60); every other header
        # byte and every segment byte is deterministic, so a retained header
        # can be reused verbatim and a retained prefix authenticated by
        # re-encryption.
        nonce_src=d/'nonce-src'; nonce_src.write_bytes((bytes(range(256))*256)[:SEG*4])
        first=d/'nonce-a.enc'; second=d/'nonce-b.enc'
        encrypt(nonce_src,first); encrypt(nonce_src,second)
        a,b=first.read_bytes(),second.read_bytes()
        assert len(a)==len(b) and a[:0x40]==b[:0x40] and a[0x50:0x60]==b[0x50:0x60] and a[0x70:]==b[0x70:]
        assert a[0x40:0x50]!=b[0x40:0x50] and a[0x60:0x70]!=b[0x60:0x70]
        for enc_file,out in ((first,d/'nonce-a.out'),(second,d/'nonce-b.out')):
            run('decrypt',enc_file,out,key,1); assert out.read_bytes()==nonce_src.read_bytes()
        passed.append('encryption deterministic except the 16-byte header nonce and its covering auth MAC; headers reusable verbatim for resume')
        before=source.read_bytes()
        run('encrypt-raw',source,source,key,CID,1,ok=False)
        alias=d/'alias'; alias.symlink_to(source)
        run('encrypt-raw',source,alias,key,CID,1,ok=False)
        hard=d/'hardlink'; hard.hardlink_to(source)
        run('encrypt-raw',source,hard,key,CID,1,ok=False)
        assert source.read_bytes()==before
        passed.append('source, symlink and hard-link overwrite rejection')
        for offset in [0,0x50,0x60,0x84,0x88,SEG,2*SEG]:
            data=bytearray(enc.read_bytes()); data[offset]^=1
            bad=d/f'bad-{offset}'; bad.write_bytes(data)
            out=d/f'bad-out-{offset}'
            run('decrypt',bad,out,key,1,ok=False)
            assert not out.exists()
        truncated=d/'truncated'; truncated.write_bytes(enc.read_bytes()[:-1])
        run('verify',truncated,key,1,ok=False)
        passed.append('malformed headers, corrupted metadata/data and truncation rejected without publishing')
        wrong=d/'wrong.key'; wrong.write_bytes(bytes([1])*16)
        run('verify',enc,wrong,1,ok=False)
        invalid=d/'invalid.key'; invalid.write_bytes(b'short')
        run('verify',enc,invalid,1,ok=False)
        rap=d/'license.RAP';rap.write_bytes(bytes(16))
        run('verify',enc,rap,1,ok=False)
        run('verify',enc,key,2,ok=False)
        passed.append('wrong key, key length and disc number rejected')
        disc2=d/'disc2'; encrypt(source,disc2,2)
        run('verify',disc2,key,2)
        passed.append('disc 2 segment numbering')
        # Exact logical-profile allowlist at the native boundary.
        run('encrypt-raw',source,d/'config2.enc',key,CID,2,'CONFIG2')
        probe=json.loads(run('inspect-encrypted',d/'config2.enc').stdout)
        assert probe['logicalName']=='CONFIG2' and probe['complete'] and probe['payloadBytes']==source.stat().st_size,probe
        for bad in ['CONFIGbanana','ISO.BIN.ENC10','ISO.BIN.ENC0','iso.bin.enc','ISO.BIN.ENC ','CONFIG0','CONFIG10',' ISO.BIN.ENC']:
            run('encrypt-raw',source,d/'rejected.enc',key,CID,1,bad,ok=False)
            assert not (d/'rejected.enc').exists()
        passed.append('exact 18-profile allowlist enforced on both write and detection')
        # Detection must not trust the unauthenticated declared size.
        named2=d/'disc2-named.enc'; run('encrypt-raw',source,named2,key,CID,2,'ISO.BIN.ENC2')
        probe=json.loads(run('inspect-encrypted',named2).stdout)
        assert probe['logicalName']=='ISO.BIN.ENC2' and probe['complete'] and probe['payloadBytes']==source.stat().st_size,probe
        huge=bytearray(named2.read_bytes());huge[0x88:0x90]=(0xFFFFFFFFFFFFFFFF).to_bytes(8,'big')
        (d/'huge-size.enc').write_bytes(huge)
        run('inspect-encrypted',d/'huge-size.enc',ok=False)
        zero=bytearray(named2.read_bytes());zero[0x88:0x90]=bytes(8)
        (d/'zero-size.enc').write_bytes(zero)
        run('inspect-encrypted',d/'zero-size.enc',ok=False)
        header_only=d/'header-only.enc';header_only.write_bytes(named2.read_bytes()[:SEG])
        partial=json.loads(run('inspect-encrypted',header_only).stdout)
        assert partial['complete'] is False and 'payloadBytes' not in partial,partial
        extra=d/'extra.enc';extra.write_bytes(named2.read_bytes()+b'\0')
        partial=json.loads(run('inspect-encrypted',extra).stdout)
        assert partial['complete'] is False and 'payloadBytes' not in partial,partial
        passed.append('detected payload size bounded and only reported when the whole file matches')
        iso=d/'小さい DVD café.iso'
        data=bytearray(25*2048); base=16*2048
        data[base]=1;data[base+1:base+6]=b'CD001';data[base+6]=1
        data[base+80:base+88]=(24).to_bytes(4,'little')+(24).to_bytes(4,'big')
        data[base+128:base+132]=(2048).to_bytes(2,'little')+(2048).to_bytes(2,'big')
        data[-2048:]=bytes([71])*2048
        iso.write_bytes(data)
        encrypt(iso,d/'iso.enc',mode='encrypt-iso')
        run('decrypt',d/'iso.enc',d/'iso.out',key,1)
        prepared=(d/'iso.out').read_bytes()
        padded=(len(data)+SEG-1)//SEG*SEG
        assert prepared[:len(data)]==data
        assert prepared[len(data):padded]==bytes(padded-len(data))
        assert prepared[padded:padded+16]==b'LIMG'+(1).to_bytes(4,'big')+(24).to_bytes(4,'big')+(2048).to_bytes(4,'big')
        assert len(prepared)==padded+SEG and iso.read_bytes()==data
        passed.append('small ISO uses sector layout; all bytes beyond first volume retained; output-only padding/LIMG')
        badiso=d/'invalid.iso'; badiso.write_bytes(bytes(25*2048))
        run('encrypt-iso',badiso,d/'invalid.enc',key,CID,1,ok=False)
        run('encrypt-iso',d/'iso.out',d/'double-limg.enc',key,CID,1,ok=False)
        passed.append('unrecognized images and already-prepared LIMG rejected')
        def limit_output():
            resource.setrlimit(resource.RLIMIT_FSIZE,(32768,32768))
        run('encrypt-raw',d/f'raw-{SEG*512+123}',d/'limited.enc',key,CID,1,ok=False,preexec_fn=limit_output)
        assert not (d/'limited.enc').exists()
        assert not list(d.glob('limited.enc.partial.*'))
        passed.append('injected write failure leaves no finished or partial output')
        large=d/'cancel-source'
        with large.open('wb') as f: f.truncate(512*1024*1024)
        p=subprocess.Popen([str(args.helper),'encrypt-raw',str(large),str(d/'cancel.enc'),str(key),CID,'1'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        assert p.stdout.readline();p.terminate();p.communicate(timeout=20)
        assert p.returncode!=0 and not (d/'cancel.enc').exists() and not list(d.glob('cancel.enc.partial.*'))
        passed.append('cancellation removes incomplete output')
        # A force-killed helper must leave durable provenance for later cleanup,
        # with a valid job id and without publishing a finished output.
        import os, time as _time
        job = '12345678-1234-4abc-8def-1234567890ab'
        killed = subprocess.Popen([str(args.helper),'encrypt-raw',str(large),str(d/'killed.enc'),str(key),CID,'1'],
                                  stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,
                                  env={**os.environ,'PS2_JOB_ID':job})
        assert killed.stdout.readline()
        killed.kill(); killed.communicate(timeout=20)
        partials=list(d.glob('killed.enc.partial.*'))
        records=list(d.glob('.ps2-partial-*.json'))
        assert len(partials)==1 and len(records)==1,(partials,records)
        record=json.loads(records[0].read_text())
        assert record['kind']=='partial' and record['jobID']==job and record['partial']==partials[0].name,record
        assert not (d/'killed.enc').exists()
        # With the writer gone the lock is released, so cleanup can reclaim it.
        import fcntl
        fd=os.open(partials[0],os.O_RDONLY)
        try:
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except OSError:
            raise AssertionError('a dead writer must not still hold the partial lock')
        os.close(fd)
        partials[0].unlink();records[0].unlink()
        passed.append('force-killed helper leaves validated partial provenance and no published output')
        if args.reference:
            ref=d/'reference.enc'
            p=subprocess.run([str(args.reference),'e','cex',str(key),str(source),str(ref),'ISO.BIN.ENC',CID],capture_output=True)
            assert p.returncode==0
            assert ref.read_bytes()[SEG:]==enc.read_bytes()[SEG:]
            run('verify',ref,key,1)
            passed.append('pinned upstream encrypted segment equivalence and header verification')
    print(json.dumps({'passed':True,'helper':binary_info(args.helper),'checks':passed},indent=2))

if __name__=='__main__':main()
