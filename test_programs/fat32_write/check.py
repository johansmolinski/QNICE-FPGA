#!/usr/bin/env python3
"""Check an image after a write layer test phase.

usage: check.py <case dir> <phase> <emulator log>
"""
import os, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fatimg import *

case, phase, log = sys.argv[1], sys.argv[2], sys.argv[3]
img = os.path.join(case, "sd.img")
fails = []
def fail(m): fails.append(m)

lines = open(log, errors="replace").read().splitlines()
if "RESULT: DONE" not in lines:
    fail("the test program did not finish")
for l in lines:
    if l.startswith("E "):
        fail("error " + l)

v = Vol(img)
if v.fat1 != v.fat2:
    n = sum(1 for i in range(0, len(v.fat1), 4) if v.fat1[i:i + 4] != v.fat2[i:i + 4])
    fail(f"FAT1 and FAT2 differ in {n} entries")
free = v.free_count()
if v.fsi_free != free:
    fail(f"FSInfo free count {v.fsi_free}, actually {free}")
if not 2 <= v.fsi_next <= v.maxclus + 1:
    fail(f"FSInfo next free {v.fsi_next:#x} out of range")

# the files of the image are intact
used_by_files = set()
with tempfile.TemporaryDirectory() as t:
    for line in open(os.path.join(case, "files.txt")):
        name, size, seed = line.split()
        if get(img, name, t) != pattern(int(size), int(seed)):
            fail(f"{name} changed")

slots = {}
for l in lines:
    if l.startswith("C "):
        slots.setdefault(int(l[2:6], 16), []).append((int(l[6:10], 16) << 16) | int(l[10:14], 16))
init_free = int(open(os.path.join(case, "free0.txt")).read())
if phase in ("C", "D", "E"):
    init_free = free

if phase in ("C", "D", "E"):
    pass
elif phase == "A":
    left = set()
    for s in (2, 3, 4, 6, 7):
        want = slots.get(s, [])
        got = v.chain(want[0]) if want else []
        if not want or got != want:
            fail(f"slot {s}: chain {got[:6]}... != allocated {want[:6]}...")
        elif v.ent(want[-1]) < 0x0FFFFFF8:
            fail(f"slot {s}: the chain ends with {v.ent(want[-1]):#x}, not an end-of-chain marker")
        left |= set(want)
    if slots.get(6) != list(range(v.maxclus - 3, v.maxclus + 1)):
        fail(f"slot 6 is not the last 4 clusters: {slots.get(6)}")
    if slots.get(7) and slots[7][0] >= v.maxclus - 3:
        fail("slot 7 did not wrap around")
    for s in (0, 1):
        for c in slots.get(s, []):
            if c not in left and v.ent(c) != 0:
                fail(f"slot {s}: cluster {c:#x} not freed")
    if free != init_free - len(left):
        fail(f"free {free}, expected {init_free} - {len(left)}")
else:
    if free != init_free:
        fail(f"free {free}, expected the initial {init_free}")
    if (int(open(os.path.join(case, "mb.txt")).read()) <= 64) != any(l.startswith("F ") for l in lines):
        fail("FILL result missing (or unexpected)")
    for l in lines:
        if l.startswith("F "):
            cnt = (int(l[6:10], 16) << 16) | int(l[10:14], 16)
            if cnt != init_free:
                fail(f"FILL allocated {cnt}, the card had {init_free} free")
            if int(l[14:18], 16) != 0xEE24:
                fail(f"FILL ended with {l[14:18]}, not DISKFULL")
    clean, out = fsck(img, case)
    if not clean:
        fail("fsck: " + " | ".join(out.splitlines()[-6:]))

