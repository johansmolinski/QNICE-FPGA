#!/usr/bin/env python3
"""
Regression test for the FAT32 shared-sector-buffer ownership invariant.

The FAT32 library keeps exactly one 512-byte sector buffer (physically inside
the SD controller). Ownership is tracked by FAT32$DEV_BUFFERED_FDH and each
handle carries its own FAT32$FDHF_DIRTY flag. Whoever repurposes that buffer
must first write back the current owner's dirty content.

FAT32$READ_FDH honours this. FAT32$DIR_OPEN and FAT32$FILE_OPEN historically
did not: they reloaded the buffer and claimed ownership without flushing, so a
handle that was in the middle of writing a sector silently lost the bytes it
had already put into the buffer. Its dirty flag stayed set, the sector was
re-read from the card on the next access, and the lost bytes reverted to their
old on-card content.

This test drives two files the way a caller with two concurrently open write
handles does: interleaved chunks, alternating between the handles. CTRLA/CTRLB
are the control pair (interleaving only, which always worked). TESTA/TESTB add
a directory open in the middle of a sector, which is what used to corrupt data.

Run:  ./fat32_multiwrite.py
"""

import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
QNICE = os.path.dirname(HERE)

SECTOR = 512
PART_START = 2048          # classic alignment; also proves the MBR is parsed
SEC_PER_CLUS = 2           # exercises both intra-cluster and cross-cluster steps
RSVD = 32
NUM_FATS = 2
TOTAL_SEC = 140000         # keeps the cluster count above the 65525 FAT32 floor

FILE_SIZE = 4000           # must match FSIZE in fat32_multiwrite.asm
CHUNK = 100                # mirrors config.vhd VD_ITERATION_SIZE

# Files are laid out round-robin so every one of them is fragmented; that makes
# the writers follow real FAT chains instead of a single contiguous run.
DATA_FILES = ["CTRLA", "CTRLB", "TESTA", "TESTB"]

# byte i of a file = (i * step + seed) & 0xFF, generated in the testbed by
# repeated addition. Distinct per file so a cross-file mix-up is visible too.
PATTERNS = {
    "CTRLA": (5, 3),
    "CTRLB": (11, 7),
    "TESTA": (5, 3),
    "TESTB": (11, 7),
}


def expected(name):
    step, seed = PATTERNS[name]
    return bytes(((i * step + seed) & 0xFF) for i in range(FILE_SIZE))


