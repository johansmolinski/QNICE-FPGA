#!/usr/bin/env python3
"""Build a FAT32 SD image and the op table of a write layer test phase.

usage: gen.py <case dir> <sectors per cluster>          make the image (sd.img, files.txt)
       gen.py <case dir> table <phase> [result log]    write tests.inc for a phase
Phase A allocates and frees chains (some stay allocated, their clusters are
listed in the log), phase B frees what A left (from A's log) and, for small
images, fills the card completely and frees it again.
"""
import os, random, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fatimg import *

case = sys.argv[1]
os.makedirs(case, exist_ok=True)
img = os.path.join(case, "sd.img")

if sys.argv[2] != "table":
    spc = int(sys.argv[2])
    cb = spc * 512
    mb = max(64, (cb * 70000) // (1024 * 1024) + 8)
    make_image(img, spc, mb)
    rnd = random.Random(spc)
    files = []
    with tempfile.TemporaryDirectory() as t:
        for i in range(12):                         # files, then holes: delete every other
            name = "F%02d.BIN" % i
            size = rnd.choice((1, 600, cb, cb + 1, 3 * cb, 5000))
            put(img, t, name, pattern(size, i))
            files.append((name, size, i))
        for name, size, i in files[1::2]:
            run("mdel", "-i", mt(img), "::" + name)
        run("mmd", "-i", mt(img), "::SUB")
        # garbage in free clusters: a big file of 0xAA, deleted again
        put(img, t, "GARBAGE.BIN", b"\xAA" * (40 * cb))
        run("mdel", "-i", mt(img), "::GARBAGE.BIN")
    with open(os.path.join(case, "files.txt"), "w") as f:
        for name, size, i in files[0::2]:
            f.write(f"{name} {size} {i}\n")
    open(os.path.join(case, "mb.txt"), "w").write(str(mb))
    sys.exit(0)

phase = sys.argv[3]
ops = []
names = []
dirs = [0]
def nm(n):
    names.append(n)
    return len(names) - 1
BEGIN, END, ALLOC, FREE, FILL, FREEC = 1, 2, 3, 4, 5, 6
if phase == "A":
    ops += [(BEGIN, 0, 0), (ALLOC, 0, 5), (END, 0, 0)]
    ops += [(BEGIN, 0, 0), (ALLOC, 1, 300), (FREE, 0, 0), (ALLOC, 2, 3), (END, 0, 0)]
    ops += [(BEGIN, 0, 0), (ALLOC, 3, 129), (FREE, 1, 0), (ALLOC, 4, 7), (END, 0, 0)]
    # the scan has to wrap: the last 4 clusters are taken, the hint points at them
    mx = Vol(img).maxclus
    ops += [(BEGIN, 0, 0), (8, (mx - 3) & 0xFFFF, (mx - 3) >> 16), (ALLOC, 6, 4),
            (8, (mx - 3) & 0xFFFF, (mx - 3) >> 16), (ALLOC, 7, 2), (END, 0, 0)]
elif phase == "B":
    left = {}
    for line in open(sys.argv[4], errors="replace"):
        if line.startswith("C "):
            slot = int(line[2:6], 16)
            c = (int(line[6:10], 16) << 16) | int(line[10:14], 16)
            left.setdefault(slot, []).append(c)
    ops.append((BEGIN, 0, 0))
    for slot in (2, 3, 4, 6, 7):
        c = left[slot][0]
        ops.append((FREEC, c & 0xFFFF, c >> 16))
    ops.append((END, 0, 0))
    if int(open(os.path.join(case, "mb.txt")).read()) <= 64:
        ops += [(BEGIN, 0, 0), (FILL, 5, 0), (END, 0, 0), (BEGIN, 0, 0), (FREE, 5, 0), (END, 0, 0)]
if phase == "C":
    import json
    v = Vol(img)
    sub = [e for e in v.dir_entries(img, v.root) if e.get("short") == "SUB"][0]["cl"]
    dirs = [0, sub]
    CREATE, DELETE, SETDE = 10, 11, 13
    long255 = "".join(chr(0x41 + (i % 26)) if i % 3 else chr(0x61 + (i % 26)) for i in range(255))
    root = ["README.TXT", "readme2.txt", "Long File Name.data", "Long File Name2.data",
            "abcdefghijklm", "abcdefghijklmnopqrstuvwxyz", long255, "\u00c5ngstr\u00f6m.txt",
            ".hidden", "a.b.c.d", "My Docs", "a:b", "trailing.", "readme.txt", "README2.TXT",
            "LONGFI~1.DAT", "longfi~1.dat", "x" * 256, ""]
    idx = {}
    for n in root:
        idx[n] = nm(n)
        ops.append((CREATE, idx[n], 0x20, 0))
    subn = ["file number %02d with a long name.txt" % i for i in range(40)]
    for n in subn:
        idx[n] = nm(n)
        ops.append((CREATE, idx[n], 0x20, 1))
    for n in ("readme2.txt", "Long File Name2.data", "abcdefghijklmnopqrstuvwxyz"):
        ops.append((DELETE, idx[n], 1, 0))
    for n in subn[25:35]:
        ops.append((DELETE, idx[n], 1, 1))
    newn = ["new file %d in the old place.txt" % i for i in range(5)]
    for n in newn:
        idx[n] = nm(n)
        ops.append((CREATE, idx[n], 0x20, 1))
    ops.append((SETDE, idx["README.TXT"], 0, 0x210C))    # date/time and attributes 0x21
    json.dump(dict(root=root, sub=subn, new=newn, names=names), open(os.path.join(case, "c.json"), "w"))
if phase == "D":
    import json
    v = Vol(img)
    cb = v.spc * 512
    CREATE, OPEN, WRITE, SYNC, SEEK, SETSIZE = 10, 20, 21, 22, 23, 24
    model = {}
    def pat(p, seed):
        return ((p >> 8) ^ p ^ seed) & 0xFF
    def mk(n):
        i = nm(n)
        ops.append((CREATE, i, 0x20, 0))
        ops.append((OPEN, i, 0, 0))
        model[n] = bytearray()
        return n
    def wr(n, count, seed, pos=None, chunk=700):
        d = model[n]
        p = len(d) if pos is None else pos
        left = count
        while left:
            k = min(chunk, left)
            ops.append((WRITE, k, 0, seed))
            for q in range(p, p + k):
                b = pat(q & 0xFFFF, seed)
                if q < len(d):
                    d[q] = b
                else:
                    d.append(b)
            p += k
            left -= k
    def sync():
        ops.append((SYNC, 0, 0, 0))
    def seek(pos):
        ops.append((SEEK, pos & 0xFFFF, 0, pos >> 16))
    def setsize(n, size):
        ops.append((SETSIZE, size & 0xFFFF, 0, size >> 16))
        d = model[n]
        if size < len(d):
            del d[size:]
        else:
            d.extend(b"\0" * (size - len(d)))
    ops.append((8, 2, 0, 0))                    # allocate from cluster 2: reuse garbage
    n = mk("one thousand.bin"); wr(n, 1000, 1); sync()
    n = mk("three clusters and a bit.bin"); wr(n, 3 * cb + 100, 2); sync()
    n = mk("overwrite.bin"); wr(n, 5000, 3); sync(); seek(1234); wr(n, 600, 4, pos=1234); sync()
    n = mk("append.bin"); wr(n, 2000, 5); sync(); seek(2000); wr(n, 1500, 6, pos=2000); sync()
    n = mk("truncate.bin"); wr(n, 3 * cb, 7); sync(); setsize(n, cb + 10)
    n = mk("extend.bin"); wr(n, 100, 8); sync(); setsize(n, 2 * cb + 50)
    n = mk("empty.bin"); setsize(n, 0)
    n = mk("to nothing.bin"); wr(n, 2 * cb, 9); sync(); setsize(n, 0)
    n = mk("one cluster.bin"); wr(n, cb, 10, chunk=512); sync(); seek(cb); wr(n, 1, 11, pos=cb); sync()
    n = mk("big.bin"); wr(n, 40000, 12, chunk=4096); sync()
    json.dump({k: v.hex() for k, v in model.items()}, open(os.path.join(case, "d.json"), "w"))
if phase == "E":
    import json
    v = Vol(img)
    cb = v.spc * 512
    CREATE, DELETE, OPEN, WRITE, SYNC, MKDIR, RENAME = 10, 11, 20, 21, 22, 30, 31
    dirs = [0, [e for e in v.dir_entries(img, v.root) if e.get("short") == "SUB"][0]["cl"], 0, 0, 0, 0, 0, 0]
    ix = {}
    def n_(x):
        if x not in ix:
            ix[x] = nm(x)
        return ix[x]
    ops += [(MKDIR, n_("New Dir"), 2, 0), (MKDIR, n_("Inner"), 3, 2)]
    ops += [(CREATE, n_("moving file.txt"), 0x20, 2), (OPEN, ix["moving file.txt"], 0, 2)]
    for k in range(0, 3000, 700):
        ops.append((WRITE, min(700, 3000 - k), 0, 21))
    ops.append((SYNC, 0, 0, 0))
    ops.append((RENAME, ix["moving file.txt"], n_("Moved File.TXT"), 2 | 3 << 8))
    ops.append((RENAME, ix["Moved File.TXT"], n_("MOVED FILE.TXT"), 3 | 3 << 8))
    ops.append((CREATE, n_("other.txt"), 0x20, 3))
    ops.append((RENAME, ix["MOVED FILE.TXT"], ix["other.txt"], 3 | 3 << 8))
    ops.append((RENAME, ix["New Dir"], n_("Loop"), 0 | 3 << 8))
    ops.append((RENAME, ix["Inner"], n_("Top Inner"), 2 | 0 << 8))
    ops += [(MKDIR, n_("Gone"), 4, 0), (DELETE, ix["Gone"], 1, 0), (MKDIR, n_("New Dir"), 5, 0)]
    # another case of a short name: its own short name is in the way -> a tail, and a long
    # name keeps the exact name
    ops += [(CREATE, n_("lower.txt"), 0x20, 0), (RENAME, ix["lower.txt"], n_("LOWER.TXT"), 0)]
    data = bytes(((p >> 8) ^ p ^ 21) & 0xFF for p in range(3000))
    json.dump(dict(names=names, data=data.hex()), open(os.path.join(case, "e.json"), "w"))
with open(os.path.join(case, "tests.inc"), "w") as f:
    f.write("T_TABLE\n")
    for op in ops + [(0, 0, 0)]:
        op = tuple(op) + (0,) * (4 - len(op))
        f.write("                .DW     %d, 0x%04X, 0x%04X, 0x%04X\n" % op)
    f.write("T_DIRS\n")
    for d in dirs:
        f.write("                .DW     0x%04X, 0x%04X\n" % (d & 0xFFFF, d >> 16))
    f.write("T_NAMES\n")
    for i in range(len(names)):
        f.write("                .DW     T_NAME%d\n" % i)
    if not names:
        f.write("                .DW     0\n")
    for i, n in enumerate(names):
        f.write("T_NAME%d\n" % i)
        for k in range(0, len(n) + 1, 12):
            part = [ord(ch) for ch in n[k:k + 12]] + ([0] if k + 12 > len(n) else [])
            if part:
                f.write("                .DW     " + ", ".join("0x%02X" % x for x in part) + "\n")