if phase == "C":
    import json
    cj = json.load(open(os.path.join(case, "c.json")))
    names = cj["names"]
    res = {}
    for l in lines:
        if l.startswith("N "):
            p = l.split()
            ea = p[2]
            res[names[int(p[1], 16)]] = (int(p[3], 16), ((int(ea[0:4], 16) << 16) | int(ea[4:8], 16), int(ea[8:12], 16)))
    NAME, EXISTS = 0xEE26, 0xEE25
    want = {n: 0 for n in cj["root"] + cj["sub"] + cj["new"]}
    for n in ("a:b", "trailing.", "x" * 256, ""):
        want[n] = NAME
    for n in ("readme.txt", "README2.TXT", "LONGFI~1.DAT", "longfi~1.dat"):
        want[n] = EXISTS
    for n, w in want.items():
        if n not in res:
            fail(f"no result for {n[:30]!r}")
        elif res[n][0] != w:
            fail(f"create {n[:30]!r}: error {res[n][0]:#x}, expected {w:#x}")
    deleted = {"readme2.txt", "Long File Name2.data", "abcdefghijklmnopqrstuvwxyz"} | set(cj["sub"][25:35])
    sub_cl = [e for e in v.dir_entries(img, v.root) if e.get("short") == "SUB"][0]["cl"]
    files = [l.split()[0] for l in open(os.path.join(case, "files.txt"))]
    for dname, dcl, created in (("root", v.root, cj["root"]), ("SUB", sub_cl, cj["sub"] + cj["new"])):
        ents = v.dir_entries(img, dcl)
        for e in ents:
            if "error" in e or e.get("lfn_err"):
                fail(f"{dname}: {e.get('error') or e.get('lfn_err')} {e.get('short')}")
        ents = [e for e in ents if "name" in e]
        got = {e["name"] for e in ents if e["name"] not in (".", "..")}
        exp = {n for n in created if want[n] == 0 and n not in deleted}
        if dname == "root":
            exp |= set(files) | {"SUB"}
        if got != exp:
            fail(f"{dname}: names differ: missing {sorted(exp - got)[:5]}, extra {sorted(got - exp)[:5]}")
        sfns = [e["sfn"] for e in ents]
        if len(sfns) != len(set(sfns)):
            fail(f"{dname}: duplicate short names")
        by = {e["name"]: e for e in ents}
        for n in exp:
            e = by.get(n)
            if not e or n in files or n == "SUB":
                continue
            if res[n][1] != e["ea"]:
                fail(f"{dname}: {n[:30]!r} reported at {res[n][1]}, is at {e['ea']}")
            if e["cdate"] != 0x5D4D:
                fail(f"{dname}: {n[:30]!r} creation date {e['cdate']:#x}")
    root = {e["name"]: e for e in v.dir_entries(img, v.root) if "name" in e}
    for n, sfn, slots in (("README.TXT", b"README  TXT", 1), ("Long File Name.data", b"LONGFI~1DAT", 3),
                          ("abcdefghijklm", b"ABCDEF~1   ", 2), ("\u00c5ngstr\u00f6m.txt", b"_NGSTR~1TXT", 2),
                          (".hidden", b"HIDDEN~1   ", 2), ("a.b.c.d", b"ABC~1   D  ", 2),
                          ("My Docs", b"MYDOCS~1   ", 2)):
        e = root.get(n)
        if not e:
            continue
        if e["sfn"] != sfn or e["nslots"] != slots:
            fail(f"{n!r}: short name {e['sfn']}, {e['nslots']} slots; expected {sfn}, {slots}")
    long255 = [n for n in cj["root"] if len(n) == 255][0]
    if root.get(long255, {}).get("nslots") != 21:
        fail("the 255-character name does not have 20 long name slots")
    rd = root.get("README.TXT")
    if rd and (rd["attr"] != 0x21 or rd["wdate"] != 0x5D4E or rd["wtime"] != 0x645D):
        fail(f"SETDE: attributes {rd['attr']:#x}, date {rd['wdate']:#x}, time {rd['wtime']:#x}")
    if res.get(cj["new"][0], (0, None))[1] != res.get(cj["sub"][25], (0, None))[1]:
        fail("the first new entry in SUB did not take the place of the first deleted one")
    clean, out = fsck(img, case)
    if not clean:
        fail("fsck: " + " | ".join(out.splitlines()[-6:]))

