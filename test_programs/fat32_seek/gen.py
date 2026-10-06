#!/usr/bin/env python3
"""Build FAT32 SD images + a QNICE test table for the FAT32 seek/map tests.

usage: gen.py <outdir> <sectors_per_cluster> [--seek-only] [--seed N]

Files on the image (pattern: the file is a sequence of 32-bit big-endian
counters, i.e. byte p = ((p >> 2) >> (8 * (3 - p % 4))) & 0xFF):
  T.BIN  large, contiguous
  F.BIN  fragmented (gaps created by deleting every other small file)
  S.BIN  1000 bytes (size not a multiple of 512)
  E.BIN  exactly 3 clusters
  Z.BIN  0 bytes
"""
import os, random, shutil, struct, subprocess, sys

PART_LBA = 2048
EOF_ERR, TOOLARGE, MAPSIZE = 0xEEEE, 0xEE21, 0xEE23


def pattern(size):
    n = (size + 3) // 4
    return b"".join(struct.pack(">I", i) for i in range(n))[:size]


def run(*cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def make_image(path, spc, mb):
    size = mb * 1024 * 1024
    with open(path, "wb") as f:
        f.truncate(size)
        mbr = bytearray(512)
        sectors = size // 512 - PART_LBA
        mbr[446:462] = struct.pack("<B3sB3sII", 0x00, b"\0\0\0", 0x0C, b"\0\0\0", PART_LBA, sectors)
        mbr[510:512] = b"\x55\xaa"
        f.write(mbr)
    run(shutil.which("mkfs.vfat") or "/usr/sbin/mkfs.vfat", "-F", "32", "-s", str(spc), "--offset", str(PART_LBA), path)


def mt(img):
    return f"{img}@@{PART_LBA * 512}"


def put(img, tmpdir, name, data):
    p = os.path.join(tmpdir, name)
    with open(p, "wb") as f:
        f.write(data)
    run("mcopy", "-o", "-i", mt(img), p, "::" + name)


def fat_info(img):
    """Return (cluster_bytes, {NAME: (size, [clusters])}) by parsing the FAT."""
    with open(img, "rb") as f:
        f.seek(PART_LBA * 512)
        bs = f.read(512)
        bps, spc = struct.unpack_from("<HB", bs, 11)
        rsvd = struct.unpack_from("<H", bs, 14)[0]
        nfats = bs[16]
        fatsz = struct.unpack_from("<I", bs, 36)[0]
        root = struct.unpack_from("<I", bs, 44)[0]
        fat_off = (PART_LBA + rsvd) * bps
        data_off = fat_off + nfats * fatsz * bps
        cbytes = bps * spc
        f.seek(fat_off)
        fat = f.read(fatsz * bps)

        def nxt(c):
            return struct.unpack_from("<I", fat, c * 4)[0] & 0x0FFFFFFF

        def chain(c):
            out = []
            while 2 <= c < 0x0FFFFFF8:
                out.append(c)
                c = nxt(c)
            return out

        files = {}
        for c in chain(root):
            f.seek(data_off + (c - 2) * cbytes)
            d = f.read(cbytes)
            for i in range(0, cbytes, 32):
                e = d[i:i + 32]
                if e[0] in (0, 0xE5) or e[11] == 0x0F or e[11] & 0x08:
                    continue
                name = e[0:8].decode().strip() + "." + e[8:11].decode().strip()
                first = (struct.unpack_from("<H", e, 20)[0] << 16) | struct.unpack_from("<H", e, 26)[0]
                size = struct.unpack_from("<I", e, 28)[0]
                files[name] = (size, chain(first) if first else [])
    return cbytes, files


def fragment(img, name, rnd):
    """Move the clusters of a file to scattered free clusters: runs of 1-3
    clusters in random order (also backwards), updating both FATs and the
    directory entry. Returns the new cluster list."""
    with open(img, "r+b") as f:
        f.seek(PART_LBA * 512)
        bs = f.read(512)
        bps, spc = struct.unpack_from("<HB", bs, 11)
        rsvd = struct.unpack_from("<H", bs, 14)[0]
        nfats = bs[16]
        fatsz = struct.unpack_from("<I", bs, 36)[0]
        root = struct.unpack_from("<I", bs, 44)[0]
        fat_off = (PART_LBA + rsvd) * bps
        data_off = fat_off + nfats * fatsz * bps
        cb = bps * spc
        f.seek(fat_off)
        fat = bytearray(f.read(fatsz * bps))
        get = lambda c: struct.unpack_from("<I", fat, c * 4)[0] & 0x0FFFFFFF
        def setc(c, v):
            old = struct.unpack_from("<I", fat, c * 4)[0]
            struct.pack_into("<I", fat, c * 4, (old & 0xF0000000) | v)
        # locate the directory entry (root directory, single cluster is enough)
        f.seek(data_off + (root - 2) * cb)
        rd = bytearray(f.read(cb))
        for i in range(0, cb, 32):
            base, ext = name.split(".")
            if rd[i:i + 11] == (base.ljust(8) + ext.ljust(3)).encode():
                ent = i
                break
        else:
            raise SystemExit("entry not found")
        first = (struct.unpack_from("<H", rd, ent + 20)[0] << 16) | struct.unpack_from("<H", rd, ent + 26)[0]
        old_chain = []
        c = first
        while 2 <= c < 0x0FFFFFF8:
            old_chain.append(c)
            c = get(c)
        n = len(old_chain)
        # free clusters far away from the file, in scattered runs
        maxc = (fatsz * bps) // 4
        free = [c for c in range(max(old_chain) + 50, min(maxc, max(old_chain) + 50 + 40 * n)) if get(c) == 0]
        runs, i = [], 0
        while sum(len(r) for r in runs) < n:
            ln = rnd.choice((1, 1, 2, 3))
            runs.append(free[i:i + ln])
            i += ln + rnd.choice((1, 2, 5, 17))
        rnd.shuffle(runs)
        new_chain = [c for r in runs for c in r][:n]
        data = []
        for c in old_chain:
            f.seek(data_off + (c - 2) * cb)
            data.append(f.read(cb))
        for c, d in zip(new_chain, data):
            f.seek(data_off + (c - 2) * cb)
            f.write(d)
        for c in old_chain:
            setc(c, 0)
        for a, b in zip(new_chain, new_chain[1:]):
            setc(a, b)
        setc(new_chain[-1], 0x0FFFFFFF)
        for k in range(nfats):
            f.seek(fat_off + k * fatsz * bps)
            f.write(fat)
        struct.pack_into("<H", rd, ent + 20, new_chain[0] >> 16)
        struct.pack_into("<H", rd, ent + 26, new_chain[0] & 0xFFFF)
        f.seek(data_off + (root - 2) * cb)
        f.write(rd)
    return new_chain


def corrupt(img, name, k, value):
    """Set the FAT entry of the k-th cluster (0-based) of a file to value."""
    cb, files = fat_info(img)
    size, ch = files[name]
    with open(img, "r+b") as f:
        f.seek(PART_LBA * 512)
        bs = f.read(512)
        bps = struct.unpack_from("<H", bs, 11)[0]
        rsvd = struct.unpack_from("<H", bs, 14)[0]
        nfats = bs[16]
        fatsz = struct.unpack_from("<I", bs, 36)[0]
        for i in range(nfats):
            f.seek((PART_LBA + rsvd + i * fatsz) * bps + ch[k] * 4)
            f.write(struct.pack("<I", value))


def extents(clusters):
    ext = []
    for c in clusters:
        if ext and ext[-1][0] + ext[-1][1] == c:
            ext[-1][1] += 1
        else:
            ext.append([c, 1])
    return ext


def main():
    outdir, spc = sys.argv[1], int(sys.argv[2])
    seek_only = "--seek-only" in sys.argv
    seed = int(sys.argv[sys.argv.index("--seed") + 1]) if "--seed" in sys.argv else 1
    rnd = random.Random(seed * 1000 + spc)
    os.makedirs(outdir, exist_ok=True)
    img = os.path.join(outdir, "sd.img")
    tmp = os.path.join(outdir, "tmp")
    os.makedirs(tmp, exist_ok=True)

    cbytes = spc * 512
    # FAT32 needs >= 65525 clusters; give it some headroom
    mb = max(64, (cbytes * 70000) // (1024 * 1024) + 8)
    make_image(img, spc, mb)

    sizes = {"T.BIN": 6 * 1024 * 1024 if spc < 64 else 24 * 1024 * 1024,
             "S.BIN": 1000, "E.BIN": 3 * cbytes, "Z.BIN": 0}
    for n in ("S.BIN", "E.BIN", "Z.BIN", "T.BIN"):
        put(img, tmp, n, pattern(sizes[n]))
    # fragmentation: fill with 1-cluster files, delete every other one, then
    # write F.BIN, which has to use the holes
    holes = 40
    for i in range(2 * holes):
        put(img, tmp, f"H{i:03d}.BIN", b"\xAA" * cbytes)
    for i in range(0, 2 * holes, 2):
        run("mdel", "-i", mt(img), f"::H{i:03d}.BIN")
    sizes["F.BIN"] = holes * cbytes + 5 * cbytes + 123
    put(img, tmp, "F.BIN", pattern(sizes["F.BIN"]))

    sizes["C.BIN"] = 20 * cbytes
    sizes["D.BIN"] = 20 * cbytes
    put(img, tmp, "C.BIN", pattern(sizes["C.BIN"]))
    put(img, tmp, "D.BIN", pattern(sizes["D.BIN"]))
    fragment(img, "F.BIN", rnd)
    part = os.path.join(tmp, "part.img")                               # must be a clean FS
    run("dd", f"if={img}", f"of={part}", "bs=1M", f"skip={PART_LBA * 512}", "iflag=skip_bytes", "conv=sparse")
    r = subprocess.run([shutil.which("fsck.vfat") or "/usr/sbin/fsck.vfat", "-n", part], capture_output=True, text=True)
    os.remove(part)
    if r.returncode != 0:
        raise SystemExit("fsck.vfat failed:\n" + r.stdout + r.stderr)
    print("fsck.vfat: clean")
    good = fat_info(img)[1]
    corrupt(img, "C.BIN", 9, 0x0FFFFFFF)      # chain ends after 10 clusters
    corrupt(img, "D.BIN", 9, 0)               # 10th cluster points to a free one
    cb, files = fat_info(img)
    files["C.BIN"] = good["C.BIN"]
    files["D.BIN"] = good["D.BIN"]
    assert cb == cbytes
    info = {}
    for n in ("T.BIN", "F.BIN", "S.BIN", "E.BIN", "Z.BIN"):
        size, ch = files[n]
        assert size == sizes[n], (n, size)
        info[n] = (size, len(extents(ch)))
        print(f"{n}: size {size}, clusters {len(ch)}, extents {len(extents(ch))}")

    ops = []   # (op, a, b, c, d)

    def seek(pos, length, expect=0, mapped=False):
        ops.append((3 if mapped else 2, pos & 0xFFFF, pos >> 16, length, expect))

    names = []
    for n in ("T.BIN", "F.BIN", "S.BIN", "E.BIN", "Z.BIN"):
        size, next_ = info[n]
        names.append(n)
        ops.append((1, len(names) - 1, 0, 0, 0))                 # open
        modes = [False] if seek_only else [False, True]
        if not seek_only:
            ops.append((4, 1 + 4 * 256, 0, next_, 0))            # map
            if next_ >= 2:
                ops.append((4, 1 + 4 * (next_ - 1), MAPSIZE, next_, 0))
                ops.append((4, 1 + 4 * 256, 0, next_, 0))
        for mapped in modes:
            pts = {0, size}
            for k in range(0, size // cbytes + 2):
                for d in (-1, 0, 1):
                    pts.add(k * cbytes + d)
            for k in range(0, min(size // 512 + 2, 40)):
                pts.add(k * 512)
            for _ in range(60 if size > 0 else 0):
                pts.add(rnd.randrange(0, size + 1))
            pts = [p for p in pts if 0 <= p <= size]
            if size > 1_000_000:                     # do not test every cluster of T.BIN
                pts = sorted(rnd.sample(sorted(pts), min(len(pts), 150)) + [0, size, size - 1])
            order = list(pts)
            rnd.shuffle(order)                       # random forward/backward jumps
            order += sorted(pts)[:30]                # and ascending runs (walk from current)
            for p in order:
                seek(p, rnd.choice((1, 3, 600, 1100)), 0, mapped)
            seek(size + 1, 0, TOOLARGE, mapped)
            seek(size + 70000, 0, TOOLARGE, mapped)
        ops.append((6, len(names) - 1, 0, 0, 0))                 # stats
        if not seek_only and size > 2000:
            for p in (0, 510, cbytes - 3, size // 2, size - 700):
                ops.append((5, p & 0xFFFF, p >> 16, 700, 0))     # write/restore
            ops.append((6, 100 + len(names) - 1, 0, 0, 0))

    # corrupted chains: data before the damage reads fine, seeks behind it
    # and map builds fail with FAT32$ERR_CHAIN (0xEE22)
    for n in ("C.BIN", "D.BIN"):
        names.append(n)
        ops.append((1, len(names) - 1, 0, 0, 0))
        for p in (0, 5 * cbytes + 17):
            seek(p, 100)
        seek(10 * cbytes - 1, 1)                 # last byte before the damage
        for p in (10 * cbytes, 15 * cbytes + 3, 20 * cbytes):
            seek(p, 0, 0xEE22)
            seek(0, 16)                          # backwards from scratch again
            seek(10 * cbytes + 5, 0, 0xEE22)     # forward from the current cluster
        if not seek_only:
            ops.append((4, 1 + 4 * 256, 0xEE22, 0xFFFF, 0))
        ops.append((6, len(names) - 1, 0, 0, 0))

    with open(os.path.join(outdir, "tests.inc"), "w") as f:
        f.write("; generated by gen.py\n")
        for i, n in enumerate(names):
            f.write(f'T_NAME{i}         .ASCII_W "/{n}"\n')
        f.write("T_NAMES         .DW " + ", ".join(f"T_NAME{i}" for i in range(len(names))) + "\n")
        for i, o in enumerate(ops):
            lbl = "T_TABLE" if i == 0 else ""
            f.write("%-16s.DW 0x%04X, 0x%04X, 0x%04X, 0x%04X, 0x%04X\n" % ((lbl,) + o))
        f.write("                .DW 0x0000, 0x0000, 0x0000, 0x0000, 0x0000\n")
    with open(os.path.join(outdir, "expected.txt"), "w") as f:
        for n in names:
            if n in info:
                f.write(f"{n} {info[n][0]}\n")
    print(f"{len(ops)} ops, image {mb} MB, cluster {cbytes} bytes")


if __name__ == "__main__":
    main()
