# Project status and acceptance plan

## Target

Native macOS 12+ PS2 Classics application for the client's 2017 Intel MacBook Air and 2024 M4 Mac mini. One Universal app; no Wine or developer tools needed by end users. Confirm actual installed OS versions during client acceptance. This folder is the staging ground authorized by the user.

## Implemented — 1.0 release candidate 6

The core local workflow is complete: inspect ISO/BIN/CUE/CHD → identify game → select per-disc CONFIG/artwork → prepare and encrypt → create metadata, EDAT and cards → build and read back PKG → report. Saved projects, serial persistent queue, cancellation/retry, image decryption and memory-card conversion are available. Native tests, reference comparisons, UI checks and all four user-supplied ISOs have passed their documented local checks. Version 0.4 added bundled CHD import, local CONFIG matching, setup retention and local diagnostic export. Version 0.5 added numbered multi-disc image profiles with keyless detection and read-only verification. Version 0.6 added ownership-safe cleanup, validated payload sizes, a unified image-tools operation state and a bounded verified stage cache. Version 0.7 makes cache deletion and eviction fail-closed behind proven ownership with the lock held throughout, binds fingerprints and cache entries to the exact snapshot bytes and crypto parameters (legacy caches are never trusted), gives cache writers exclusive ownership, checkpoints every verified stage, integrates package builds and all utility entry points into one operation slot with real progress/cancel, and confirms recovered jobs only against their own completion records. Version 0.8 makes selected CONFIG failures strict instead of silently omitted, binds recovery to a queue-owned identity persisted at enqueue time, enforces the unchanged-source invariant on reused stages as well as fresh ones, and makes recovery's digest pass cancellable with honest progress. Version 0.9 finishes operation ownership at the real app entry points, normalizes user cancellation during package verification, and upgrades recovery to a durable build-attempt fingerprint. The 1.0 line adds backward-compatible session migration with a recoverable backup, holds the operation token until a replaced import's helper stops, converts every record reader to a single bounded read, and (RC2) makes session decoding structural — typed scalar settings and member-by-member queue arrays so one damaged entry can never discard the queue or crash on an ordinary saved CONFIG-library selection. RC2 also adds local CONFIG-library availability/refresh/provenance, optional local artwork matching by exact game ID, and exact CUE preflight diagnostics. RC3 normalizes every recovered queue entry to a unique identifier (preferring fully-decoded entries and clearing ambiguous recovery evidence) and gives the artwork and CONFIG searches explicit folder/generation/project ownership so a superseded or dismissed search can never overwrite newer results. RC4 guarantees a search always finishes its own lifecycle when its disc is edited or removed mid-scan, and adds an optional WAV→ATRAC3 audio conversion using a bundled native (atracdenc-based) helper.

RC5 corrected audio completion ownership, malformed WAV acceptance and unsafe filesystem publication. RC6 adds system decoding/resampling for common audio formats, independently checked by a second decoder, and connects the optional ROM/audio release gates.

Retry reuses verified encrypted stages when every input is unchanged; it never resumes a partially written stream.

The application intentionally requires a matching user support-file set. No production klicensee/RAP, console logo or blank console template is bundled. Synthetic fixtures prove local workflow operation but cannot establish console launch compatibility.

## Must complete before external release

1. Supply real support files and record their matching content ID. Test install, launch and saving on the target modified PS3.
2. Test Xenosaga II switching in both directions and save/load across discs. Until then, multi-disc console behavior remains experimental.
3. Run on the actual Intel Monterey MacBook Air and M4 mini. Record OS/build, time, memory and standalone behavior. Cross-compilation is not runtime acceptance.
4. Test external-volume behavior, including large-file limitations and interrupted/disconnected destinations.
5. Resolve release license arrangement, preserve third-party notices/corresponding source, Developer ID sign and notarize.

## Deferred enhancements

Older/parent-dependent/multi-track CHD; audio/mixed-track CUE and pregaps; curated online CONFIG database/updates (local library search is available); manual creation; richer save management; console transfer; resume of a partially written encryption stream. Retries reuse verified encrypted stages when inputs are unchanged, as described in the UI.

## Data and output rules

Originals read-only. No silent overwrite. File size never decides CD/DVD. Retain all source bytes, including DVD9 bytes after the first descriptor volume. Structured helper arguments; bounded buffers; a single operation (build, import or utility) owns the app at a time. CONFIG fingerprints and source notes persist with projects. Incomplete workspaces and unpublished partials carry a durable creation manifest and a shared writer lock; ordinary cancellations clean them up, and leftovers from a forced quit can be reviewed and moved to Trash explicitly, with the lock held through removal. Only entries the app can prove it created are removable; anything that merely resembles app naming is manual-review only. Stage caches are writer-exclusive, checkpointed per verified stage, fingerprint-bound to exact snapshot bytes, and evicted only behind the same ownership proof; legacy caches are never trusted. Each build persists a durable attempt (attempt ID, build fingerprint, ordered source/CONFIG/support/asset hashes and the fit/crop setting) before encryption; recovery confirms a published package only against that attempt, and a job without one stays unconfirmed.

Completion labels: **Built** = output stages completed; **Locally verified** = named structural/round-trip checks passed; **Console-tested** = actual recorded PS3 evidence. No label guarantees universal game compatibility.

Current destination requirement: build/export on APFS or Mac OS Extended, then copy completed files to exFAT if needed. Direct publication on filesystems lacking exclusive rename or hard links is refused before work starts; no placeholder is published. Physical USB disconnection testing remains separate.
