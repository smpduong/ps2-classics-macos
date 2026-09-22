# EDAT adapter

Sources/PS2Convert/extras.inc adapts the scoped EDAT v3 / local license / type 1 / uncompressed 16 KiB-block encryption procedure and RAP conversion from Hykem's make_npdata, Linux/make_npdata.c and constants in make_npdata.h, commit 0462b6c972dceb092b0499b5445ca2a8e884a2ee. GPLv3; copyright Hykem (C) 2014. Preserve the included GPLv3 license.
Source: https://github.com/masible/make_npdata

The adapter uses Apple CommonCrypto. It does not compile or incorporate the reference AES, SHA, elliptic-curve, LZ or brute-force implementations. EDAT ECDSA fields are placeholders, matching the reference creation workflow; they are not Sony signatures. This is a modified-console debug-package workflow.

Memory-card layout/key derivation is from the pinned PS2Classic reference already documented in ../PS2Classic/NOTICE.md.
