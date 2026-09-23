#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Synthetic PS2 memory-card builder + independent inventory reader.

Layout follows Ross Ridge's public-domain filesystem description (see
docs/SAVE_FORMAT_NOTES.md): 512-byte pages with 16-byte spare areas, clusters
of 2 pages, superblock geometry, double-indirect FAT, 512-byte directory
entries. The builder and the reader below are separate code paths; the Swift
parser (MemoryCardSaves) is validated against cards produced here during
development, and its committed tests construct their own small cards.
"""
import hashlib
import struct
from pathlib import Path

PAGE_DATA = 512
PAGE_SPARE = 16
PAGE_RAW = 528


class Card:
    def __init__(self, clusters=8192, pages_per_cluster=2, alloc_offset=41):
        self.clusters = clusters
        self.ppc = pages_per_cluster
        self.alloc = alloc_offset
        self.pages = clusters * pages_per_cluster
        self.raw = bytearray(self.pages * PAGE_RAW)

    def _page_off(self, page):
        return page * PAGE_RAW

    def write_page_data(self, page, data: bytes):
        assert len(data) <= PAGE_DATA
        off = self._page_off(page)
        self.raw[off:off + len(data)] = data

    def write_cluster(self, absolute, data: bytes):
        assert len(data) <= self.ppc * PAGE_DATA
        for i in range(self.ppc):
            chunk = data[i * PAGE_DATA:(i + 1) * PAGE_DATA]
            self.write_page_data(absolute * self.ppc + i, chunk)

    def cluster_bytes(self):
        return self.ppc * PAGE_DATA

    def bytes(self):
        return bytes(self.raw)


def dirent(mode, length, cluster, name, first=False):
    assert len(name.encode('ascii')) < 32
    entry = bytearray(512)
    struct.pack_into('<H', entry, 0, mode)
    struct.pack_into('<I', entry, 4, length)
    struct.pack_into('<I', entry, 0x10, cluster)
    if first:
        struct.pack_into('<I', entry, 0x14, 0)
    entry[0x40:0x40 + len(name)] = name.encode('ascii')
    return bytes(entry)


DMODE = 0x8427
FMODE = 0x8417
LAST = 0xFFFFFFFF
USED = 0x80000000


def build_standard(files: dict, second_save=True) -> bytes:
    """files maps save-dir name -> {filename: bytes}. Returns a full 8MiB card."""
    card = Card()
    fat = [0] * (card.clusters - card.alloc)
    nxt = [0]

    def take(n):
        out = []
        for _ in range(n):
            while nxt[0] in (r for r, v in enumerate(fat) if v != 0):
                nxt[0] += 1
            out.append(nxt[0])
            fat[nxt[0]] = USED
            nxt[0] += 1
        for a, b in zip(out, out[1:]):
            fat[a] = USED | b
        fat[out[-1]] = LAST
        return out

    per = card.cluster_bytes() // 512
    root_chain = take(2)
    root_entries = [dirent(DMODE, 0, 0, '.'), dirent(DMODE, 0, 0, '..')]
    # Root length patched below once saves are known.
    save_names = list(files)
    if second_save:
        save_names.append('BESLES-54321EMPTY')
        files = dict(files)
        files['BESLES-54321EMPTY'] = {}
    dir_chains = {}
    for name in save_names:
        contents = files[name]
        entries = [dirent(DMODE, 0, 0, '.'), dirent(DMODE, 0, 0, '..')]
        for fname, fdata in contents.items():
            need = max(1, (len(fdata) + card.cluster_bytes() - 1) // card.cluster_bytes())
            chain = take(need) if fdata else []
            if fdata:
                blob = fdata + bytes(need * card.cluster_bytes() - len(fdata))
                for rel, i in zip(chain, range(need)):
                    card.write_cluster(card.alloc + rel, blob[i * card.cluster_bytes():(i + 1) * card.cluster_bytes()])
            entries.append(dirent(FMODE, len(fdata), chain[0] if chain else LAST, fname))
        need_dir = (len(entries) + per - 1) // per
        chain = take(need_dir)
        dir_chains[name] = (chain, entries)
        root_entries.append(dirent(DMODE, len(entries), chain[0], name))
    root_entries[0] = dirent(DMODE, len(root_entries), 0, '.')
    for rel, i in zip(root_chain, range(2)):
        blob = b''.join(root_entries[i * per:(i + 1) * per])
        card.write_cluster(card.alloc + rel, blob + bytes(card.cluster_bytes() - len(blob)))
    for name, (chain, entries) in dir_chains.items():
        for rel, i in zip(chain, range(len(chain))):
            blob = b''.join(entries[i * per:(i + 1) * per])
            card.write_cluster(card.alloc + rel, blob + bytes(card.cluster_bytes() - len(blob)))
    # Indirect FAT + FAT clusters at absolute 8 and 9..40.
    fat_clusters = (len(fat) + 255) // 256
    indirect = [9 + i for i in range(fat_clusters)] + [LAST] * (256 - fat_clusters)
    card.write_cluster(8, struct.pack('<256I', *indirect))
    flat = (fat + [0] * (fat_clusters * 256 - len(fat)))
    for i in range(fat_clusters):
        card.write_cluster(9 + i, struct.pack('<256I', *flat[i * 256:(i + 1) * 256]))
    sb = bytearray(PAGE_DATA)
    sb[0:28] = b'Sony PS2 Memory Card Format '
    sb[0x1C:0x1C + 12] = b'1.2.0.0\x00\x00\x00\x00\x00'
    struct.pack_into('<H', sb, 0x28, 512)
    struct.pack_into('<H', sb, 0x2A, 2)
    struct.pack_into('<H', sb, 0x2C, 16)
    struct.pack_into('<H', sb, 0x2E, 0xFF00)
    struct.pack_into('<I', sb, 0x30, card.clusters)
    struct.pack_into('<I', sb, 0x34, card.alloc)
    struct.pack_into('<I', sb, 0x38, 8135)
    struct.pack_into('<I', sb, 0x3C, 0)
    struct.pack_into('<I', sb, 0x40, 1023)
    struct.pack_into('<I', sb, 0x44, 1022)
    struct.pack_into('<32I', sb, 0x50, *([8] + [LAST] * 31))
    struct.pack_into('<32I', sb, 0xD0, *([LAST] * 32))
    sb[0x150] = 2
    sb[0x151] = 0x52
    card.write_page_data(0, bytes(sb))
    return card.bytes()


def inventory(raw: bytes):
    """Independent reader: returns {save: {file: (bytes, sha256)}}."""
    def page(p):
        return raw[p * PAGE_RAW:p * PAGE_RAW + PAGE_DATA]
    sb = page(0)
    assert sb[0:28] == b'Sony PS2 Memory Card Format '
    page_len, ppc = struct.unpack_from('<HH', sb, 0x28)
    clusters, alloc = struct.unpack_from('<II', sb, 0x30)
    (root_rel,) = struct.unpack_from('<I', sb, 0x3C)
    cbytes = page_len * ppc
    ifc = struct.unpack_from('<32I', sb, 0x50)

    def cluster_data(absolute):
        out = b''
        for i in range(ppc):
            out += page(absolute * ppc + i)
        return out

    fat = {}
    per_fat = cbytes // 4

    def fat_entry(rel):
        if rel not in fat:
            ind = cluster_data(ifc[(rel // per_fat) // 256])
            fat_cluster = struct.unpack_from('<256I', ind, ((rel // per_fat) % 256) * 4)[0]
            blob = cluster_data(fat_cluster)
            base = (rel // per_fat) * per_fat
            for i in range(per_fat):
                fat[base + i] = struct.unpack_from('<I', blob, i * 4)[0]
        return fat[rel]

    def chain(first):
        out, seen, cur = [], set(), first
        while True:
            assert cur not in seen and cur < clusters - alloc
            seen.add(cur)
            out.append(cluster_data(alloc + cur))
            entry = fat_entry(cur)
            assert entry & USED
            if entry == LAST:
                break
            cur = entry & 0x7FFFFFFF
        return b''.join(out)

    def entries(blob):
        result = []
        for i in range(0, len(blob), 512):
            e = blob[i:i + 512]
            (mode,) = struct.unpack_from('<H', e, 0)
            (length,) = struct.unpack_from('<I', e, 4)
            (first,) = struct.unpack_from('<I', e, 0x10)
            name = e[0x40:0x60].split(b'\x00')[0].decode('ascii')
            result.append((mode, length, first, name))
        return result

    root = entries(chain(root_rel))
    assert [n for _, _, _, n in root[:2]] == ['.', '..']
    saves = {}
    for mode, length, first, name in root[2:]:
        assert mode & 0x8000 and mode & 0x20
        sub = entries(chain(first)[:length * 512])
        assert [n for _, _, _, n in sub[:2]] == ['.', '..']
        files = {}
        for fmode, flen, ffirst, fname in sub[2:]:
            assert fmode & 0x8000 and fmode & 0x10
            data = chain(ffirst)[:flen] if flen else b''
            assert len(data) == flen
            files[fname] = (data, hashlib.sha256(data).hexdigest())
        saves[name] = files
    return saves


if __name__ == '__main__':
    import json
    import subprocess
    import sys
    import tempfile
    icon = bytes(range(100))
    payload = bytes((i * 37) % 256 for i in range(2500))
    raw = build_standard({'BASLUS-12345GAMEDATA': {'icon.sys': icon, 'data.bin': payload}})
    assert len(raw) == 8650752, len(raw)
    found = inventory(raw)
    assert set(found) == {'BASLUS-12345GAMEDATA', 'BESLES-54321EMPTY'}, found.keys()
    assert found['BASLUS-12345GAMEDATA']['icon.sys'][0] == icon
    assert found['BASLUS-12345GAMEDATA']['data.bin'][0] == payload
    assert found['BESLES-54321EMPTY'] == {}
    print(json.dumps({'passed': True, 'bytes': len(raw),
                      'saves': {k: {f: {'bytes': len(d), 'sha256': h} for f, (d, h) in v.items()}
                                for k, v in found.items()}}))
