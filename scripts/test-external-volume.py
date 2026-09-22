#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise the app against real mounted filesystems (exFAT, FAT32 and APFS disk
images). This is stronger than injected limits: it uses actual filesystems, so
it covers large-file handling, the FAT32 per-file cap and a forced
disconnection mid-build. It never touches a user's existing drive — only
disposable disk images created in a temporary directory.

Usage: python3 scripts/test-external-volume.py [--builder dist/ps2-build] [--helper dist/ps2-convert]
"""
import argparse
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CID = "UP0001-SLUS12345_00-0000000000000001"


def run(*args, **kw):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, **kw)


def make_support(folder: Path):
    (folder / "klic.bin").write_bytes(bytes(range(16)))
    (folder / "license.rap").write_bytes(bytes(range(16, 32)))
    (folder / "PS3LOGO.DAT").write_bytes(b"SYNTHETIC TEST ASSET - NOT A CONSOLE LOGO")
    card = bytearray(8650752); card[:28] = b"Sony PS2 Memory Card Format  "[:28]
    (folder / "SCEVMC0.VMC").write_bytes(bytes(card))


def make_iso(path: Path, extra_bytes: int = 0):
    data = bytearray(24 * 2048); p = 16 * 2048
    data[p] = 1; data[p + 1:p + 6] = b"CD001"; data[p + 6] = 1
    data[p + 80] = 24; data[p + 87] = 24; data[p + 129] = 8; data[p + 130] = 8
    with open(path, "wb") as handle:
        handle.write(data)
        if extra_bytes:
            handle.seek(len(data) + extra_bytes - 1)
            handle.write(b"\0")


def make_project(folder: Path, output: Path) -> Path:
    def uri(n): return (folder / n).as_uri()
    project = {
        "version": 1, "title": "External volume test", "titleID": "SLUS12345",
        "discs": [{"id": str(uuid.uuid4()), "source": uri("disc.iso"), "gameID": "SLUS12345",
                   "config": None, "configHash": None, "configSource": "synthetic"}],
        "support": {"key": uri("klic.bin"), "rap": uri("license.rap"), "logo": uri("PS3LOGO.DAT"),
                    "card": uri("SCEVMC0.VMC"), "contentID": CID, "sourceFolder": None},
        "icon": None, "background": None, "sound": None, "cropArtwork": False, "output": output.as_uri(),
    }
    manifest = folder / "project.ps2project"
    manifest.write_text(json.dumps(project))
    return manifest


def attach(image: Path):
    out = run("hdiutil", "attach", image, "-nobrowse", "-noverify").stdout
    for line in out.splitlines():
        if "/Volumes/" in line:
            return Path(line.split("\t")[-1].strip())
    raise SystemExit(f"could not mount {image}")


def detach(mount: Path, force=False):
    args = ["hdiutil", "detach", str(mount), "-quiet"]
    if force:
        args.insert(2, "-force")
    run(*args)


def mount_image(work: Path, name: str, size: str, fs: str) -> Path:
    image = work / f"{name}.dmg"
    created = run("hdiutil", "create", "-size", size, "-fs", fs, "-volname", name, image, "-quiet")
    if created.returncode != 0:
        raise SystemExit(f"could not create {fs} image: {created.stderr}")
    return attach(image)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--builder", type=Path, default=ROOT / "dist/ps2-build")
    parser.add_argument("--helper", type=Path, default=ROOT / "dist/ps2-convert")
    args = parser.parse_args()
    checks = []

    with tempfile.TemporaryDirectory(prefix="ps2-extvol-") as tmp:
        work = Path(tmp)
        src = work / "src"; src.mkdir()
        make_support(src); make_iso(src / "disc.iso")

        # --- exFAT: fail closed before creating a misleading output ---
        exfat = mount_image(work, "PS2ExFAT", "600m", "ExFAT")
        try:
            checked = run("swift", "test", "--filter", "testRealMountedVolumeFilesystemDetection",
                          env=dict(os.environ, PS2_TEST_VOLUME=str(exfat)))
            assert checked.returncode == 0, checked.stdout + checked.stderr
            manifest = make_project(src, exfat / "out.pkg")
            built = run(args.builder, manifest, args.helper)
            assert built.returncode != 0, "exFAT must not use the unsafe placeholder/rename fallback"
            assert "cannot safely publish" in built.stderr, built.stderr
            assert not (exfat / "out.pkg").exists(), "no empty or partial final file may be left behind"
            assert not list(exfat.glob(".ps2-*-test-*")), "publication probes must be removed"
            checks.append({"case": "exFAT unsupported exclusive publication refused before build", "passed": True})
        finally:
            detach(exfat)

        # --- FAT32: a >4 GiB single file must be refused by the real filesystem ---
        fat32 = mount_image(work, "PS2FAT32", "64m", "MS-DOS")
        try:
            checked = run("swift", "test", "--filter", "testRealMountedVolumeFilesystemDetection",
                          env=dict(os.environ, PS2_TEST_VOLUME=str(fat32)))
            assert checked.returncode == 0, checked.stdout + checked.stderr
            make_iso(src / "big.iso", extra_bytes=int(4_300e6))  # sparse; encoded single file exceeds 4 GiB
            def uri(n): return (src / n).as_uri()
            project = json.loads(make_project(src, fat32 / "big.pkg").read_text())
            project["discs"][0]["source"] = uri("big.iso")
            (src / "big.ps2project").write_text(json.dumps(project))
            result = run(args.builder, src / "big.ps2project", args.helper)
            assert result.returncode != 0, "a >4 GiB image must not build to FAT32"
            detail = result.stderr + result.stdout
            assert "msdos" in detail, f"FAT32 refusal did not name the filesystem: {detail[-300:]}"
            assert not (fat32 / "big.pkg").exists(), "nothing must be published on FAT32"
            checks.append({"case": "FAT32 per-file cap refused on real FAT32", "passed": True,
                           "detail": detail.strip().splitlines()[-1][:160]})
        finally:
            detach(fat32)

        # --- forced disconnection mid-build ---
        exfat = mount_image(work, "PS2Detach", "1g", "APFS")
        make_iso(src / "long.iso", extra_bytes=int(320e6))
        def uri2(n): return (src / n).as_uri()
        project = json.loads(make_project(src, exfat / "disc.pkg").read_text())
        project["discs"][0]["source"] = uri2("long.iso")
        (src / "long.ps2project").write_text(json.dumps(project))
        before = (src / "long.iso").stat().st_size
        process = subprocess.Popen([str(args.builder), str(src / "long.ps2project"), str(args.helper)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(3.0)
        detach(exfat, force=True)          # simulate the drive disappearing
        try:
            out, err = process.communicate(timeout=120)
        except subprocess.TimeoutExpired:
            process.kill(); out, err = process.communicate()
            raise SystemExit("build did not stop after the volume was disconnected")
        detail = (err or out).strip()
        assert process.returncode != 0, "a build must fail when its destination disappears"
        assert "needs about" not in detail, f"the build failed before reaching the write phase: {detail[-200:]}"
        assert not (exfat / "disc.pkg").exists(), "nothing must be published after a forced disconnection"
        assert (src / "long.iso").stat().st_size == before, "the original image must be unchanged"
        checks.append({"case": "forced disconnection mid-build fails cleanly", "passed": True,
                       "exit": process.returncode, "detail": (err or out).strip().splitlines()[-1][:160] if (err or out).strip() else ""})

    print(json.dumps({"passed": True, "checks": checks}, indent=2))
    for check in checks:
        print("Passed: " + check["case"], file=sys.stderr)


if __name__ == "__main__":
    main()
