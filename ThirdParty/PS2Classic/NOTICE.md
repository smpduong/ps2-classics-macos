# PS2 Classic backend provenance

The native helper's PS2 header/segment logic and format constants are adapted from `ps2classic.c`, marked GPLv3 by its authors (2013 USER; decryption algorithms by flatz).

Pinned reference: https://github.com/sahlberg/pop-fe2/blob/2afb9a3544e26ec1927f6389857240a0fe4bc205/ps2classic/ps2classic-ps2classic/ps2classic.c

An unchanged copy is retained as `ps2classic.reference.c` for provenance, excluded from compilation. COPYING contains GPL version 3. The adapted helper at `Sources/PS2Convert/main.c` is distributed under GPL-3.0. Preserve these notices and supply its corresponding source with distribution.

The adapter replaces the legacy file operations, buffer management, random generation and crypto wrappers; adds strict headers, content IDs, segment hashes/index checks, ciphertext lengths, disk checks, cancellation and atomic no-overwrite publication; and verifies recovered SHA-256 against the prepared input stream. Apple CommonCrypto implements AES-CBC and SHA; the CMAC composition uses those primitives. Legacy `tools.c`, `types.h`, `aes.c` and `sha1.c` are not incorporated into the app. Their mixed file-level license notices must not be assumed identical to the GPLv3 converter notice.

The ISO preparation policy was compared with `pop-fe2.py` at the same pinned revision and Apollo `source/ps2classic.c` at 687989878273c34a68ccae4e6419797ac43f6cd0. Those files are not bundled. ISO sector layout selects LIMG type 1/2048, the descriptor supplies the logical block count, and the entire source is preserved, including any additional volume/layer bytes. There is no fallback based on file size.

Only the CEX ISO.BIN.ENC profile is currently exposed. The user supplies the 16-byte klicensee; no user license key, RAP/RIF, console template or game asset is bundled. Fixed format constants originating in the public reference code are included in the adapter. Generated test keys are temporary and are not production license material.
