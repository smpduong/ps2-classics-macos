#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Validate the release artifacts and emit a machine-readable manifest.

Every check runs against the actual built bundle and the exact extracted
release archive, so a stale bundled resource or a wrong version can never pass
silently. Exits non-zero on the first failure.
"""
import argparse
import hashlib
import math
import json
import plistlib
import re
import subprocess
import sys
import tempfile
import tarfile
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "dist" / "PS2 Classics for Mac.app"
DOCS = ROOT / "docs"
THIRDPARTY = ROOT / "ThirdParty"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def run(*args, check=True):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(map(str, args))}\n{result.stdout}\n{result.stderr}")
    return result


def info_plist(app: Path) -> dict:
    with open(app / "Contents" / "Info.plist", "rb") as handle:
        return plistlib.load(handle)


def architectures(binary: Path) -> list:
    return run("lipo", "-archs", binary).stdout.split()


def min_os_versions(binary: Path) -> dict:
    versions = {}
    for arch in architectures(binary):
        out = run("vtool", "-show-build", "-arch", arch, binary).stdout
        match = re.search(r"minos\s+([0-9.]+)", out)
        if match:
            versions[arch] = match.group(1)
    return versions


def verify_signature(path: Path, deep=False):
    args = ["codesign", "--verify", "--strict"]
    if deep:
        args.append("--deep")
    run(*args, path)


def check_bundle(app: Path, version: str, build: str, manifest: dict, label: str):
    plist = info_plist(app)
    assert plist.get("CFBundleShortVersionString") == version, \
        f"{label}: CFBundleShortVersionString is {plist.get('CFBundleShortVersionString')!r}, expected {version!r}"
    assert plist.get("CFBundleVersion") == build, \
        f"{label}: CFBundleVersion is {plist.get('CFBundleVersion')!r}, expected {build!r}"
    assert plist.get("LSMinimumSystemVersion") == "12.0", f"{label}: minimum system version is not 12.0"
    verify_signature(app, deep=True)

    executables = [app / "Contents" / "MacOS" / "PS2ClassicsApp",
                   app / "Contents" / "Helpers" / "ps2-convert",
                   app / "Contents" / "Helpers" / "ps2-at3"]
    arch_report = {}
    os_report = {}
    for binary in executables:
        assert binary.exists(), f"{label}: missing executable {binary}"
        verify_signature(binary)
        archs = architectures(binary)
        assert "arm64" in archs and "x86_64" in archs, f"{label}: {binary.name} is not Universal: {archs}"
        minos = min_os_versions(binary)
        assert all(v == "12.0" for v in minos.values()), f"{label}: {binary.name} minos {minos}"
        arch_report[binary.name] = archs
        os_report[binary.name] = minos
    manifest[f"{label}Architectures"] = arch_report
    manifest[f"{label}MinOS"] = os_report

    # The bundled resources must match the source-of-truth docs/notices exactly.
    resources = app / "Contents" / "Resources"
    pairs = [("LICENSE.txt", ROOT / "LICENSE"), ("Licensing.md", ROOT / "LICENSING.md"),
             ("User Guide.md", DOCS / "USER_GUIDE.md"),
             ("PS2Classic-COPYING.txt", THIRDPARTY / "PS2Classic" / "COPYING"),
             ("PS2Classic-NOTICE.txt", THIRDPARTY / "PS2Classic" / "NOTICE.md"),
             ("atracdenc-LICENSE.txt", THIRDPARTY / "atracdenc" / "LICENSE"),
             ("libgha-LICENSE.txt", THIRDPARTY / "atracdenc" / "src" / "lib" / "libgha" / "LICENSE"),
             ("libsndfile-COPYING.txt", THIRDPARTY / "libsndfile" / "COPYING"),
             ("ATRAC-SOURCES.txt", THIRDPARTY / "ATRAC_SOURCES.md")]
    for packaged, source in pairs:
        bundled = resources / packaged
        assert bundled.exists(), f"{label}: bundled resource missing: {packaged}"
        assert sha256(bundled) == sha256(source), \
            f"{label}: bundled {packaged} does not match its source file (stale bundle)"
    manifest[f"{label}UserGuideSHA256"] = sha256(resources / "User Guide.md")
    manifest[f"{label}HelperSHA256"] = sha256(app / "Contents" / "Helpers" / "ps2-convert")
    for tree in ("atracdenc", "libsndfile"):
        for source in (THIRDPARTY / tree).rglob("*"):
            if source.is_file():
                bundled = resources / "Audio Sources" / tree / source.relative_to(THIRDPARTY / tree)
                assert bundled.is_file() and sha256(bundled) == sha256(source), f"{label}: missing/stale nested audio source notice {source.name}"
    manifest[f"{label}AT3HelperSHA256"] = sha256(app / "Contents" / "Helpers" / "ps2-at3")
    manifest[f"{label}ExecutableSHA256"] = sha256(app / "Contents" / "MacOS" / "PS2ClassicsApp")


def at3_encode_smoke(helper: Path, scratch: Path, label: str):
    """Encode a short synthetic WAV and confirm the ATRAC3 RIFF output, so a
    broken or mis-sliced encoder cannot pass release validation."""
    import struct, wave
    wav = scratch / "tone.wav"
    with wave.open(str(wav), "wb") as handle:
        handle.setnchannels(2); handle.setsampwidth(2); handle.setframerate(44100)
        frames = bytearray()
        for i in range(4410):  # 0.1 s
            sample = int(12000 * math.sin(2 * math.pi * 1000 * i / 44100))
            frames += struct.pack("<hh", sample, sample)
        handle.writeframes(bytes(frames))
    out = scratch / "tone.at3"
    result = run(helper, "-e", "atrac3", "--container", "riff", "-i", wav, "-o", out, check=False)
    assert result.returncode == 0 and out.is_file() and out.stat().st_size > 0, f"{label}: ps2-at3 produced no output\n{result.stdout}\n{result.stderr}"
    data = out.read_bytes()
    assert data[:4] == b"RIFF" and data[8:12] == b"WAVE", f"{label}: ps2-at3 output is not RIFF/WAVE"
    fmt_tag = int.from_bytes(data[20:22], "little")
    assert fmt_tag == 0x270, f"{label}: ps2-at3 output fmt tag is 0x{fmt_tag:03x}, expected ATRAC3 0x270"
    return out.stat().st_size


def check_release_records(version: str, build: str, label: str, short_version: str):
    """The acceptance template in the gate ledger is a hash-bound record: it
    must name this exact artifact, manifest, version/build and corresponding
    source archive, and must not retain any older source archive filename.
    Runs inside the release gate so future staleness fails loudly instead of
    shipping a checklist bound to the wrong source."""
    ledger = (DOCS / "RELEASE_GATE_LEDGER.md").read_text()
    marker = "## Acceptance results template"
    assert marker in ledger, "release gate ledger has no acceptance template"
    assert f"{marker} ({label})" in ledger, \
        f"acceptance template heading does not match this candidate ({label})"
    template = ledger.split(marker, 1)[1]
    expected = [
        f"dist/PS2 Classics for Mac {version} {label}.zip",
        f"dist/release-manifest-{version}-{label}.json",
        f"Version/build: {short_version} / {build}",
        f"dist/source-baseline-{version}-{label}.tar.gz",
    ]
    for text in expected:
        assert text in template, f"acceptance template is stale: missing {text!r}"
    stale = [line.strip() for line in template.splitlines()
             if "source-baseline-" in line and f"source-baseline-{version}-{label}.tar.gz" not in line]
    assert not stale, f"acceptance template retains an older source archive: {stale}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default="1.0")
    parser.add_argument("--build", default="10")
    parser.add_argument("--label", default="RC")
    args = parser.parse_args()
    short_version = args.version if args.version.count(".") >= 2 else f"{args.version}.0"
    zip_path = ROOT / "dist" / f"PS2 Classics for Mac {args.version} {args.label}.zip"
    sidecar = Path(str(zip_path) + ".sha256")

    assert APP.is_dir(), f"missing app bundle: {APP}"
    assert zip_path.is_file(), f"missing archive: {zip_path} (run scripts/make-archive.sh)"
    assert sidecar.is_file(), f"missing checksum sidecar: {sidecar}"

    zip_digest = sha256(zip_path)
    recorded = sidecar.read_text().split()[0]
    assert recorded == zip_digest, f"ZIP checksum mismatch: sidecar {recorded}, actual {zip_digest}"

    manifest = {
        "product": "PS2 Classics for Mac",
        "version": short_version,
        "build": args.build,
        "channel": "release-candidate" if args.label.upper().startswith("RC") else "release",
        "archive": zip_path.name,
        "archiveSHA256": zip_digest,
        "checks": [],
        "externalGates": [
            "Production support-file set matching a real console installation",
            "PS3 install/launch/save and Xenosaga II disc switching in both directions",
            "Intel Monterey MacBook Air and M4 Mac mini runtime acceptance",
            "Physical USB behavior on supported destination filesystems (large files, disconnection)",
            "PS3 acceptance of the encoded ATRAC3 audio",
            "PS3 acceptance of encoded manual display, FTP transfer/install, and imported-card saves",
            "Developer ID signing and notarization",
        ],
    }

    # Verify every archived source file against the present source tree without
    # extracting anything. The same allowlist excludes media and local state.
    spec = importlib.util.spec_from_file_location("source_baseline", ROOT / "scripts" / "make-source-baseline.py")
    baseline = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(baseline)
    expected = {str(path.relative_to(ROOT)): path for path in baseline.source_files()}
    source_path = ROOT / "dist" / f"source-baseline-{args.version}-{args.label}.tar.gz"
    assert source_path.is_file(), "missing source baseline (run scripts/make-source-baseline.py)"
    with tarfile.open(source_path, "r:gz") as archive:
        members = archive.getmembers()
        assert len(members) == len(expected) and {m.name for m in members} == set(expected), "source baseline file list is stale"
        for member in members:
            path = expected[member.name]
            assert member.isfile() and member.size == path.stat().st_size, f"invalid source member: {member.name}"
            digest = hashlib.sha256()
            with archive.extractfile(member) as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            assert digest.hexdigest() == sha256(path), f"stale source member: {member.name}"
    source_digest = sha256(source_path)
    assert Path(str(source_path) + ".sha256").read_text().split()[0] == source_digest, "source baseline checksum mismatch"
    manifest["sourceArchive"] = source_path.name
    manifest["sourceArchiveSHA256"] = source_digest
    manifest["sourceFileCount"] = len(expected)
    manifest["checks"].append("source archive matches the complete allowlisted source tree, excludes local media/state, and includes encoder dependencies")

    # Source bundle checks and hashes.
    check_bundle(APP, short_version, args.build, manifest, "source")
    manifest["checks"].append("source bundle version, signature, Universal slices, macOS 12 minos and resource freshness")

    # Standalone developer tools.
    standalone = {}
    for tool in ("ps2-convert", "ps2-inspect", "ps2-build", "ps2-at3"):
        binary = ROOT / "dist" / tool
        assert binary.is_file(), f"missing standalone tool: {binary}"
        archs = architectures(binary)
        assert "arm64" in archs and "x86_64" in archs, f"{tool} is not Universal: {archs}"
        verify_signature(binary)
        standalone[tool] = {"sha256": sha256(binary), "architectures": archs}
    manifest["standaloneTools"] = standalone
    manifest["checks"].append("standalone tools are Universal and strictly signed")
    with tempfile.TemporaryDirectory(prefix="ps2-at3-smoke-") as directory:
        size = at3_encode_smoke(ROOT / "dist" / "ps2-at3", Path(directory), "standalone")
        manifest["at3SmokeBytes"] = size
    manifest["checks"].append("ATRAC3 helper encodes a synthetic WAV to valid ATRAC3 RIFF (fmt tag 0x270)")

    # The exact extracted archive is what a client receives: validate it, and
    # run the backend suite against its bundled helper.
    with tempfile.TemporaryDirectory(prefix="ps2-release-") as directory:
        extracted_root = Path(directory)
        run("ditto", "-x", "-k", zip_path, extracted_root)
        extracted = extracted_root / APP.name
        assert extracted.is_dir(), "the archive did not contain the app bundle"
        check_bundle(extracted, short_version, args.build, manifest, "extracted")
        manifest["checks"].append("extracted archive bundle version, signature, slices, minos and resource freshness")
        helper_name = "ps2-convert"
        bundled_helper = extracted / "Contents" / "Helpers" / helper_name
        result = run("python3", ROOT / "scripts" / "test-backend.py", "--helper", bundled_helper, check=False)
        if result.returncode != 0:
            raise SystemExit(f"backend suite failed against the extracted bundled helper\n{result.stdout}\n{result.stderr}")
        manifest["checks"].append("backend regression suite passes against the extracted bundled helper")
        manifest["extractedHelperSHA256"] = sha256(bundled_helper)
        with tempfile.TemporaryDirectory(prefix="ps2-at3-smoke-") as at3_dir:
            at3_encode_smoke(extracted / "Contents" / "Helpers" / "ps2-at3", Path(at3_dir), "extracted")
        manifest["checks"].append("extracted bundled ps2-at3 encodes a synthetic WAV to valid ATRAC3 RIFF")

    out = ROOT / "dist" / f"release-manifest-{args.version}-{args.label}.json"
    check_release_records(args.version, args.build, args.label, short_version)
    manifest["checks"].append("acceptance template names this exact artifact, manifest, version/build and source archive with no older source retained")
    out.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"Wrote {out}")
    print(f"Archive SHA-256: {zip_digest}")


if __name__ == "__main__":
    main()
