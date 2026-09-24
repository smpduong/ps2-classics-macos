# Client acceptance checklist — 1.0 RC20

This app is locally built and locally verified. It has **not** been tested on a real PS3 or on the client Macs. Use this checklist to close the remaining gaps. Do not mark an item passed until it has actually been performed and recorded against the exact artifact hash in `dist/release-manifest-1.0-RC20.json`.

## 1. Prerequisites before you start

- [ ] A matching support set from your existing workflow: 16-byte binary klicensee, matching 16-byte RAP, `PS3LOGO.DAT`, and a blank formatted `SCEVMC0.VMC`, plus the 36-character content ID. These are not bundled.
- [ ] A compatible modified PS3 for installation/launch testing.
- [ ] The target 2017 Intel MacBook Air (Monterey) and the 2024 M4 Mac mini. Record the exact OS version and build on each.
- [ ] Real memory cards (or card images) with actual saves for the save workflow, plus a blank card for import targets. Never test with your only copy of a save.

## 2. Run on each client Mac

- [ ] Drag `PS2 Classics for Mac.app` to Applications, launch it.
- [ ] Confirm the window opens, the sidebar shows 1.0 RC20, and no security/Gatekeeper block appears.
- [ ] Import the support folder in Setup; confirm the content ID is recognized and no mismatch warning is shown.
- [ ] Open a saved project or add a disc; confirm inspection reports the expected game ID.
- [ ] Add a parent-dependent CHD without its parent; confirm the disc reports the declared parent identity and refuses to build until the exact parent is chosen with **Choose parent…**. Then choose the parent and confirm the pair verifies.
- [ ] In Setup, choose a local CONFIG **library folder**, then quit and reopen; confirm the selection and its availability status are restored without an error.
- [ ] Use **Find matches…** to review a matching CONFIG's fingerprint, size and modification date, and select it. Optionally load an opt-in HTTPS catalog, review its publisher/revision/license, download one entry, restart offline and confirm the cached copy is offered and refresh never changes the project selection.
- [ ] Optionally use **Find artwork…** against a folder of images named with the game ID; confirm the previews, that nothing is applied until you choose it, and that **Change folder…** immediately replaces the matches with the new folder's.
- [ ] Convert a short WAV/MP3 sample with **Convert audio to AT3…**; confirm cancellation works and no partial file remains.
- [ ] Build one small package to a local destination; confirm it completes as *Locally verified*.
- [ ] Record OS version, time to build, and observed memory for the build.

## 3. Real hardware acceptance on the PS3

- [ ] Install the package; record whether installation succeeds.
- [ ] Launch the title; record whether it starts.
- [ ] Save and reload; confirm the save appears.
- [ ] For a multi-disc title (e.g. Xenosaga II), test disc switching both directions.
- [ ] Play the converted AT3 audio; record whether it plays correctly.
- [ ] Open a package built with a PDF manual; check page orientation, legibility, navigation and return-to-game behavior.
- [ ] Record the exact title, disc order, package size and content ID used.

## 4. Memory-card save workflow (whole cards and individual saves)

- [ ] Back up a copy of a known card, restore into another new file, and test the restored copy on console without replacing the original backup.
- [ ] Browse the saves on a real card; confirm the listed names match the console browser.
- [ ] Export one save, then import it into a copy of another card using **Import save…**; confirm the original card is byte-identical before and after (hash it on the Mac).
- [ ] Test the imported copy on console: the save loads and new saves still work. Record the result; this is the open ECC/console-acceptance gate for imports.
- [ ] Confirm refusals behave: importing the same save twice, importing with no free space, and tampered exports must all fail with a reason and publish nothing.

## 5. Console transfer over FTP

- [ ] Start the PS3 FTP server; record its product/version, actual port and folder. The app's displayed `/dev_hdd0/packages` is only a starting value.
- [ ] Transfer a completed package; confirm the reported new subfolder, the read-back verification, and the final `package.pkg` name.
- [ ] Interrupt a separate transfer and inspect the identified partial folder; confirm nothing was overwritten and no partial was renamed.
- [ ] Locate the folder with the console file manager and install explicitly. Passwords must not be recorded in the acceptance report.

## 6. External volume acceptance

- [ ] Build to an external USB volume with enough free space.
- [ ] Confirm large-file behavior on a supported APFS/Mac OS Extended volume; confirm FAT32 rejects files over its 4 GiB limit and direct exFAT publication is refused with guidance to copy completed files.
- [ ] Disconnect the volume mid-build; confirm the app reports a clear error and publishes no bad output.
- [ ] After a forced quit, reopen the app and use **Review interrupted work…**: only entries the app can prove it created show **Move to Trash**; anything else is manual review.
- [ ] Confirm a package published just before a crash is offered **Check published package** and is not labelled verified until that read-only check passes.

## 7. Reporting and distribution

- [ ] Export diagnostics from Setup or Build queue and attach it. It contains no key bytes or game data, but review local paths before sharing.
- [ ] Record any failure with the exact message, the stage, and the app version.
- [ ] Developer ID signing and notarization are separate: ad-hoc signatures in this build are not acceptance.

## Known limits that are not defects

- Multi-disc console behavior is experimental until your title is tested.
- A retry reuses already-verified encrypted stages when inputs are unchanged; it does not resume a partially written stream.
- Common audio conversion, manuals, whole-card backups, save browse/export/import, parent-CHD import and FTP transfer are implemented and locally checked. Verify audio/manual playback, console FTP behavior and imported-save behavior separately as listed above.
- Deeper parent chains, older/multi-track CHD and mixed/audio CUE, a curated public CONFIG feed, in-place save import into existing cards and protected per-console card formats remain outside this candidate.
- The app is ad-hoc signed for local use; Developer ID signing and notarization are not done.

Current destination requirement: build/export on APFS or Mac OS Extended, then copy completed files to exFAT if needed. Direct publication on filesystems lacking exclusive rename or hard links is refused before work starts; no placeholder is published. Physical USB disconnection testing remains separate.
