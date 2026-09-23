# Version 1.0 — release candidate 14 (RC14, build 23)

- Correctness and memory fix in save import verification: the encrypted-card round-trip now streams a bounded byte comparison instead of comparing two failable whole-file reads. Previously two read failures compared equal (`nil == nil`) and could pass verification; now a missing, short, different, symlinked or cancelled comparison throws, and 64 MiB cards are never loaded whole. The published-file check likewise removes an unverified output, and the import workspace (which holds full card copies) is removed on success as well as failure.
- Records reconciled for this candidate: the client acceptance checklist, project plan heading and generated release-manifest external gates (the RC7-closed licence decision is no longer listed as open); README no longer contradicts itself on save import. Historical RC9–RC13 notes are left as the accurate records of those builds.
- Resume design evidence measured rather than inferred: two encryptions of identical inputs differ only in the 16-byte header nonce and its covering authentication MAC; every other header byte and every segment byte is deterministic (`scripts/test-backend.py` nonce case). This is recorded as design evidence for a future resume journal, not as implemented resume.

Still a release candidate: PS3 install/launch/save/disc/audio/manual/FTP and imported-card save acceptance, client Intel Monterey and M4 runtime, physical USB behavior and Developer ID signing/notarization remain open. Deeper parent chains, older/multi-track CHD, stream resume and curated CONFIG feeds stay deferred (see DEFERRED_WORK.md for the design/evidence/rights split).

# Version 1.0 — release candidate 13 (RC13, build 22)

- Untested write-path coverage for save import: root growth, deleted-slot reuse and multi-FAT-cluster files are now proven, alongside truncation-at-any-offset parser sweeps, CHD header field sweeps, catalog shape sweeps, seeded ECC corruption properties and project round trips with parent discs. No behavior change; the verification already refused these cases, and now regressions lock each path.
- No user-visible changes. All acceptance gates and deferred items stand as in RC12.

Still a release candidate: PS3 install/launch/save/disc/audio/manual/FTP acceptance, client Intel Monterey and M4 runtime, physical USB behavior and Developer ID signing/notarization remain open. Protected card formats, real-card geometry coverage, deeper/older/multi-track CHD, stream resume and curated CONFIG feeds stay deferred.

# Version 1.0 — release candidate 12 (RC12, build 21)

- Import hardening from a hostile review of the new code: a damaged zero-length root no longer traps (it fails precisely), 1024-byte pages refuse import with a naming message (ECC is defined per 512-byte page), the surgical diff streams in bounded chunks with a free-space preflight, the offline catalog cache evicts oldest-beyond-16, and single-page-cluster plus wide-page geometries are proven by tests.
- No user-visible behavior changes beyond more precise refusals; the RC11 import flow, verification and disclosure stand as documented.

Still a release candidate: PS3 install/launch/save/disc/audio/manual/FTP acceptance, client Intel Monterey and M4 runtime, physical USB behavior and Developer ID signing/notarization remain open. Protected card formats, real-card geometry coverage, deeper/older/multi-track CHD, stream resume and curated CONFIG feeds stay deferred.

# Version 1.0 — release candidate 11 (RC11, build 20)

- Verified save import into new card files. Only `.ps2save` folders this app exported are accepted, and only into a new destination: the source card is copied first and never opened for writing. Allocation is strict first-fit over truly free clusters, subdirectory links match the reference layout, and every written page gets fresh ECC with a zero tail. Publication requires a full re-parse (new save byte-exact, all other saves unchanged), a surgical page diff, and a helper round trip; anything less publishes nothing. ECC is proven bit-exact against 128 independent vectors, and an independent card manager's filesystem check passes on import results. Console acceptance of imported cards remains open.
- CONFIG provenance research concluding the leading community corpus is Sony-derived or unlicensed; no default feed selected, nothing bundled.

Still a release candidate: PS3 install/launch/save/disc/audio/manual/FTP acceptance, client Intel Monterey and M4 runtime, physical USB behavior and Developer ID signing/notarization remain open. Protected card formats, real-card geometry coverage, deeper/older/multi-track CHD, stream resume and curated CONFIG feeds stay deferred.

# Version 1.0 — release candidate 10 (RC10, build 19)

- Parent-dependent (delta) CHD import. A CHD that stores differences against a parent declares the exact parent identity it needs; choosing that file verifies the pair immediately in package discs and image tools. The helper resolves parent-backed hunks through the reference decoder with identity, depth (single-level), same-file and mid-run change checks, and the raw-SHA-1 check covers the resolved bytes. Parent paths and byte hashes travel through saved projects, queue snapshots, build fingerprints, the verified stage cache and recovery records, so a swapped parent invalidates exactly like a swapped source. Proven byte-exact against the reference chdman, including a parent-CHD package.
- Precise format reports: non-CHD input, detected non-v5 versions and misplaced parent selections each fail with a naming message instead of a generic error.

