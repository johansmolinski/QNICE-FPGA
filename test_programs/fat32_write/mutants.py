#!/usr/bin/env python3
"""Mutation tests for fat32_write.asm: every mutant must make ./run.sh fail.

usage: mutants.py [spc ...]   (default: 1)
"""
import os, shutil, subprocess, sys, tempfile
H = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(H, "../.."))
MUTANTS = [
    ("no_fat2_mirror", "_F32W_FL_MIR    MOVE    @R0, R5", "_F32W_FL_MIR    RBRA    _F32W_FL_DONE, 1\n                MOVE    @R0, R5"),
    ("no_fsinfo_free", "                RSUB    _F32W_WDW, 1                ; R8 = device handle", "                NOP"),
    ("no_link", "                MOVE    R1, R7\n                OR      R2, R7\n                RBRA    _F32W_AL_HNT, Z", "                RBRA    _F32W_AL_HNT, 1"),
    ("eoc_wrong", "_F32W_AL_FND    MOVE    R5, R9\n                MOVE    R6, R10\n                MOVE    0xFFFF, R11", "_F32W_AL_FND    MOVE    R5, R9\n                MOVE    R6, R10\n                MOVE    0xFFF7, R11"),
    ("free_count_used", "                SUB     1, @R7++\n                SUBC    0, @R7", "                SUB     1, @R7++\n                NOP"),
    ("maxclus_off", "_F32W_GM_DIVD   ADD     1, R10", "_F32W_GM_DIVD   ADD     2, R10"),
    ("no_wrap", "                MOVE    2, R5\n                XOR     R6, R6\n_F32W_AL_W", "                RBRA    _F32W_AL_FULL, 1\n                XOR     R6, R6\n_F32W_AL_W"),
    ("sec_no_read", "                MOVE    FAT32$DEV_BLOCK_READ, R10\n                MOVE    @R0, R11\n                RSUB    FAT32$CALL_DEV, 1\n                MOVE    R8, R9\n                CMP     0, R9\n                RBRA    _F32W_SC_RET, !Z", "                XOR     R9, R9"),
    ("lfn_checksum", "                ADD     1, R9                       ; checksum\n                MOVE    R3, R10", "                ADD     1, R9                       ; checksum\n                MOVE    R3, R10\n                ADD     1, R10"),
    ("lfn_no_last", "                OR      0x0040, R10\n_F32W_PL_NL", "                MOVE    R10, R10\n_F32W_PL_NL"),
    ("lfn_no_term", "                RBRA    _F32W_PL_W, !Z\n                XOR     R10, R10\n_F32W_PL_W", "                RBRA    _F32W_PL_W, 1\n                XOR     R10, R10\n_F32W_PL_W"),
    ("no_tail", "_F32W_CR_TLN    ADD     1, R12", "_F32W_CR_TLN    RBRA    _F32W_CR_PUT, 1"),
    ("delete_sfn_only", "_F32W_DL_MARK   MOVE    R6, R9\n                ADD     FAT32$SB_L, R9", "_F32W_DL_MARK   MOVE    R6, R9\n                ADD     FAT32$SB_E, R9"),
    ("no_alias_match", "                RBRA    _F32W_SN_FND, !Z\n_F32W_SN_BYS", "                RBRA    _F32W_SN_FND, !Z\n                RBRA    _F32W_SN_NEXT, 1\n_F32W_SN_BYS"),
    ("colon_ok", "                MOVE    _F32W_LFNBAD, R11\n                RSUB    _F32W_INSTR, 1\n                RBRA    _F32W_MK_BAD, C", "                MOVE    _F32W_LFNBAD, R11"),
    ("upc_noop", "_F32W_UC_UP     SUB     0x0020, R10", "_F32W_UC_UP     ADD     0x0000, R10"),
    ("no_zero_cluster", "_F32W_ZC_B      RSUB    FAT32$WRITE_B, 1", "_F32W_ZC_B      MOVE    R0, R0"),
    ("adv_no_grow", "_F32W_AV_GROW   MOVE    R3, @R1", "_F32W_AV_GROW   RBRA    _F32W_AV_RET, 1\n                MOVE    R3, @R1"),
    ("put_no_link", "                RBRA    _F32W_PT_E2, C\n                MOVE    R0, R4", "                RBRA    _F32W_PT_E2, 1\n                MOVE    R0, R4"),
    ("setsize_no_free", "                MOVE    R11, R9\n                RSUB    _F32W_FREE, 1", "                MOVE    R11, R9\n                MOVE    R0, R0"),
    ("setsize_no_tail", "_F32W_SS_TAIL   MOVE    R0, R8", "_F32W_SS_TAIL   XOR     R9, R9\n                RET\n                MOVE    R0, R8"),
    ("sync_no_entry", "                MOVE    R1, R8\n                RSUB    FAT32$W_SETDE, 1\n                CMP     0, R9\n                RBRA    _F32W_SY_RET, !Z", "                XOR     R9, R9"),
    ("sync_no_clus", "                OR      FAT32$WSF_CLUS, @R4\n", ""),
    ("rename_no_dotdot", "_F32W_RN_DD     MOVE    R0, R8", "_F32W_RN_DD     RBRA    _F32W_RN_DEL, 1\n                MOVE    R0, R8"),
    ("rename_no_loop", "                MOVE    FAT32$ERR_LOOP, R9\n                RBRA    _F32W_RN_END, 1", "                RBRA    _F32W_RN_NEW, 1"),
    ("create_no_ignore", "                CMP     0, @R8++\n                RBRA    _F32W_SN_BYI, Z", "                CMP     0, @R8++\n                RBRA    _F32W_SN_BYI, 1"),
    ("mkdir_dotdot_root", "                CMP     @R11, R10\n                RBRA    _F32W_MD_P, !Z\n                XOR     R9, R9", "                CMP     @R11, R10\n                RBRA    _F32W_MD_P, 1\n                XOR     R9, R9"),
]
spcs = sys.argv[1:] or ["1"]
killed = 0
for name, old, new in MUTANTS:
    with tempfile.TemporaryDirectory() as t:
        lib = os.path.join(t, "monitor")
        shutil.copytree(os.path.join(ROOT, "monitor"), lib)
        p = None
        for f in ("fat32_write.asm", "fat32_wfile.asm"):
            q = os.path.join(lib, f)
            if open(q).read().count(old) == 1:
                p = q
        if not p:
            print(f"{name}: pattern not found once"); continue
        s = open(p).read()
        s = s.replace(old, new)
        if "_F32W_AL_FULL" in new:
            s = s.replace("                MOVE    FAT32$ERR_DISKFULL, R9\n                RBRA    _F32W_AL_ERR, 1",
                          "_F32W_AL_FULL   MOVE    FAT32$ERR_DISKFULL, R9\n                RBRA    _F32W_AL_ERR, 1")
        open(p, "w").write(s.replace("NOP", "MOVE    R0, R0"))
        r = subprocess.run([os.path.join(H, "run.sh")] + spcs, env=dict(os.environ, LIB=lib, WORK=os.path.join(H, "work-mut"), TMO="600"),
                           capture_output=True, text=True)
        dead = "FAIL" in r.stdout or r.returncode != 0
        killed += dead
        print(f"{name}: {'killed' if dead else 'SURVIVED'}")
print(f"MUTANTS: {killed}/{len(MUTANTS)} killed")
