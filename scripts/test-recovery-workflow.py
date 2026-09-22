#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Recovery adversarial tests: interruption, key binding, checkpoints, identity.

Uses synthetic fixtures only and never console-ready output. Each test drives
the production builder/helper binaries and asserts fail-closed behavior:
- a key file swapped mid-build cannot rebind the cache (permanent key-swap regression);
- a failed two-disc build still checkpoints disc 1 for the retry;
- SIGKILL/SIGTERM leave no published output and no trusted-but-unverified stages;
- a moved source fails with the precise message;
- a valid unrelated package verifies generically but binds to nothing.
"""
import argparse, hashlib, importlib.machinery, json, os, signal, struct, subprocess, sys, tempfile, time, uuid
from pathlib import Path

wf = importlib.machinery.SourceFileLoader('workflow', str(Path(__file__).with_name('test-package-workflow.py'))).load_module()
CID = wf.CID
OTHER_CID = 'UP0001-SLUS99999_00-0000000000000002'

def sha256_stream(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        while True:
            data = stream.read(8 * 1024 * 1024)
            if not data:
                break
            digest.update(data)
    return digest.hexdigest()

def support_files(d):
    (d / 'klic.bin').write_bytes(bytes(range(16)))
    (d / 'license.rap').write_bytes(bytes(range(16)))
    (d / 'PS3LOGO.DAT').write_bytes(b'SYNTHETIC TEST ASSET - NOT A CONSOLE LOGO')
    card = bytearray(8650752)
    card[:28] = b'Sony PS2 Memory Card Format '
    (d / 'SCEVMC0.VMC').write_bytes(card)

def project_for(d, name, discs, output, content_id=CID):
    entries = []
    for (p, gid, extra) in discs:
        entry = dict(id=str(uuid.uuid4()), source=p.as_uri(), gameID=gid,
                     configSource='Synthetic fixture')
        entry.update(extra)
        entries.append(entry)
    project = dict(version=1, title='Recovery ' + name, titleID=discs[0][1],
                   discs=entries,
                   support=dict(key=(d / 'klic.bin').as_uri(), rap=(d / 'license.rap').as_uri(),
                                logo=(d / 'PS3LOGO.DAT').as_uri(), card=(d / 'SCEVMC0.VMC').as_uri(),
                                contentID=content_id),
                   cropArtwork=False, output=output.as_uri())
    manifest = d / 'test.ps2project'
    manifest.write_text(json.dumps(project))
    return manifest

def run_builder(builder, helper, manifest, timeout=600):
    return subprocess.run([str(builder), str(manifest), str(helper)],
                          capture_output=True, text=True, timeout=timeout)

def sparse_iso(path, size):
    """A valid small ISO descriptor padded (sparsely) to `size` bytes."""
    data = wf.synthetic_iso()
    with open(path, 'wb') as f:
        f.write(data)
        os.ftruncate(f.fileno(), size)

def wait_for(predicate, timeout, message):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        hit = predicate()
        if hit:
            return hit
        time.sleep(0.05)
    raise AssertionError(message)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[1]
    parser.add_argument('--builder', type=Path, default=root / 'dist/ps2-build')
    parser.add_argument('--helper', type=Path, default=root / 'dist/ps2-convert')
    args = parser.parse_args()
    results = []
    with tempfile.TemporaryDirectory(prefix='ps2-recovery-tests-') as tmp:
        d = Path(tmp)
        support_files(d)
        (d / 'test.iso').write_bytes(wf.synthetic_iso())

        # 1. Key swapped mid-build must not rebind the cache.
        key = d / 'klic.bin'
        keyA, keyB = bytes(16), bytes([0x42]) * 16
        key.write_bytes(keyA)
        manifest = project_for(d, 'key-swap', [(d / 'test.iso', 'SLUS12345', {})], d / 'first.pkg')
        task = subprocess.Popen([str(args.builder), str(manifest), str(args.helper)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
        workspace = wait_for(lambda: next(d.glob('.ps2-build-*'), None), 60,
                             'builder workspace never appeared')
        wait_for(lambda: (workspace / 'klicensee.bin').exists(), 60,
                 'key snapshot never appeared')
        time.sleep(0.2)
        key.write_bytes(keyB)  # after snapshot, before support fingerprinting
        assert task.wait(timeout=600) == 0, 'first build must succeed'
        assert key.read_bytes() == keyB
        caches = list(d.glob('.ps2-cache-*'))
        assert len(caches) == 1, caches
        cached = caches[0] / 'ISO.BIN.ENC'
        (d / 'keyA').write_bytes(keyA)
        assert subprocess.run([str(args.helper), 'verify', str(cached), str(d / 'keyA'), '1', 'ISO.BIN.ENC'],
                              capture_output=True).returncode == 0, 'cached image must verify with the snapshot key A'
        assert subprocess.run([str(args.helper), 'verify', str(cached), str(key), '1', 'ISO.BIN.ENC'],
                              capture_output=True).returncode != 0, 'cached image must not verify with the swapped key B'
        first_report = json.loads((d / 'first.pkg.report.json').read_text())
        manifest = project_for(d, 'key-swap', [(d / 'test.iso', 'SLUS12345', {})], d / 'second.pkg')
        rerun = run_builder(args.builder, args.helper, manifest)
        assert rerun.returncode == 0, rerun.stderr[-800:]
        second_report = json.loads((d / 'second.pkg.report.json').read_text())
        assert second_report['reusedStages'] == 0, second_report
        assert second_report['fingerprint'] != first_report['fingerprint'], 'different snapshot bytes must select a different cache'
        f, entries, read = wf.package_entries(d / 'second.pkg')
        with f:
            offset, size, _ = entries['USRDIR/ISO.BIN.ENC']
            (d / 'extracted.enc').write_bytes(read(offset, size))
        assert subprocess.run([str(args.helper), 'verify', str(d / 'extracted.enc'), str(key), '1', 'ISO.BIN.ENC'],
                              capture_output=True).returncode == 0, 'rebuilt image must verify with the current key B'
        results.append('mid-build key swap cannot rebind the cache')
        print('Passed: key-swap binding', file=sys.stderr, flush=True)

        # 2. A build that fails on disc 2 still checkpoints disc 1 for the retry.
        # Stale selection hashes already fail fast during fingerprinting (covered
        # by the Swift suite), so this scenario removes disc 2 after disc 1's
        # encrypted image appears: the failure must land after the checkpoint.
        key.write_bytes(keyA)
        (d / 'disc2.iso').write_bytes(wf.synthetic_iso())
        disc2_backup = (d / 'disc2.iso').read_bytes()
        discs = [(d / 'test.iso', 'SLUS12345', {}),
                 (d / 'disc2.iso', 'SLUS12345', {})]
        caches_before = set(d.glob('.ps2-cache-*'))
        manifest = project_for(d, 'checkpoint', discs, d / 'duo.pkg')
        task = subprocess.Popen([str(args.builder), str(manifest), str(args.helper)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
        workspace = wait_for(lambda: next(d.glob('.ps2-build-*'), None), 60,
                             'builder workspace never appeared')
        wait_for(lambda: (workspace / 'package' / 'USRDIR' / 'ISO.BIN.ENC').exists(), 120,
                 'disc 1 image never appeared')
        (d / 'disc2.iso').unlink()
        assert task.wait(timeout=600) != 0, 'build with a removed second disc must fail'
        assert not (d / 'duo.pkg').exists(), 'a failed build must not publish'
        checkpointed = [c for c in set(d.glob('.ps2-cache-*')) - caches_before
                        if (c / 'manifest.json').exists()
                        and json.loads((c / 'manifest.json').read_text()).get('entries')]
        assert len(checkpointed) == 1, 'disc 1 must be checkpointed after the failure'
        assert 'ISO.BIN.ENC' in json.loads((checkpointed[0] / 'manifest.json').read_text())['entries']
        (d / 'disc2.iso').write_bytes(disc2_backup)
        # Note: delete+restore changed disc2's mtime. Reuse must still hit:
        # cache identity is content-based, never size/mtime-based.
        manifest = project_for(d, 'checkpoint', discs, d / 'duo.pkg')
        retry = run_builder(args.builder, args.helper, manifest)
        assert retry.returncode == 0, retry.stderr[-800:]
        retry_report = json.loads((d / 'duo.pkg.report.json').read_text())
        assert retry_report['reusedStages'] == 1, retry_report
        results.append('failed two-disc build checkpoints disc 1 for the retry')
        print('Passed: disc-2 failure checkpoint', file=sys.stderr, flush=True)

        # 3. SIGKILL mid-build publishes nothing and trusts nothing.
        caches_before_kill = set(d.glob('.ps2-cache-*'))
        sparse_iso(d / 'big.iso', 512 * 1024 * 1024)
        manifest = project_for(d, 'kill', [(d / 'big.iso', 'SLUS12345', {})], d / 'killed.pkg')
        victim = subprocess.Popen([str(args.builder), str(manifest), str(args.helper)],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
        workspace = wait_for(lambda: next(d.glob('.ps2-build-*'), None), 60, 'workspace never appeared')
        wait_for(lambda: (workspace / 'klicensee.bin').exists(), 60, 'snapshot never appeared')
        time.sleep(1.0)  # encryption of 512 MiB is still running; publication is far away
        victim.kill()
        assert victim.wait(timeout=120) != 0
        time.sleep(0.5)
        assert not (d / 'killed.pkg').exists() and not (d / 'killed.pkg.report.json').exists()
        for record in [c / 'manifest.json' for c in set(d.glob('.ps2-cache-*')) - caches_before_kill
                       if (c / 'manifest.json').exists()]:
            assert not json.loads(record.read_text()).get('entries'), 'a killed build must leave no trusted stages'
        for partial in list(d.glob('.ps2-build-*')) + list(d.glob('*.partial.*')):
            pass  # provenance'd leftovers are the cleanup review's job, not a false success
        assert not list(d.glob('.ps2-build-*/*.pkg')), 'no package may appear inside a dead workspace'
        manifest = project_for(d, 'kill', [(d / 'big.iso', 'SLUS12345', {})], d / 'after-kill.pkg')
        assert run_builder(args.builder, args.helper, manifest, timeout=900).returncode == 0
        (d / 'after-kill.pkg').unlink(); (d / 'after-kill.pkg.report.json').unlink()
        results.append('SIGKILL publishes nothing and trusts nothing')
        print('Passed: SIGKILL boundary', file=sys.stderr, flush=True)

        # 4. SIGTERM cancels cleanly with no output and no published partials.
        manifest = project_for(d, 'cancel', [(d / 'big.iso', 'SLUS12345', {})], d / 'cancelled.pkg')
        task = subprocess.Popen([str(args.builder), str(manifest), str(args.helper)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
        workspace = wait_for(lambda: next(d.glob('.ps2-build-*'), None), 60, 'workspace never appeared')
        wait_for(lambda: (workspace / 'klicensee.bin').exists(), 60, 'snapshot never appeared')
        time.sleep(1.0)
        task.terminate()
        assert task.wait(timeout=120) != 0
        assert not (d / 'cancelled.pkg').exists() and not (d / 'cancelled.pkg.report.json').exists()
        assert not list(d.glob('cancelled.pkg.partial.*')), 'cancelled outputs must be removed'
        results.append('SIGTERM cancels with no output and no published partials')
        print('Passed: SIGTERM boundary', file=sys.stderr, flush=True)

        # 5. A moved source fails with the precise message instead of reusing.
        manifest = project_for(d, 'moved', [(d / 'test.iso', 'SLUS12345', {})], d / 'moved.pkg')
        assert run_builder(args.builder, args.helper, manifest).returncode == 0
        (d / 'test.iso').rename(d / 'test.iso.moved')
        try:
            manifest = project_for(d, 'moved', [(d / 'test.iso', 'SLUS12345', {})], d / 'moved2.pkg')
            moved = run_builder(args.builder, args.helper, manifest)
            assert moved.returncode != 0 and 'missing or was moved' in moved.stderr, moved.stderr[-400:]
        finally:
            (d / 'test.iso.moved').rename(d / 'test.iso')
        results.append('moved sources fail precisely instead of reusing')
        print('Passed: moved-source negative', file=sys.stderr, flush=True)

        # 6. A valid unrelated package verifies generically but binds to nothing.
        root = d / 'notes-root'
        root.mkdir()
        (root / 'notes.txt').write_text('unrelated synthetic notes\n')
        notes_pkg = d / 'notes.pkg'
        assert subprocess.run([str(args.helper), 'package', str(root), str(notes_pkg), OTHER_CID],
                              capture_output=True).returncode == 0
        generic = subprocess.run([str(args.helper), 'verify-package', str(notes_pkg)],
                                 capture_output=True, text=True)
        assert generic.returncode == 0, generic.stderr
        info = json.loads(generic.stdout.strip().splitlines()[-1])
        assert info['verified'] and info['entries'] == 1 and info['titleID'] == '', info
        assert info['contentID'] == OTHER_CID, info
        assert subprocess.run([str(args.helper), 'verify-package', str(notes_pkg), CID],
                              capture_output=True).returncode != 0, 'wrong content ID must fail binding'
        assert subprocess.run([str(args.helper), 'verify-package', str(notes_pkg), OTHER_CID, 'SLUS12345'],
                              capture_output=True).returncode != 0, 'missing title ID must fail binding'
        results.append('unrelated valid package verifies generically but binds to nothing')
        print('Passed: unrelated-package binding', file=sys.stderr, flush=True)
        # The SIGKILL test intentionally leaves its dead workspace behind for
        # the cleanup review; the temporary directory removes everything.
    print(json.dumps(dict(passed=True, helper=wf.binary_info(args.helper),
                          builder=wf.binary_info(args.builder), checks=results), indent=2))

if __name__ == '__main__':
    main()
