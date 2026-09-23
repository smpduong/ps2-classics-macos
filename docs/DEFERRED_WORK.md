# Deferred work — scoped prerequisites

This record separates deferred enhancements from external acceptance for implemented features.
Each deferred feature records the prerequisites for implementation; completed
features list their remaining external acceptance separately. None of these is an unresolved defect in an
advertised capability; see [FEATURE_LEDGER.md](FEATURE_LEDGER.md).

## 1. Curated / online CONFIG updates

**Prerequisite:** an approved primary upstream whose licence permits
redistribution of its CONFIG data, with a stable revision or checksum mechanism
(pinned commit, signed manifest, or equivalent).

**Primary sources checked in RC3 (none satisfies both conditions):**
- `https://ps3.aldostools.org/ps2config.html` — the community "PS2 CONFIG
  Database". Served as an HTML page; no documented stable machine-readable
  revision or checksum endpoint.
- `https://github.com/ps3classics/ps2` — a community resource that states its
  data is sourced from the PS Dev Wiki and offers a `TEMPLATE.CONFIG`.
- Archive.org mirror "PS2 CONFIG 20230406" (PS2 Classics Vault) — licensed
  **CC BY-NC-ND 4.0** (non-commercial, no derivatives).
- The original Windows PS2 Classics GUI bundled CONFIGs "from the ManaGunZ
  repository"; its NET/GX/SOFT categories derive from Sony's emulator and
  official releases.