Still a release candidate: PS3 install/launch/save/disc/audio/manual/FTP acceptance, client Intel Monterey and M4 runtime, physical USB behavior and Developer ID signing/notarization remain open. Deeper parent chains, older/multi-track CHD, save import, stream resume and curated CONFIG feeds stay deferred.

# Version 1.0 — release candidate 9 (RC9, build 18)

- Read-only save browsing with verified per-save export. The Memory cards view lists each save folder with file counts and byte totals; export copies one save into a new `.ps2save` folder with a SHA-256 manifest, re-reading every file from the card. Cards are never modified, existing exports are never replaced, and save import (writing back) is not offered. Proven on synthetic small and full-8 MiB cards plus an encrypted round trip.
- Offline CONFIG catalog cache. Reviewed catalogs are kept verbatim with their retrieval date and can be reloaded with no network use; downloads still verify size and hash, refresh stays explicit, and project selections never change silently. Download receipts now record the catalog source, revision and license.
- Genuine parent-CHD rejection evidence. A real MAME 0.289 reference-built parent/child pair and a spec-faithful synthetic pair prove the precise parent message beyond byte-flip proxies; the parent expands byte-exact through the helper.
- Hardening regressions across the RC8 workflows: rotated-PDF upright rendering, FTP upload-abort and failure folder-reporting, backup missing/swapped payload binding, foreign catalog entries, pre-network package rejection, multi-frame/oversized/symlinked manuals and catalog schema negatives.
- Design records without implementation: the encryption nonce constraint that any future stream-resume journal must satisfy, and the exact save-import prerequisites (FAT allocation, ECC handling, kill-tested writes).

Still a release candidate: PS3 install/launch/save/disc/audio/manual/FTP acceptance, client Intel Monterey and M4 runtime, physical USB behavior and Developer ID signing/notarization remain open. The helper binary is byte-identical to RC8, so RC8 conversion evidence carries over; this build re-validates inspection read-only on the four local ISOs.

# Version 1.0 — release candidate 8 (RC8, build 17)

- Whole-card verified backup/restore creates new copies and preserves existing saves. It checks conversion integrity, not individual saved-game health.
- Native PDF/image manuals become indexed 960×768 BC1 pages, included in package and recovery fingerprints. Original manual files are unchanged. Actual PS3 display remains untested.
- Optional HTTPS CONFIG catalog loading with explicit provenance review and size/SHA-256-verified downloads. No default public catalog, background updates or silent project changes.
- Optional FTP console transfer into a fresh remote folder. The local package is verified, upload is read back in full, and only matching bytes receive the final `.pkg` name. Credentials are not persisted. Loopback acceptance is automated; no real console has been contacted.
- Bounded process output and streaming read-back protect memory use. All new utilities share the existing cancellable operation slot.

# Version 1.0 — release candidate 7 (RC7, build 16)

- Applied the owner's approved GPL-3.0-only public license; preserved vendor grants and added full nested audio sources/notices to the app.
- Established a local Git baseline. No public repository or push was created.
- Strict release checks now require all test prerequisites and reject skipped required tests; generated filesystem/CHD fixtures exercise the full suite.
- The exact extracted source archive rebuilds in a fresh directory and passes native functional checks with no access to the original build products.

The remaining release gates are real PS3/client/physical-drive acceptance and Developer ID signing/notarization. The public-license decision is closed. Broader disc formats, individual-save editing, a curated public CONFIG feed and mid-stream encryption resume remain unfinished enhancements.

## Historical release notes

# Version 1.0 — release candidate 6 (RC6, build 15)

- Audio import now accepts mono/stereo WAV, AIFF, MP3, AAC/ALAC M4A and FLAC.
  macOS decodes and resamples in small blocks before the bundled ATRAC3 encoder;
  no new runtime dependency. Maximum 150 seconds and 512 MB. Surround/protected
  or unsupported codecs are refused explicitly.
- Cancellation also covers normalization, and private intermediate files are
  removed after success, rejection or cancellation. Existing destinations and
  source audio remain untouched. RC5 project/sound ownership safeguards remain.
- Independent synthetic fixtures check distinct left/right tones through both
  normalization and final AT3 decoding. Source bytes, timing, sample rate,
  channels and absence of clipping are checked automatically.
- `BUILD_REAL_ROMS=1` now runs the advertised read-only package tests.
  `FFMPEG_TEST_TOOL` enables the independent audio gate. Optional filesystem
  tests run only when explicitly set to `1`.