if phase == "D":
    import json
    model = {k: bytes.fromhex(v) for k, v in json.load(open(os.path.join(case, "d.json"))).items()}
    ents = {e["name"]: e for e in v.dir_entries(img, v.root) if "name" in e}
    with tempfile.TemporaryDirectory() as t:
        for n, want in model.items():
            e = ents.get(n)
            if not e:
                fail(f"{n}: missing"); continue
            if e["size"] != len(want):
                fail(f"{n}: size {e['size']}, expected {len(want)}")
            if len(want) == 0 and e["cl"] != 0:
                fail(f"{n}: empty but first cluster {e['cl']:#x}")
            got = get(img, n, t)
            if got != want:
                k = next((i for i in range(min(len(got), len(want))) if got[i] != want[i]), min(len(got), len(want)))
                fail(f"{n}: content differs from byte {k} ({len(got)} bytes read)")
            if e["cl"]:
                need = (len(want) + v.spc * 512 - 1) // (v.spc * 512)
                if len(v.chain(e["cl"])) != max(need, 1):
                    fail(f"{n}: {len(v.chain(e['cl']))} clusters, needs {need}")
            if e["wdate"] != 0x5D4D or e["wtime"] != 0x645C:
                fail(f"{n}: write date/time {e['wdate']:#x} {e['wtime']:#x}")
    clean, out = fsck(img, case)
    if not clean:
        fail("fsck: " + " | ".join(out.splitlines()[-6:]))

if phase == "E":
    import json
    ej = json.load(open(os.path.join(case, "e.json")))
    names = ej["names"]
    rres = {}
    for l in lines:
        if l.startswith("R "):
            p = l.split()
            rres.setdefault(names[int(p[1], 16)], []).append(int(p[2], 16))
    want = {"moving file.txt": [0], "Moved File.TXT": [0], "MOVED FILE.TXT": [0xEE25], "New Dir": [0xEE29], "Inner": [0],
            "lower.txt": [0]}
    for k, w in want.items():
        if rres.get(k) != w:
            fail(f"rename {k!r}: {rres.get(k)}, expected {w}")
    errs = [l for l in lines if l.startswith("E ")]
    if len(errs) != 1 or not errs[0].endswith("EE25"):
        fail(f"errors {errs}: expected one EXISTS (the second New Dir)")
    fails[:] = [m for m in fails if not m.startswith("error E ")]
    root = {e["name"]: e for e in v.dir_entries(img, v.root) if "name" in e}
    for n in ("New Dir", "Top Inner"):
        if n not in root or not root[n]["attr"] & 0x10:
            fail(f"root: no directory {n!r}")
    if "LOWER.TXT" not in root or "lower.txt" in root:
        fail(f"rename to LOWER.TXT: {sorted(k for k in root if k.lower() == 'lower.txt')}")
    if "Gone" in root or "Inner" in root:
        fail("root: Gone or Inner still there")
    if "New Dir" in root:
        nd = {e["name"]: e for e in v.dir_entries(img, root["New Dir"]["cl"]) if "name" in e}
        if set(nd) != {".", ".."}:
            fail(f"New Dir: {sorted(nd)}")
        elif nd[".."]["cl"] != 0 or nd["."]["cl"] != root["New Dir"]["cl"]:
            fail("New Dir: . or .. wrong")
    if "Top Inner" in root:
        ti = {e["name"]: e for e in v.dir_entries(img, root["Top Inner"]["cl"]) if "name" in e}
        if set(ti) != {".", "..", "MOVED FILE.TXT", "other.txt"}:
            fail(f"Top Inner: {sorted(ti)}")
        elif ti[".."]["cl"] != 0:
            fail(f"Top Inner: .. is {ti['..']['cl']:#x}, not 0 (the root)")
        else:
            with tempfile.TemporaryDirectory() as t:
                if get(img, "Top Inner/MOVED FILE.TXT", t) != bytes.fromhex(ej["data"]):
                    fail("the moved file lost its data")
    clean, out = fsck(img, case)
    if not clean:
        fail("fsck: " + " | ".join(out.splitlines()[-6:]))

print(f"CHECK {phase}: " + ("PASS" if not fails else "FAIL"))
for m in fails[:20]:
    print("  " + m)
