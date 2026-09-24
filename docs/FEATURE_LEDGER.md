# Feature ledger — PS2 Classics for Mac 1.0 RC19

This ledger is deliberately honest about what is **implemented and tested**,
what is **experimental**, and what is **deferred with a concrete prerequisite**.
A deferred optional feature is not an unresolved defect in an advertised
capability; those deferred features remain outside the advertised scope. No placeholder or disabled
buttons are added for work that is not done.

## Implemented and tested locally (RC19 accuracy and behavior)

| Area | Change | Evidence |
| --- | --- | --- |
| Validation narrative | Entry-swap test covers the pre-verdict swap, not the residual fstat-to-delete window; absolute phrases narrowed to the stated threat model | This section; `MemoryCardImportTests` entry-swap scope comment |
| User-facing accuracy | Workspace errors name the real destination path; verified signal fires only after cleanup; quarantine-directory outcome separated; failure workspace message conditional on evidence | `MemoryCardImportTests` callback-ordering and outcome-separation tests |

## Implemented and tested locally (RC18 quarantine + cleanup consistency)

| Area | Change | Evidence |
| --- | --- | --- |
| Quarantine guarantee | Entry moved into a private 0700 directory with an unguessable name; absolute claim narrowed to a stated same-user residual (no identity-conditional unlink on macOS); vanished entries report exactly that | `MemoryCardImportTests` entry-swap and vanished-quarantine tests |
| Cleanup consistency | One structured choke point per outcome on both paths; combined primary+cleanup errors preserve the cause; no double attempts; good output never deleted for cleanup failure | `MemoryCardImportTests` combined-failure and immutable-workspace tests |

## Implemented and tested locally (RC17 ownership cleanup, guarantee narrowed in RC18)

| Area | Change | Evidence |
| --- | --- | --- |
| Owned-output removal | Required captured identity (no identity-less fallback); quarantine protocol with the absolute race claim narrowed to a stated residual in RC18; foreign files restored, never deleted within that model; uncapturable publications left in place honestly | `MemoryCardImportTests` nil-capture, quarantine-window and foreign-restore tests |
| Workspace honesty | Unremovable workspace after a verified publish reports its exact location (with digest) instead of claiming removal; good output never deleted for cleanup failure | `MemoryCardImportTests` immutable-workspace test |
| Release hygiene | Acceptance template names the exact current source archive; manifest step asserts template/artifact/manifest/version/source agreement every gate | `scripts/release-manifest.py` ledger check; RC14 stale line corrected |

## Implemented and tested locally (RC16 standard-size geometry)

| Area | Change | Evidence |
| --- | --- | --- |
| Standard-size card geometry | Synthetic 16/32/64 MiB export/import round trips (large-FAT allocation, ECC, baseline diff, helper round trip); no behavior change; real-card layouts deferred | `MemoryCardImportTests` MiB round trips |
| Deeper-chain sizing | Full ancestry must thread helper args, importer, fingerprints, recovery, projects, queue, cache and multi-parent UI — RC10-scale, still deferred, not half-built | DEFERRED_WORK scoping note |

## Implemented and tested locally (RC15 import verification completion)

| Area | Change | Evidence |
| --- | --- | --- |
| Surgical import diff | Final bytes compared against an immutable pre-write baseline (both raw and decrypted inputs) in bounded cancellable chunks; allowed pages derived from the planned allocation and metadata changes, never from what writes happened to touch; unrelated-page corruption refused | `MemoryCardImportTests` pre-write-baseline corruption test on the real import path |
| Post-publication cleanup (.VMC and .VME) | Cancellation or read failure during final hashing after exclusive rename/encryption removes only the proven-owned output (device+inode match, regular non-symlink); files it did not publish are restored rather than deleted within the residual stated in RC18; removal failures are honest in the thrown error | `MemoryCardImportTests` post-publication cancellation tests for both extensions plus concurrent-replacement protection |
| Published-card verification | Decrypted published output compared byte-for-byte with the verified raw card (bounded cancellable comparator, strict length/read handling) in addition to the imported-save hash check; unrelated alterations refused and the owned output removed | `MemoryCardImportTests` free-page tampering test with matching imported-save hashes |
| RC14 record correction | The RC14 round-trip fix replaced two failable whole-file reads (`nil == nil` pass) with a streaming comparison; the RC14 published-file check compared only the imported save's hashes (unrelated alterations could escape) — now completed above | Commit history and `testPublishedVerificationRemovesUnverifiedOutput` plus the new full-byte test |

## Implemented and tested locally (RC14 verification integrity, corrected)

| Area | Change | Evidence |
| --- | --- | --- |
| Import verification integrity (RC14, corrected) | Encrypted-card round-trip replaced two failable whole-file reads (`nil == nil` pass) with a bounded streaming comparison that throws on missing/short/different/symlink/cancelled inputs; published-file verification removed unverified output but compared only the imported save's hashes (completed byte-for-byte in RC15); the workspace is removed on success and failure | `MemoryCardImportTests` strict-comparison and published-verification tests; workspace-leak assertion |
| Resume design evidence | Measured that encryption differs only in the header nonce + its auth MAC; segment bytes deterministic | `scripts/test-backend.py` nonce case (design evidence, not resume) |

