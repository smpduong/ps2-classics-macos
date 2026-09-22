# Package format adapter

Sources/PS2Convert/package.inc adapts the debug package layout and QA digest procedure from PSL1GHT tools/ps3py/pkg.py, commit e05843e7233acde200d052c3e1421eac8c5c25a3, MIT license (included).
Source: https://github.com/sahlberg/PSL1GHT

The native implementation adds streaming read-back verification, exclusive publication, bounded buffers, input mutation checks and cancellation. No SELF rewriting is implemented; this writer is used only for PS2 Classics data packages. A synthetic native package was byte-identical to the pinned Python reference writer.
