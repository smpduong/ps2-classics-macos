# libchdr and bundled codecs

Source: https://github.com/rtissera/libchdr
Pinned revision: 8e7b8bd32bc676b7e5c6b42fe7d2daca986c4a0d (v0.3.0).

The source in this directory is unmodified. Build selection is in Package.swift;
LOWRAM_TARGET=1 enables the checkpoint map reader. Raw data sectors, subcode and
block CRC validation use upstream defaults. No external runtime is required.
The app adapter is Sources/PS2Convert/chd.inc and supports a restricted CHD v5
DVD / single data-track CD profile; it does not claim every libchdr format.

libchdr and MAME-derived routines carry BSD 3-clause notices in LICENSE.txt and
the individual source/header files. Bundled LZMA 26.02 is public domain (deps/lzma-26.02/LICENSE).
miniz 3.1.2 includes MIT/public-domain notices in its C/header sources; zstd 1.5.7
includes BSD notices in its amalgamated sources; the BSD option is selected.
Its complete LICENSE is additionally retained from
https://raw.githubusercontent.com/facebook/zstd/v1.5.7/LICENSE. dr_flac carries its public-domain
or MIT-0 license text at the end of include/dr_libs/dr_flac.h.

The complete retained libchdr source directory, including these license texts and
copyright notices, is copied into the application's Resources for binary distribution.
The upstream tests and repository metadata are omitted. MAME chdman is used only
as an independent development test tool; it is not bundled or required by users.
