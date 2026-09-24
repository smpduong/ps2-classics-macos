# Local workflow test images

Confirmed 2026-09-20: `ROMS/` contains exactly four ISO files. The user supplied these as local workflow test inputs. Keep originals read-only and excluded from version control. Use this set for future backend acceptance work as the relevant features become available.

| File | Bytes | Test role | Observed volume label |
| --- | ---: | --- | --- |
| 4x4 Evo 2 (Europe).iso | 501,731,328 | CD-sized image; physical CD/DVD type not inferred from size | 4X4_EVOLUTION_2 |
| Xenosaga Episode 1.iso | 8,468,299,776 | User-supplied double-layer DVD case | Empty |
| Xenosaga Episode 2 (Disc 1).iso | 4,682,121,216 | Multi-disc game, disc 1 | XENOSAGA_II |
| Xenosaga Episode 2 (Disc 2).iso | 4,693,164,032 | Multi-disc game, disc 2 | XENOSAGA_II |

Names and ordering originate from the user/filenames. Version 0.3 additionally reads SYSTEM.CNF: SLES51199 (4x4), SLUS20469 (Episode 1), SLUS20892 (Episode 2 Disc 1), SLUS21133 (Episode 2 Disc 2). A boot ID does not independently establish disc sequence. The small image is a CD-sized test case, not verified evidence that its original medium was a CD. It does not replace a raw BIN/CUE fixture.

## Completed checks

All four images passed read-only inspection through the released local `ps2-inspect` executable, which shares the application's core. ISO descriptors were recognized and expected sizes/labels were reported. Full-file SHA-256 hashes matched before and after each inspection; file sizes and modification timestamps also remained unchanged. The checks read in bounded chunks and made no copies or changes to the ISOs.

The detailed local report, including hashes and executable fingerprint, is `test-results/rom-inspection.json`. This report and the entire ROMS folder are excluded from version control. These are basic inspection results, not complete integrity or game-compatibility validation.

## Cases to preserve in future implementation

- Xenosaga Episode 1's first descriptor declares 4,254,367,744 bytes, while the file contains 8,468,299,776 bytes. The current inspector reports the extra bytes as uninspected. This is not by itself a corruption finding or verified layer layout. Future DVD9 preparation must explicitly inspect the full layout and must never truncate the source to the first declared volume length.
- The Episode 2 images both use `XENOSAGA_II`. A volume label alone cannot distinguish these discs or establish their order. Future projects must retain explicit disc order and separate per-disc fingerprints/settings.
- The CD-sized image must not be forced to CD solely because it is small. Keep physical-medium evidence and any explicit override separate.

## Repeat the current checks

From the project folder, after building the preview:

```sh
python3 scripts/test-rom-workflow.py > test-results/rom-inspection.json
```

The optional developer script expects this exact fixture set and uses no third-party Python packages. It is not an end-user application dependency. It emits JSON to standard output, progress to standard error, and exits nonzero on failed checks. It hashes every source twice, so allow time for disk reads. Do not redirect its output into ROMS or over an image.

Preparation/encryption/decryption are now tested as described below. Packaging is now locally tested in 0.3. Actual DVD9 console behavior, disc switching, Intel Monterey execution and PS3 installation/launch/saving remain untested. Extend local integration tests to cover those stages when they are implemented; retain synthetic fixtures for ordinary unit tests.

## Conversion follow-up — 0.2 (2026-09-20)

All four originals completed prepare → encrypt → verify → decrypt using a temporary synthetic klicensee. Recovered source-prefix SHA-256 hashes matched each full original, original before/after hashes matched, and the appended padding/LIMG fields and complete prepared length matched expectations. Episode 2 Disc 2 was exercised with disc number 2; the other cases used disc number 1. No game data was omitted from the DVD9-sized input. This does not prove on-console DVD9 behavior or disc switching.

Run `python3 scripts/test-rom-conversion.py > test-results/rom-conversion.json` to repeat. The script requires workspace for one encrypted and one decrypted image at a time, removes only the temporary outputs it creates, and never alters the originals. The saved report records the tested helper fingerprint and checks; no production key or console-ready output is retained.

## Package follow-up — 0.3

Complete packages passed for 4x4 Evo 2, Xenosaga Episode 1 and the two Episode 2 discs together. Source hashes remain unchanged. The local package test uses generated support fixtures and deletes its outputs; it validates complete native read-back plus independent metadata/index/sample extraction. See VALIDATION.md. The two-disc project preserves the separate boot IDs and user-specified order.

## Version 0.4 follow-up

All four originals passed descriptor, boot-ID and full SHA-256 preservation checks again. Temporary CHDs generated from these originals completed the native CHD-to-PKG workflow: CD-sized 14.88 s, DVD9 239.08 s, two-disc package 262.40 s (fixture compression excluded). All native integrity checks and independent package checks passed; temporary files were removed. See VALIDATION.md for exact package sizes and remaining hardware gates.

## Version 0.5 follow-up

