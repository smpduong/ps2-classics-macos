# Backend review — 0.6

Current native additions:

- **Ownership-safe cleanup.** Workspaces, image workspaces and unpublished partials carry a `.ps2-owner.json` manifest (format/version/kind/jobID/target/pid) and a `.ps2-lock` shared lock. Writers (the Swift builder and every helper process, via `PS2_WORKSPACE`/`PS2_JOB_ID`) hold the lock for their lifetime. `WorkspaceCleanup` only offers removal when the manifest is valid, the kind matches the directory pattern, an exclusive lock can be taken (proving no live writer, including a helper that outlived the app) and the file identity is unchanged since the scan; removal revalidates all of this and moves the entry to Trash. Name matching alone yields "review manually". The helper also flocks each partial and writes a sibling `.ps2-partial-*.json` record, so a SIGKILL leaves recoverable, validated evidence.
- **Bounded, validated detection.** `inspect-encrypted` rejects impossible declared sizes, uses overflow-safe `encoded_size`/padding arithmetic and reports `payloadBytes` only when the whole file matches; otherwise `complete:false`. The Swift boundary validates the JSON number range before any conversion.
- **Exact profile allowlist.** A single `supported_profiles[]` table gates argument validation and detection; `CONFIGbanana` and other malformed names are rejected.
- **Read-only package verification.** `verify-package` recomputes the header digests, the doubly-derived `pad`/`pad2` fields, the index, the encrypted payload, the QA digest and the license field, and confirms the empty trailer, without writing anything.
- **Stage cache.** Encrypted disc images are cached beside the destination under a SHA-256 fingerprint of source bytes, CONFIG, key/RAP/logo/card hashes, content ID, title, artwork, helper hash and app version. Reuse re-hashes the cached file and rechecks provenance; a corrupted cache entry is dropped. Retention is bounded by size and age and never removes a locked cache. Raw key bytes are never stored.
- **Destination preflight.** `statfs` filesystem type, FAT32 per-file cap, path-component and total path length, free space and a write probe are checked before a build.

- PSL1GHT package layout adapted from commit `e05843e7233acde200d052c3e1421eac8c5c25a3` (MIT). Native streaming SHA-1 debug keystream, sorted entries, QA digest, bounded buffers, no SELF rewriting. Reject links and excessive nesting; verify entire decoded payload before exclusive publication.
- Hykem make_npdata EDAT v3/type 1/local-license procedure adapted from commit `0462b6c972dceb092b0499b5445ca2a8e884a2ee` (GPLv3 scoped main/constant logic). Crypto through Apple CommonCrypto; no legacy EC/LZ/AES source compiled. Independent reference decryption/hash checks pass. Signature placeholders make this a modified-console workflow, not an officially signed retail package.
- CEX memory cards use reference per-16-KiB CBC behavior. Standard ECC card sizes and the extended 16-KiB template size are retained exactly; reverse conversion is hashed against the original stream.
- pop-fe2's ordered multi-disc conventions provide DISC.IDX, numbered ISO.BIN.ENC/CONFIG logical names and 17-byte title trailers. Console switching remains experimental.
- Raw MODE1/2352 and MODE2/2352 sectors identified by descriptor location. Every physical-sector byte is retained; LIMG type 2/2352. Unknown images are rejected. CUE input is intentionally limited to one data track at zero.
- Exclusive same-directory `renamex_np(RENAME_EXCL)` publishes outputs without relying on hard links, supporting destinations whose filesystems lack hard links. Actual external-filesystem testing remains pending.
- Package workspaces are isolated at the selected destination, cleaned on normal success/failure/cancellation. Queues persist snapshots; retries restart from source. No claim of cached-stage or partial encryption resume.

See ThirdParty/PSL1GHT and ThirdParty/NPData for exact licenses/provenance. Original prepared-image logic remains as described in the historical review except for the added raw-sector layouts and logical filenames. `encrypt-raw` is also used for CONFIG payloads. The app does not persist key bytes: only paths. Temporary key snapshots live in the private job workspace and are removed with it.

The following is the preserved earlier review; statements about unimplemented features describe 0.2 only.

# Historical backend review — 0.2

Reviewed and implemented 2026-09-20. Public repositories were downloaded to temporary review directories, compared at pinned commits, and only the scoped reference/adapter listed below was incorporated.

