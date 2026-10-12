# Release gate ledger — PS2 Classics for Mac 1.0

This ledger is the authoritative list of what is **closed locally** and what
remains **open** for a final 1.0. It is deliberately explicit: a passing local
suite is not evidence of console or client-hardware behaviour, and this build is
therefore labelled a **1.0 release candidate**.

Artifact under evaluation: `dist/PS2 Classics for Mac 1.0 RC24.zip`
(`CFBundleShortVersionString` 1.0.0, `CFBundleVersion` 33, Universal
`arm64` + `x86_64`, minimum macOS 12.0). Exact hashes are recorded in
`dist/release-manifest-1.0-RC24.json` and `docs/VALIDATION.md`. RC23 build 32, RC22 build 31, RC21 build 30, RC20 build 29, RC19 build 28, RC18 build 27, RC17 build 26, RC16 build 25, RC15 build 24, RC14 build 23, RC13 build 22, RC12 build 21, RC11 build 20, RC10 build 19, RC9 build 18, RC8 build 17, RC7 build 16, RC6 build 15, RC5 build 14, RC4 build 13, RC3 build 12,
RC2 build 11, RC1 build 10 and all earlier archives are preserved.

## Gate history

- RC1 build 10 was reopened on two reproduced session failures (an ordinary
  saved CONFIG-library selection crashed the loader; one malformed queue
  element discarded the whole queue with no backup) and closed in RC2 build 11.
- RC2 build 11 was reopened on two further reproduced issues: a salvaged queue
  duplicate could share an identifier with a valid row (so row actions could
  affect the wrong or multiple rows), and changing the artwork folder left
  stale results. RC3 build 12 fixes both structurally and adds the regressions
  listed below.
- RC3 build 12 was reopened on one reproduced issue: editing a game ID or
  removing a disc while a CONFIG/artwork scan was pending left the search
  control disabled. RC4 build 13 fixes the completion lifecycle and adds
  completion-coordinated regressions; the gate is closed again for RC4.

## Closed local gates

