#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Independent MAME chdman fixtures; no games or production support assets required."""
import argparse,hashlib,importlib.machinery,json,struct,subprocess,sys,tempfile,uuid,resource
from pathlib import Path
wf=importlib.machinery.SourceFileLoader('workflow',str(Path(__file__).with_name('test-package-workflow.py'))).load_module()
p=argparse.ArgumentParser();p.add_argument('--chdman',type=Path,required=True);p.add_argument('--helper',type=Path,required=True);p.add_argument('--builder',type=Path,required=True);a=p.parse_args()
def run(args,ok=True):
 r=subprocess.run(list(map(str,args)),capture_output=True,text=True,timeout=120)
 assert (r.returncode==0)==ok,(args,r.stdout[-1500:],r.stderr[-1500:]);return r
with tempfile.TemporaryDirectory(prefix='ps2-chd-check-') as tmp:
 d=Path(tmp);iso=d/'source.iso';data=wf.synthetic_iso()+bytes((i*31+i//17)%256 for i in range(2048*104));iso.write_bytes(data)
 # Includes bytes after the declared volume, deliberately testing preservation.
 fixtures=[]
 for codec in ['none','zlib','lzma','zstd','huff','flac']:
  chd=d/(codec+'.chd');run([a.chdman,'createdvd','-i',iso,'-o',chd,'-c',codec,'-np','2']);fixtures.append((chd,data,iso))
 for track,width,offset in [('MODE1/2048',2048,0),('MODE1/2352',2352,16),('MODE2/2352',2352,24)]:
  raw=bytearray()
  for i in range(len(data)//2048):
   sector=bytearray(width);sector[offset:offset+2048]=data[i*2048:(i+1)*2048]
   if width==2352:sector[:12]=bytes([0]+[255]*10+[0]);sector[15]=1 if offset==16 else 2
   raw+=sector
  name=track.replace('/','-');bin=d/(name+'.bin');bin.write_bytes(raw);cue=d/(name+'.cue');cue.write_text(f'FILE "{bin.name}" BINARY\n TRACK 01 {track}\n INDEX 01 00:00:00\n')
  for codec in ['cdzl','cdlz','cdzs','cdfl']:
   chd=d/(name+'-'+codec+'.chd');run([a.chdman,'createcd','-i',cue,'-o',chd,'-c',codec,'-np','2']);fixtures.append((chd,bytes(raw),bin))
 for chd,expected,source in fixtures:
  before=hashlib.sha256(chd.read_bytes()).hexdigest();probe=json.loads(run([a.helper,'inspect-chd',chd]).stdout)
  assert probe['gameID']=='SLUS12345' and probe['expandedByteCount']==len(expected),probe
  out=d/(chd.stem+'.image');run([a.helper,'extract-chd',chd,out]);assert out.read_bytes()==expected,chd
  assert hashlib.sha256(chd.read_bytes()).hexdigest()==before
  run([a.helper,'extract-chd',chd,out],False);assert out.read_bytes()==expected
  print('Passed exact extraction:',chd.name,file=sys.stderr,flush=True)
 # Reject malformed hashes, parent CHDs and unsupported multi-track layouts.
 original=(d/'zlib.chd').read_bytes()
 for name,mutation in [('bad-sha1',lambda b:b.__setitem__(64,b[64]^1)),('parent',lambda b:b.__setitem__(104,1)),('bad-hunk',lambda b:b.__setitem__(slice(56,60),struct.pack('>I',0x7fffffff)))]:
  bad=bytearray(original);mutation(bad);path=d/(name+'.chd');path.write_bytes(bad);out=d/(name+'.iso');run([a.helper,'extract-chd',path,out],False);assert not out.exists()
 trunc=d/'truncated.chd';trunc.write_bytes(original[:130]);run([a.helper,'extract-chd',trunc,d/'bad.iso'],False)
 cue=d/'mixed.cue';cue.write_text('FILE "MODE1-2352.bin" BINARY\n TRACK 01 MODE1/2352\n INDEX 01 00:00:00\n TRACK 02 AUDIO\n INDEX 01 00:01:00\n')
 mixed=d/'mixed.chd';run([a.chdman,'createcd','-i',cue,'-o',mixed,'-np','2']);run([a.helper,'inspect-chd',mixed],False)
 # Genuine parent-dependent pair from the pinned v5 layout (scripts/synth_chd.py,
 # no chdman needed): the parent must expand byte-exact through the helper, and
 # the child — identical except a real nonzero parentsha1 — must be rejected
 # precisely rather than misread. This complements the byte-flip proxies above.
 synth=importlib.machinery.SourceFileLoader('synth',str(Path(__file__).with_name('synth_chd.py'))).load_module()
 logical=bytes(wf.synthetic_iso());assert len(logical)%synth.HUNK==0
 genuine_parent=d/'genuine-parent.chd';genuine_child=d/'genuine-child.chd'
 combined=synth.write_dvd_parent(genuine_parent,logical)
 probe=json.loads(run([a.helper,'inspect-chd',genuine_parent]).stdout)
 assert probe['gameID']=='SLUS12345' and probe['expandedByteCount']==len(logical),probe
 genuine_out=d/'genuine-parent.image';run([a.helper,'extract-chd',genuine_parent,genuine_out])
 assert genuine_out.read_bytes()==logical
 before_parent=hashlib.sha256(genuine_parent.read_bytes()).hexdigest()
 synth.write_dvd_child(genuine_child,genuine_parent,combined)
 assert genuine_child.read_bytes()[104:124]==combined!=bytes(20)
 probe=json.loads(run([a.helper,'inspect-chd',genuine_child]).stdout)
 assert probe.get('requiresParent') is True and probe.get('parentSHA1')==combined.hex(),probe
 failed=run([a.helper,'extract-chd',genuine_child,d/'genuine-child.image'],False)
 assert 'Parent-dependent CHDs must be flattened' in failed.stderr,failed.stderr[-500:]
 assert not (d/'genuine-child.image').exists()
 assert hashlib.sha256(genuine_parent.read_bytes()).hexdigest()==before_parent
 print('Passed genuine parent/child rejection',file=sys.stderr,flush=True)
 # Reference parent/child chains from chdman itself: the helper must expand
 # the child byte-exact (matching both the input and chdman's own
 # extraction), and must refuse wrong, nested and self parents precisely.
 p_iso=d/'chain-p.iso';c_iso=d/'chain-c.iso'
 p_iso.write_bytes(bytes(wf.synthetic_iso()))
 c_data=bytearray(p_iso.read_bytes());c_data[40000]^=1;c_iso.write_bytes(bytes(c_data))
 p_chd=d/'chain-p.chd';c_chd=d/'chain-c.chd'
 run([a.chdman,'createdvd','-i',p_iso,'-o',p_chd,'-c','zstd','-np','2'])
 run([a.chdman,'createdvd','-i',c_iso,'-o',c_chd,'-op',p_chd,'-c','zstd','-np','2'])
 # A deeper chain from the synthetic pair: the grandchild declares the
 # (parent-dependent) child as its parent, which must be refused as nested.
 g_chd=d/'chain-g.chd'
 synth.write_dvd_child(g_chd,genuine_child,genuine_child.read_bytes()[84:104])
 probe=json.loads(run([a.helper,'inspect-chd',c_chd]).stdout)
 assert probe.get('requiresParent') is True and probe.get('parentSHA1')==c_chd.read_bytes()[104:124].hex(),probe
 probe=json.loads(run([a.helper,'inspect-chd',c_chd,p_chd]).stdout)
 assert probe['gameID']=='SLUS12345' and probe['expandedByteCount']==len(c_iso.read_bytes()),probe
 helper_out=d/'chain-c.image';run([a.helper,'extract-chd',c_chd,helper_out,p_chd])
 assert helper_out.read_bytes()==c_iso.read_bytes()
 ref_out=d/'chain-c.ref.iso';run([a.chdman,'extractdvd','-i',c_chd,'-ip',p_chd,'-o',ref_out])
 assert ref_out.read_bytes()==c_iso.read_bytes()==helper_out.read_bytes()
 wrong=run([a.helper,'extract-chd',c_chd,d/'chain-wrong.image',d/'zlib.chd'],False)
 assert 'not this image' in wrong.stderr and 'identity mismatch' in wrong.stderr,wrong.stderr[-500:]
 assert not (d/'chain-wrong.image').exists()
 nested=run([a.helper,'extract-chd',g_chd,d/'chain-nested.image',c_chd],False)
 assert 'single-level' in nested.stderr,nested.stderr[-500:]
 assert not (d/'chain-nested.image').exists()
 selfed=run([a.helper,'inspect-chd',c_chd,c_chd],False)
 assert 'same file' in selfed.stderr,selfed.stderr[-500:]
 unneeded=run([a.helper,'inspect-chd',p_chd,p_chd],False)
 assert 'declares no parent' in unneeded.stderr,unneeded.stderr[-500:]
 print('Passed reference parent/child parity and refusals',file=sys.stderr,flush=True)
 # A parent-CHD disc must build into an independently decoded package.
 for name in ['pkey','prap']: (d/name).write_bytes(bytes(range(16)))
 (d/'plogo').write_bytes(b'NOT A CONSOLE LOGO');pcard=bytearray(8650752);pcard[:28]=b'Sony PS2 Memory Card Format ';(d/'pcard').write_bytes(pcard)
 out=d/'package-parent-chd.pkg'
 project=dict(version=1,title='Parent CHD fixture',titleID='SLUS12345',discs=[dict(id=str(uuid.uuid4()),source=c_chd.as_uri(),gameID='SLUS12345',configSource='Synthetic',chdParent=p_chd.as_uri())],support=dict(key=(d/'pkey').as_uri(),rap=(d/'prap').as_uri(),logo=(d/'plogo').as_uri(),card=(d/'pcard').as_uri(),contentID=wf.CID),cropArtwork=False,output=out.as_uri())
 manifest=d/'project-parent.ps2project';manifest.write_text(json.dumps(project));run([a.builder,manifest,a.helper]);wf.check_package(out,[c_iso],'SLUS12345');print('Passed parent-CHD package',file=sys.stderr,flush=True)
 # Non-CHD and versioned headers fail with precise reports, not generic errors.
 garbage=d/'garbage.chd';garbage.write_bytes(bytes(200)+b'not a chd'+bytes(200))
 failed=run([a.helper,'inspect-chd',garbage],False);assert 'Not a CHD image' in failed.stderr,failed.stderr[-300:]
 v4=bytearray((d/'zlib.chd').read_bytes());v4[12:16]=struct.pack('>I',4);v4path=d/'v4.chd';v4path.write_bytes(bytes(v4))
 failed=run([a.helper,'inspect-chd',v4path],False);assert 'version 4' in failed.stderr,failed.stderr[-300:]
 # Fail a real write and interrupt extraction; neither may publish partial output.
 def limit_output():resource.setrlimit(resource.RLIMIT_FSIZE,(1024,1024))
 fault=d/'write-fault.iso'
 failed=subprocess.run([str(a.helper),'extract-chd',str(fixtures[0][0]),str(fault)],capture_output=True,preexec_fn=limit_output)
 assert failed.returncode!=0 and not fault.exists()
 large=d/'cancel-source.iso'
 with large.open('wb') as f:f.write(data);f.truncate(512*1024*1024)
 cancel_chd=d/'cancel.chd';run([a.chdman,'createdvd','-i',large,'-o',cancel_chd,'-c','none','-np','2'])
 cancel_out=d/'cancelled.iso'
 task=subprocess.Popen([str(a.helper),'extract-chd',str(cancel_chd),str(cancel_out)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 assert b'extract CHD' in task.stdout.readline()
 task.terminate();stdout,stderr=task.communicate(timeout=30)
 assert task.returncode!=0 and not cancel_out.exists(),(task.returncode,stderr)
 assert not list(d.glob('*.partial.*'))
 print('Passed extraction cancellation and write failure',file=sys.stderr,flush=True)
 # CHD to complete, independently decoded package, with synthetic support.
 for name in ['key','rap']: (d/name).write_bytes(bytes(range(16)))
 (d/'logo').write_bytes(b'NOT A CONSOLE LOGO');card=bytearray(8650752);card[:28]=b'Sony PS2 Memory Card Format ';(d/'card').write_bytes(card)
 for index,(chd,expected,source) in enumerate([fixtures[3],fixtures[-1]]):
  out=d/f'package-{index}.pkg'
  project=dict(version=1,title='CHD workflow fixture',titleID='SLUS12345',discs=[dict(id=str(uuid.uuid4()),source=chd.as_uri(),gameID='SLUS12345',configSource='Synthetic')],support=dict(key=(d/'key').as_uri(),rap=(d/'rap').as_uri(),logo=(d/'logo').as_uri(),card=(d/'card').as_uri(),contentID=wf.CID),cropArtwork=False,output=out.as_uri())
  manifest=d/'project.ps2project';manifest.write_text(json.dumps(project));run([a.builder,manifest,a.helper]);wf.check_package(out,[source],'SLUS12345');print('Passed CHD package:',chd.name,file=sys.stderr,flush=True)
 assert not list(d.glob('.ps2-build-*')) and not list(d.glob('*.partial.*'))
 print(json.dumps(dict(passed=True,helper=wf.binary_info(a.helper),builder=wf.binary_info(a.builder),chdman=str(a.chdman),exactExtractions=len(fixtures),packages=3,negativeCases=14)))