- Corrected the source inventory to include the bundled audio encoder and its
  vendored dependencies; corrected the RC4 build number in the gate ledger.

This is still a local release candidate. Actual PS3/audio playback, client Macs,
physical USB acceptance, signing/notarization and the owner's licence decision
remain open. Earlier release notes below are historical.

# Version 1.0 — release candidate 5 (RC5)

Independent review confirmed RC4's search fixes and native WAV-to-AT3 feature. RC5 corrects three remaining areas:

- Audio completion respects project replacement and a newer sound selection; a finished export stays available without silently changing another project.
- WAV inspection verifies the declared file/chunk/sample layout and supports large metadata chunks with bounded reads. Cancellation is checked after encoding and before publication; the validated AT3 read has a hard size cap.
- Publication uses exclusive rename or atomic hard-link creation. The unsafe reserve-placeholder/plain-rename fallback is removed. Destination preflight refuses unsupported filesystems (including the tested exFAT volume); build on APFS/Mac OS Extended and copy completed files afterward. Physical USB tests remain external.

The candidate remains version 1.0.0 with build 14. Earlier archives are preserved. No console or client-hardware acceptance is implied.

# Version 0.9 — local beta

Closes the operation-ownership, recovery-identity, release-validation and artifact-freshness gaps found in an independent review of 0.8. No production support assets are bundled and no console claim is made.

## What 0.8 left open, and what 0.9 changes

- **Import/inspection bypassed the shared operation slot.** `Add discs` only guarded its own flag, so a disc import could inspect and add discs while a build or utility owned the app, and CHD inspection could launch a helper outside the cancellable runner. Import and inspection now claim the same single-operation slot as builds and utilities: a queued build waits while an import runs, an import is refused while anything else owns the app, and the slot is released exactly once. Image-tool inspection and profile detection now run through the shared cancellable process path, and their Cancel buttons stop the launched helper instead of leaving it running.
- **Cancel during package verification was misreported.** A cancellation that arrived during the native-helper phase was swallowed by an inner catch and surfaced as "the published package did not verify", contradicting the cancellation promise. User cancellation is now normalized after both the digest and helper phases and at their boundary: the package is left untouched, the job returns to Interrupted with a cancellation message, and it never implies corruption or a successful recovery.
- **Recovery relied on the queue's enqueue-time references.** Those carried paths and IDs but not the immutable input fingerprint, and they omitted the artwork fit setting. At build start the builder now snapshots an immutable attempt — attempt ID, build fingerprint, ordered per-disc source and CONFIG hashes, support and produced-asset hashes and the fit/crop setting — and the queue persists it before any encryption begins. Recovery confirms a package only when the completion record matches that durable attempt on every field, then the queued reference, then the bytes. A job with no durable attempt (legacy, or a crash before the attempt was written) stays explicitly unconfirmed; a retry invalidates the previous attempt.
- **Neighboring reports were read unbounded on the main actor.** The report is now parsed with a hard size cap, only when it is a readable regular non-symlink file, and off the main actor. It remains an editable local file used as evidence to compare — not tamper-proof provenance.
- **Routine release checks skipped the important tests.** The standard release script now builds the tools first, then automatically runs all helper-dependent Swift tests against the freshly built helper, and reports the optional CHD gate distinctly instead of silently skipping it.
- **Artifact freshness and evidence.** The bundled user guide is compared byte-for-byte against its source before the archive is accepted, version/build are checked in both the source and the exact extracted archive, and a machine-readable release manifest records the measured hashes, architectures, minimum OS and resource hashes from the real artifacts.

## Smaller corrections

- Completion reports now carry the attempt identity, build fingerprint, fit/crop setting and support/asset hashes.
- The build-attempt record is written to a durable, bounded, symlink-safe store under Application Support; the neighboring report reader applies the same bounds.
- Cleanup review and cache measurement now use the shared operation slot where they mutate or scan, rather than only a soft flag.

Retains the complete ISO/BIN/CUE/CHD workflow, numbered decryption, ordered multi-disc packages, artwork/sound, memory-card tools, saved projects and the serial queue, fail-closed cleanup and eviction, exclusive cache claims, per-stage checkpoints and identity-bound recovery. The app and helper are Universal binaries targeting macOS 12.

This remains a locally tested beta. The production support-file set, actual PS3 install/launch/save/disc-switch tests, client Intel Monterey/M4 execution, external-volume acceptance and public-release signing/licensing remain outstanding. A retry restarts the job but reuses verified encrypted stages; it does not resume a partially written stream. See VALIDATION.md and USER_GUIDE.md for evidence and limits.

