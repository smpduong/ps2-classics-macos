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

**Unresolved prerequisite:** file-level redistribution provenance has not been
established for a selected CONFIG source in this project. This is an open
research/approval question, not proof that no usable source exists. A pinned
repository commit with recorded content digests can supply version identity;
a dedicated checksum endpoint is not intrinsically required. No curated
updater or newly approved CONFIG data is included in RC6.

**Acceptance design (when unblocked):**
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

## 4. Manuals, save management, console transfer

- **Manuals:** import a user-supplied PDF/png as a package resource is a small
  addition, pending the exact package resource name and size limits used by the
  console workflow.
- **Save management:** any addition must copy-first export/backup with format
  checks and restore verification, and must never modify a real save in place.
- **Console transfer:** requires a defined authenticated protocol and real
  endpoint acceptance; no upload is attempted or implied.

## 5. Mid-stream resume

**Prerequisite:** authenticated checkpoints, immutable source identity and
crash-consistent partial records for the encrypted image format. Retain
verified-stage reuse on retry; do not append to arbitrary partial ciphertext.