**RC11 provenance research (negative result, prerequisite stands):** the most
cited community source disqualifies itself. ManaGunZ's changelog states its
NET CONFIGs come from official PS2 classic packages, GX from the gxemu
emulator and SOFT from softemu (all Sony-derived), CUSTOM is unofficial with
no stated rights, and v1.49 removed the bundled set ("I can't keep it up to
date"), pointing at webMAN-MOD — whose PS2CONFIG package is the same
Sony-derived lineage via Aldostools. No candidate offers file-level
redistribution rights, so no default feed is selected and nothing new is
bundled. This is a negative result about the examined candidates, not proof
that no usable source exists; a pinned source with recorded digests and a
clear rights grant would still satisfy the prerequisite. The generic importer, offline cache and receipts remain the
available path for user-supplied catalogs with proven provenance.

**Curated-feed acceptance design (generic importing is implemented in RC8):**
- User-initiated, opt-in download only; never automatic and never a background
  fetch.
- A reviewable candidate list with provenance (source, revision, checksum,
  retrieved date) and explicit selection.
- An offline last-known-good cache under Application Support; the app remains
  fully usable offline.
- Never replace a user-selected CONFIG silently; a changed file requires
  re-acceptance and its bytes are bound into the project/attempt fingerprint.
- Bounded downloads and atomic updates; no ROMs, keys, local paths, telemetry
  or unrelated user data leave the Mac.

## 2. Audio console acceptance — implementation complete locally

RC4 supplied the bundled ATRAC3 encoder; RC5 added ownership and publication
safeguards; RC6 adds system decoding/resampling for WAV, AIFF, MP3, AAC/ALAC M4A
and FLAC. Eight independently generated formats and separately decoded AT3
outputs pass local channel, rate, duration and tone-content checks. No external
runtime dependency was added. Inputs are mono/stereo, 8–192 kHz, at most 150
seconds and 512 MB. Unsupported/protected codecs are rejected explicitly.

The remaining audio gate is **real PS3 playback**, plus the same client-runtime
and distribution decisions that apply to the whole app. Source revisions and
notices are recorded in [the source inventory](CORRESPONDING_SOURCE.md).

## 3. Broader input formats (multi-track/audio CUE and CHD, older/parent CHD)

**Prerequisite:** a written geometry/track specification and independent
fixtures for each variant covering sector size, track timing, pregaps,
subchannel data and parent identity, with byte/metadata comparison against a
reference. Decoder openability is explicitly not sufficient.

**Until then:** keep exact rejection diagnostics and never discard or flatten
content silently.

**RC9 evidence:** the parent rejection is now proven against genuine
reference images, not only byte-flip proxies. A MAME 0.289 chdman built from
upstream source (tools-only build; independent of the pinned libchdr)
produced a real parent/child DVD pair; the helper expands the parent
byte-exact and rejects the child with the precise parent message on both
inspect and extract paths. `scripts/synth_chd.py` additionally builds
spec-faithful uncompressed parent/child pairs from the pinned v5 layout
(parentsha1 at header bytes 104–124, uncompressed map entries, metadata
blobs); the parent passes the bundled decoder end-to-end and the child,
differing only in a real nonzero parentsha1, is rejected precisely. The
committed `test-chd.py` matrix now covers this genuine pair alongside the
proxies. Older (v1–v4) CHDs still have no independently produced fixtures —
only the version-field rejection — and multi-track support still lacks a
proven console representation for track timing/audio.

**RC10 implementation (single-level parents only):** delta CHDs are now
supported when the user explicitly chooses the exact parent file. The helper
opens the pair through libchdr, enforces the parent identity match, resolves
parent-backed hunks during inspection, expansion and game-ID detection, and
re-checks both files for mid-run changes; the raw-SHA-1 check covers the
resolved bytes. Only single-level parents are accepted (a parent-dependent
parent is refused); the child and parent must be different files; a parent
selection on a standalone image is refused. The parent path and the SHA-256
of its exact bytes travel through saved projects, queue snapshots, build
fingerprints, the verified stage cache and recovery records, so swapping the
parent invalidates dependent stages and confirmations exactly like swapping
the source. Proven by `CHDParentTests`, reference parity (helper output ==
chdman output == input) and a parent-CHD package in `test-chd.py`. Deeper
chains still need flattening; older versions and multi-track/audio still have
no responsible implementation path (see prerequisite above).

## 4. Manuals, card backups and console transfer — implemented locally in RC8

- Manuals use the `USRDIR/CONTENT/manual.idx` and numbered `.dxt` page format found in pinned pop-fe2 commit `2afb9a3544e26ec1927f6389857240a0fe4bc205`: 960×768, eight-byte little-endian dimensions plus opaque BC1 blocks. The renderer/encoder is original native code. Independent FFmpeg decoding and real synthetic package extraction check the result. PS3 display/navigation remains an external acceptance case. RC9 locks in the probed `/Rotate` behavior (rotated pages render upright) as a regression test.
- Whole-card backup/restoration copies first, checks framing, performs native round-trip validation and verifies hashes. Existing files are not overwritten. Individual-save browsing, verified export and verified import into new files are implemented (see §6 below for scope and open acceptance); in-place import and protected formats stay deferred.
- FTP was selected from the user's protocol history. A local loopback server tests upload, read-back, corruption, truncation, extra bytes, failure and cancellation. No real console address, credentials or destination was supplied, and no real console was contacted. Real server command/path compatibility and installation are separate acceptance cases. RC9 adds an upload-abort mode and locks failure-message folder reporting into regressions.

## 5. Mid-stream resume

**Prerequisite:** authenticated checkpoints, immutable source identity and
crash-consistent partial records for the encrypted image format. Retain
verified-stage reuse on retry; do not append to arbitrary partial ciphertext.

**RC9 design finding (implements nothing yet):** the encryption stream is not
byte-reproducible across runs by construction — `Sources/PS2Convert/main.c`
seals each image with 16 `arc4random` nonce bytes in the header (offset
0x40), so two encryptions of identical inputs differ in the header while
every segment ciphertext stays deterministic. **Measured in RC14
(`scripts/test-backend.py` nonce case): the differing bytes are exactly the
nonce (0x40–0x4F) and the authentication MAC covering it (0x60–0x6F); all
other header bytes and every segment byte are identical across runs, and
both outputs decrypt to the source.** Any future resume must therefore
reuse the partial's own header verbatim and authenticate the retained prefix
by re-encrypting the source groups and comparing bytes (never by regenerating
a header or trusting a length field). The retained journal must bind source
bytes, key, content ID, disc/profile and helper revision; persist entries only
after fsync; and be kill-tested at data, journal and publication boundaries.
The fail-closed half already holds: SIGKILL mid-build publishes nothing and
trusts nothing (`scripts/test-recovery-workflow.py`), and killed CHD
extraction publishes no partial (`scripts/test-chd.py`). The next
implementable slice is the nonce-aware prefix-verified resume journal
described above — scoped, but still larger than a safe single pass, so it
remains deferred with this exact design.

## Concrete remaining implementation work

Remaining items fall into three kinds, and are not all "blocked":

- **Deferred engineering with a concrete design** (implementable locally, not
  yet done): deeper-than-single-level parent chains, and the nonce-aware
  partial-stream resume journal.
- **Needs independent evidence before any implementation is responsible**:
  older (v1–v4) CHD variants and multi-track/audio CHD/CUE (format/track/console
  representation), and real-card 16/32/64 MiB geometry coverage for the card
  tools.
- **Needs a rights/provenance decision**: a curated default CONFIG feed.

For deeper-than-single-level parent chains, carry the full ancestry with the
same explicit selection, identity validation, depth/cycle bounds and
fingerprinting the single-level path already has; until then they are refused
precisely. Older versions need their own bounded header/map validation and
independently produced fixtures. Multi-track formats additionally need a proven console representation for track timing and audio; silently dropping audio is not acceptable.

For mid-stream resume, introduce an owned partial-stage journal tied to source/key/content/profile hashes, persist only complete authenticated groups after syncing them, verify the retained prefix before resuming, and test forced termination at every journal/data publication boundary. Integrate partial-stage retention with writer locks, cache limits, cancellation and recovery. This is unfinished engineering work; completed-stage reuse must not be relabelled as stream resume.

## 6. Individual-save import — implemented locally in RC11

RC9 added a bounded read-only card filesystem parser (`MemoryCardSaves`):
superblock geometry, double-indirect FAT and 512-byte directory entries per
Ross Ridge's public-domain filesystem description (corroborated by the PS2
developer wiki), with cycle/range/length/name cross-checks, exact-size
validation, and precise rejection of the `+16 KiB` extended form. Save listing
and verified export (exclusive `<name>.ps2save` folders with hash manifests,
card opened read-only, source re-hashed before/after) are proven on synthetic
8 MiB and small-geometry fixtures plus an encrypted-card round trip.

RC11 adds verified import of those exports into a NEW card file
(`MemoryCardImport`): manifest-bound payloads only (no arbitrary files, no
merges, existing names never replaced), copy-first workspace discipline,
strict first-fit allocation over truly free clusters, subdirectory link
entries matching the reference layout, current-time JST timestamps,
conventional modes, fresh ECC with zero tails on every written page,
re-parse with the new save byte-exact and all other saves digest-identical,
a surgical page diff, and a helper round trip — all fail-closed with no
published output. ECC bit-exactness is proven against an independent
implementation's 128 vectors plus erased/single-bit properties
(`MemoryCardECCTests`); an independent card manager's filesystem check
passes on import results. Real-card coverage (any size), 16/32/64 MiB
geometry fixtures, protected per-console formats, and actual console
acceptance of imported cards remain open; the original card is never
modified, so a failed experiment always leaves the source intact.
