#!/usr/bin/env python3
"""Make a FAT32 SD image whose root holds first.adf, one long name and last.adf;
the case damages the long name.

usage: gen.py <image> <case>
  ok    intact long name (40 chars, 4 records)
  l255  intact long name of 255 chars (20 records, the maximum)
  seq   2nd record: wrong sequence number
  last  last record (number 1): wrong sequence number
  chk   2nd record: wrong checksum
  zero  1st record claims 0 records
  big   1st record claims 63 records
  n21   a consistent run of 21 records (one more than a name can have)
  n63   a consistent run of 63 records
Prints the name FAT32$DIR_LIST has to return for the long entry."""
import os, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fat32_write"))
from fatimg import make_image, put, Vol

img, case = sys.argv[1], sys.argv[2]
make_image(img, 8, 64)
long = "L" * 251 + ".adf" if case == "l255" else "averyveryverylongfilename_number_one.adf"
with tempfile.TemporaryDirectory() as t:
    put(img, t, "first.adf", b"x" * 100)
    put(img, t, long, b"y" * 100)
    put(img, t, "last.adf", b"z" * 100)
v = Vol(img)
slots = v.dir_slots(img, v.root)
i = next(i for i, s in enumerate(slots) if s[3][0] & 0x40 and s[3][11] == 0x0F)


def poke(j, ofs, val):
    c, sec, k, _ = slots[j]
    with open(img, "r+b") as f:
        f.seek(v.data_off + (c - 2) * v.spc * v.bps + sec * 512 + k * 32 + ofs)
        f.write(bytes([val]))


if case == "seq":
    poke(i + 1, 0, 0x07)
elif case == "last":
    poke(i + 3, 0, 0x05)
elif case == "chk":
    poke(i + 1, 13, slots[i + 1][3][13] ^ 0x55)
elif case == "zero":
    poke(i, 0, 0x40)
elif case == "big":
    poke(i, 0, 0x7F)
elif case in ("n21", "n63"):
    # rewrite the directory from the long name on: n records, numbered and
    # checksummed correctly, the short name of the long entry, last.adf
    n = int(case[1:])
    sfn, last = slots[i + 4][3], slots[i + 5][3]
    s = 0
    for ch in sfn[:11]:
        s = (((s & 1) << 7) + (s >> 1) + ch) & 0xFF
    recs = []
    for seq in range(n, 0, -1):
        r = bytearray(b"\xff" * 32)
        r[0] = seq | (0x40 if seq == n else 0)
        r[11], r[12], r[13], r[26], r[27] = 0x0F, 0, s, 0, 0
        for o in (1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30):
            r[o], r[o + 1] = ord("M"), 0
        recs.append(bytes(r))
    run = recs + [sfn, last]
    assert i + len(run) <= len(slots)
    for j, r in enumerate(run):
        for o, b in enumerate(r):
            poke(i + j, o, b)
elif case not in ("ok", "l255"):
    sys.exit("unknown case " + case)
print(long if case in ("ok", "l255") else "AVERYV~1.ADF")
