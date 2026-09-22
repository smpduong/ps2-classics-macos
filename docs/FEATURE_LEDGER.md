# Feature ledger — PS2 Classics for Mac 1.0 RC6

This ledger is deliberately honest about what is **implemented and tested**,
what is **experimental**, and what is **deferred with a concrete prerequisite**.
A deferred optional feature is not an unresolved defect in an advertised
capability; those deferred features remain outside the advertised scope. No placeholder or disabled
buttons are added for work that is not done.

## Implemented and tested locally

| Area | Change | Evidence |
| --- | --- | --- |
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

## Deferred with a concrete prerequisite (checked in RC3)

- **Curated/online CONFIG updates.** Primary sources checked: the aldostools
  `PS2 CONFIG Database` (`ps3.aldostools.org/ps2config.html`) is an HTML page
  with no documented stable revision/checksum endpoint; the community
  `ps3classics/ps2` resource states its data is sourced from the PS Dev Wiki;
  the widely mirrored `PS2 CONFIG 20230406` archive is licensed
  **CC BY-NC-ND 4.0** (non-commercial, no derivatives); the original Windows
  tool shipped CONFIGs "from the ManaGunZ repository", and its NET/GX/SOFT
  categories are derived from Sony's emulator and official releases. **Unresolved:** a selected source's file-level redistribution provenance
  remains unestablished. A pinned repository revision and recorded digests can
  supply version identity without a dedicated checksum endpoint. RC6 does not
  implement an online updater or claim that no usable upstream can exist.
- **Multi-track/audio CUE and CHD, older/parent-dependent CHD.** Needs defined
  track timing, pregap, sector/subchannel and parent-identity semantics plus
  independent reference fixtures. RC3 ships exact rejection diagnostics only.
  Decoder openability is explicitly not treated as supported conversion.
- **Manuals, richer save management, console transfer.** See
  [DEFERRED_WORK.md](DEFERRED_WORK.md); no real save is modified and no console
  transfer is attempted.
- **Mid-stream encryption resume.** Needs authenticated checkpoints, immutable
  source identity and crash-consistent partial records. Verified-stage reuse on
  retry is retained.