| Gate | Status | Evidence |
| --- | --- | --- |
| No known data-loss defect | Closed (RC3) | Structural `SessionStore` decode; heterogeneous queue members; backup-or-lock on every unclean load; `SessionStoreTests`, `StudioModelTests` round trip and damaged-queue tests |
| Queue identifiers are unique after salvage | Closed (RC3) | One normalization path; decoded entries preferred; evidence cleared on reassignment; `SessionStoreTests` duplicate/mixed-queue tests; `testRemovingOrRetryingRecoveredDuplicateRowAffectsOnlyThatRow` |
| No known persistence/crash-on-load defect | Closed (RC2) | `testConfigLibraryURLRoundTripsThroughProductionEncoder`, `testConfigLibraryNilNullAndWrongTypeAreHandled`, `testURLFromSessionStringValidates`; full-model encoder/loader round trip with every optional setting |
| No known corruption/overwrite defect | Closed | Exclusive publication, existing-destination refusal, `PackageBuilderConfigTests` destination tests |
| No known operation-ownership defect | Closed | Token held until helper exits; import contention tests |
| Search results cannot go stale | Closed (RC3) | Folder/generation/project ownership for CONFIG and artwork searches; `StudioModelTests` ownership tests; live GUI folder A→B check |
| A search always finishes its lifecycle | Closed (RC4) | Owned-generation completion clears busy state and never publishes stale matches; `StudioModelTests` game-ID-edit/disc-removal/older-vs-newer/dismiss/replace/error tests await the real handler |
| Optional audio conversion is validated | Closed locally (RC6) | Common-audio normalization, format/duration/channel limits, cancellation, no overwrite, independent eight-format decoding and spectral checks. Console and client runtime acceptance remain external |
| Migration and recovery regressions | Closed | Legacy/mixed/malformed session tests; genuine recovery, stale attempt, missing/foreign evidence tests |
| Required automated suites | Closed | `scripts/validate-release.sh`: core + app tests, backend/formats/package/recovery suites, CHD matrix |
| App-level regression checks | Closed automatically (RC6) | Actual app-model tests cover ownership, contention, cancellation, recovery and sound selection. Earlier isolated GUI checks remain historical evidence; no new manual UI acceptance is claimed |
| Bounded record reads | Closed | `BoundedFile` used by attempt/report/workspace/cache/profile readers |
| Filesystem publication safety | Closed (RC5) | Unsupported exclusive publication fails closed before work; no unsafe placeholder fallback. Direct exFAT build is outside supported scope; physical USB acceptance remains open |
| Bundle/archive/resource agreement | Closed | `scripts/release-manifest.py` on the extracted archive |
| Licensing/source reproducibility | Closed locally (RC7) | Approved GPL-3.0-only, vendor notices and complete audio sources; strict extracted-source rebuild |
| Card backups/manual packaging/FTP protocol | Closed locally (RC8) | Card integrity/restore/cancel tests; independently decoded manual pages from single/multi packages; local FTP success/failure/corruption tests. Hardware acceptance remains open |
| Super Slim / HEN serial batch export | RC23 feature; RC24 hardening (local gate closed) | RC23 has 31 new tests (18 exporter + 10 session + 3 ROM), not 30; its cancellation evidence was pre-cancel only, and CONFIG-during-conversion was not established. RC23 full real synthetic conversion receipt remains valid. RC24 binds full ISO SHA-256 to reviewed preflight, checks it before conversion, verifies CONFIG after conversion, rejects key symlinks, locks damaged queues against overwrite, excludes published rows from preflight and fixes cancellation/retry ownership. Four-ROM RC24 read-only preflight receipt passed; strict gate passed 16/16; full real four-ROM conversion not repeated in RC24. Console acceptance remains open |
| Opt-in CONFIG catalog import | Implemented and tested locally (RC8); offline cache and receipts added (RC9) | Bounded schema/process tests and size/hash-verified local receipts; cached-copy review/download/forget tests; no default third-party feed claimed |
| Individual-save browse/export | Implemented and tested locally (RC9) | Bounded parser, synthetic small/full-size/encrypted fixtures, damage/cancellation/export regressions; cards never modified. Real-card and console save acceptance remain open |
| Single-level parent-CHD import | Implemented and tested locally (RC10) | Explicit parent selection with identity/depth/same-file checks through import, projects, queue, fingerprints, cache and recovery; reference byte-parity and parent-CHD package. Deeper chains, older/multi-track variants remain deferred |
| Individual-save import | Implemented and tested locally (RC11) | Manifest-bound exports into new files only; copy-first, strict allocation, reference-layout links, fresh ECC, re-parse/diff/round-trip verification. Originals never modified; console acceptance and protected formats remain open |
| Exact card ECC | Proven locally (RC11) | Bit-exact on 128 independent vectors plus erased/single-bit properties |
| Importer hardening | Closed locally (RC12) | Trap-free damaged roots, geometry-scoped ECC, bounded diff/cache, extra geometry fixtures; no behavior change |
| Write-path coverage | Closed locally (RC13) | Root growth, slot reuse, multi-FAT-cluster files, truncation/header/shape sweeps, ECC properties; no behavior change |
| Import verification integrity | Closed locally (RC15; removal guarantee narrowed in RC18) | Pre-write baseline surgical diff with a planned-allocation allowlist (both raw and decrypted inputs, bounded cancellable chunks); post-publication cancellation/read failure removes only the proven-owned .VMC/.VME output with honest cleanup errors and restores anything it did not publish (residual stated in RC18); decrypted published output compared byte-for-byte with the verified raw card in addition to the imported-save hashes; workspace (full card copies) removed on success and failure. RC14 closed the round-trip `nil == nil` whole-file-read flaw with a streaming comparison and removed unverified output; its published-file check compared only the imported save's hashes, completed in RC15 |
| Standard-size card geometry | Proven locally (RC16) | Synthetic 16/32/64 MiB export/import round trips; no behavior change; real-card layouts remain deferred |
| Owned-output removal consistency | Hardened locally (RC18) | Required identity, private-quarantine directory with a stated same-user residual (no identity-conditional unlink on macOS), vanished-entry honesty; one structured workspace choke point per outcome with combined causes; template/source consistency asserted every gate |
| Genuine parent-CHD rejection | Proven locally (RC9) | Reference-built and synthetic parent/child pairs rejected precisely; parent expands byte-exact. Broader parent/older/multi-track support remains deferred |
| Supported-scope limitations visible | Closed | README, USER_GUIDE, PROJECT_PLAN, RELEASE_NOTES, FEATURE_LEDGER, DEFERRED_WORK |

## Open external gates

Each item names what is needed and who can provide it. None can be closed by
local development alone, and none is waived.