| Area | Change | Evidence |
| --- | --- | --- |
| Import write paths | Root growth, deleted-slot reuse and multi-FAT-cluster files proven; truncation-at-any-offset parser sweeps never trap | `MemoryCardImportTests` root-extension/slot-reuse/large-file; truncation sweep |
| Format sweeps | CHD header versions/fields, catalog shapes, seeded ECC corruption, project parent round trips locked | `test-chd.py` 25 negatives; catalog/ECC/parent regression tests |

| Area | Change | Evidence |
| --- | --- | --- |
| Importer trap safety | Damaged zero-length roots fail instead of trapping; 1024-byte pages refuse import precisely; single-page-cluster and hand-built wide geometries proven | `MemoryCardImportTests` single-page round trip, wide-page refusal |
| Bounded verification | Surgical diff streams with a free-space preflight; catalog cache evicts oldest beyond 16 | Streaming diff, `testCatalogCacheEvictsOldestBeyondLimit` |

| Area | Change | Evidence |
| --- | --- | --- |
| Individual-save import | Verified import of app exports into NEW card files: manifest-bound payloads only, copy-first workspace, strict allocation, reference-layout link entries, fresh ECC with zero tails, re-parse/diff/round-trip verification, exclusive publication; originals never modified | `MemoryCardImportTests` round-trip/collision/space/foreign/exclusive/cancel/encrypted/full-size; bit-exact ECC vectors plus erased/single-bit properties; independent manager filesystem check on import results |
| Exact card ECC | Clean-room Hamming implementation proven bit-exact on 128 independent vectors; slice-base regression locked | `MemoryCardECCTests` |
| CONFIG provenance research | Negative result recorded: leading community corpus is Sony-derived or unlicensed; no default feed | Changelog lineage in DEFERRED_WORK; generic importer unchanged |

| Area | Change | Evidence |
| --- | --- | --- |
| Parent-dependent CHD import | Explicit parent selection for delta CHDs through import, image tools, saved projects, queue, fingerprints, stage cache and recovery; single-level depth bound, same-file/nesting/identity checks, parent stability re-checks, version-precise rejection | `CHDParentTests` (11 tests, in-test fixtures + helper); `test-chd.py` reference parity (helper output == chdman output == input), 6 new refusals, parent-CHD package; loopback-independent |
| Precise CHD format reports | Non-CHD input, detected non-v5 versions and unneeded/declared-absent parents each fail with a naming message | `test-chd.py` garbage/version cases; `CHDParentTests` version/format tests |

| Area | Change | Evidence |
| --- | --- | --- |
| Individual-save browse/export | Bounded read-only card filesystem parser (geometry, double-indirect FAT, dirent cross-checks); verified export into exclusive `.ps2save` folders with hash manifests; cards never modified; extended 16 KiB form and import refused precisely | `MemoryCardSavesTests` inventory/export/damage/cancellation on synthetic small and full-8 MiB cards plus encrypted round trip; `scripts/synth_card.py` independent builder/reader; in-app Browse/Export in Memory cards |
| Offline CONFIG catalog cache | Reviewed catalogs cached verbatim with retrieval date; explicit offline reuse with unchanged size/hash download checks; explicit refresh/forget; damaged caches load as absent; download receipts now carry catalog source/revision/license | `NetworkWorkflowTests` cache round-trip and fail-closed loads; `OnlineConfigView` cached-copy flow |
| Genuine parent-CHD rejection | Real reference-built parent/child pair plus spec-faithful synthetic pair prove precise parent rejection beyond byte-flip proxies | `test-chd.py` genuine-pair block; `scripts/synth_chd.py` self-test; MAME 0.289 reference built from upstream source |
| RC8 hardening regressions | Rotated-PDF upright rendering locked in; upload-abort and failure folder-reporting covered; foreign catalog entries, pre-network package rejection, missing/swapped card payloads, multi-frame/oversized/symlinked manuals, schema negatives | `SoftwareManualTests`, `NetworkWorkflowTests`, `MemoryCardBackupTests` additions; loopback FTP `storfail` mode |

## Implemented and tested locally (RC8)

