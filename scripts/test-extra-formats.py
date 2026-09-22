#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Native package, EDAT, memory-card, raw-sector and logical-name regressions."""
import argparse,hashlib,json,struct,subprocess,tempfile
from pathlib import Path
from importlib.machinery import SourceFileLoader
workflow=SourceFileLoader('workflow',str(Path(__file__).with_name('test-package-workflow.py'))).load_module()
CID=workflow.CID
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--helper',type=Path,default=Path(__file__).resolve().parents[1]/'dist/ps2-convert');parser.add_argument('--reference',type=Path);parser.add_argument('--npdata',type=Path)
args=parser.parse_args();passed=[]
with tempfile.TemporaryDirectory(prefix='ps2-formats-') as tmp:
 d=Path(tmp);key=d/'klic.bin';key.write_bytes(bytes(range(16)));rap=d/'test.rap';rap.write_bytes(bytes(range(16)))
 def run(*parts,ok=True):
  p=subprocess.run([str(args.helper),*map(str,parts)],capture_output=True,text=True)
  assert (p.returncode==0)==ok,(parts,p.stderr);return p
 for offset in [16,24]:
  iso=workflow.synthetic_iso();raw=bytearray(24*2352)
  for sector in range(24):raw[sector*2352+offset:sector*2352+offset+2048]=iso[sector*2048:(sector+1)*2048]
  source=d/f'raw-{offset}.bin';source.write_bytes(raw);enc=d/f'raw-{offset}.enc';plain=d/f'raw-{offset}.out'
  run('encrypt-iso',source,enc,key,CID,1);run('decrypt',enc,plain,key,1)
  recovered=plain.read_bytes();assert recovered[:len(raw)]==raw;assert recovered[-16384:-16368]==b'LIMG'+struct.pack('>III',2,24,2352)
 passed.append('MODE1/2352 and MODE2/2352 preserve every raw byte and produce reference-layout LIMG')
 for name,disc in [('CONFIG',1),('CONFIG2',2),('ISO.BIN.ENC2',2)]:
  src=d/'config';src.write_bytes(bytes(range(31)));enc=d/(name+'.enc');out=d/(name+'.plain')
  run('encrypt-raw',src,enc,key,CID,disc,name);run('decrypt',enc,out,key,disc,name);assert out.read_bytes()==src.read_bytes()
  run('verify',enc,key,disc,'ISO.BIN.ENC',ok=False)
 passed.append('per-disc logical filenames and CONFIG header authentication')
 for size in [8650752,8667136]:
  src=d/f'card-{size}';card=bytearray(size);card[:28]=b'Sony PS2 Memory Card Format ';src.write_bytes(card)
  enc=d/f'card-{size}.vme';out=d/f'card-{size}.vmc'
  run('vmc-encrypt',src,enc);run('vmc-decrypt',enc,out);assert out.read_bytes()==card
  if args.reference:
   ref=d/f'card-{size}.reference';p=subprocess.run([str(args.reference),'ve','cex',str(src),str(ref)],capture_output=True)
   assert ref.read_bytes()==enc.read_bytes(),p.stderr
 passed.append('standard and extended memory-card round trips'+(' and pinned reference equivalence' if args.reference else ''))
 bad=d/'badcard';bad.write_bytes(bytes(8650752));run('vmc-encrypt',bad,d/'badout',ok=False);assert not (d/'badout').exists()
 run('edat','SLUS12345',d/'ISO.BIN.EDAT',key,rap,CID)
 if args.npdata:
  p=subprocess.run([str(args.npdata),'-v','-d','ISO.BIN.EDAT','edat.txt','8','test.rap'],cwd=d,capture_output=True,text=True)
  assert (d/'edat.txt').read_bytes()==b'SLUS_12345',p.stdout
  assert 'NPD title hash is valid!' in p.stdout and 'NPD dev hash is valid!' in p.stdout,p.stdout
  assert 'ERROR' not in p.stdout.upper(),p.stdout
  passed.append('independent make_npdata EDAT decryption, title/dev/header/metadata hash validation; placeholder signatures expected')
 root=d/'package';root.mkdir();(root/'EMPTY').write_bytes(b'');(root/'payload').write_bytes(bytes(range(255)))
 run('package',root,d/'test.pkg',CID)
 f,entries,read=workflow.package_entries(d/'test.pkg')
 with f:
  assert entries['EMPTY'][1]==0;offset,size,_=entries['payload'];assert read(offset,size)==bytes(range(255))
 (root/'alias').symlink_to(root/'payload');run('package',root,d/'bad.pkg',CID,ok=False);assert not (d/'bad.pkg').exists()
 passed.append('independent package extraction including empty files; symlink rejection')
 assert not list(d.glob('*.partial.*'))
print(json.dumps(dict(passed=True,helper=workflow.binary_info(args.helper),checks=passed),indent=2))
