# Bundled ATRAC3 encoder — source, revisions and licence obligations

The optional audio-conversion workflow uses a small native encoder helper,
`ps2-at3`, built from the following pinned upstream sources. The helper is a
**separate executable** invoked with structured arguments; the LGPL components
are not linked into the application itself.

| Component | Upstream | Pinned revision | Licence |
| --- | --- | --- | --- |
| atracdenc | https://github.com/dcherednik/atracdenc | `cb170709f836cb43dc0312455188c791159d81dc` | LGPL-2.1 |
| libgha (atracdenc submodule) | https://github.com/dcherednik/libgha | `00a95243254cfb1e43b05888ebc68e9aa401507a` | BSD-2-Clause |
| libsndfile | https://github.com/libsndfile/libsndfile | `72f6af15e8f85157bd622ed45b979025828b7001` (1.2.2) | LGPL-2.1 |

Source trees are vendored under `ThirdParty/atracdenc` and
`ThirdParty/libsndfile`. Build with `scripts/build-at3-helper.sh`, which
produces a Universal (`arm64` + `x86_64`), macOS 12 binary at `dist/ps2-at3`.
libsndfile is built as a static library with external codecs disabled (WAV/AIFF
reading only), so the helper has no runtime dependency beyond the system
libraries.

## Licence obligations to resolve before public distribution

LGPL-2.1 applies to atracdenc and libsndfile. They are bundled as a **separate
executable** and a **statically linked library** respectively, which triggers:

- Include the LGPL-2.1 text and copyright notices (done: bundled as
  `atracdenc-LICENSE.txt`, `libgha-LICENSE.txt`, `libsndfile-COPYING.txt`).
- Provide the complete corresponding source of the exact bundled revisions,
  and permit relinking against a modified version. The vendored source trees
  satisfy the source-availability part; the relink/notice mechanics should be
  confirmed by the product owner's licence review.
- libgha is BSD-2-Clause and its notice must be retained.

The product owner's public-licence decision and the complete corresponding-source
package remain an open external release gate; this note records the obligation
without choosing that licence on the owner's behalf.
