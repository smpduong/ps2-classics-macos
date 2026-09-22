# Corresponding source and license inventory — 1.0 RC6

This inventory lists the third-party code incorporated into the shipped helper and app, the license it is used under, and its compatibility with the project. Original project code is GPL-3.0-only; the owner approved this policy. Third-party grants remain unchanged.

| Component | Where | Pinned revision | License | Notes |
| --- | --- | --- | --- | --- |
| PSL1GHT ps3py (package format) | `Sources/PS2Convert/package.inc` | `e05843e7233acde200d052c3e1421eac8c5c25a3` | MIT | Package layout/keystream only; no SELF rewriting. Notice: `ThirdParty/PSL1GHT/`. |
| Hykem make_npdata (EDAT v3) | `Sources/PS2Convert/extras.inc` | `0462b6c972dceb092b0499b5445ca2a8e884a2ee` | GPLv3 | Crypto via Apple CommonCrypto; no legacy EC/LZ/AES source compiled. Notice: `ThirdParty/NPData/`. |
| ps2classic (CEX image format) | `Sources/PS2Convert/main.c` | lineage of `sdkmap/PS2Classics` `3241733c99a30ad0e2b1d09f52a952e4f5801608` | GPLv3 | Header/segment layout adapted; I/O and validation new. Notice: `ThirdParty/PS2Classic/`. |
| libchdr | `ThirdParty/libchdr`, static link | `8e7b8bd32bc676b7e5c6b42fe7d2daca986c4a0d` | BSD-3-Clause | Built with `LOWRAM_TARGET=1`. Notice: `ThirdParty/libchdr/PS2-NOTICE.md`. |
| zstd | `ThirdParty/libchdr/deps/zstd-1.5.7` | 1.5.7 | BSD-3-Clause | Retained separately (`LICENSE`). |
| LZMA SDK | `ThirdParty/libchdr/deps/lzma-26.02` | 26.02 | Public domain | Decompression only. |
| miniz | `ThirdParty/libchdr/deps/miniz-3.1.2` | 3.1.2 | MIT | Decompression only. |
| dr_flac | `ThirdParty/libchdr/include/dr_libs` | as vendored | Public domain / MIT-0 | FLAC decode. |
| atracdenc (`ps2-at3`) | `ThirdParty/atracdenc`, separate executable | `cb170709f836cb43dc0312455188c791159d81dc` | LGPL-2.1 | Native ATRAC3 encoder; bundled `atracdenc-LICENSE.txt`. |
| libsndfile | `ThirdParty/libsndfile`, static library in encoder | `72f6af15e8f85157bd622ed45b979025828b7001` | LGPL-2.1 | External codecs disabled; bundled `libsndfile-COPYING.txt`. |
| libgha | `ThirdParty/atracdenc/src/lib/libgha` | `00a95243254cfb1e43b05888ebc68e9aa401507a` | BSD-2-Clause | Bundled `libgha-LICENSE.txt`. |

The released bundle copies these notices into `Contents/Resources/` (`PS2Classic-COPYING.txt`, `PS2Classic-NOTICE.txt`, `PSL1GHT/`, `NPData/`, `libchdr/`).

## Obligations when distributing

- GPLv3 components (`ps2classic` and `make_npdata` adaptations) require the corresponding source and license text to be made available to recipients. Keep the `Sources/PS2Convert` sources and the `ThirdParty` notices bundled or otherwise offered.
- Do not silently replace the pinned revisions above with unreviewed newer versions.
- Apple CommonCrypto is used for AES/SHA/HMAC/HKDF; no separate crypto source is compiled.
- No production klicensee, RAP, `PS3LOGO.DAT` or formatted blank console card is bundled, and no Sony signature is produced.

## Regenerating

`swift build -c release --arch arm64 --arch x86_64` followed by `bash scripts/build-app.sh` reproduces the Universal helper and app from these sources. `bash scripts/validate-release.sh` runs the local synthetic checks.

## Audio source and rebuild path

The exact vendored audio source and build options are included in the source
baseline. `bash scripts/build-at3-helper.sh` rebuilds the separate Universal
encoder, including its static dependencies. `bash scripts/build-app.sh` installs
it and its notices into the app and applies local ad-hoc signatures. This gives
the owner a concrete rebuild/relink path to review before distribution; it preserves the selected GPL-3.0-only policy for original code and the upstream library grants.
See `ThirdParty/ATRAC_SOURCES.md` for the recorded revisions and notices.

RC6 normalization uses Apple's system AudioToolbox framework. FFmpeg is used
only by optional development tests; it is neither bundled nor a runtime
requirement. The source archive excludes ROMS, personal projects, keys, build
outputs, test results and local tool/session state.

`python3 scripts/make-source-baseline.py --version 1.0 --label RC6` produces the
source archive and checksum automatically. The release validator checks its
complete file list and every file's bytes against the source tree, and records
the source archive hash alongside the app archive hash. The standard release
script runs these steps after building the application.

## Nested audio components

The encoder/library trees also contain Kiss FFT (BSD-3-Clause), Apple ALAC
(Apache-2.0), GSM 06.10 (the retained permissive COPYRIGHT), and Sun G72x
(the retained source-file notice). Their original notices and full vendored
source are included in the app's Audio Sources folder and in the source archive.
The top-level LGPL files are **not** a replacement for these nested notices.
The audio sources generally grant LGPL-2.1-or-later; retain that grant, including
any applicable later-version compatibility when rebuilding combined components.