# Version 1.0 — release candidate 4 (RC4)

Fixes a search-state defect found in an independent review of RC3 and adds an optional native audio encoder. This is still a **release candidate**: the local gates are closed for this build, but the external gates in [RELEASE_GATE_LEDGER.md](RELEASE_GATE_LEDGER.md) remain open. No production support assets are bundled and no console claim is made.

## What RC3 got wrong, and what RC4 changes

- **A pending search could leave its control disabled.** If a disc's game ID was edited (or the disc removed) while a CONFIG/artwork scan was still running, the completion handler returned before clearing `findingConfigs`/`findingArtwork`, so further searches stayed disabled and only an app restart or New Project recovered. The completion now always finishes the lifecycle of the generation it owns: it clears its busy flag and never publishes stale matches, while a superseded generation still cannot touch a newer search's state. Editing a game ID or removing a disc also explicitly invalidates the affected search. Every real dismissal path (Close buttons, Change library, selecting a result, sheet dismissal) now routes through the invalidation methods.

## New optional feature — WAV → ATRAC3 (AT3) audio

- Builds a bundled native encoder helper (`ps2-at3`) from pinned vendored source (`atracdenc` LGPL-2.1, `libgha` BSD-2-Clause, `libsndfile` LGPL-2.1), Universal for `arm64` + `x86_64` on macOS 12, statically linked so it has no runtime dependency beyond the system libraries. **Choose AT3 sound…** (import) is retained; **Convert audio to AT3…** encodes a 44.1 kHz 16-bit WAV, runs as a normal cancellable single operation, and never overwrites its source or destination. Unsupported inputs (non-WAV, compressed, 8-bit, non-44.1 kHz, more than two channels, empty) are rejected with a specific reason. The encoded output must satisfy the app's own ATRAC3 RIFF rules before it is published.
- Limitations: only WAV input is implemented. Console acceptance of the encoded audio remains an external gate.

# Version 1.0 — release candidate 3 (RC3)

Fixes two issues found in an independent review of RC2 and records evidence-based blockers for the optional features that remain. This is still a **release candidate**: the local gates are closed for this build, but the external gates in [RELEASE_GATE_LEDGER.md](RELEASE_GATE_LEDGER.md) remain open. No production support assets are bundled and no console claim is made.

## What RC2 got wrong, and what RC3 changes

- **Recovered queue rows could share an identifier.** When a damaged queue entry was salvaged, it was appended before the duplicate-identifier check, so a salvaged duplicate and a valid job could keep the same identifier. Removing or retrying one row could then affect both. Every recovered member now passes through one normalization path: identifiers are unique regardless of order, a fully-decoded entry keeps its identifier in preference to a salvaged duplicate, and any reassigned entry has its queue/attempt evidence cleared rather than left ambiguously trusted.
- **Changing the artwork folder left stale results.** "Change folder…" only stored the new folder; the sheet kept showing the old folder's matches. Choosing a folder now clears stale matches and immediately re-scans an open sheet, with explicit ownership so a superseded or dismissed search cannot overwrite newer results.

# Version 1.0 — release candidate 2 (RC2)

Fixes two session-loading defects found in RC1 build 10 and adds bounded optional features. This is still a **release candidate**: the local gates in [RELEASE_GATE_LEDGER.md](RELEASE_GATE_LEDGER.md) are closed for this build, but the external gates remain open. No production support assets are bundled and no console claim is made.

## What RC1 got wrong, and what RC2 changes

- **An ordinary saved CONFIG-library selection could crash session loading.** The loader round-tripped the saved URL value through `JSONSerialization`, which raises an uncatchable Objective-C exception for a bare string. The decode boundary is now structural: the CONFIG-library and artwork-folder settings are read as typed values with validation, never as generic fragments.
- **One malformed queue element silently discarded the whole queue.** The loader cast the entire jobs array to an array of dictionaries, so `[validJob, null]` failed the cast and returned zero jobs with no note and no backup — a later save could then overwrite the original queue unprotected. Queue members are now read individually; valid jobs keep their order and metadata, a malformed position is preserved as an **Interrupted** placeholder, a missing or wrongly-typed container is reported as damage (distinct from a genuinely empty queue), duplicate identifiers are made distinct, and every unclean load writes a byte-identical backup or, if that cannot be done, locks the session against overwriting.
- **Recovery is easier to act on.** The recovery message names the backup, and the app offers **Reveal backup** to open the session folder in Finder.

## New optional features (implemented and tested)

