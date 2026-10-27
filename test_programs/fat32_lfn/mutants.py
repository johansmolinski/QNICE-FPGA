#!/usr/bin/env python3
"""Mutation tests for the long name checks of FAT32$DIR_LIST: every mutant must
make ./run.sh fail. usage: mutants.py"""
import os, shutil, subprocess, tempfile
H = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(H, "../.."))
MUTANTS = [
    ("no_stack_restore", "                ADD     13, SP\n                ADD     1, R6", "                MOVE    R0, R0\n                ADD     1, R6"),
    ("seq_skips_bare", "                RBRA    _F32_DLST_LNX, !Z           ; no: skip until short nm.",
     "                RBRA    _F32_DLST_DS, !Z"),
    ("chk_skips_bare", "                RBRA    _F32_DLST_LN2B, Z           ; yes: go on",
     "                RBRA    _F32_DLST_DS, !Z\n                RBRA    _F32_DLST_LN2B, 1"),
    ("no_max", "                RBRA    _F32_DLST_DS, N             ; have: corrupt, skip", "                MOVE    R0, R0"),
    ("max_19", "FAT32$INT_LONG_MAX      .EQU    20", "FAT32$INT_LONG_MAX      .EQU    19"),
    ("max_21", "FAT32$INT_LONG_MAX      .EQU    20", "FAT32$INT_LONG_MAX      .EQU    21"),
]
killed = 0
for name, old, new in MUTANTS:
    with tempfile.TemporaryDirectory() as t:
        lib = os.path.join(t, "monitor")
        shutil.copytree(os.path.join(ROOT, "monitor"), lib)
        p = os.path.join(lib, "fat32_library.asm")
        s = open(p).read()
        if s.count(old) != 1:
            print(f"{name}: pattern not found once"); continue
        open(p, "w").write(s.replace(old, new))
        r = subprocess.run([os.path.join(H, "run.sh")], env=dict(os.environ, LIB=lib, WORK=os.path.join(H, "work-mut")),
                           capture_output=True, text=True)
        dead = "FAIL" in r.stdout or r.returncode != 0
        killed += dead
        print(f"{name}: {'killed' if dead else 'SURVIVED'}")
print(f"MUTANTS: {killed}/{len(MUTANTS)} killed")