| Reference | Pinned commit | Decision |
| --- | --- | --- |
| [sdkmap/PS2Classics](https://github.com/sdkmap/PS2Classics) | `3241733c99a30ad0e2b1d09f52a952e4f5801608` | Original converter lineage and GPLv3 license reference |
| [sahlberg/pop-fe2](https://github.com/sahlberg/pop-fe2) | `2afb9a3544e26ec1927f6389857240a0fe4bc205` | CEX header/segment format and disc numbering basis; current ISO preparation policy compared |
| [bucanero/apollo-ps3](https://github.com/bucanero/apollo-ps3) | `687989878273c34a68ccae4e6419797ac43f6cd0` | LIMG/preparation changes compared; code not bundled |

## Findings verified against those revisions

- The legacy C preparation/inspection code combines independent LIMG mismatch conditions with AND and writes to the source. The adapter does not invoke it.
- Converter paths do not consistently check opens, allocations, reads, writes or finalization. Its first partial encryption group can use uninitialized padding. The adapter uses zeroed buffers and checks every source/output operation.
- The older decryption loop does not verify stored ciphertext hashes and does not safely constrain malformed segment sizes/counts. The adapter accepts only the documented fixed profile and checks lengths, CMACs, metadata hashes and indices before completion.
- Apollo recomputes the image size after LIMG preparation, preventing the header from retaining the old size. The adapter computes the exact prepared-stream length before writing its header.
- Current pop-fe2 identifies stored sector layout from the descriptor rather than size alone. Its fallback still guesses if detection fails; the new adapter rejects unknown layouts instead.
- Original helper files have differing GPLv2 and other file-level notices. `tools.c`, `types.h`, `aes.c`, `sha1.c` and the old ISO preparer are not incorporated. The adapter uses standard integer types and Apple CommonCrypto, and retains the GPLv3 converter attribution. See `ThirdParty/PS2Classic/NOTICE.md`.

## Implemented boundary

`ps2-convert` is an independently executable C helper, bundled for Intel and Apple Silicon. It exposes CEX `encrypt-iso`, `encrypt-raw` (developer/reference tests), `decrypt`, and `verify`, using the logical header filename `ISO.BIN.ENC`. A matching binary klicensee is supplied by file; key bytes are not logged or persisted by the app. The helper contains fixed public format constants from the reference, not a user/production license key.

Preparation streams all original bytes, zero alignment padding and a new 16 KiB LIMG block without writing to the input or making a full prepared-image copy. For supported ISO sectors, LIMG uses type 1 / 2048, with the primary descriptor's logical block count. The original file's full length remains in the payload even when it exceeds that first declared volume. Raw CD formats and already-present LIMG repair are rejected.

The helper uses bounded buffers (~8 MiB data plus small fixed buffers), 64-bit lengths, a 256 GiB payload limit, exact I/O checks, destination space checks, exclusive temporary files, source size/mtime checks, cancellation and no-overwrite publication. Encryption verifies header fields and CMACs, each ciphertext segment hash/index, and the SHA-256 of the recovered entire prepared stream against the streamed input. Decryption checks the same structural/ciphertext metadata but cannot compare against an external original unless one is supplied by a test. These checks do not establish console operation or a claim of adversarial authenticity for the legacy format.

Output is first written beside its destination under a `.partial.*` name, then published with an exclusive hard link after successful checks. Therefore the destination filesystem must support hard links (the current development APFS volume does). Filesystems without that capability fail safely rather than publish. External FAT/exFAT handling remains release work. SIGINT/SIGTERM and ordinary I/O failures clean up the generated partial file; a force-kill/power loss may leave it for later cleanup. This is not a persistent/recoverable queue yet.

## Validation evidence

The adapted helper's metadata and data ciphertext matches the pinned upstream converter on an aligned synthetic input; random header bytes are intentionally excluded from byte equality. The new verifier also accepts that reference header. A recorded SHA-256 of the deterministic reference payload is part of the regression suite.

Full prepare/encrypt/verify/decrypt tests passed on all four supplied ISOs, using only a temporary synthetic test key. Whole-file source hashes remained unchanged and recovered source bytes matched exactly, including the entire DVD9-sized file. Synthetic tests cover truncated/corrupt containers, wrong keys/disc numbers, partial segments, group boundaries, aliases/overwrite attempts, injected write failure and cancellation. AddressSanitizer/UndefinedBehaviorSanitizer runs passed.

## Next integration work

1. Identify games from SYSTEM.CNF with bounded ISO parsing and separate media evidence from storage layout; add explicit raw-CD handling.
2. Pin/audit packaging helpers (ps3py/PSL1GHT, make_npdata and audio components), required package-template inputs and CONFIG provenance. No console template is bundled yet.
3. Build the first single-disc package using the verified image path; validate installation, launch and saving on the target console.
4. Add saved projects, persistent manifests/retry, CONFIG UI, artwork/audio and memory-card conversion.
5. Validate both client Macs, external volumes and standalone distribution/signing. Do not equate cross-compilation with Intel Monterey runtime testing.

## CHD reader — 0.4

libchdr is pinned to 8e7b8bd32bc676b7e5c6b42fe7d2daca986c4a0d with vendored codecs and upstream source notices. The helper statically links it for both architectures. The adapter restricts version, geometry, parent dependencies and track metadata before expansion. It checks block CRCs, recorded raw SHA-1 when present, output SHA-256 read-back and source file identity. Expanded output stays in the private job workspace. CHD input does not bypass normal ISO preparation checks.

The local CONFIG browser searches exact normalized serial filenames, preserves alternatives and skips symlinks/encrypted files. Stored SHA-256 is compared with the actual bytes used, not a second unrelated file read. Matching a filename is not a game-compatibility claim.