def _fat_size(total, rsvd, spc, num_fats):
    """Iterate to a self-consistent FAT size."""
    fatsz = 1
    while True:
        data = total - rsvd - num_fats * fatsz
        clusters = data // spc
        need = -(-(clusters + 2) * 4 // SECTOR)
        if need == fatsz:
            return fatsz, clusters
        fatsz = need


def _dirent(name, ext, attr, cluster, size):
    raw = name.ljust(8)[:8].encode("ascii") + ext.ljust(3)[:3].encode("ascii")
    return (raw + bytes([attr]) + b"\x00" * 8 +
            struct.pack("<H", (cluster >> 16) & 0xFFFF) +
            b"\x00" * 4 +
            struct.pack("<H", cluster & 0xFFFF) +
            struct.pack("<I", size))


def build_image(path):
    """Write an MBR + FAT32 image and return the on-disk extents of each file."""
    fatsz, clusters = _fat_size(TOTAL_SEC, RSVD, SEC_PER_CLUS, NUM_FATS)
    assert clusters >= 65525, f"only {clusters} clusters: that would be FAT16"

    fat_start = PART_START + RSVD
    data_start = fat_start + NUM_FATS * fatsz

    def clus_lba(n):
        return data_start + (n - 2) * SEC_PER_CLUS

    # ---- cluster allocation -------------------------------------------------
    root_clus = 2
    sub_clus = 3
    clus_bytes = SECTOR * SEC_PER_CLUS
    per_file = -(-FILE_SIZE // clus_bytes)     # round up, the tail is partial
    chains = {n: [] for n in DATA_FILES}
    nxt = 4
    for _ in range(per_file):                 # round-robin => fragmented files
        for name in DATA_FILES:
            chains[name].append(nxt)
            nxt += 1

    # ---- FAT ----------------------------------------------------------------
    fat = bytearray(fatsz * SECTOR)

    def set_fat(idx, val):
        struct.pack_into("<I", fat, idx * 4, val & 0x0FFFFFFF)

    set_fat(0, 0x0FFFFFF8)
    set_fat(1, 0x0FFFFFFF)
    set_fat(root_clus, 0x0FFFFFFF)
    set_fat(sub_clus, 0x0FFFFFFF)
    for chain in chains.values():
        for a, b in zip(chain, chain[1:]):
            set_fat(a, b)
        set_fat(chain[-1], 0x0FFFFFFF)

    # ---- directories --------------------------------------------------------
    root = bytearray()
    root += _dirent("SUBDIR", "", 0x10, sub_clus, 0)
    for name in DATA_FILES:
        root += _dirent(name, "BIN", 0x20, chains[name][0], FILE_SIZE)
    root = root.ljust(SECTOR * SEC_PER_CLUS, b"\x00")

    sub = bytearray()
    sub += _dirent(".", "", 0x10, sub_clus, 0)
    sub += _dirent("..", "", 0x10, 0, 0)
    sub += _dirent("DUMMY1", "TXT", 0x20, 0, 0)
    sub += _dirent("DUMMY2", "TXT", 0x20, 0, 0)
    sub = sub.ljust(SECTOR * SEC_PER_CLUS, b"\x00")

    # ---- boot sector --------------------------------------------------------
    bs = bytearray(SECTOR)
    bs[0:3] = b"\xEB\x58\x90"
    bs[3:11] = b"QNICETST"
    struct.pack_into("<H", bs, 11, SECTOR)
    bs[13] = SEC_PER_CLUS
    struct.pack_into("<H", bs, 14, RSVD)
    bs[16] = NUM_FATS
    struct.pack_into("<H", bs, 17, 0)          # root entries: 0 on FAT32
    struct.pack_into("<H", bs, 19, 0)          # total sec 16: 0 on FAT32
    bs[21] = 0xF8
    struct.pack_into("<H", bs, 22, 0)          # FATSz16 must be 0 (sanity check)
    struct.pack_into("<H", bs, 24, 63)
    struct.pack_into("<H", bs, 26, 255)
    struct.pack_into("<I", bs, 28, PART_START)
    struct.pack_into("<I", bs, 32, TOTAL_SEC)
    struct.pack_into("<I", bs, 36, fatsz)
    struct.pack_into("<H", bs, 40, 0)
    struct.pack_into("<H", bs, 42, 0)
    struct.pack_into("<I", bs, 44, root_clus)
    struct.pack_into("<H", bs, 48, 1)          # FSInfo
    struct.pack_into("<H", bs, 50, 6)          # backup boot sector
    bs[64] = 0x80
    bs[66] = 0x29
    struct.pack_into("<I", bs, 67, 0x12345678)
    bs[71:82] = b"QNICETEST  "
    bs[82:90] = b"FAT32   "
    struct.pack_into("<H", bs, 510, 0xAA55)

    fsinfo = bytearray(SECTOR)
    struct.pack_into("<I", fsinfo, 0, 0x41615252)
    struct.pack_into("<I", fsinfo, 484, 0x61417272)
    struct.pack_into("<I", fsinfo, 488, clusters - 2 - len(DATA_FILES) * per_file)
    struct.pack_into("<I", fsinfo, 492, nxt)
    struct.pack_into("<H", fsinfo, 510, 0xAA55)

    # ---- MBR ----------------------------------------------------------------
    mbr = bytearray(SECTOR)
    entry = (bytes([0x00, 0x01, 0x01, 0x00, 0x0C, 0xFE, 0xFF, 0xFF]) +
             struct.pack("<I", PART_START) + struct.pack("<I", TOTAL_SEC))
    mbr[446:462] = entry
    struct.pack_into("<H", mbr, 510, 0xAA55)

    # ---- assemble the image -------------------------------------------------
    with open(path, "wb") as f:
        f.truncate((PART_START + TOTAL_SEC) * SECTOR)

        def put(lba, data):
            f.seek(lba * SECTOR)
            f.write(data)

        put(0, mbr)
        put(PART_START, bs)
        put(PART_START + 1, fsinfo)
        put(PART_START + 6, bs)                # backup boot sector
        for i in range(NUM_FATS):
            put(fat_start + i * fatsz, fat)
        put(clus_lba(root_clus), root)
        put(clus_lba(sub_clus), sub)
        for name in DATA_FILES:                # files start out all-zero
            for c in chains[name]:
                put(clus_lba(c), b"\x00" * SECTOR * SEC_PER_CLUS)

    return {n: [clus_lba(c) * SECTOR for c in chains[n]] for n in DATA_FILES}


def read_back(path, extents, name):
    out = bytearray()
    with open(path, "rb") as f:
        for off in extents[name]:
            f.seek(off)
            out += f.read(SECTOR * SEC_PER_CLUS)
    return bytes(out[:FILE_SIZE])


def first_diff(got, want):
    for i, (a, b) in enumerate(zip(got, want)):
        if a != b:
            return i
    return None


def main():
    asm = os.path.join(QNICE, "assembler", "asm")
    emu = os.path.join(QNICE, "emulator", "qnice")
    monitor = os.path.join(QNICE, "monitor", "monitor.out")
    src = os.path.join(HERE, "fat32_multiwrite.asm")
    out = os.path.join(HERE, "fat32_multiwrite.out")

    for p in (asm, emu, monitor):
        if not os.path.exists(p):
            print(f"FAIL: missing {p}")
            print("      build the toolchain and the monitor first")
            return 1

    r = subprocess.run([asm, os.path.basename(src)], cwd=HERE,
                       capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(out):
        print("FAIL: assembling fat32_multiwrite.asm")
        print(r.stdout + r.stderr)
        return 1

    with tempfile.TemporaryDirectory() as tmp:
        img = os.path.join(tmp, "fat32test.img")
        extents = build_image(img)

        try:
            r = subprocess.run([emu, "-a", img, "-b", "0x8000", monitor, out],
                               capture_output=True, text=True, timeout=300,
                               stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            print("FAIL: emulator timed out")
            return 1

        print(r.stdout.strip())
        # Always diff the image, even when the testbed aborted: its own
        # read-back check stops at the first bad byte, while the diff below
        # shows every file that was damaged.
        reported_ok = "TESTBED-OK" in r.stdout

        bad = []
        for name in DATA_FILES:
            got = read_back(img, extents, name)
            want = expected(name)
            if got != want:
                i = first_diff(got, want)
                bad.append((name, i, want[i], got[i]))

    if not reported_ok or bad:
        print()
        if not reported_ok:
            print("FAIL: testbed aborted before reporting success")
        if not bad:
            return 1
        print("FAIL: file contents differ from what was written")
        for name, i, want, got in bad:
            kind = "control" if name.startswith("CTRL") else "dir-open"
            print(f"  {name}.BIN ({kind}): first mismatch at byte {i} "
                  f"(0x{i:04X}) -- expected 0x{want:02X}, got 0x{got:02X}")
        print()
        print("  CTRL* failing means plain interleaved writes across two open")
        print("  handles are broken. TEST* failing means a directory open stole")
        print("  the shared sector buffer from a handle that was mid-sector.")
        return 1

    print("PASS: interleaved writes and dir-open injection both byte-exact")
    return 0


if __name__ == "__main__":
    sys.exit(main())
