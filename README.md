# PS2 Classics for Mac

**Version 1.0 — release candidate 12 (RC12).** Native macOS 12+ application with Intel and Apple Silicon builds. It creates PS2 Classics debug packages, handles image encryption/decryption (including numbered multi-disc profiles) and memory-card conversion, provides saved projects and a persistent serial queue, and recovers safely from interruption with fail-closed cleanup, checkpointed verified stages and a durable, attempt-bound package reconciliation. Every import, build and utility operation shares one cancellable ownership slot; sessions migrate without data loss and every unclean load is backed up or write-locked; record files are read with hard size caps. RC12 hardens the save importer (trap-free damaged roots, geometry-scoped ECC, bounded diff/cache) with no behavior change beyond more precise refusals. RC11 added verified save import into new card copies with bit-exact ECC. RC7 established GPL-3.0-only licensing and strict reproducible release gates. Real PS3 and Intel Monterey acceptance remain outstanding, so this is a candidate, not a final release.

Open **dist/PS2 Classics for Mac.app** and follow [the quick start](docs/USER_GUIDE.md). Supply your matching licensing files, logo and blank memory-card template in Setup. No game files or production support assets are bundled.

## Implemented

- ISO9660 inspection and SYSTEM.CNF game-ID detection, including raw MODE1/2352 and MODE2/2352 sectors; strict single-data-track CUE resolution.
- CHD v5 DVD and supported single-data-track CD import, with bundled decompression and integrity checks. Single-level parent-dependent (delta) CHDs are supported once their exact parent file is chosen; the pair is verified immediately and the parent's bytes join the build identity.
- Local CONFIG library search by exact game ID, alternatives and recorded fingerprints.
- Native CEX image preparation/encryption, full prepared-payload verification, decryption with numbered ISO.BIN.ENC profiles and keyless profile detection, read-only image verification, and CONFIG encryption with per-disc logical filenames. Full DVD9 file preserved.
- Native PARAM.SFO, EDAT title record, memory cards and streaming debug PKG creation, with full decrypted-payload read-back before exclusive output publication.
- Optional native conversion of mono/stereo PCM WAV, AIFF, MP3, AAC/ALAC M4A, or FLAC into ATRAC3 audio; automatic resampling, cancellation, input validation and safe output publication. Clips up to 2 minutes 30 seconds; no extra software needed.
- Whole-card backups and restoration into new files, with size, format and SHA-256 checks.
- Read-only save browsing and verified per-save export with hash manifests; verified import of those exports into new card files with fresh ECC. Cards chosen as sources are never modified and imports are never merged or replaced.
- PDF/image manuals encoded natively into numbered console-format pages, included in the package and recovery fingerprint.
- Opt-in HTTPS CONFIG catalogs with reviewable provenance, verified downloads and an offline cache of reviewed catalogs; no preselected public database.
- FTP upload into a new remote folder, bounded streaming read-back and SHA-256 comparison before final naming. Credentials are not saved.
- Editable titles, optional CONFIG with fingerprint/source notes, fit/crop artwork, generated title cards and existing AT3 audio import.
- Ordered multi-disc packages (experimental console behavior), project save/open, drag-and-drop, persistent queue, cancellation/retry, read-only published-package verification against a durable attempt fingerprint, a bounded verified stage cache with input-fingerprint invalidation, ownership-proven interrupted-work review, early support-file and destination checks, reusable named support profiles, local build reports and diagnostic export.
- One shared operation slot covers disc import/inspection, package builds and every utility action (image tools, card conversion, cache clearing, package checks), each cancellable; a stale completion can never release a newer operation.
- Local CONFIG library with availability detection (missing/disconnected/unreadable), refresh, reveal and clear, and per-candidate size/modification provenance; optional local artwork matching by exact game ID with bounded previews and explicit acceptance.
- Original images opened read-only and SHA-256 checked before/after package building. New outputs only. Jobs run serially; buffers are bounded. A retry restarts the job but reuses verified encrypted stages; it does not resume a partially written stream.