All four originals again passed descriptor, boot-ID and full SHA-256 checks, then completed complete packages through the release builder with the modified helper: CD-sized 520,135,344 B / 13.24 s, DVD9 8,502,254,080 B / 213.45 s, two-disc 9,411,154,448 B / 239.10 s (SLUS20892 then SLUS21133 in order). The CD-sized image was additionally prepared and encrypted with the explicit ISO.BIN.ENC2 profile and disc number 2, detected back as ISO.BIN.ENC2, verified, and decrypted; the recovered prefix matched the original hash and the original stayed unchanged. Temporary outputs were removed. This remains local workflow/integrity evidence, not console behavior.

## Version 0.6 follow-up

All four originals passed descriptor, boot-ID and full SHA-256 checks and completed packages through the release 0.6 tools: CD-sized 520,135,344 B / 19.33 s, DVD9 8,502,254,080 B / 323.35 s, two-disc 9,411,154,448 B / 357.89 s (SLUS20892 then SLUS21133 retained). Every original hash matched the known value and was unchanged before/after. Each package passed both independent Python decoding and the new native read-only `verify-package` check. Times rose because every package is now additionally re-verified and sources are fingerprinted up front. Temporary outputs were removed. This is still local workflow/integrity evidence, not console behavior.

## Version 0.7 follow-up

All four originals passed descriptor, boot-ID and full SHA-256 checks and completed packages through the release 0.7 tools; every original hash matched the known value and was unchanged before/after. Each package passed independent Python decoding **and** native `verify-package` with content-ID, title-ID and image-name binding. Times are development-host measurements, not client promises. Temporary outputs were removed. This is still local workflow/integrity evidence, not console behavior.

## Version 0.8 follow-up

All four originals passed descriptor, boot-ID and full SHA-256 checks and completed packages through the release 0.8 tools (CD-sized 21.1 s, DVD9 346.11 s, two-disc 381.18 s); every original hash matched the known value and was unchanged before/after. Each package passed independent Python decoding **and** identity-bound native `verify-package`. Times are development-host measurements, not client promises. Temporary outputs were removed. This is still local workflow/integrity evidence, not console behavior.

## Version 0.9 follow-up

All four originals passed descriptor, boot-ID and full SHA-256 checks and completed packages through the release 0.9 tools (CD-sized 520,135,344 B / 20.78 s, DVD9 8,502,254,080 B / 328.33 s, two-disc 9,411,154,448 B / 348.94 s, SLUS20892 then SLUS21133 retained). Every original hash matched the known value and was unchanged before/after, and each build report now carries the durable attempt fingerprint, fit/crop setting and support/asset hashes. Each package passed independent Python decoding **and** identity-bound native `verify-package`. Times are development-host measurements, not client promises. Temporary outputs were removed. This is still local workflow/integrity evidence, not console behavior.

## Version 1.0 release-candidate follow-up

All four originals passed descriptor, boot-ID and full SHA-256 checks and completed packages through the release 1.0 candidate tools (CD-sized 520,135,344 B / 19.42 s, DVD9 8,502,254,080 B / 315.06 s, two-disc 9,411,154,448 B / 360.23 s, SLUS20892 then SLUS21133 retained). Every original hash matched the known value and was unchanged before/after, and each build report carried the durable attempt fingerprint, fit/crop setting and support/asset hashes. Each package passed independent Python decoding **and** identity-bound native `verify-package`. Times are development-host measurements, not client promises. Temporary outputs were removed. This is still local workflow/integrity evidence, not console behavior.

## Version 1.0 RC2 follow-up

All four originals passed descriptor, boot-ID and full SHA-256 checks and completed packages through the release 1.0 RC2 tools (CD-sized 520,135,344 B / 21.31 s, DVD9 8,502,254,080 B / 345.21 s, two-disc 9,411,154,448 B / 361.87 s, SLUS20892 then SLUS21133 retained). Every original hash matched the known value and was unchanged before/after, and each build report carried the durable attempt fingerprint, fit/crop setting and support/asset hashes. Each package passed independent Python decoding **and** identity-bound native `verify-package`. Times are development-host measurements, not client promises. Temporary outputs were removed. This is still local workflow/integrity evidence, not console behavior.

## Version 1.0 RC3 follow-up

All four originals passed descriptor, boot-ID and full SHA-256 checks and completed packages through the release 1.0 RC3 tools (CD-sized 520,135,344 B / 19.34 s, DVD9 8,502,254,080 B / 321.19 s, two-disc 9,411,154,448 B / 355.09 s, SLUS20892 then SLUS21133 retained). Every original hash matched the known value and was unchanged before/after, and each build report carried the durable attempt fingerprint, fit/crop setting and support/asset hashes. Each package passed independent Python decoding **and** identity-bound native `verify-package`. Times are development-host measurements, not client promises. Temporary outputs were removed. This is still local workflow/integrity evidence, not console behavior.

## Version 1.0 RC4 follow-up