| Area | Change | Evidence |
| --- | --- | --- |
| Licensing and reproducible release | Approved GPL-3.0-only, complete nested audio notices/sources in bundle, strict no-skip gate and fresh extracted-source rebuild | `LICENSE`, `LICENSING.md`, `validate-release.py`, `test-clean-source.py`; RC7 milestone |
| Whole-card backup/restore | Copy-first, no overwrite, format and byte verification; original card unchanged | `MemoryCardBackupTests` raw/encrypted restore, damage, traversal, symlink, cancellation |
| PDF/image manuals | Native 960×768 BC1 pages and index; exact generated bytes bound to build attempt | `SoftwareManualTests`; `test-manual-workflow.py` single/multi packages and independent FFmpeg BC1 decoding |
| Opt-in online CONFIG import | User-supplied HTTPS catalog, explicit review/download, bounded input, size/hash verification and local receipts | `NetworkWorkflowTests` schema, size/hash rejection, injection and cancellation; live third-party catalog acceptance remains unclaimed |
| FTP transfer | Fresh remote directory, upload, complete read-back hash, final rename; no saved password | Loopback FTP fixture with genuine synthetic PKG, corrupt/truncated/overlong replies, denied directory, cancellation and existing-file preservation; real PS3 FTP acceptance remains open |
| Search lifecycle | A pending CONFIG/artwork search whose disc is edited or removed mid-scan now always clears its busy flag and never publishes stale matches; superseded generations cannot touch a newer search. UI dismissal/selection paths route through invalidation | `StudioModelTests` game-ID-edit, disc-removal, older-vs-newer, dismiss/replace (completion-coordinated) and error-completion tests; `searchCompletionHook` |
| Common audio→ATRAC3 | macOS decodes/resamples mono/stereo PCM WAV, AIFF, MP3, AAC/ALAC M4A, or FLAC; bundled `ps2-at3` encodes AT3 RIFF. 150-second/512 MB cap, mono/stereo only, bounded buffers, cancellation and exclusive output | `AudioNormalizerTests`, `AT3ConverterTests`, app-model tests, independent eight-format spectral checks in `test-audio-formats.py`, release encoder smoke |
| Exclusive publication (RC5 correction) | Exclusive rename or hard link only; unsupported filesystems rejected during preflight. RC4 placeholder/plain-rename fallback removed | Publication fault-injection regression; mounted filesystem gate. Direct exFAT build is not supported; copy completed files afterward |
| Queue identity after salvage | Every recovered queue member (decoded, migrated, salvaged, placeholder) passes through one normalization path so identifiers are always unique regardless of order; a fully-decoded entry keeps its identifier in preference to a salvaged duplicate, and any reassigned entry has its queue/attempt evidence cleared rather than left ambiguously trusted | `SessionStoreTests` duplicate/mixed-queue tests; `StudioModelTests.testRemovingOrRetryingRecoveredDuplicateRowAffectsOnlyThatRow` |
| Artwork search refresh | Choosing another artwork folder clears stale matches and immediately re-scans an open results sheet; a dismissed search cannot reopen the sheet, a superseded search cannot overwrite newer results, a failed scan clears matches instead of leaving the old folder's, and project replacement discards in-flight searches | `StudioModelTests` artwork ownership tests; live GUI folder A→B check |
| CONFIG search ownership | The same folder/generation/project ownership and index guard applied to the adjacent CONFIG search | `StudioModelTests.testConfigFolderChangeDiscardsSlowOlderSearch` |

## Implemented and tested in earlier candidates

| Area | Evidence |
| --- | --- |
| Structural session decode; typed CONFIG-library/artwork settings; heterogeneous queue arrays; backup-or-lock on every unclean load; full model round trip | `SessionStoreTests` (26), `StudioModelTests` |
| Local CONFIG library availability/refresh/reveal/clear and candidate size/date provenance | `ConfigLibraryTests`, GUI Setup |
| Optional local artwork matching by exact game ID with bounded previews and explicit acceptance | `ArtworkLibraryTests`, GUI sheet |
| Exact CUE preflight diagnostics | `ProjectTests.testCUEUnsupportedLayoutsHaveSpecificReasons` |
| Single-slot operation ownership; token held until helper exit; cancellation normalization; bounded record reads; durable attempt-bound recovery | earlier suites |

## Experimental (present but not part of the validated claim)

- Multi-disc debug PKG console behaviour. Locally built and verified; disc
  switching needs title-specific PS3 testing.

## Remaining enhancements

- A curated public CONFIG feed with established file-level provenance. The generic HTTPS importer is available; there is no approved default catalog or automatic background updater.
- Multi-track/audio CUE and CHD, older (v1–v4) CHD. These need explicit geometry, track/pregap/subchannel and version handling plus independent reference fixtures. Supported v5 single-data-track and single-level parent-dependent import remains unchanged.
- Protected per-console card formats and real-card 16/32/64 MiB geometry coverage.
  Browse, export and import are proven on synthetic fixtures; whole-card
  backup/restore remains the safe path for anything unusual.
- Mid-stream encryption resume. Completed verified stages can be reused; partially written ciphertext still cannot be resumed. The RC9 design record pins the nonce constraint and the exact journal slice; fault-injection tests for the fail-closed half already exist.

See [DEFERRED_WORK.md](DEFERRED_WORK.md) for the remaining engineering scope. Real hardware acceptance and signing are separate from these enhancements.
