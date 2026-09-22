#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic two-page PDF -> real packages -> independent FFmpeg BC1 decoding."""
import argparse, subprocess, tempfile
from pathlib import Path

def fixture():
    streams=[b'0 0 1 rg 0 0 960 768 re f 1 0 0 rg 0 384 960 384 re f',b'0 1 0 rg 0 0 960 768 re f']
    objects=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>']
    for number,stream in enumerate(streams):
        objects.append(('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 960 768] /Resources << >> /Contents %d 0 R >>'%(4+number*2)).encode())
        objects.append(b'<< /Length '+str(len(stream)).encode()+b' >>\nstream\n'+stream+b'\nendstream')
    result=b'%PDF-1.4\n';offsets=[0]
    for i,obj in enumerate(objects,1):
        offsets.append(len(result));result+=str(i).encode()+b' 0 obj\n'+obj+b'\nendobj\n'
    start=len(result);result+=b'xref\n0 7\n0000000000 65535 f \n'
    result+=b''.join(('%010d 00000 n \n'%off).encode() for off in offsets[1:])
    return result+b'trailer\n<< /Size 7 /Root 1 0 R >>\nstartxref\n'+str(start).encode()+b'\n%%EOF\n'

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--ffmpeg',required=True);args=parser.parse_args()
    root=Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='ps2-manual-fixture-') as tmp:
        manual=Path(tmp)/'manual.pdf';manual.write_bytes(fixture())
        subprocess.run(['python3',str(root/'scripts/test-package-workflow.py'),'--manual',str(manual),'--ffmpeg',args.ffmpeg],check=True)