All four originals passed descriptor, boot-ID and full SHA-256 checks and completed packages through the release 1.0 RC4 tools (CD-sized 520,135,344 B / 21.31 s, DVD9 8,502,254,080 B / 337.8 s, two-disc 9,411,154,448 B / 373.31 s, SLUS20892 then SLUS21133 retained). Every original hash matched the known value and was unchanged before/after, and each build report carried the durable attempt fingerprint, fit/crop setting and support/asset hashes. Each package passed independent Python decoding **and** identity-bound native `verify-package`. Times are development-host measurements, not client promises. Temporary outputs were removed. This is still local workflow/integrity evidence, not console behavior. RC4 additionally adds an optional WAV->ATRAC3 encoder whose output was validated by independent decoding.

## RC18 follow-up

No disc-conversion code changed (card quarantine/cleanup consistency and docs only; the `ps2-convert` helper is byte-identical to RC17), so no package rebuild was claimed. All four originals re-passed read-only descriptor, boot-ID and full SHA-256 checks with the current helper (`test-results/rom-inspection.json`, passed). This remains local workflow/integrity evidence, not console behavior.

## RC17 follow-up

No disc-conversion code changed (card ownership-cleanup and docs only; the `ps2-convert` helper is byte-identical to RC16), so no package rebuild was claimed. All four originals re-passed read-only descriptor, boot-ID and full SHA-256 checks with the current helper (`test-results/rom-inspection.json`, passed). This remains local workflow/integrity evidence, not console behavior.

## RC16 follow-up

No disc-conversion code changed (card-geometry regressions and docs only; the `ps2-convert` helper is byte-identical to RC15), so no package rebuild was claimed. All four originals re-passed read-only descriptor, boot-ID and full SHA-256 checks with the current helper (`test-results/rom-inspection.json`, passed). This remains local workflow/integrity evidence, not console behavior.

## RC15 follow-up

No disc-conversion code changed (Swift card tools and docs only; the `ps2-convert` helper is byte-identical to RC14), so no package rebuild was claimed. All four originals re-passed read-only descriptor, boot-ID and full SHA-256 checks with the current helper (`test-results/rom-inspection.json`, passed). This remains local workflow/integrity evidence, not console behavior.

## RC14 follow-up

No disc-conversion code changed (the `ps2-convert` helper is byte-identical to RC13), so no package rebuild was claimed. All four originals re-passed read-only descriptor, boot-ID and full SHA-256 checks with the current tools (`test-results/rom-inspection.json`, passed). This remains local workflow/integrity evidence, not console behavior.

## RC13 follow-up

No disc-conversion code changed (tests and docs only), so no package rebuild was claimed. All four originals re-passed read-only descriptor, boot-ID and full SHA-256 checks with the current helper (`test-results/rom-inspection.json`, passed). This remains local workflow/integrity evidence, not console behavior.

## RC12 follow-up

No disc-conversion code changed (card tools and docs only), so no package rebuild was claimed. All four originals re-passed read-only descriptor, boot-ID and full SHA-256 checks with the current helper (`test-results/rom-inspection.json`, passed). This remains local workflow/integrity evidence, not console behavior.

## RC11 follow-up

No disc-conversion code changed (Swift card tools and docs only), so no package rebuild was claimed. All four originals re-passed read-only descriptor, boot-ID and full SHA-256 checks with the current helper (`test-results/rom-inspection.json`, passed). This remains local workflow/integrity evidence, not console behavior.

## RC10 follow-up

The `ps2-convert` helper changed (parent-aware CHD open/inspect/extract plus precise format reports), so the full read-only package suite ran again: CD-sized 520,135,344 bytes / 19.67 s, DVD9 8,502,254,080 bytes / 329.33 s, two-disc 9,411,154,448 bytes / 377.01 s (SLUS20892 then SLUS21133 retained). Every original hash matched the known value and was unchanged before/after, and each package passed independent Python decoding and identity-bound native verification. Results: `test-results/v19-real-packages.json` (git-ignored). This remains local workflow/integrity evidence, not console behavior.

## RC9 follow-up

The `ps2-convert` helper is byte-identical to the RC8 manifest, so no disc-conversion behavior changed. All four originals passed read-only descriptor, boot-ID and full SHA-256 checks again with the rebuilt helper (`test-results/rom-inspection.json`, passed); every original hash matched and was unchanged before/after. No full ROMS package rebuild is claimed for RC9; RC8 package evidence carries over on identical helper bytes. This remains local workflow/integrity evidence, not console behavior.

## RC5 independent correction pass

CD-sized: 520,135,344 bytes / 20.81 seconds; DVD9: 8,502,254,080 bytes / 339.09 seconds; two-disc: 9,411,154,448 bytes / 373.38 seconds. All four original SHA-256 values were unchanged, disc order/IDs retained, independent decoding and identity-bound verification passed. Exact tested tools match the RC5 release manifest. Results: `test-results/v14-real-packages.json`. No console compatibility is implied.