**Still outside this candidate:** deeper parent chains, older/multi-track CHD, mixed/audio-track CUE, curated automatic CONFIG updates, individual-save import, resume of a partially written encryption stream, actual hardware acceptance, Developer ID signing/notarization. Multi-disc installation/launch/swap/save behavior needs title-specific PS3 testing. These are not represented as implemented or verified. See [the release gate ledger](docs/RELEASE_GATE_LEDGER.md) for the exact open gates.

## Development

Requires Xcode/Swift 5.9 or later, CMake and Python 3 on a Mac. End users need only the bundled application.

```sh
swift test
bash scripts/build-app.sh
python3 scripts/test-backend.py
python3 scripts/test-extra-formats.py
python3 scripts/test-package-workflow.py
```

Run `bash scripts/validate-release.sh` for strict local release checks. FFmpeg and MAME chdman are required **test tools**, not app dependencies. Set `FFMPEG_TEST_TOOL` and `CHDMAN_TEST_TOOL` when they are not on PATH. Validation creates its own disposable CHD and mounted-filesystem fixtures, forbids skipped required Swift tests, runs independent package/manual/audio checks and a loopback FTP fixture, and rebuilds the extracted source archive in a fresh directory. Add `--with-roms` (or `BUILD_REAL_ROMS=1`) for the separate read-only four-ISO integration cases.

Developer test scripts use Python's standard library. Optional `--reference`/`--npdata` paths allow independent pinned-tool comparison; they are not app dependencies. The package workflow test uses generated, non-production support files and removes test packages.

Opt-in real-image testing:

```sh
python3 scripts/test-rom-workflow.py
python3 scripts/test-rom-conversion.py
python3 scripts/test-package-workflow.py --roms ROMS
```

The four local ISOs are excluded from Git and remain unmodified. Real-image tests use synthetic support assets; their temporary packages are not console-ready. See [validation](docs/VALIDATION.md) for measured evidence, [project status](docs/PROJECT_PLAN.md) for acceptance gates, [backend review](docs/BACKEND_REVIEW.md) for provenance, [release checklist](docs/CLIENT_ACCEPTANCE_CHECKLIST.md) for the remaining hardware steps and [corresponding source](docs/CORRESPONDING_SOURCE.md) for the license inventory.

## Source map

- `Sources/PS2ClassicsApp`: native SwiftUI interface, project and queue management.
- `Sources/PS2ClassicsCore`: inspector, models, metadata, artwork and package orchestration.
- `Sources/PS2Convert`: streaming native image/card/EDAT/PKG helper using Apple CommonCrypto.
- `Sources/PS2Inspect`, `Sources/PS2Build`: developer command-line entry points.
- `Tests`, `scripts`: synthetic regressions and opt-in local workflow tests.
- `ThirdParty`: pinned-source license/provenance notices. The helper includes GPLv3 adaptations and an MIT package-format adaptation.

Licensed under **GPL-3.0-only** for original project code; third-party components retain their own terms. See [LICENSE](LICENSE), [licensing policy](LICENSING.md) and [the dependency inventory](docs/CORRESPONDING_SOURCE.md). Binary releases include the matching source archive.

Current destination requirement: build/export on APFS or Mac OS Extended, then copy completed files to exFAT if needed. Direct publication on filesystems lacking exclusive rename or hard links is refused before work starts; no placeholder is published. Physical USB disconnection testing remains separate.

## Strict release verification

`bash scripts/validate-release.sh` requires CMake, Python 3, FFmpeg and MAME
chdman (test tools only). Set `FFMPEG_TEST_TOOL`/`CHDMAN_TEST_TOOL` if they are
not on PATH. Missing tools, skipped Swift tests or a failed gate stop release
validation. The command generates its own CHD and mounted-filesystem fixtures,
runs all tests, rebuilds the extracted source archive in a fresh directory and
records the exact artifact hashes in a release-check receipt. `--with-roms` adds
the optional four local ISO builds. Plain `swift test` remains a fast developer
check and is not a release acceptance claim. Release metadata is in release.json.
