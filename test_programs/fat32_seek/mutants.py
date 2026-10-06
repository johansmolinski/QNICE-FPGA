#!/usr/bin/env python3
"""Mutation tests: every mutant of the seek/map code must make the suite fail.
(An end-of-file index mutant was found to be equivalent through the public
interface and is therefore not part of this list.)
usage: mutants.py <monitor dir> <work dir>"""
import os, shutil, subprocess, sys
mon, work = sys.argv[1], sys.argv[2]
here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(mon, "fat32_library.asm")).read()
M = {
 "fat_entry_mask": ("                AND     0x007F, R9\n                SHL     2, R9",
                    "                AND     0x003F, R9\n                SHL     2, R9"),
 "map_branch":     ("RBRA    _F32_CA_MHIT, C ", "RBRA    _F32_CA_MHIT, Z "),
 "map_no_merge":   ("                CMP     R10, R6\n                RBRA    _F32_FM_NEW, !Z",
                    "                RBRA    _F32_FM_NEW, 1"),
 "no_eoc_check":   ("                CMP     0xFFF8, R10\n                RBRA    _F32_FN_OK, N ",
                    "                RBRA    _F32_FN_OK, 1\n                RBRA    _F32_FN_OK, N "),
 "free_not_bad":   ("                CMP     2, R10\n                RBRA    _F32_FN_BAD, N ",
                    "                CMP     2, R10\n                RBRA    _F32_FN_OK, N "),
 "walk_from_cur":  ("                SUBC    R9, R7\n                RBRA    _F32_CA_STEP, !C",
                    "                SUBC    R9, R7\n                ADD     1, R6\n                RBRA    _F32_CA_STEP, !C"),
 "flush_r9":       ("_FAT32$FLUSH_0  XOR     R9, R9", "_FAT32$FLUSH_0  NOP"),
}
ok = True
for name, (old, new) in M.items():
    assert src.count(old) == 1, (name, src.count(old))
    d = os.path.join(work, "mutant")
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(mon, d)
    open(os.path.join(d, "fat32_library.asm"), "w").write(src.replace(old, new))
    res = []
    for spc in (1, 8, 64):
        out = subprocess.run(["bash", "-c", f'source <(sed -n "/^run_case()/,/^}}/p" {here}/run.sh); '
                              f'H={here}; W={work}; run_case {d} {work}/case{spc} mutant'],
                             capture_output=True, text=True).stdout
        res.append("PASS" if "RESULT: PASS" in out and "HOSTCHECK: PASS" in out else "FAIL")
    killed = "FAIL" in res
    ok &= killed
    print(f"{name:16s} {'killed' if killed else 'SURVIVED'}  {' '.join(res)}")
print("MUTANTS:", "PASS (all killed)" if ok else "FAIL (survivors)")