- **Local CONFIG-library maintenance.** Setup shows whether the saved folder is available, missing, not a folder or unreadable, with **Refresh**, **Reveal** and **Clear**, and each match shows its size and modification date for provenance.
- **Optional local artwork matching.** **Find artwork…** scans a chosen folder for PNG/JPEG images whose name begins with the disc's exact game ID, with bounded previews and dimensions; nothing is applied until you accept it as icon or background.
- **Exact input diagnostics.** CUE preflight names the exact unsupported case (audio track, other sector mode, multiple tracks, INDEX 00 pregap, non-zero start, non-BINARY FILE, multi-file layout) and ignores informational metadata.

# Version 1.0 — release candidate

Closes the two data-integrity regressions and the remaining bounded-read gaps found in an independent review of 0.9. This is a **release candidate**: the local workflow and its automated checks pass, but the external acceptance gates in [CLIENT_ACCEPTANCE_CHECKLIST.md](CLIENT_ACCEPTANCE_CHECKLIST.md) and [RELEASE_GATE_LEDGER.md](RELEASE_GATE_LEDGER.md) are still open, so it is not labelled a final release. No production support assets are bundled and no console claim is made.

## What 0.9 left open, and what 1.0 changes

- **A 0.8 session could be lost.** The 0.9 queue identity added a non-optional `cropArtwork` field, so an older session that lacked it failed to decode as a whole; the project and every queue item disappeared, and the next New Project overwrote the file. Decoding is now explicitly tolerant, and a session loader migrates older files: it recovers the project, queue order, statuses, destinations and any recoverable identity, derives a missing setting from that job's own saved project, and preserves an unreadable entry as unconfirmed instead of dropping it. Whenever a session is not read cleanly the app first writes a byte-for-byte backup beside it and tells you the name; if that copy cannot be made, it refuses to overwrite the file until you move it aside. One damaged entry no longer discards unrelated valid data.
- **Replacing the project could release the operation slot early.** New Project / Open Project / Edit a Copy cancelled an in-flight disc import and immediately released the shared slot, even though cancellation only *requests* termination — a new operation could then start while the old CHD helper was still alive. The token is now held until the import's asynchronous work and helper have actually stopped.
- **Record readers were not hard-bounded.** Attempt, report, workspace, cache and profile records now use one bounded read through the open descriptor that also rejects symlinks and detects a size change while reading.
- **Cancellation call sites audited.** Package builds and image-tool conversions now pass their cancellable runner into CHD inspection.

# Version 0.9 — local beta

Closes the operation-ownership, recovery-identity, release-validation and artifact-freshness gaps found in an independent review of 0.8. No production support assets are bundled and no console claim is made.

- **Import/inspection bypassed the shared operation slot.** Import and inspection now claim the same single-operation slot as builds and utilities, and image-tool inspection and detection run through the shared cancellable process path.
- **Cancel during package verification was misreported.** User cancellation is normalized after both phases and at their boundary: the package is left untouched and the job returns to Interrupted with a cancellation message.
- **Recovery relied on enqueue-time references.** A durable attempt (attempt ID, build fingerprint, ordered source/CONFIG/support/asset hashes and fit/crop) is snapshotted before encryption and compared during recovery; a job without one stays unconfirmed.
- **Neighboring reports were read unbounded on the main actor.** Now bounded and parsed off the main actor; it remains editable evidence, not tamper-proof provenance.
- **Routine release checks skipped the important tests.** The release script now runs all helper-dependent Swift tests against the freshly built helper and reports the optional CHD gate distinctly.

# Version 0.8 — local beta

Corrects recovery-trust defects found in an independent review of 0.7. No production support assets are bundled and no console claim is made.

- **A selected CONFIG could silently vanish.** A missing, unreadable, empty, oversized or changed CONFIG is now mandatory data: read strictly up front, a changed selection hash fails immediately, and only an explicitly cleared selection permits omission — including in multi-disc builds.
- **Recovery trusted the neighboring report, not the job.** Each queued job persists its own build identity at enqueue time, and recovery accepts a package only when the record matches that identity on every field *and* the bytes match the record.
- **Reused stages skipped the stability check.** Fresh and cached stages now share one cancellable, bounded unchanged-source check before publication.
- **Recovery's digest pass ignored Cancel and showed no progress.** One operation-owned cancellation signal covers the digest and the helper together, with honest progress.

Retains the complete ISO/BIN/CUE/CHD workflow, numbered decryption, ordered multi-disc packages, artwork/sound, memory-card tools, saved projects and the serial queue, fail-closed cleanup and eviction, exclusive cache claims, per-stage checkpoints and identity-bound recovery. The app and helper are Universal binaries targeting macOS 12.
