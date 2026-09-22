# Client acceptance checklist — 1.0 RC5

This app is locally built and locally verified. It has **not** been tested on a real PS3 or on the client Macs. Use this checklist to close the remaining gaps. Do not mark an item passed until it has actually been performed and recorded.

## 1. Prerequisites before you start

- [ ] A matching support set from your existing workflow: 16-byte binary klicensee, matching 16-byte RAP, `PS3LOGO.DAT`, and a blank formatted `SCEVMC0.VMC`, plus the 36-character content ID. These are not bundled.
- [ ] A compatible modified PS3 for installation/launch testing.
- [ ] The target 2017 Intel MacBook Air (Monterey) and the 2024 M4 Mac mini. Record the exact OS version and build on each.

## 2. Run on each client Mac

- [ ] Drag `PS2 Classics for Mac.app` to Applications, launch it.
- [ ] Confirm the window opens, the sidebar shows 1.0 RC5, and no security/Gatekeeper block appears.
- [ ] Import the support folder in Setup; confirm the content ID is recognized and no mismatch warning is shown.
- [ ] Open a saved project or add a disc; confirm inspection reports the expected game ID.
- [ ] In Setup, choose a local CONFIG **library folder**, then quit and reopen; confirm the selection and its availability status are restored without an error (this exercised a crash in an earlier candidate).
- [ ] Use **Find matches…** to review a matching CONFIG's fingerprint, size and modification date, and select it.
- [ ] Optionally use **Find artwork…** against a folder of images named with the game ID; confirm the previews, that nothing is applied until you choose it, and that **Change folder…** immediately replaces the matches with the new folder's.
- [ ] Build one small package to a local destination; confirm it completes as *Locally verified*.
- [ ] Record OS version, time to build, and observed memory for the build.

## 3. Real hardware acceptance on the PS3

- [ ] Install the package; record whether installation succeeds.
- [ ] Launch the title; record whether it starts.
- [ ] Save and reload; confirm the save appears.
- [ ] For a multi-disc title (e.g. Xenosaga II), test disc switching both directions.
- [ ] Record the exact title, disc order, package size and content ID used.

## 4. External volume acceptance

- [ ] Build to an external USB volume with enough free space.
- [ ] Confirm large-file behavior on a supported APFS/Mac OS Extended volume; confirm FAT32 rejects files over its 4 GiB limit and direct exFAT publication is refused with guidance to copy completed files.
- [ ] Disconnect the volume mid-build; confirm the app reports a clear error and publishes no bad output.
- [ ] After a forced quit, reopen the app and use **Review interrupted work…**: only entries the app can prove it created show **Move to Trash**; anything else is manual review.
- [ ] Confirm a package published just before a crash is offered **Check published package** and is not labelled verified until that read-only check passes.

## 5. Reporting

- [ ] Export diagnostics from Setup or Build queue and attach it. It contains no key bytes or game data, but review local paths before sharing.
- [ ] Record any failure with the exact message, the stage, and the app version.

## Known limits that are not defects

- Multi-disc console behavior is experimental until your title is tested.
- A retry reuses already-verified encrypted stages when inputs are unchanged; it does not resume a partially written stream.
- Non-WAV audio conversion, multi-track CUE/CHD, manuals and console transfer are not implemented.
- The app is ad-hoc signed for local use; Developer ID signing and notarization are not done.

Current RC5 destination requirement: build/export on APFS or Mac OS Extended, then copy completed files to exFAT if needed. Direct publication on filesystems lacking exclusive rename or hard links is refused before work starts; no placeholder is published. Physical USB disconnection testing remains separate.
