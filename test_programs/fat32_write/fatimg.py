"""FAT32 SD image helpers for the write layer tests (MBR + one FAT32 partition)."""
import os, shutil, struct, subprocess

PART_LBA = 2048


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


def pattern(size, seed=0):
    n = (size + 3) // 4
    return b"".join(struct.pack(">I", (i + seed * 0x10000) & 0xFFFFFFFF) for i in range(n))[:size]


def put(img, tmpdir, name, data):
    p = os.path.join(tmpdir, os.path.basename(name))
    with open(p, "wb") as f:
        f.write(data)
    run("mcopy", "-o", "-i", mt(img), p, "::" + name)


def get(img, name, tmpdir):
    p = os.path.join(tmpdir, "get.bin")
    run("mcopy", "-o", "-i", mt(img), "::" + name, p)
    return open(p, "rb").read()


class Vol:
    """The FAT32 volume of an image: geometry, both FATs, FSInfo."""

    def __init__(self, img):
        with open(img, "rb") as f:
            f.seek(PART_LBA * 512)
            bs = f.read(512)
            self.bps, self.spc = struct.unpack_from("<HB", bs, 11)
            self.rsvd = struct.unpack_from("<H", bs, 14)[0]
            self.nfats = bs[16]
            self.totsec = struct.unpack_from("<I", bs, 32)[0]
            self.fatsz = struct.unpack_from("<I", bs, 36)[0]
            self.root = struct.unpack_from("<I", bs, 44)[0]
            self.fsinfo = struct.unpack_from("<H", bs, 48)[0]
            self.fat_off = (PART_LBA + self.rsvd) * self.bps
            self.data_off = self.fat_off + self.nfats * self.fatsz * self.bps
            data_secs = self.totsec - (self.rsvd + self.nfats * self.fatsz)
            self.maxclus = min(data_secs // self.spc + 1, self.fatsz * 128 - 1)
            f.seek(self.fat_off)
            self.fat1 = f.read(self.fatsz * self.bps)
            self.fat2 = f.read(self.fatsz * self.bps)
            f.seek((PART_LBA + self.fsinfo) * 512)
            fsi = f.read(512)
            self.fsi_free, self.fsi_next = struct.unpack_from("<II", fsi, 488)

    def ent(self, c, fat=None):
        return struct.unpack_from("<I", fat or self.fat1, c * 4)[0] & 0x0FFFFFFF

    def chain(self, c):
        out = []
        while 2 <= c <= self.maxclus and c not in out:
            out.append(c)
            c = self.ent(c)
        return out

    def dir_slots(self, img, first):
        """All 32-byte slots of a directory: [(cluster, sector, slot, bytes)]."""
        out = []
        with open(img, "rb") as f:
            for c in self.chain(first):
                f.seek(self.data_off + (c - 2) * self.spc * self.bps)
                d = f.read(self.spc * self.bps)
                for sec in range(self.spc):
                    for k in range(16):
                        o = sec * 512 + k * 32
                        out.append((c, sec, k, d[o:o + 32]))
        return out

    def dir_entries(self, img, first):
        """The entries of a directory with their long names (checked like
        Windows does: sequence and checksum). Returns a list of dicts."""
        ents, run, end = [], [], False
        for c, sec, k, e in self.dir_slots(img, first):
            if end or e[0] == 0:
                end = True
                if any(e):
                    ents.append(dict(error=f"slot behind the end marker not zero at {c:#x}/{sec}/{k}"))
                continue
            if e[0] == 0xE5:
                run = []
                continue
            if e[11] & 0x3F == 0x0F:
                run.append(e)
                continue
            sfn = e[:11]
            chk = 0
            for b in sfn:
                chk = (((chk & 1) << 7) + (chk >> 1) + b) & 0xFF
            lfn, lfn_err = None, None
            if run:
                n = len(run)
                ok = (run[0][0] & 0x40) and (run[0][0] & 0x1F) == n and all(
                    (r[0] & 0x1F) == n - i and r[13] == chk and r[11] == 0x0F for i, r in enumerate(run))
                if ok:
                    chars = []
                    for r in reversed(run):
                        for o in (1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30):
                            chars.append(r[o] | (r[o + 1] << 8))
                    name = []
                    for ch in chars:
                        if ch == 0:
                            break
                        name.append(ch)
                    lfn = "".join(chr(ch) for ch in name)
                else:
                    lfn_err = "bad long name run"
            base = sfn[:8].decode("latin-1").rstrip()
            ext = sfn[8:].decode("latin-1").rstrip()
            short = base + ("." + ext if ext else "")
            ents.append(dict(name=lfn if lfn is not None else short, lfn=lfn, short=short, sfn=bytes(sfn),
                             attr=e[11], cl=(int.from_bytes(e[20:22], "little") << 16) | int.from_bytes(e[26:28], "little"),
                             size=int.from_bytes(e[28:32], "little"), wtime=int.from_bytes(e[22:24], "little"),
                             wdate=int.from_bytes(e[24:26], "little"), cdate=int.from_bytes(e[16:18], "little"),
                             ea=(c, sec << 4 | k), lfn_err=lfn_err, nslots=len(run) + 1))
            run = []
        return ents

    def free_count(self):
        return sum(1 for c in range(2, self.maxclus + 1) if self.ent(c) == 0)


def fsck(img, workdir):
    """fsck.fat -n on the partition; returns (clean, output)."""
    part = os.path.join(workdir, "part.img")
    subprocess.run(["dd", f"if={img}", f"of={part}", "bs=1M", "skip=1", "conv=sparse", "status=none"], check=True)
    r = subprocess.run(["/usr/sbin/fsck.fat", "-n", "-V", part], capture_output=True, text=True)
    os.unlink(part)
    return r.returncode == 0, r.stdout + r.stderr
