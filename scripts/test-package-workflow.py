#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Complete package builds using generated support assets. Never console-ready output.
Independent Python decoding checks package indices, metadata and sampled image headers.
The native pipeline verifies every encrypted image and the entire package payload.
"""
import argparse, hashlib, json, os, struct, subprocess, sys, tempfile, time, uuid
from pathlib import Path

CID='UP0001-SLUS12345_00-0000000000000001'

def binary_info(path):
    digest=hashlib.sha256(path.read_bytes()).hexdigest()
    version=subprocess.run([str(path),'--version'],capture_output=True,text=True).stdout.strip()
    return dict(path=str(path),sha256=digest,version=version)
def synthetic_iso():
    data=bytearray(24*2048);p=16*2048;data[p]=1;data[p+1:p+6]=b'CD001';data[p+6]=1
    data[p+80:p+88]=struct.pack('<I',24)+struct.pack('>I',24);data[p+128:p+132]=b'\0\x08\x08\0'
    data[p+156]=34;data[p+158:p+162]=struct.pack('<I',20);data[p+166:p+170]=struct.pack('<I',2048)
    cnf=b'BOOT2 = cdrom0:\\SLUS_123.45;1\r\n';r=20*2048;name=b'SYSTEM.CNF;1'
    data[r]=46;data[r+2:r+6]=struct.pack('<I',21);data[r+10:r+14]=struct.pack('<I',len(cnf));data[r+32]=len(name);data[r+33:r+33+len(name)]=name;data[21*2048:21*2048+len(cnf)]=cnf
    return data

def package_entries(path):
    f=path.open('rb');header=f.read(128)
    assert header[:4]==b'\x7fPKG' and int.from_bytes(header[24:32],'big')==path.stat().st_size
    assert f.read(16)==hashlib.sha1(header).digest()[3:19]
    key=header[96:112];base=int.from_bytes(header[32:40],'big');length=int.from_bytes(header[40:48],'big')
    def read(offset,count):
        assert offset>=0 and count>=0 and offset+count<=length
        start=offset//16*16;f.seek(base+start);data=f.read((offset-start+count+15)//16*16);out=bytearray()
        for i in range(0,len(data),16):
            ctx=key[:8]*2+key[8:]*2+bytes(24)+struct.pack('>Q',(start+i)//16)
            out.extend(a^b for a,b in zip(data[i:i+16],hashlib.sha1(ctx).digest()))
        return bytes(out[offset-start:offset-start+count])
    entries={};count=int.from_bytes(header[20:24],'big');index=read(0,count*32)
    for i in range(count):
        nameoff,nlen,offset,size,flags,_=struct.unpack_from('>IIQQII',index,i*32)
        name=read(nameoff,nlen).decode('ascii');assert not name.startswith('/') and '..' not in name.split('/')
        assert offset+size<=length
        entries[name]=(offset,size,flags)
    return f,entries,read

def check_package(path,discs,titleid,sound=None):
    f,entries,read=package_entries(path)
    with f:
        def content(name):
            off,size,_=entries[name];return read(off,size)
        for name in ['PARAM.SFO','ICON0.PNG','PIC1.PNG','PS3LOGO.DAT','USRDIR/ISO.BIN.EDAT','USRDIR/SAVEDATA/SCEVMC0.VME','USRDIR/SAVEDATA/SCEVMC1.VME']: assert name in entries,name
        if sound is not None: assert content('SND0.AT3') == sound.read_bytes(), 'packaged sound differs from selected AT3'
        sfo=content('PARAM.SFO');assert sfo[:4]==b'\0PSF' and titleid.encode() in sfo
        for name,size in [('ICON0.PNG',(320,176)),('PIC1.PNG',(1920,1080))]:
            png=content(name);assert png[:8]==b'\x89PNG\r\n\x1a\n';assert struct.unpack('>II',png[16:24])==size
        for i,source in enumerate(discs):
            name='USRDIR/ISO.BIN.ENC'+(str(i+1) if i else '');offset,size,_=entries[name]
            head=read(offset,16384);assert head[:4]==b'PS2\0'
            assert int.from_bytes(head[0x88:0x90],'big')==(source.stat().st_size+16383)//16384*16384+16384
            assert read(offset+size-32,32)!=bytes(32)
        if len(discs)>1:
            assert content('USRDIR/DISC.IDX')==bytes([len(discs),0])
            for i in range(len(discs)): assert 'USRDIR/CONFIG'+(str(i+1) if i else '') in entries
        return len(entries)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    root=Path(__file__).resolve().parents[1]
    parser.add_argument('--builder',type=Path,default=root/'dist/ps2-build');parser.add_argument('--helper',type=Path,default=root/'dist/ps2-convert');parser.add_argument('--roms',type=Path)
    parser.add_argument('--chdman',type=Path,help='Create CHDs with this independent tool and build from those instead.')
    parser.add_argument('--report',type=Path,help='Write the JSON result summary to this path.')
    parser.add_argument('--sound',type=Path,help='Include this test AT3 and independently compare its packaged bytes.')
    args=parser.parse_args();results=[]
    with tempfile.TemporaryDirectory(prefix='ps2-package-tests-') as tmp:
        d=Path(tmp);(d/'klic.bin').write_bytes(bytes(range(16)));(d/'license.rap').write_bytes(bytes(range(16)))
        (d/'PS3LOGO.DAT').write_bytes(b'SYNTHETIC TEST ASSET - NOT A CONSOLE LOGO')
        card=bytearray(8650752);card[:28]=b'Sony PS2 Memory Card Format ';(d/'SCEVMC0.VMC').write_bytes(card)
        (d/'test.iso').write_bytes(synthetic_iso())
        cases=[('synthetic single',[(d/'test.iso','SLUS12345')]),('synthetic multi',[(d/'test.iso','SLUS12345'),(d/'test.iso','SLUS12345')])]
        if args.roms:
            cases += [('CD-sized',[(args.roms/'4x4 Evo 2 (Europe).iso','SLES51199')]),('DVD9',[(args.roms/'Xenosaga Episode 1.iso','SLUS20469')]),('two-disc',[(args.roms/'Xenosaga Episode 2 (Disc 1).iso','SLUS20892'),(args.roms/'Xenosaga Episode 2 (Disc 2).iso','SLUS21133')])]
        chds={}
        def fingerprint(path):
            digest=hashlib.sha256()
            with path.open('rb') as stream:
                while data:=stream.read(8*1024*1024):digest.update(data)
            return digest.hexdigest()
        for number,(name,discs) in enumerate(cases):
            original_discs=discs
            if args.chdman:
                compressed=[]
                for source,gid in discs:
                    if source not in chds:
                        before=fingerprint(source);chd=d/f'compressed-{len(chds)}.chd'
                        create=subprocess.run([str(args.chdman),'createdvd','-i',str(source),'-o',str(chd),'-c','zstd','-np','2'],capture_output=True,text=True)
                        assert create.returncode==0,create.stderr
                        assert fingerprint(source)==before
                        chds[source]=chd
                    compressed.append((chds[source],gid))
                discs=compressed;name+=' via CHD'
                print('Prepared: '+name,file=sys.stderr,flush=True)
            output=d/f'case-{number}.pkg'
            project=dict(version=1,title='Workflow test '+name,titleID=discs[0][1],discs=[dict(id=str(uuid.uuid4()),source=p.as_uri(),gameID=gid,configSource='Synthetic fixture') for p,gid in discs],support=dict(key=(d/'klic.bin').as_uri(),rap=(d/'license.rap').as_uri(),logo=(d/'PS3LOGO.DAT').as_uri(),card=(d/'SCEVMC0.VMC').as_uri(),contentID=CID),cropArtwork=False,output=output.as_uri())
            if args.sound: project['sound']=args.sound.resolve().as_uri()
            manifest=d/'test.ps2project';manifest.write_text(json.dumps(project))
            start=time.monotonic();run=subprocess.run([str(args.builder),str(manifest),str(args.helper)],capture_output=True,text=True)
            assert run.returncode==0,(name,run.stderr,run.stdout[-1000:])
            entries=check_package(output,[p for p,_ in original_discs],discs[0][1],args.sound)
            report=json.loads(Path(str(output)+'.report.json').read_text());assert all(d['originalUnchanged'] for d in report['discs'])
            # Read-only package verification must accept the real package and reject tampering.
            # Mutations use bounded sparse copies, never whole multi-gigabyte reads.
            def sparse_mutant(path, offset, name):
                size = path.stat().st_size
                assert 0 <= offset < size
                mutant = d / name
                with open(path, 'rb') as src, open(mutant, 'wb') as dst:
                    head = bytearray(src.read(offset + 1))
                    head[offset] ^= 1
                    dst.write(head)
                    os.ftruncate(dst.fileno(), size)
                return mutant
            verified=subprocess.run([str(args.helper),'verify-package',str(output)],capture_output=True,text=True)
            assert verified.returncode==0,verified.stderr
            info=json.loads(verified.stdout.strip().splitlines()[-1]);assert info['verified'] and info['entries']==entries and info['payloadBytes']>0,info
            assert info['contentID']==CID and info['titleID']==discs[0][1],info
            assert any(n.endswith('ISO.BIN.ENC') for n in info['names']),info
            tampered = sparse_mutant(output, 0x140 + 64, 'tampered.pkg')
            assert subprocess.run([str(args.helper),'verify-package',str(tampered)],capture_output=True).returncode!=0
            truncated = d / 'truncated.pkg'
            with open(truncated, 'wb') as dst: os.ftruncate(dst.fileno(), output.stat().st_size - 1)
            assert subprocess.run([str(args.helper),'verify-package',str(truncated)],capture_output=True).returncode!=0
            for leftover in ('tampered.pkg', 'truncated.pkg'):
                (d / leftover).unlink()
            duplicate=subprocess.run([str(args.builder),str(manifest),str(args.helper)],capture_output=True,text=True)
            assert duplicate.returncode!=0 and 'already exists' in duplicate.stderr,duplicate.stderr[-400:]
            if name=='synthetic single':
                # A second build with identical inputs must reuse the verified encrypted image.
                second=d/'case-cache.pkg';project['output']=second.as_uri();manifest.write_text(json.dumps(project))
                rerun=subprocess.run([str(args.builder),str(manifest),str(args.helper)],capture_output=True,text=True);assert rerun.returncode==0,rerun.stderr[-800:]
                cached=json.loads(Path(str(second)+'.report.json').read_text());assert cached['reusedStages']>=1,cached
                # A changed content ID changes the fingerprint and must not reuse.
                third=d/'case-nocache.pkg';project['output']=third.as_uri();project['support']['contentID']='UP0001-SLUS12345_00-0000000000000002';manifest.write_text(json.dumps(project))
                fresh=subprocess.run([str(args.builder),str(manifest),str(args.helper)],capture_output=True,text=True);assert fresh.returncode==0,fresh.stderr[-800:]
                changed=json.loads(Path(str(third)+'.report.json').read_text());assert changed['reusedStages']==0,changed
                for extra in (second,third): extra.unlink();Path(str(extra)+'.report.json').unlink()
                results.append(dict(case='stage cache reuse + content-ID invalidation',reusedStages=cached['reusedStages'],invalidatedStages=changed['reusedStages']))
            results.append(dict(case=name,bytes=output.stat().st_size,entries=entries,payloadVerified=info['payloadBytes'],seconds=round(time.monotonic()-start,2),discs=report['discs'],consoleTested=False))
            print('Passed: '+name,file=sys.stderr,flush=True)
            output.unlink();Path(str(output)+'.report.json').unlink()
        assert not list(d.glob('.ps2-build-*'))
    summary=dict(passed=True,helper=binary_info(args.helper),builder=binary_info(args.builder),results=results)
    if args.report:
        args.report.write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary,indent=2))
if __name__=='__main__':main()
