# PS2 Classics for Mac

**Version 1.0 — release candidate 6 (RC6).** Native macOS 12+ application with Intel and Apple Silicon builds. It creates PS2 Classics debug packages, handles image encryption/decryption (including numbered multi-disc profiles) and memory-card conversion, provides saved projects and a persistent serial queue, and recovers safely from interruption with fail-closed cleanup, checkpointed verified stages and a durable, attempt-bound package reconciliation. Every import, build and utility operation shares one cancellable ownership slot; sessions migrate without data loss and every unclean load is backed up or write-locked; record files are read with hard size caps. RC6 adds common-audio import with native streaming resampling, retaining RC5’s audio ownership and exclusive-publication safeguards and the earlier session/search fixes. Real PS3 and Intel Monterey acceptance remain outstanding, so this is a candidate, not a final release.

Open **dist/PS2 Classics for Mac.app** and follow [the quick start](docs/USER_GUIDE.md). Supply your matching licensing files, logo and blank memory-card template in Setup. No game files or production support assets are bundled.

## Implemented

- ISO9660 inspection and SYSTEM.CNF game-ID detection, including raw MODE1/2352 and MODE2/2352 sectors; strict single-data-track CUE resolution.
- CHD v5 DVD and supported single-data-track CD import, with bundled decompression and integrity checks.
- Local CONFIG library search by exact game ID, alternatives and recorded fingerprints.
- Native CEX image preparation/encryption, full prepared-payload verification, decryption with numbered ISO.BIN.ENC profiles and keyless profile detection, read-only image verification, and CONFIG encryption with per-disc logical filenames. Full DVD9 file preserved.
- Native PARAM.SFO, EDAT title record, memory cards and streaming debug PKG creation, with full decrypted-payload read-back before exclusive output publication.
- Optional native conversion of mono/stereo PCM WAV, AIFF, MP3, AAC/ALAC M4A, or FLAC into ATRAC3 audio; automatic resampling, cancellation, input validation and safe output publication. Clips up to 2 minutes 30 seconds; no extra software needed.
- Editable titles, optional CONFIG with fingerprint/source notes, fit/crop artwork, generated title cards and existing AT3 audio import.
- Ordered multi-disc packages (experimental console behavior), project save/open, drag-and-drop, persistent queue, cancellation/retry, read-only published-package verification against a durable attempt fingerprint, a bounded verified stage cache with input-fingerprint invalidation, ownership-proven interrupted-work review, early support-file and destination checks, reusable named support profiles, local build reports and diagnostic export.
- One shared operation slot covers disc import/inspection, package builds and every utility action (image tools, card conversion, cache clearing, package checks), each cancellable; a stale completion can never release a newer operation.
- Local CONFIG library with availability detection (missing/disconnected/unreadable), refresh, reveal and clear, and per-candidate size/modification provenance; optional local artwork matching by exact game ID with bounded previews and explicit acceptance.
- Original images opened read-only and SHA-256 checked before/after package building. New outputs only. Jobs run serially; buffers are bounded. A retry restarts the job but reuses verified encrypted stages; it does not resume a partially written stream.

**Still outside this candidate:** multi-track/parent-dependent/older CHD, mixed/audio-track CUE, automatic online CONFIG database, manuals, console transfer, resume of a partially written encryption stream, actual hardware acceptance, Developer ID signing/notarization. Multi-disc installation/launch/swap/save behavior needs title-specific PS3 testing. These are not represented as implemented or verified. See [the release gate ledger](docs/RELEASE_GATE_LEDGER.md) for the exact open gates.

## Development

Requires Xcode/Swift 5.9 or later, CMake and Python 3 on a Mac. End users need only the bundled application.

```sh
swift test
bash scripts/build-app.sh
python3 scripts/test-backend.py
python3 scripts/test-extra-formats.py
python3 scripts/test-package-workflow.py
```

Run `bash scripts/validate-release.sh` for the standard local release checks. It builds the Universal app and tools, then automatically runs the helper-dependent Swift tests and every Python suite against the freshly built helper, assembles the archive with `scripts/make-archive.sh`, creates a source baseline with `scripts/make-source-baseline.py`, and validates both the exact extracted app and the complete source archive with `scripts/release-manifest.py`. Set `CHDMAN_TEST_TOOL` to an independently installed chdman path to include compressed-format fixtures; that optional gate is reported distinctly and skipped otherwise. For full real-image CHD testing, add `--chdman /path/to/chdman` to the package workflow command. chdman is a development test dependency only. Set `FFMPEG_TEST_TOOL=/path/to/ffmpeg` for independent audio fixtures and decoding; FFmpeg is not bundled or required by the app. Set `BUILD_REAL_ROMS=1` to run the four read-only ISO package cases. Set `PS2_TEST_EXTERNAL_VOLUME=1` for disposable mounted-filesystem tests.

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