1. **Matching production support assets and PS3 behaviour.** Needed: the real
   16-byte klicensee, matching RAP, `PS3LOGO.DAT`, blank `SCEVMC0.VMC` and the
   matching content ID, plus a compatible modified PS3. Verify install, launch,
   save/load. Owner: product owner + test console.
2. **Multi-disc console behaviour (if multi-disc is part of the 1.0 claim).**
   Needed: Xenosaga II disc switching in both directions and save/load across
   discs on the console. Owner: product owner + test console.
3. **Intel Monterey MacBook Air and M4 Mac mini runtime.** Needed: launch the
   assembled app on each client machine, build one small package, record OS
   version/build, time and observed memory. Cross-compilation is not runtime
   acceptance. Owner: product owner + the two client Macs.
4. **External-volume acceptance.** Needed: build to a real external USB volume,
   confirm large-file behaviour on its filesystem and confirm interrupted/
   disconnected destinations fail safely. Owner: product owner + an external
   drive.
5. **Distribution signing/notarization.** Needed: the chosen channel's
   Developer ID certificate, hardened-runtime signing and notarization. Owner:
   product owner + credentials.
6. **PS3 acceptance of the newer optional workflows.** Needed on the console:
   encoded manual display/navigation, FTP transfer/install, ATRAC3 playback,
   and imported-card saves (that an imported copy loads and still saves). Owner:
   product owner + test console.
7. **HEN Super Slim acceptance of the Super Slim / HEN batch export.** Needed on
   a HEN console: copy a generated `.BIN.ENC` and its optional plain CONFIG to
   `/dev_hdd0/PS2ISO` by the user's chosen method, confirm webMAN MOD lists it,
   that the PS2 Classics Launcher starts it, and that the game behaves as
   expected. Also confirm whether the optional `dev_hdd0/PS2ISO` folder layout
   the app produces is recognised as-is, or whether files must be flattened.
   Whether the images work at all on HEN has not been established locally: all
   local runs used a synthetic 16-byte klicensee and a matching content ID that
   no console has. This does not establish multi-disc support. Owner: product
   owner + HEN test console.
Public-license and corresponding-source decisions are **closed locally in RC7**: the owner approved GPL-3.0-only; vendor grants and nested sources/notices are preserved, with exact source archives rebuilt during the strict gate. Distribute the matching source with the binary. This is no longer an external approval gate.

## How to close the external gates

Follow [CLIENT_ACCEPTANCE_CHECKLIST.md](CLIENT_ACCEPTANCE_CHECKLIST.md). Record
each result against the exact artifact hash above. If every external gate
passes on this artifact, it may be promoted from release candidate to 1.0 with
no code change; otherwise the artifact stays a candidate and the findings feed
the next build.

## Acceptance results template (RC24)

Copy this into a new record and fill it in on the actual hardware. Every row is
performed on **this exact artifact**:

```
Artifact: dist/PS2 Classics for Mac 1.0 RC24.zip
SHA-256: copy archiveSHA256 from dist/release-manifest-1.0-RC24.json
Version/build: 1.0.0 / 33

[ ] PS3 install        result:            title/disc/CID used:
[ ] PS3 launch         result:            observed:
[ ] PS3 encoded audio playback  result:
[ ] PS3 save/load      result:            observed:
[ ] Xenosaga II disc 1 -> 2   result:      observed:
[ ] Xenosaga II disc 2 -> 1   result:      observed:
[ ] HEN: webMAN MOD lists the .BIN.ENC  result:   webMAN version:
[ ] HEN: PS2 Classics Launcher starts it  result:  observed:
[ ] HEN: nested dev_hdd0/PS2ISO folder recognised as-is?  result:
[ ] Intel MacBook Air (2017) runtime   OS/build:            result:
[ ] M4 Mac mini runtime                OS/build:            result:
[ ] Standalone launch (no dev tools)   result:
[ ] External USB volume large-file     filesystem/size:     result:
[ ] External drive disconnect mid-build result:             output published?:
[ ] Developer ID signing               result:
[ ] Notarization                       result:
[x] Owner licence decision             LICENSE and LICENSING.md
[x] Corresponding-source package       dist/source-baseline-1.0-RC24.tar.gz
[ ] PS3 manual display/navigation      result:
[ ] PS3 FTP transfer/install           server/folder/result:
[ ] PS3 imported-card save loads/saves result:
```

Signature integrity checked locally is **not** Developer ID/notarization
acceptance; cross-compilation is **not** runtime acceptance.

Record all client acceptance against the RC24 manifest hash; earlier candidate hashes do not identify this build.
