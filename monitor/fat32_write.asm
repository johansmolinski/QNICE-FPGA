;*****************************************************************************
;* FAT32 write layer: allocate and free clusters, create, delete and rename
;* directory entries, grow and shrink files
;*
;* Megamiga (johansmolinski/QNICE-FPGA, branch fat32-fastseek), October 2026.
;* Needs fat32_library.asm (it uses its device callbacks and byte helpers).
;*
;* THE WRITE SESSION
;*
;* Every operation of this layer runs inside a write session: a small
;* structure (FAT32$WS_SIZE words, usually on the stack of the caller) that
;* owns the one 512-byte sector buffer of the device for the duration of the
;* operation. _F32W_BEGIN flushes the buffer of whatever file handle owns it
;* and takes it away from that handle (it re-reads its sector on its next
;* access). Inside the session the buffer holds one "current sector" (any LBA:
;* a FAT sector, a directory sector, the FSInfo sector); _F32W_SEC makes a
;* sector current and writes the previous one back first if it was changed.
;* A changed FAT sector is written to both FATs. _F32W_END writes the last
;* sector back and settles the free-cluster count and the next-free hint in
;* the FSInfo sector.
;*
;* The order of the writes protects the file system against a card that is
;* pulled in the middle of an operation as far as FAT allows: clusters are
;* allocated (and linked) before a directory entry points to them, and a
;* directory entry stops pointing to clusters before they are freed. At worst
;* clusters are lost, which every FAT checker repairs.
;*****************************************************************************

; the write session
FAT32$WS_DEV            .EQU    0                   ; device handle
FAT32$WS_LBA_LO         .EQU    1                   ; the current sector, 0xFFFF/
FAT32$WS_LBA_HI         .EQU    2                   ; 0xFFFF = none
FAT32$WS_DIRTY          .EQU    3                   ; 1: the current sector changed
FAT32$WS_FREE_LO        .EQU    4                   ; free clusters gained (signed,
FAT32$WS_FREE_HI        .EQU    5                   ; 32 bit) during the session
FAT32$WS_SIZE           .EQU    6

; FAT32 boot sector (BPB) and FSInfo offsets
_F32W_BPB_TOTSEC        .EQU    0x0020              ; total sectors (32 bit)
_F32W_BPB_FATSZ         .EQU    0x0024              ; sectors per FAT (32 bit)
_F32W_BPB_FSINFO        .EQU    0x0030              ; FSInfo sector (16 bit)
_F32W_FSI_SIG1          .EQU    0x0000              ; 0x41615252
_F32W_FSI_SIG2          .EQU    0x01E4              ; 0x61417272
_F32W_FSI_FREE          .EQU    0x01E8              ; free cluster count
_F32W_FSI_NEXT          .EQU    0x01EC              ; next free cluster

;*****************************************************************************
;* _F32W_BEGIN starts a write session
;*
;* INPUT:  R8  the session structure (FAT32$WS_SIZE words)
;*         R9  device handle
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, otherwise an error code (then no session is open)
;*         R10..R12 unchanged
;*****************************************************************************
;
_F32W_BEGIN     INCRB
                MOVE    R8, R0                      ; R0: session
                MOVE    R9, R1                      ; R1: device handle
                MOVE    R10, R5
                MOVE    R11, R6
                MOVE    R12, R7
                MOVE    R1, @R0                     ; WS_DEV
                MOVE    R0, R2
                ADD     FAT32$WS_LBA_LO, R2
                MOVE    0xFFFF, @R2++               ; no current sector
                MOVE    0xFFFF, @R2++
                MOVE    0, @R2++                    ; WS_DIRTY
                MOVE    0, @R2++                    ; WS_FREE_LO
                MOVE    0, @R2                      ; WS_FREE_HI

                ; take the sector buffer: write back what its owner changed
                MOVE    R1, R8
                RSUB    FAT32$FLUSH_OWNER, 1
                CMP     0, R9
                RBRA    _F32W_BG_RET, !Z
                MOVE    R1, R2
                ADD     FAT32$DEV_BUFFERED_FDH, R2
                MOVE    0, @R2                      ; owned by nobody

                ; the geometry, once per mount
                MOVE    R1, R2
                ADD     FAT32$DEV_W_VALID, R2
                CMP     0, @R2
                RBRA    _F32W_BG_OK, !Z
                MOVE    R0, R8
                RSUB    _F32W_GEOMETRY, 1
                CMP     0, R9
                RBRA    _F32W_BG_RET, !Z
                MOVE    R1, R2
                ADD     FAT32$DEV_W_VALID, R2
                MOVE    1, @R2

_F32W_BG_OK     XOR     R9, R9
_F32W_BG_RET    MOVE    R0, R8
                MOVE    R5, R10
                MOVE    R6, R11
                MOVE    R7, R12
                DECRB
                RET

;*****************************************************************************
;* _F32W_GEOMETRY fills FAT2, MAXCLUS, FSINFO and HINT of the device handle
;*
;* Reads the boot sector (and the FSInfo sector) into the buffer of the
;* session, which has no current sector yet.
;*
;* INPUT:  R8  session
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, otherwise an error code
;*         R10..R12 clobbered
;*****************************************************************************
;
_F32W_GEOMETRY  INCRB
                MOVE    R8, R0                      ; R0: session
                MOVE    @R0, R1                     ; R1: device handle

                ; the boot sector
                MOVE    R1, R2
                ADD     FAT32$DEV_FS_LO, R2
                MOVE    @R2++, R9                   ; DEV_FS_HI follows LO
                MOVE    @R2, R10
                RSUB    _F32W_SEC, 1
                CMP     0, R9
                RBRA    _F32W_GM_RET, !Z

                ; FAT2 = FAT + sectors per FAT
                MOVE    R1, R8
                MOVE    _F32W_BPB_FATSZ, R9
                RSUB    FAT32$READ_DW, 1            ; R11|R10: sectors per FAT
                MOVE    R10, R4
                MOVE    R11, R5                     ; R5|R4: sectors per FAT
                MOVE    R1, R2
                ADD     FAT32$DEV_FAT_LO, R2
                MOVE    @R2++, R6
                MOVE    @R2, R7
                ADD     R4, R6
                ADDC    R5, R7
                MOVE    R1, R2
                ADD     FAT32$DEV_FAT2_LO, R2
                MOVE    R6, @R2++
                MOVE    R7, @R2

                ; data sectors = total sectors - (cluster start - FS start)
                MOVE    _F32W_BPB_TOTSEC, R9
                RSUB    FAT32$READ_DW, 1            ; R11|R10: total sectors
                MOVE    R1, R2
                ADD     FAT32$DEV_CLUSTER_LO, R2
                MOVE    @R2++, R6
                MOVE    @R2, R7                     ; R7|R6: cluster start
                MOVE    R1, R2
                ADD     FAT32$DEV_FS_LO, R2
                SUB     @R2++, R6
                SUBC    @R2, R7                     ; R7|R6: start - FS start
                SUB     R6, R10
                SUBC    R7, R11                     ; R11|R10: data sectors

                ; clusters = data sectors / sectors per cluster (a power of
                ; two); the highest cluster number is clusters + 1
                MOVE    R1, R2
                ADD     FAT32$DEV_SECT_PER_CLUS, R2
                MOVE    @R2, R2
_F32W_GM_DIV    CMP     1, R2
                RBRA    _F32W_GM_DIVD, Z
                MOVE    R11, R3                     ; R11|R10 >>= 1 (masks:
                AND     1, R3                       ; SHR fills from C)
                SHR     1, R10
                AND     0x7FFF, R10
                CMP     0, R3
                RBRA    _F32W_GM_D1, Z
                OR      0x8000, R10
_F32W_GM_D1     SHR     1, R11
                AND     0x7FFF, R11
                SHR     1, R2
                AND     0x7FFF, R2
                RBRA    _F32W_GM_DIV, 1
_F32W_GM_DIVD   ADD     1, R10
                ADDC    0, R11

                ; ... but never beyond what the FAT can hold: 128 entries
                ; per FAT sector, numbers 0 .. 128 * sectors per FAT - 1
                MOVE    R4, R6
                MOVE    R5, R7
                RSUB    _F32W_SHL7, 1               ; R7|R6 = sectors * 128
                SUB     1, R6
                SUBC    0, R7
                CMP     R11, R7                     ; R11|R10 > R7|R6 ?
                RBRA    _F32W_GM_CAP, N             ; (N: R11 > R7)
                RBRA    _F32W_GM_MAX, !Z            ; R11 < R7
                CMP     R10, R6
                RBRA    _F32W_GM_MAX, !N            ; R10 <= R6
_F32W_GM_CAP    MOVE    R6, R10
                MOVE    R7, R11
_F32W_GM_MAX    MOVE    R1, R2
                ADD     FAT32$DEV_MAXCLUS_LO, R2
                MOVE    R10, @R2++
                MOVE    R11, @R2

                ; the FSInfo sector (0 or 0xFFFF in the boot sector: none)
                MOVE    R1, R8
                MOVE    _F32W_BPB_FSINFO, R9
                RSUB    FAT32$READ_W, 1
                MOVE    R1, R2
                ADD     FAT32$DEV_FSINFO_LO, R2
                MOVE    0, @R2++
                MOVE    0, @R2
                MOVE    R1, R2
                ADD     FAT32$DEV_HINT_LO, R2
                MOVE    2, @R2++                    ; default hint: cluster 2
                MOVE    0, @R2
                CMP     0, R10
                RBRA    _F32W_GM_OK, Z
                CMP     0xFFFF, R10
                RBRA    _F32W_GM_OK, Z
                MOVE    R1, R2
                ADD     FAT32$DEV_FS_LO, R2
                MOVE    @R2++, R6
                MOVE    @R2, R7
                ADD     R10, R6
                ADDC    0, R7                       ; R7|R6: FSInfo LBA
                MOVE    R0, R8
                MOVE    R6, R9
                MOVE    R7, R10
                RSUB    _F32W_SEC, 1
                CMP     0, R9
                RBRA    _F32W_GM_RET, !Z
                RSUB    _F32W_FSI_OK, 1             ; signatures right?
                RBRA    _F32W_GM_OK, !C
                MOVE    R1, R2
                ADD     FAT32$DEV_FSINFO_LO, R2
                MOVE    R6, @R2++
                MOVE    R7, @R2

                ; its next-free hint, if it is a data cluster
                MOVE    R1, R8
                MOVE    _F32W_FSI_NEXT, R9
                RSUB    FAT32$READ_DW, 1            ; R11|R10
                MOVE    R0, R8
                MOVE    R10, R9
                MOVE    R11, R10
                RSUB    _F32W_ISDATA, 1
                RBRA    _F32W_GM_OK, !C
                MOVE    R1, R2
                ADD     FAT32$DEV_HINT_LO, R2
                MOVE    R9, @R2++
                MOVE    R10, @R2

_F32W_GM_OK     XOR     R9, R9
_F32W_GM_RET    MOVE    R0, R8
                DECRB
                RET

;*****************************************************************************
;* _F32W_SHL7: R7|R6 := R7|R6 * 128. Other registers unchanged.
;*****************************************************************************
;
_F32W_SHL7      MOVE    R8, @--SP
                MOVE    R6, R8                      ; the bits that move from
                SWAP    R8, R8                      ; R6 to R7: R6 >> 9
                AND     0x00FF, R8
                SHR     1, R8
                AND     0x007F, R8
                SHL     7, R7                       ; (masks: SHL fills from X)
                AND     0xFF80, R7
                OR      R8, R7
                SHL     7, R6
                AND     0xFF80, R6
                MOVE    @SP++, R8
                RET

;*****************************************************************************
;* _F32W_ISDATA: C = 1 if the cluster R10|R9 is a data cluster of the device
;* of the session R8 (2 .. MAXCLUS). Registers unchanged.
;*****************************************************************************
;
_F32W_ISDATA    INCRB
                MOVE    @R8, R0
                ADD     FAT32$DEV_MAXCLUS_LO, R0
                MOVE    @R0++, R1
                MOVE    @R0, R2                     ; R2|R1: MAXCLUS
                CMP     0, R10                      ; below 2?
                RBRA    _F32W_ID_HI, !Z
                CMP     2, R9
                RBRA    _F32W_ID_NO, N              ; (2 > R9)
_F32W_ID_HI     CMP     R10, R2                     ; above MAXCLUS?
                RBRA    _F32W_ID_NO, N              ; R10 > R2
                RBRA    _F32W_ID_YES, !Z            ; R10 < R2
                CMP     R9, R1
                RBRA    _F32W_ID_NO, N              ; R9 > R1
_F32W_ID_YES    OR      0x0004, SR                  ; C = 1
                DECRB
                RET
_F32W_ID_NO     AND     0xFFFB, SR                  ; C = 0
                DECRB
                RET

;*****************************************************************************
;* _F32W_FSI_OK: C = 1 if the current sector has both FSInfo signatures.
;* R8 = session. Registers unchanged.
;*****************************************************************************
;
_F32W_FSI_OK    INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    R10, R2
                MOVE    R11, R3
                MOVE    @R0, R8
                MOVE    _F32W_FSI_SIG1, R9
                RSUB    FAT32$READ_DW, 1
                CMP     0x5252, R10
                RBRA    _F32W_FO_NO, !Z
                CMP     0x4161, R11
                RBRA    _F32W_FO_NO, !Z
                MOVE    _F32W_FSI_SIG2, R9
                RSUB    FAT32$READ_DW, 1
                CMP     0x7272, R10
                RBRA    _F32W_FO_NO, !Z
                CMP     0x6141, R11
                RBRA    _F32W_FO_NO, !Z
                MOVE    R0, R8
                MOVE    R1, R9
                MOVE    R2, R10
                MOVE    R3, R11
                OR      0x0004, SR                  ; C = 1
                DECRB
                RET
_F32W_FO_NO     MOVE    R0, R8
                MOVE    R1, R9
                MOVE    R2, R10
                MOVE    R3, R11
                AND     0xFFFB, SR                  ; C = 0
                DECRB
                RET

;*****************************************************************************
;* _F32W_SEC makes a sector the current sector of the session
;*
;* Writes the previous current sector back first if it was changed (a FAT
;* sector to both FATs), then reads the new one unless it is already there.
;*
;* INPUT:  R8  session
;*         R9  LBA low word
;*         R10 LBA high word
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, otherwise an error code
;*         R10 unchanged
;*****************************************************************************
;
_F32W_SEC       INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    R10, R2
                MOVE    R11, R3
                MOVE    R12, R4
                MOVE    R0, R5
                ADD     FAT32$WS_LBA_LO, R5
                CMP     @R5++, R1                   ; already there?
                RBRA    _F32W_SC_NEW, !Z
                CMP     @R5, R2
                RBRA    _F32W_SC_OK, Z
_F32W_SC_NEW    RSUB    _F32W_FLUSH, 1
                CMP     0, R9
                RBRA    _F32W_SC_RET, !Z
                MOVE    R0, R5
                ADD     FAT32$WS_LBA_LO, R5
                MOVE    0xFFFF, @R5                 ; unknown if the read fails
                MOVE    R1, R8
                MOVE    R2, R9
                MOVE    FAT32$DEV_BLOCK_READ, R10
                MOVE    @R0, R11
                RSUB    FAT32$CALL_DEV, 1
                MOVE    R8, R9
                CMP     0, R9
                RBRA    _F32W_SC_RET, !Z
                MOVE    R1, @R5++
                MOVE    R2, @R5
_F32W_SC_OK     XOR     R9, R9
_F32W_SC_RET    MOVE    R0, R8
                MOVE    R2, R10
                MOVE    R3, R11
                MOVE    R4, R12
                DECRB
                RET

;*****************************************************************************
;* _F32W_FLUSH writes the current sector of the session back if it changed
;*
;* A sector of the first FAT is written to the same place of the second FAT
;* as well. The sector stays current.
;*
;* INPUT:  R8  session
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, otherwise an error code
;*         R10..R12 unchanged
;*****************************************************************************
;
_F32W_FLUSH     INCRB
                MOVE    R8, R0
                MOVE    R10, R1
                MOVE    R11, R2
                MOVE    R12, R3
                XOR     R9, R9
                MOVE    R0, R4
                ADD     FAT32$WS_DIRTY, R4
                CMP     0, @R4
                RBRA    _F32W_FL_RET, Z
                MOVE    R0, R5
                ADD     FAT32$WS_LBA_LO, R5
                MOVE    @R5++, R6
                MOVE    @R5, R7                     ; R7|R6: the sector
                MOVE    R6, R8
                MOVE    R7, R9
                MOVE    FAT32$DEV_BLOCK_WRITE, R10
                MOVE    @R0, R11
                RSUB    FAT32$CALL_DEV, 1
                MOVE    R8, R9
                CMP     0, R9
                RBRA    _F32W_FL_RET, !Z

                ; in the first FAT (FAT <= LBA < FAT2)? Then also into FAT2.
                MOVE    @R0, R5
                ADD     FAT32$DEV_FAT_LO, R5
                MOVE    @R5++, R8
                MOVE    @R5, R9                     ; R9|R8: FAT
                SUB     R8, R6
                SUBC    R9, R7                      ; R7|R6: LBA - FAT
                RBRA    _F32W_FL_DONE, C            ; LBA < FAT (borrow)
                MOVE    @R0, R5
                ADD     FAT32$DEV_FAT2_LO, R5
                MOVE    @R5++, R10
                MOVE    @R5, R11                    ; R11|R10: FAT2
                SUB     R8, R10
                SUBC    R9, R11                     ; R11|R10: sectors per FAT
                CMP     R7, R11                     ; LBA - FAT < sectors?
                RBRA    _F32W_FL_DONE, N            ; R7 > R11: no
                RBRA    _F32W_FL_MIR, !Z            ; R7 < R11: yes
                CMP     R6, R10
                RBRA    _F32W_FL_DONE, N            ; R6 > R10: no
                RBRA    _F32W_FL_DONE, Z            ; R6 = R10: no
_F32W_FL_MIR    MOVE    @R0, R5
                ADD     FAT32$DEV_FAT2_LO, R5
                MOVE    @R5++, R8
                MOVE    @R5, R9
                ADD     R6, R8
                ADDC    R7, R9                      ; R9|R8: FAT2 + offset
                MOVE    FAT32$DEV_BLOCK_WRITE, R10
                MOVE    @R0, R11
                RSUB    FAT32$CALL_DEV, 1
                MOVE    R8, R9
                CMP     0, R9
                RBRA    _F32W_FL_RET, !Z
_F32W_FL_DONE   MOVE    0, @R4                      ; clean
                XOR     R9, R9
_F32W_FL_RET    MOVE    R0, R8
                MOVE    R1, R10
                MOVE    R2, R11
                MOVE    R3, R12
                DECRB
                RET

;*****************************************************************************
;* _F32W_END ends a write session
;*
;* Writes the current sector back and settles the FSInfo sector: the free
;* cluster count changes by what the session gained or lost (unless it is
;* "unknown", 0xFFFFFFFF) and the next-free hint is the one of the device
;* handle. The sector buffer stays owned by nobody.
;*
;* INPUT:  R8  session
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, otherwise an error code
;*         R10..R12 unchanged
;*****************************************************************************
;
_F32W_END       INCRB
                MOVE    R8, R0
                MOVE    R10, R1
                MOVE    R11, R2
                MOVE    R12, R3
                RSUB    _F32W_FLUSH, 1
                CMP     0, R9
                RBRA    _F32W_EN_RET, !Z
                MOVE    @R0, R4                     ; R4: device handle
                MOVE    R4, R5
                ADD     FAT32$DEV_FSINFO_LO, R5
                MOVE    @R5++, R9
                MOVE    @R5, R10
                MOVE    R9, R5
                OR      R10, R5
                RBRA    _F32W_EN_RET, Z             ; no FSInfo (R9 = 0)
                RSUB    _F32W_SEC, 1
                CMP     0, R9
                RBRA    _F32W_EN_RET, !Z
                RSUB    _F32W_FSI_OK, 1
                RBRA    _F32W_EN_OK, !C             ; (gone: leave it alone)

                ; free count += gained, unless unknown
                MOVE    R4, R8
                MOVE    _F32W_FSI_FREE, R9
                RSUB    FAT32$READ_DW, 1            ; R11|R10
                MOVE    R10, R5
                AND     R11, R5
                CMP     0xFFFF, R5
                RBRA    _F32W_EN_NXT, Z
                MOVE    R0, R5
                ADD     FAT32$WS_FREE_LO, R5
                ADD     @R5++, R10
                ADDC    @R5, R11
                MOVE    R10, R6
                MOVE    R11, R7
                MOVE    _F32W_FSI_FREE, R9
                RSUB    _F32W_WDW, 1                ; R8 = device handle

                ; next free = the hint
_F32W_EN_NXT    MOVE    R4, R5
                ADD     FAT32$DEV_HINT_LO, R5
                MOVE    @R5++, R6
                MOVE    @R5, R7
                MOVE    R4, R8
                MOVE    _F32W_FSI_NEXT, R9
                RSUB    _F32W_WDW, 1
                MOVE    R0, R5
                ADD     FAT32$WS_DIRTY, R5
                MOVE    1, @R5
                MOVE    R0, R8
                RSUB    _F32W_FLUSH, 1
                CMP     0, R9
                RBRA    _F32W_EN_RET, !Z
_F32W_EN_OK     XOR     R9, R9
_F32W_EN_RET    MOVE    R0, R8
                MOVE    R1, R10
                MOVE    R2, R11
                MOVE    R3, R12
                DECRB
                RET

;*****************************************************************************
;* _F32W_WDW writes the double word R7|R6 little endian to the sector buffer
;* at byte R9 (R8 = device handle). Registers unchanged.
;*****************************************************************************
;
_F32W_WDW       MOVE    R9, @--SP                   ; (no INCRB: R7|R6 are the
                MOVE    R10, @--SP                  ; caller's registers)
                MOVE    R6, R10
                RSUB    _F32W_WW, 1
                ADD     2, R9
                MOVE    R7, R10
                RSUB    _F32W_WW, 1
                MOVE    @SP++, R10
                MOVE    @SP++, R9
                RET

;*****************************************************************************
;* _F32W_WW writes the word R10 little endian to the sector buffer at byte R9
;* (R8 = device handle). Registers unchanged.
;*****************************************************************************
;
_F32W_WW        INCRB
                MOVE    R10, R0
                AND     0x00FF, R10
                RSUB    FAT32$WRITE_B, 1
                ADD     1, R9
                MOVE    R0, R10
                SWAP    R10, R10
                AND     0x00FF, R10
                RSUB    FAT32$WRITE_B, 1
                SUB     1, R9
                MOVE    R0, R10
                DECRB
                RET

;*****************************************************************************
;* _F32W_FATLOC: the FAT entry of the cluster R10|R9 (session R8) is in the
;* sector R10|R9 (of the first FAT) at byte R11. R8 unchanged.
;*****************************************************************************
;
_F32W_FATLOC    INCRB
                MOVE    R9, R11                     ; byte: (cluster % 128) * 4
                AND     0x007F, R11
                SHL     2, R11
                AND     0x01FC, R11
                MOVE    R10, R0                     ; R0|R9 := cluster >> 7
                SHL     9, R0                       ; (masks: SHL fills from X,
                AND     0xFE00, R0                  ; SHR from C)
                SHR     7, R9
                AND     0x01FF, R9
                OR      R0, R9
                SHR     7, R10
                AND     0x01FF, R10
                MOVE    @R8, R0
                ADD     FAT32$DEV_FAT_LO, R0
                ADD     @R0++, R9
                ADDC    @R0, R10
                DECRB
                RET

;*****************************************************************************
;* _F32W_FATGET reads the FAT entry of a cluster
;*
;* INPUT:  R8  session
;*         R9  cluster low word
;*         R10 cluster high word
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, otherwise an error code
;*         R10 entry low word
;*         R11 entry high word (the upper 4 reserved bits are cleared)
;*         R12 unchanged
;*****************************************************************************
;
_F32W_FATGET    INCRB
                MOVE    R8, R0
                RSUB    _F32W_FATLOC, 1
                MOVE    R11, R1                     ; R1: byte in the sector
                RSUB    _F32W_SEC, 1
                CMP     0, R9
                RBRA    _F32W_FG_RET, !Z
                MOVE    @R0, R8
                MOVE    R1, R9
                RSUB    FAT32$READ_DW, 1
                AND     0x0FFF, R11
                XOR     R9, R9
_F32W_FG_RET    MOVE    R0, R8
                DECRB
                RET

;*****************************************************************************
;* _F32W_FATSET sets the FAT entry of a cluster
;*
;* Keeps the upper 4 reserved bits of the entry and counts clusters that
;* become free or used in the session.
;*
;* INPUT:  R8  session
;*         R9  cluster low word
;*         R10 cluster high word
;*         R11 new value low word
;*         R12 new value high word (28 bits are used)
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, otherwise an error code
;*         R10..R12 unchanged
;*****************************************************************************
;
_F32W_FATSET    INCRB
                MOVE    R8, R0
                MOVE    R10, R2
                MOVE    R11, R3
                MOVE    R12, R4
                RSUB    _F32W_FATLOC, 1
                MOVE    R11, R1                     ; R1: byte in the sector
                RSUB    _F32W_SEC, 1
                CMP     0, R9
                RBRA    _F32W_FS_RET, !Z
                MOVE    @R0, R8
                MOVE    R1, R9
                RSUB    FAT32$READ_DW, 1            ; R11|R10: old entry
                MOVE    R11, R5
                AND     0xF000, R5                  ; R5: its reserved bits
                AND     0x0FFF, R11
                OR      R10, R11                    ; R11 = 0: it was free

                ; the free count of the session
                MOVE    R4, R6
                AND     0x0FFF, R6
                OR      R3, R6                      ; R6 = 0: it becomes free
                MOVE    R0, R7
                ADD     FAT32$WS_FREE_LO, R7
                CMP     0, R11
                RBRA    _F32W_FS_WASU, !Z
                CMP     0, R6                       ; free -> used: -1
                RBRA    _F32W_FS_WR, Z
                SUB     1, @R7++
                SUBC    0, @R7
                RBRA    _F32W_FS_WR, 1
_F32W_FS_WASU   CMP     0, R6                       ; used -> free: +1
                RBRA    _F32W_FS_WR, !Z
                ADD     1, @R7++
                ADDC    0, @R7

_F32W_FS_WR     MOVE    R3, R6
                MOVE    R4, R7
                AND     0x0FFF, R7
                OR      R5, R7
                MOVE    R1, R9                      ; R8 = device handle
                RSUB    _F32W_WDW, 1
                MOVE    R0, R7
                ADD     FAT32$WS_DIRTY, R7
                MOVE    1, @R7
                XOR     R9, R9
_F32W_FS_RET    MOVE    R0, R8
                MOVE    R2, R10
                MOVE    R3, R11
                MOVE    R4, R12
                DECRB
                RET

;*****************************************************************************
;* _F32W_ALLOC allocates a cluster
;*
;* Searches a free cluster from the hint of the device handle on (wrapping
;* around), marks it as the end of a chain and links it behind the cluster
;* R10|R9 unless that is 0.
;*
;* INPUT:  R8  session
;*         R9  low word of the cluster to link it to, or 0
;*         R10 high word of that cluster, or 0
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, FAT32$ERR_DISKFULL or another error code
;*         R10 low word of the new cluster
;*         R11 high word of the new cluster
;*         R12 unchanged
;*****************************************************************************
;
_F32W_ALLOC     INCRB
                MOVE    R8, R0
                MOVE    R9, R1                      ; R2|R1: link behind this
                MOVE    R10, R2
                MOVE    R12, R3
                MOVE    @R0, R4
                ADD     FAT32$DEV_HINT_LO, R4
                MOVE    @R4++, R5
                MOVE    @R4, R6                     ; R6|R5: candidate
                MOVE    R5, R9
                MOVE    R6, R10
                RSUB    _F32W_ISDATA, 1
                RBRA    _F32W_AL_H, C
                MOVE    2, R5                       ; a bad hint: start at 2
                XOR     R6, R6
_F32W_AL_H      MOVE    R5, @--SP                   ; where the search began
                MOVE    R6, @--SP

_F32W_AL_L      MOVE    R5, R9
                MOVE    R6, R10
                RSUB    _F32W_FATGET, 1
                CMP     0, R9
                RBRA    _F32W_AL_ERR, !Z
                OR      R10, R11
                RBRA    _F32W_AL_FND, Z             ; a free cluster
                ADD     1, R5                       ; the next one, after
                ADDC    0, R6                       ; MAXCLUS cluster 2
                MOVE    R5, R9
                MOVE    R6, R10
                RSUB    _F32W_ISDATA, 1
                RBRA    _F32W_AL_W, C
                MOVE    2, R5
                XOR     R6, R6
_F32W_AL_W      CMP     @SP, R6                     ; back where it began?
                RBRA    _F32W_AL_L, !Z
                MOVE    SP, R7
                ADD     1, R7
                CMP     @R7, R5
                RBRA    _F32W_AL_L, !Z
                MOVE    FAT32$ERR_DISKFULL, R9
                RBRA    _F32W_AL_ERR, 1

                ; mark it as the end of a chain, then link it
_F32W_AL_FND    MOVE    R5, R9
                MOVE    R6, R10
                MOVE    0xFFFF, R11
                MOVE    0x0FFF, R12
                RSUB    _F32W_FATSET, 1
                CMP     0, R9
                RBRA    _F32W_AL_ERR, !Z
                MOVE    R1, R7
                OR      R2, R7
                RBRA    _F32W_AL_HNT, Z
                MOVE    R1, R9
                MOVE    R2, R10
                MOVE    R5, R11
                MOVE    R6, R12
                RSUB    _F32W_FATSET, 1
                CMP     0, R9
                RBRA    _F32W_AL_ERR, !Z

                ; the hint: the cluster after the new one
_F32W_AL_HNT    MOVE    @R0, R4
                ADD     FAT32$DEV_HINT_LO, R4
                MOVE    R5, R7
                ADD     1, R7
                MOVE    R7, @R4++
                MOVE    R6, R7
                ADDC    0, R7
                MOVE    R7, @R4
                MOVE    R5, R10
                MOVE    R6, R11
                XOR     R9, R9
_F32W_AL_ERR    ADD     2, SP
                MOVE    R0, R8
                MOVE    R3, R12
                DECRB
                RET

;*****************************************************************************
;* _F32W_FREE frees a cluster chain
;*
;* Frees the cluster R10|R9 and all clusters behind it. Stops at the end of
;* the chain and at anything that is not a data cluster (which also ends a
;* chain that runs in a circle: its first cluster is free by then).
;*
;* INPUT:  R8  session
;*         R9  low word of the first cluster (0: nothing to free)
;*         R10 high word of the first cluster
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, otherwise an error code
;*         R10..R12 unchanged
;*****************************************************************************
;
_F32W_FREE      INCRB
                MOVE    R8, R0
                MOVE    R10, R1
                MOVE    R11, R2
                MOVE    R12, R3
                MOVE    R9, R4                      ; R5|R4: the cluster
                MOVE    R10, R5
_F32W_FR_L      MOVE    R4, R9
                MOVE    R5, R10
                RSUB    _F32W_ISDATA, 1
                RBRA    _F32W_FR_OK, !C
                RSUB    _F32W_FATGET, 1             ; R11|R10: the next one
                CMP     0, R9
                RBRA    _F32W_FR_RET, !Z
                MOVE    R10, R6                     ; R7|R6
                MOVE    R11, R7
                CMP     0, R7                       ; already free: stop
                RBRA    _F32W_FR_F, !Z
                CMP     0, R6
                RBRA    _F32W_FR_OK, Z
_F32W_FR_F      MOVE    R4, R9
                MOVE    R5, R10
                XOR     R11, R11
                XOR     R12, R12
                RSUB    _F32W_FATSET, 1
                CMP     0, R9
                RBRA    _F32W_FR_RET, !Z
                MOVE    R6, R4
                MOVE    R7, R5
                RBRA    _F32W_FR_L, 1
_F32W_FR_OK     XOR     R9, R9
_F32W_FR_RET    MOVE    R0, R8
                MOVE    R1, R10
                MOVE    R2, R11
                MOVE    R3, R12
                DECRB
                RET

;*****************************************************************************
;* DIRECTORY SLOTS
;*
;* A directory is a chain of clusters of 32-byte slots. The directory walker
;* (FAT32$DW_SIZE words) goes through the slots of one directory inside a
;* write session. The position of a slot is its entry address: the cluster
;* and, in one word, the sector in the cluster (bits 15..4) and the slot in
;* the sector (bits 3..0). An entry address never changes while the entry
;* exists: creating and deleting entries never moves other entries.
;*****************************************************************************

FAT32$DW_DIR_LO         .EQU    0                   ; first cluster of the
FAT32$DW_DIR_HI         .EQU    1                   ; directory
FAT32$DW_CL_LO          .EQU    2                   ; entry address of the
FAT32$DW_CL_HI          .EQU    3                   ; current slot: cluster,
FAT32$DW_POS            .EQU    4                   ; sector << 4 | slot
FAT32$DW_ORD            .EQU    5                   ; number of the slot
FAT32$DW_SIZE           .EQU    6

;*****************************************************************************
;* _F32W_DW_START puts a directory walker on the first slot of a directory
;*
;* INPUT:  R8  session
;*         R9  directory walker
;*         R10 low word of the first cluster of the directory
;*         R11 high word of the first cluster of the directory
;* OUTPUT: all registers unchanged
;*****************************************************************************
;
_F32W_DW_START  INCRB
                MOVE    R9, R0
                MOVE    R10, @R0++                  ; DW_DIR
                MOVE    R11, @R0++
                MOVE    R10, @R0++                  ; DW_CL
                MOVE    R11, @R0++
                MOVE    0, @R0++                    ; DW_POS
                MOVE    0, @R0                      ; DW_ORD
                DECRB
                RET

;*****************************************************************************
;* _F32W_DW_SLOT makes the sector of the current slot current
;*
;* INPUT:  R8  session
;*         R9  directory walker
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, otherwise an error code
;*         R10 byte offset of the slot in the sector buffer
;*         R11, R12 unchanged
;*****************************************************************************
;
_F32W_DW_SLOT   INCRB
                MOVE    R9, R0
                MOVE    R11, R1
                MOVE    R12, R2
                MOVE    R0, R3
                ADD     FAT32$DW_POS, R3
                MOVE    @R3, R3                     ; R3: sector << 4 | slot
                MOVE    R0, R4
                ADD     FAT32$DW_CL_LO, R4
                MOVE    @R4++, R9
                MOVE    @R4, R10
                MOVE    R3, R11
                SHR     4, R11
                AND     0x0FFF, R11
                RSUB    _F32W_CLSEC, 1              ; R10|R9: LBA
                CMP     0xFFFF, R11
                RBRA    _F32W_DS_RD, !Z
                MOVE    FAT32$ERR_ILLEGAL_CLUS, R9
                RBRA    _F32W_DS_RET, 1
_F32W_DS_RD     RSUB    _F32W_SEC, 1
                MOVE    R3, R10
                AND     0x000F, R10
                SHL     5, R10
                AND     0x01E0, R10
_F32W_DS_RET    MOVE    R1, R11
                MOVE    R2, R12
                DECRB
                RET

;*****************************************************************************
;* _F32W_CLSEC: the LBA of sector R11 of the data cluster R10|R9 (session R8)
;* -> R10|R9; R11 = 0xFFFF if R10|R9 is not a data cluster. R8, R12 unchanged.
;*****************************************************************************
;
_F32W_CLSEC     INCRB
                RSUB    _F32W_ISDATA, 1
                RBRA    _F32W_CS_OK, C
                MOVE    0xFFFF, R11
                DECRB
                RET
_F32W_CS_OK     MOVE    R8, R0
                MOVE    R11, R1                     ; R1: sector
                MOVE    R12, R2
                MOVE    R9, R8                      ; (cluster - 2) * spc
                MOVE    R10, R9
                SUB     2, R8
                SUBC    0, R9
                MOVE    @R0, R10
                ADD     FAT32$DEV_SECT_PER_CLUS, R10
                MOVE    @R10, R10
                XOR     R11, R11
                RSUB    MTH$MULU32, 1               ; R11|R10|R9|R8
                MOVE    @R0, R3
                ADD     FAT32$DEV_CLUSTER_LO, R3
                ADD     @R3++, R8
                ADDC    @R3, R9
                ADD     R1, R8
                ADDC    0, R9
                MOVE    R1, R11
                MOVE    R8, R1                      ; (no 0xFFFF in R11 here:
                MOVE    R9, R10                     ; sectors are < 128)
                MOVE    R1, R9
                MOVE    R0, R8
                MOVE    R2, R12
                DECRB
                RET

;*****************************************************************************
;* _F32W_DW_NEXT moves a directory walker to the next slot
;*
;* At the end of the last cluster of the directory it either stops (R10 = 0)
;* or adds a new, zeroed cluster to the directory (R10 = 1).
;*
;* INPUT:  R8  session
;*         R9  directory walker
;*         R10 1: extend the directory if needed
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, FAT32$EOF at the end of the directory (R10 = 0),
;*             FAT32$ERR_DIRFULL after 65536 slots, otherwise an error code
;*         R10..R12 unchanged
;*****************************************************************************
;
_F32W_DW_NEXT   INCRB
                MOVE    R9, R0
                MOVE    R10, R1
                MOVE    R11, R2
                MOVE    R12, R3
                MOVE    R0, R4
                ADD     FAT32$DW_ORD, R4
                CMP     0xFFFF, @R4                 ; the last slot FAT allows
                RBRA    _F32W_DN_ORD, !Z
                MOVE    FAT32$ERR_DIRFULL, R9
                RBRA    _F32W_DN_RET, 1
_F32W_DN_ORD    ADD     1, @R4
                MOVE    R0, R5
                ADD     FAT32$DW_POS, R5
                ADD     1, @R5                      ; next slot ...
                MOVE    @R5, R6
                SHR     4, R6
                AND     0x0FFF, R6                  ; R6: sector
                MOVE    @R8, R7
                ADD     FAT32$DEV_SECT_PER_CLUS, R7
                CMP     @R7, R6                     ; ... still in the cluster?
                RBRA    _F32W_DN_OK, !Z

                ; the next cluster of the directory
                MOVE    0, @R5
                MOVE    R0, R6
                ADD     FAT32$DW_CL_LO, R6
                MOVE    @R6++, R9
                MOVE    @R6, R10
                RSUB    _F32W_FATGET, 1             ; R11|R10: next
                CMP     0, R9
                RBRA    _F32W_DN_RET, !Z
                MOVE    R10, R9
                MOVE    R11, R10
                RSUB    _F32W_ISDATA, 1
                RBRA    _F32W_DN_SET, C
                MOVE    FAT32$EOF, R9               ; the end: extend?
                CMP     0, R1
                RBRA    _F32W_DN_END, Z
                MOVE    R0, R6
                ADD     FAT32$DW_CL_LO, R6
                MOVE    @R6++, R9
                MOVE    @R6, R10
                RSUB    _F32W_ALLOC, 1              ; R11|R10: new cluster
                CMP     0, R9
                RBRA    _F32W_DN_END, !Z
                MOVE    R10, R6
                MOVE    R11, R7
                MOVE    R6, R9
                MOVE    R7, R10
                RSUB    _F32W_ZEROCL, 1
                CMP     0, R9
                RBRA    _F32W_DN_END, !Z
                MOVE    R6, R9
                MOVE    R7, R10
_F32W_DN_SET    MOVE    R0, R6
                ADD     FAT32$DW_CL_LO, R6
                MOVE    R9, @R6++
                MOVE    R10, @R6
_F32W_DN_OK     XOR     R9, R9
                RBRA    _F32W_DN_RET, 1
_F32W_DN_END    SUB     1, @R4                      ; stays on the last slot
                MOVE    R0, R5
                ADD     FAT32$DW_POS, R5
                MOVE    @R8, R7
                ADD     FAT32$DEV_SECT_PER_CLUS, R7
                MOVE    @R7, R7
                SHL     4, R7
                SUB     1, R7
                MOVE    R7, @R5
_F32W_DN_RET    MOVE    R1, R10
                MOVE    R2, R11
                MOVE    R3, R12
                DECRB
                RET

;*****************************************************************************
;* _F32W_ZEROCL fills the data cluster R10|R9 with zeros (session R8)
;* R9 = 0 if OK, otherwise an error code; R10..R12 unchanged.
;*****************************************************************************
;
_F32W_ZEROCL    INCRB
                MOVE    R9, R0                      ; R1|R0: the cluster
                MOVE    R10, R1
                MOVE    R11, R2
                MOVE    R12, R3
                XOR     R4, R4                      ; R4: sector
_F32W_ZC_SEC    RSUB    _F32W_FLUSH, 1              ; the old sector first
                CMP     0, R9
                RBRA    _F32W_ZC_RET, !Z
                MOVE    R8, R5                      ; the new one without
                ADD     FAT32$WS_LBA_LO, R5         ; reading it
                MOVE    R0, R9
                MOVE    R1, R10
                MOVE    R4, R11
                RSUB    _F32W_CLSEC, 1
                MOVE    R9, @R5++
                MOVE    R10, @R5++
                MOVE    1, @R5                      ; WS_DIRTY
                MOVE    R8, R6
                MOVE    @R8, R8
                XOR     R9, R9
                XOR     R10, R10
_F32W_ZC_B      RSUB    FAT32$WRITE_B, 1
                ADD     1, R9
                CMP     512, R9
                RBRA    _F32W_ZC_B, !Z
                MOVE    R6, R8
                ADD     1, R4
                MOVE    @R8, R7
                ADD     FAT32$DEV_SECT_PER_CLUS, R7
                CMP     @R7, R4
                RBRA    _F32W_ZC_SEC, !Z
                XOR     R9, R9
_F32W_ZC_RET    MOVE    R1, R10
                MOVE    R2, R11
                MOVE    R3, R12
                DECRB
                RET

;*****************************************************************************
;* THE DIRECTORY SCAN
;*
;* _F32W_SCAN goes through a directory once and looks for
;*   - an entry: by name (long or short name, ignoring case) or by the entry
;*     address of its short name entry;
;*   - a short name (11 bytes; used to make a new short name unique);
;*   - a run of free slots for a new entry.
;* Its scan block (FAT32$SB_SIZE words) holds the questions and the answers.
;* Names are zero-terminated strings with one ISO 8859-1 character per word.
;*****************************************************************************

FAT32$SB_DW             .EQU    0                   ; directory walker (6)
FAT32$SB_MODE           .EQU    6                   ; 1: by name, 2: by address
FAT32$SB_NAME           .EQU    7                   ; mode 1: the name
FAT32$SB_NLEN           .EQU    8                   ; (its length)
FAT32$SB_TEA            .EQU    9                   ; mode 2: entry address (3)
FAT32$SB_SFN            .EQU    12                  ; short name to look for
                                                    ; (11 words) or 0
FAT32$SB_NEED           .EQU    13                  ; free slots needed or 0
FAT32$SB_HIT            .EQU    14                  ; 1: the entry was found
FAT32$SB_E              .EQU    15                  ; its entry address (3)
FAT32$SB_L              .EQU    18                  ; address of its first
                                                    ; long name slot (3)
FAT32$SB_ATTR           .EQU    21                  ; its attributes,
FAT32$SB_FCL            .EQU    22                  ; first cluster (2),
FAT32$SB_FSZ            .EQU    24                  ; size (2)
FAT32$SB_SFNHIT         .EQU    26                  ; 1: the short name exists
FAT32$SB_RFOUND         .EQU    27                  ; 1: free slots found
FAT32$SB_R              .EQU    28                  ; where they start (3) and
FAT32$SB_RORD           .EQU    31                  ; the number of that slot
FAT32$SB_RLEN           .EQU    32                  ; free slots in a row
FAT32$SB_LSEQ           .EQU    33                  ; long name run: last seq.,
FAT32$SB_LCHK           .EQU    34                  ; its checksum,
FAT32$SB_LOK            .EQU    35                  ; 1: it matches the name,
FAT32$SB_LS             .EQU    36                  ; its first slot (3)
FAT32$SB_TMP            .EQU    39                  ; 11 words: a short name
FAT32$SB_IGNON          .EQU    50                  ; 1: by name, the entry at
FAT32$SB_IGNEA          .EQU    51                  ; SB_IGNEA (3) never matches
FAT32$SB_SIZE           .EQU    54

; the 13 characters of a long name slot: their byte offsets
_F32W_LFN_OFS   .DW     1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30

;*****************************************************************************
;* _F32W_UPC: R10 in upper case (ASCII and ISO 8859-1). Other registers kept.
;*****************************************************************************
;
_F32W_UPC       CMP     0x0061, R10                 ; below 'a'?
                RBRA    _F32W_UC_RET, N             ; (0x61 > R10)
                CMP     R10, 0x007A                 ; 'a' .. 'z'
                RBRA    _F32W_UC_UP, !N             ; (R10 <= 0x7A)
                CMP     0x00E0, R10                 ; 0x7B .. 0xDF
                RBRA    _F32W_UC_RET, N
                CMP     0x00F7, R10                 ; division sign
                RBRA    _F32W_UC_RET, Z
                CMP     R10, 0x00FE                 ; above 0xFE?
                RBRA    _F32W_UC_RET, N
_F32W_UC_UP     SUB     0x0020, R10
_F32W_UC_RET    RET

;*****************************************************************************
;* _F32W_EACPY: copy the entry address of the walker R9 to R10 (3 words).
;* Registers unchanged.
;*****************************************************************************
;
_F32W_EACPY     INCRB
                MOVE    R9, R0
                ADD     FAT32$DW_CL_LO, R0
                MOVE    R10, R1
                MOVE    @R0++, @R1++
                MOVE    @R0++, @R1++
                MOVE    @R0, @R1
                DECRB
                RET

;*****************************************************************************
;* _F32W_SCAN scans a directory
;*
;* INPUT:  R8  session
;*         R9  scan block (SB_MODE, SB_NAME or SB_TEA, SB_SFN, SB_NEED set)
;*         R10 low word of the first cluster of the directory
;*         R11 high word of the first cluster of the directory
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, otherwise an error code
;*         R10..R12 unchanged
;*         The scan stops at the entry it looks for (SB_HIT = 1). Otherwise it
;*         goes to the end of the directory; if SB_NEED free slots in a row
;*         were not found (SB_RFOUND = 0), SB_R/SB_RORD is where a new entry
;*         goes after the directory has grown: the first of the free slots at
;*         the end (SB_RLEN > 0) or behind the last slot (SB_RLEN = 0).
;*****************************************************************************
;
_F32W_SCAN      INCRB
                MOVE    R9, R0                      ; R0: scan block
                MOVE    R10, R1
                MOVE    R11, R2
                MOVE    R12, R3
                MOVE    R8, R7                      ; R7: session
                RSUB    _F32W_DW_START, 1
                MOVE    R0, R4                      ; clear the answers
                ADD     FAT32$SB_HIT, R4
                MOVE    FAT32$SB_TMP, R5
                SUB     FAT32$SB_HIT, R5
_F32W_SN_CLR    MOVE    0, @R4++
                SUB     1, R5
                RBRA    _F32W_SN_CLR, !Z
                XOR     R6, R6                      ; the length of the name
                MOVE    R0, R4
                ADD     FAT32$SB_MODE, R4
                CMP     1, @R4
                RBRA    _F32W_SN_NL0, !Z
                MOVE    R0, R4
                ADD     FAT32$SB_NAME, R4
                MOVE    @R4, R5
_F32W_SN_NL     CMP     0, @R5++
                RBRA    _F32W_SN_NL0, Z
                ADD     1, R6
                RBRA    _F32W_SN_NL, 1
_F32W_SN_NL0    MOVE    R0, R4
                ADD     FAT32$SB_NLEN, R4
                MOVE    R6, @R4

                ; ---- the slot: R4 = offset, R5 = first byte, R6 = attrib.
_F32W_SN_SLOT   MOVE    R7, R8
                MOVE    R0, R9
                RSUB    _F32W_DW_SLOT, 1
                CMP     0, R9
                RBRA    _F32W_SN_RET, !Z
                MOVE    R10, R4
                MOVE    @R7, R8
                MOVE    R4, R9
                RSUB    FAT32$READ_B, 1
                MOVE    R10, R5
                ADD     11, R9
                RSUB    FAT32$READ_B, 1
                MOVE    R10, R6
                CMP     0x00E5, R5
                RBRA    _F32W_SN_FREE, Z
                CMP     0, R5
                RBRA    _F32W_SN_USED, !Z

                ; a free slot: count it into the run of free slots
_F32W_SN_FREE   MOVE    R0, R8
                ADD     FAT32$SB_LSEQ, R8
                MOVE    0, @R8                      ; no long name run
                MOVE    R0, R8
                ADD     FAT32$SB_RFOUND, R8
                CMP     0, @R8
                RBRA    _F32W_SN_NEXT, !Z
                MOVE    R0, R8
                ADD     FAT32$SB_RLEN, R8
                CMP     0, @R8
                RBRA    _F32W_SN_RL, !Z
                MOVE    R0, R9                      ; the run starts here
                MOVE    R0, R10
                ADD     FAT32$SB_R, R10
                RSUB    _F32W_EACPY, 1
                MOVE    R0, R9
                ADD     FAT32$DW_ORD, R9
                MOVE    R0, R10
                ADD     FAT32$SB_RORD, R10
                MOVE    @R9, @R10
_F32W_SN_RL     ADD     1, @R8
                MOVE    R0, R9
                ADD     FAT32$SB_NEED, R9
                CMP     0, @R9
                RBRA    _F32W_SN_NEXT, Z
                CMP     @R9, @R8                    ; NEED > RLEN?
                RBRA    _F32W_SN_NEXT, N
                MOVE    R0, R8
                ADD     FAT32$SB_RFOUND, R8
                MOVE    1, @R8
                RBRA    _F32W_SN_NEXT, 1

                ; a slot in use breaks a run of free slots
_F32W_SN_USED   MOVE    R0, R8
                ADD     FAT32$SB_RFOUND, R8
                CMP     0, @R8
                RBRA    _F32W_SN_U1, !Z
                MOVE    R0, R8
                ADD     FAT32$SB_RLEN, R8
                MOVE    0, @R8
_F32W_SN_U1     MOVE    R6, R8
                AND     0x003F, R8
                CMP     0x000F, R8
                RBRA    _F32W_SN_SFN, !Z

                ; a long name slot
                MOVE    @R7, R8
                MOVE    R4, R9
                ADD     13, R9
                RSUB    FAT32$READ_B, 1             ; R10: its checksum
                MOVE    R0, R11
                ADD     FAT32$SB_LSEQ, R11          ; R11: SB_LSEQ
                MOVE    R5, R12
                AND     0x001F, R12                 ; R12: sequence number
                MOVE    R5, R8
                AND     0x0040, R8
                RBRA    _F32W_SN_LCONT, Z
                MOVE    R12, @R11++                 ; the last part (the
                MOVE    R10, @R11++                 ; first slot of the run)
                MOVE    0, @R11                     ; SB_LOK
                MOVE    R0, R8
                ADD     FAT32$SB_MODE, R8
                CMP     1, @R8
                RBRA    _F32W_SN_LS, !Z
                MOVE    1, @R11
_F32W_SN_LS     MOVE    R0, R9
                MOVE    R0, R10
                ADD     FAT32$SB_LS, R10
                RSUB    _F32W_EACPY, 1
                CMP     0, R12
                RBRA    _F32W_SN_LCMP, !Z
                MOVE    0, @R11                     ; seq. 0: no run
                SUB     2, R11
                MOVE    0, @R11
                RBRA    _F32W_SN_NEXT, 1
_F32W_SN_LCONT  CMP     0, @R11                     ; continues the run?
                RBRA    _F32W_SN_LBAD, Z
                MOVE    @R11, R8
                SUB     1, R8
                CMP     R8, R12
                RBRA    _F32W_SN_LBAD, !Z
                MOVE    R11, R8
                ADD     1, R8
                CMP     @R8, R10
                RBRA    _F32W_SN_LBAD, !Z
                MOVE    R12, @R11
                RBRA    _F32W_SN_LCMP, 1
_F32W_SN_LBAD   MOVE    0, @R11
                RBRA    _F32W_SN_NEXT, 1
_F32W_SN_LCMP   MOVE    R0, R8
                ADD     FAT32$SB_LOK, R8
                CMP     0, @R8
                RBRA    _F32W_SN_NEXT, Z
                MOVE    @R7, R8
                MOVE    R4, R9
                MOVE    R12, R10
                MOVE    R5, R11
                AND     0x0040, R11
                MOVE    R0, R12
                RSUB    _F32W_LFNCMP, 1
                RBRA    _F32W_SN_NEXT, 1

                ; a short name slot: its 11 bytes to SB_TMP
_F32W_SN_SFN    MOVE    @R7, R8
                MOVE    R4, R9
                MOVE    R0, R11
                ADD     FAT32$SB_TMP, R11
                MOVE    11, R12
_F32W_SN_CP     RSUB    FAT32$READ_B, 1
                MOVE    R10, @R11++
                ADD     1, R9
                SUB     1, R12
                RBRA    _F32W_SN_CP, !Z

                ; the short name to look for?
                MOVE    R0, R8
                ADD     FAT32$SB_SFN, R8
                MOVE    @R8, R9
                CMP     0, R9
                RBRA    _F32W_SN_LV, Z
                MOVE    R6, R8
                AND     FAT32$FA_VOLUME_ID, R8
                RBRA    _F32W_SN_LV, !Z
                MOVE    R0, R10
                ADD     FAT32$SB_TMP, R10
                MOVE    11, R12
_F32W_SN_SC     CMP     @R9++, @R10++
                RBRA    _F32W_SN_LV, !Z
                SUB     1, R12
                RBRA    _F32W_SN_SC, !Z
                MOVE    R0, R8
                ADD     FAT32$SB_SFNHIT, R8
                MOVE    1, @R8

                ; a valid long name run belongs to it: R12 = 1
_F32W_SN_LV     XOR     R12, R12
                MOVE    R0, R8
                ADD     FAT32$SB_LSEQ, R8
                CMP     1, @R8
                RBRA    _F32W_SN_HIT, !Z
                MOVE    R0, R8
                ADD     FAT32$SB_TMP, R8
                RSUB    FAT32$CHECKSUM, 1
                MOVE    R0, R9
                ADD     FAT32$SB_LCHK, R9
                CMP     @R9, R8
                RBRA    _F32W_SN_HIT, !Z
                MOVE    1, R12

                ; is it the entry?
_F32W_SN_HIT    MOVE    R0, R8
                ADD     FAT32$SB_LSEQ, R8
                MOVE    0, @R8                      ; the run is used up
                MOVE    R0, R8
                ADD     FAT32$SB_MODE, R8
                CMP     2, @R8
                RBRA    _F32W_SN_BYN, !Z
                MOVE    R0, R8                      ; by address
                ADD     FAT32$DW_CL_LO, R8
                MOVE    R0, R9
                ADD     FAT32$SB_TEA, R9
                CMP     @R8++, @R9++
                RBRA    _F32W_SN_NEXT, !Z
                CMP     @R8++, @R9++
                RBRA    _F32W_SN_NEXT, !Z
                CMP     @R8, @R9
                RBRA    _F32W_SN_NEXT, !Z
                RBRA    _F32W_SN_FND, 1
_F32W_SN_BYN    MOVE    R6, R8                      ; by name, not the label:
                AND     FAT32$FA_VOLUME_ID, R8      ; the long name or the
                RBRA    _F32W_SN_NEXT, !Z           ; short name (like Windows)
                MOVE    R0, R8                      ; (not the entry to ignore)
                ADD     FAT32$SB_IGNON, R8
                CMP     0, @R8++
                RBRA    _F32W_SN_BYI, Z
                MOVE    R0, R9
                ADD     FAT32$DW_CL_LO, R9
                CMP     @R8++, @R9++
                RBRA    _F32W_SN_BYI, !Z
                CMP     @R8++, @R9++
                RBRA    _F32W_SN_BYI, !Z
                CMP     @R8, @R9
                RBRA    _F32W_SN_NEXT, Z
_F32W_SN_BYI    CMP     0, R12
                RBRA    _F32W_SN_BYS, Z
                MOVE    R0, R8
                ADD     FAT32$SB_LOK, R8
                CMP     0, @R8
                RBRA    _F32W_SN_FND, !Z
_F32W_SN_BYS    MOVE    R12, @--SP
                MOVE    R0, R12
                RSUB    _F32W_SFNCMP, 1
                MOVE    @SP++, R12
                RBRA    _F32W_SN_NEXT, !C

                ; found: its address, the start of its long name, its data
_F32W_SN_FND    MOVE    R0, R8
                ADD     FAT32$SB_HIT, R8
                MOVE    1, @R8
                MOVE    R0, R9
                MOVE    R0, R10
                ADD     FAT32$SB_E, R10
                RSUB    _F32W_EACPY, 1
                MOVE    R0, R10
                ADD     FAT32$SB_L, R10
                RSUB    _F32W_EACPY, 1
                CMP     0, R12
                RBRA    _F32W_SN_FD, Z
                MOVE    R0, R8
                ADD     FAT32$SB_LS, R8
                MOVE    @R8++, @R10++
                MOVE    @R8++, @R10++
                MOVE    @R8, @R10
_F32W_SN_FD     MOVE    R0, R5
                ADD     FAT32$SB_ATTR, R5
                MOVE    R6, @R5++
                MOVE    @R7, R8
                MOVE    R4, R9
                ADD     26, R9
                RSUB    FAT32$READ_W, 1
                MOVE    R10, @R5++                  ; SB_FCL low
                SUB     6, R9
                RSUB    FAT32$READ_W, 1
                MOVE    R10, @R5++                  ; SB_FCL high
                ADD     8, R9
                RSUB    FAT32$READ_DW, 1
                MOVE    R10, @R5++                  ; SB_FSZ
                MOVE    R11, @R5
                RBRA    _F32W_SN_DONE, 1

                ; the next slot
_F32W_SN_NEXT   MOVE    R7, R8
                MOVE    R0, R9
                XOR     R10, R10
                RSUB    _F32W_DW_NEXT, 1
                CMP     0, R9
                RBRA    _F32W_SN_SLOT, Z
                CMP     FAT32$EOF, R9
                RBRA    _F32W_SN_RET, !Z

                ; the end of the directory: where would a new entry go?
                MOVE    R0, R8
                ADD     FAT32$SB_RFOUND, R8
                CMP     0, @R8
                RBRA    _F32W_SN_DONE, !Z
                MOVE    R0, R8
                ADD     FAT32$SB_RLEN, R8
                CMP     0, @R8
                RBRA    _F32W_SN_DONE, !Z
                MOVE    R0, R9                      ; behind the last slot
                MOVE    R0, R10
                ADD     FAT32$SB_R, R10
                RSUB    _F32W_EACPY, 1
                MOVE    R0, R9
                ADD     FAT32$DW_ORD, R9
                MOVE    R0, R10
                ADD     FAT32$SB_RORD, R10
                MOVE    @R9, @R10
_F32W_SN_DONE   XOR     R9, R9
_F32W_SN_RET    MOVE    R7, R8
                MOVE    R1, R10
                MOVE    R2, R11
                MOVE    R3, R12
                DECRB
                RET

;*****************************************************************************
;* _F32W_LFNCMP compares one long name slot with the name of a scan block
;*
;* Clears SB_LOK if the 13 characters of the slot do not match the name at
;* their position ((sequence - 1) * 13), ignoring case.
;*
;* INPUT:  R8  device handle (the slot is in the sector buffer)
;*         R9  byte offset of the slot
;*         R10 sequence number (1..20)
;*         R11 not 0: this slot holds the end of the name
;*         R12 scan block
;* OUTPUT: R8..R12 unchanged
;*****************************************************************************
;
_F32W_LFNCMP    MOVE    R10, @--SP
                MOVE    R11, @--SP
                INCRB
                MOVE    R9, R0                      ; R0: slot offset
                MOVE    R10, R1
                MOVE    R11, R2                     ; R2: end flag
                MOVE    R12, R3                     ; R3: scan block
                MOVE    R1, R4                      ; R4: position in name
                SUB     1, R4                       ; (seq - 1) * 13
                MOVE    R4, R5
                SHL     2, R5
                AND     0xFFFC, R5
                ADD     R5, R4
                ADD     R5, R4
                ADD     R5, R4                      ; R4 = (seq - 1) * 13
                MOVE    R3, R5
                ADD     FAT32$SB_NLEN, R5
                MOVE    @R5, R5                     ; R5: name length
                MOVE    R3, R6
                ADD     FAT32$SB_NAME, R6
                MOVE    @R6, R6
                ADD     R4, R6                      ; R6: name at R4
                MOVE    _F32W_LFN_OFS, R7
                MOVE    13, R1                      ; R1: characters left
_F32W_LC_L      MOVE    R0, R9
                ADD     @R7++, R9
                RSUB    FAT32$READ_W, 1             ; R10: the character
                CMP     0xFFFF, R10                 ; padding
                RBRA    _F32W_LC_N, Z
                CMP     0, R10                      ; the end of the name
                RBRA    _F32W_LC_C, !Z
                CMP     R4, R5                      ; ... at the name's end?
                RBRA    _F32W_LC_NO, !Z
                RBRA    _F32W_LC_RET, 1             ; (the rest is padding)
_F32W_LC_C      CMP     R5, R4                      ; past the name's end?
                RBRA    _F32W_LC_NO, !N             ; (R4 >= R5)
                CMP     R10, 0x00FF                 ; not ISO 8859-1
                RBRA    _F32W_LC_NO, N              ; (R10 > 0xFF)
                RSUB    _F32W_UPC, 1
                MOVE    R10, R11
                MOVE    @R6, R10
                RSUB    _F32W_UPC, 1
                CMP     R10, R11
                RBRA    _F32W_LC_NO, !Z
_F32W_LC_N      ADD     1, R4
                ADD     1, R6
                SUB     1, R1
                RBRA    _F32W_LC_L, !Z
                CMP     0, R2                       ; the end slot without a
                RBRA    _F32W_LC_RET, Z             ; terminator: the name
                CMP     R4, R5                      ; ends exactly here?
                RBRA    _F32W_LC_RET, Z
_F32W_LC_NO     MOVE    R3, R8
                ADD     FAT32$SB_LOK, R8
                MOVE    0, @R8
_F32W_LC_RET    MOVE    R0, R9
                MOVE    R3, R12
                DECRB
                MOVE    @SP++, R11
                MOVE    @SP++, R10
                RET

;*****************************************************************************
;* _F32W_SFNCMP: C = 1 if the short name in SB_TMP of the scan block R12,
;* written as "NAME.EXT", is the name of the scan block (ignoring case).
;* R8..R12 unchanged.
;*****************************************************************************
;
_F32W_SFNCMP    INCRB
                MOVE    R10, R0
                MOVE    R11, R1
                MOVE    R12, R2
                MOVE    R12, R3
                ADD     FAT32$SB_TMP, R3            ; R3: the 11 bytes
                MOVE    R12, R4
                ADD     FAT32$SB_NAME, R4
                MOVE    @R4, R4                     ; R4: the name
                MOVE    8, R5                       ; the base name
                MOVE    R3, R6
_F32W_SC_B      MOVE    @R6++, R10
                CMP     0x0020, R10
                RBRA    _F32W_SC_BE, Z
                CMP     0x0005, R10                 ; (0x05 stands for 0xE5)
                RBRA    _F32W_SC_B1, !Z
                MOVE    0x00E5, R10
_F32W_SC_B1     RSUB    _F32W_SC_CH, 1
                RBRA    _F32W_SC_NO, !C
                SUB     1, R5
                RBRA    _F32W_SC_B, !Z
_F32W_SC_BE     MOVE    R3, R6                      ; the extension
                ADD     8, R6
                CMP     0x0020, @R6
                RBRA    _F32W_SC_END, Z
                MOVE    0x002E, R10                 ; "."
                RSUB    _F32W_SC_CH, 1
                RBRA    _F32W_SC_NO, !C
                MOVE    3, R5
_F32W_SC_E      MOVE    @R6++, R10
                CMP     0x0020, R10
                RBRA    _F32W_SC_END, Z
                RSUB    _F32W_SC_CH, 1
                RBRA    _F32W_SC_NO, !C
                SUB     1, R5
                RBRA    _F32W_SC_E, !Z
_F32W_SC_END    CMP     0, @R4                      ; the name ends, too?
                RBRA    _F32W_SC_NO, !Z
                MOVE    R0, R10
                MOVE    R1, R11
                MOVE    R2, R12
                OR      0x0004, SR                  ; C = 1
                DECRB
                RET
_F32W_SC_NO     MOVE    R0, R10
                MOVE    R1, R11
                MOVE    R2, R12
                AND     0xFFFB, SR                  ; C = 0
                DECRB
                RET

; _F32W_SC_CH: C = 1 if R10 equals @R4 ignoring case; then R4 + 1. R11 used.
_F32W_SC_CH     CMP     0, @R4
                RBRA    _F32W_SH_NO, Z
                RSUB    _F32W_UPC, 1
                MOVE    R10, R11
                MOVE    @R4, R10
                RSUB    _F32W_UPC, 1
                CMP     R10, R11
                RBRA    _F32W_SH_NO, !Z
                ADD     1, R4
                OR      0x0004, SR
                RET
_F32W_SH_NO     AND     0xFFFB, SR
                RET

;*****************************************************************************
;* CREATE, DELETE AND CHANGE DIRECTORY ENTRIES
;*
;* The public functions take a parameter block (FAT32$PB_SIZE words; it also
;* holds the write session, the scan block and a short name).
;*****************************************************************************

FAT32$PB_DEV            .EQU    0                   ; device handle
FAT32$PB_DIR_LO         .EQU    1                   ; first cluster of the
FAT32$PB_DIR_HI         .EQU    2                   ; directory
FAT32$PB_NAME           .EQU    3                   ; name (create)
FAT32$PB_ATTR           .EQU    4                   ; attributes (create, set)
FAT32$PB_FLAGS          .EQU    4                   ; flags (delete, set)
FAT32$PB_DATE           .EQU    5                   ; FAT date (create, set)
FAT32$PB_TIME           .EQU    6                   ; FAT time (create, set)
FAT32$PB_CL_LO          .EQU    7                   ; first cluster of the
FAT32$PB_CL_HI          .EQU    8                   ; entry (create, set)
FAT32$PB_SZ_LO          .EQU    9                   ; size (create, set)
FAT32$PB_SZ_HI          .EQU    10
FAT32$PB_EA             .EQU    11                  ; entry address (3)
FAT32$PB_WS             .EQU    14                  ; write session
FAT32$PB_SB             .EQU    20                  ; scan block
FAT32$PB_SFN            .EQU    74                  ; short name (11 words)
FAT32$PB_BASIS          .EQU    85                  ; its basis (11 words)
FAT32$PB_DIR2_LO        .EQU    96                  ; rename: target directory
FAT32$PB_DIR2_HI        .EQU    97
FAT32$PB_OLDEA          .EQU    98                  ; rename: old address (3)
FAT32$PB_RAW            .EQU    101                 ; rename: entry bytes 11..31
FAT32$PB_IGN            .EQU    122                 ; create: 1 = ignore the
                                                    ; entry at PB_OLDEA
FAT32$PB_SIZE           .EQU    123

; flags of FAT32$W_DELETE
FAT32$WDF_FREE          .EQU    0x0001              ; free the cluster chain
; flags of FAT32$W_SETDE: the fields to set
FAT32$WSF_SIZE          .EQU    0x0001
FAT32$WSF_CLUS          .EQU    0x0002
FAT32$WSF_ATTR          .EQU    0x0004
FAT32$WSF_TIME          .EQU    0x0008              ; date and time of the
                                                    ; last write

;*****************************************************************************
;* _F32W_CREATE creates a directory entry
;*
;* The entry gets a long name (unless the name is a short name in upper case)
;* and a unique short name. Its creation, last write and last access dates
;* are PB_DATE/PB_TIME, its first cluster and size PB_CL and PB_SZ.
;*
;* INPUT:  R8  parameter block: PB_DEV, PB_DIR, PB_NAME, PB_ATTR, PB_DATE,
;*             PB_TIME, PB_CL, PB_SZ
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, FAT32$ERR_NAME, FAT32$ERR_EXISTS, FAT32$ERR_DIRFULL,
;*             FAT32$ERR_DISKFULL or another error code
;*         PB_EA: the entry address of the new entry
;*         R10..R12 unchanged
;*****************************************************************************
;
_F32W_CREATE  INCRB
                MOVE    R8, R0                      ; R0: parameter block
                MOVE    R10, R1
                MOVE    R11, R2
                MOVE    R12, R3

                ; the name and its short name: R4 = long name slots needed
                RSUB    _F32W_MKSFN, 1              ; R9 = error, R10 = lossy
                CMP     0, R9
                RBRA    _F32W_CR_RET, !Z
                MOVE    R11, R4                     ; R11: long name slots
                MOVE    R10, R5                     ; R5: lossy

                MOVE    R0, R8                      ; the session
                ADD     FAT32$PB_WS, R8
                MOVE    @R0, R9
                RSUB    _F32W_BEGIN, 1
                CMP     0, R9
                RBRA    _F32W_CR_RET, !Z
                MOVE    R8, R7                      ; R7: session
                MOVE    R0, R6
                ADD     FAT32$PB_SB, R6             ; R6: scan block

                ; does it exist? Is the short name taken? Where does it go?
                XOR     R12, R12                    ; R12: numeric tail
_F32W_CR_SCAN   MOVE    R0, R8                      ; the entry to ignore
                ADD     FAT32$PB_IGN, R8
                MOVE    R6, R9
                ADD     FAT32$SB_IGNON, R9
                MOVE    @R8, @R9++
                MOVE    R0, R8
                ADD     FAT32$PB_OLDEA, R8
                MOVE    @R8++, @R9++
                MOVE    @R8++, @R9++
                MOVE    @R8, @R9
                MOVE    R6, R8
                ADD     FAT32$SB_MODE, R8
                MOVE    1, @R8++                    ; by name
                MOVE    R0, R9
                ADD     FAT32$PB_NAME, R9
                MOVE    @R9, @R8                    ; SB_NAME
                MOVE    R6, R8
                ADD     FAT32$SB_SFN, R8
                MOVE    R0, R9
                ADD     FAT32$PB_SFN, R9
                MOVE    R9, @R8++                   ; SB_SFN
                MOVE    R4, @R8                     ; SB_NEED = slots + 1
                ADD     1, @R8
                MOVE    R7, R8
                MOVE    R6, R9
                MOVE    R0, R10
                ADD     FAT32$PB_DIR_LO, R10
                MOVE    @R10, R10
                MOVE    R0, R11
                ADD     FAT32$PB_DIR_HI, R11
                MOVE    @R11, R11
                RSUB    _F32W_SCAN, 1
                CMP     0, R9
                RBRA    _F32W_CR_END, !Z
                MOVE    R6, R8
                ADD     FAT32$SB_HIT, R8
                CMP     0, @R8
                RBRA    _F32W_CR_NEW, Z
                MOVE    FAT32$ERR_EXISTS, R9
                RBRA    _F32W_CR_END, 1
_F32W_CR_NEW    CMP     0, R5                       ; a lossy short name gets
                RBRA    _F32W_CR_TL, !Z             ; a numeric tail; a short
                MOVE    R6, R8                      ; name that is taken, too
                ADD     FAT32$SB_SFNHIT, R8
                CMP     0, @R8
                RBRA    _F32W_CR_PUT, Z
_F32W_CR_TL     MOVE    R6, R8                      ; a short name that is
                ADD     FAT32$SB_SFNHIT, R8         ; free (with this tail)
                CMP     0, @R8
                RBRA    _F32W_CR_TLN, !Z
                CMP     0, R12
                RBRA    _F32W_CR_PUT, !Z
_F32W_CR_TLN    ADD     1, R12
                CMP     0, R4                       ; a short name that gets a
                RBRA    _F32W_CR_TL2, !Z            ; tail needs a long name
                MOVE    R0, R8                      ; to keep its exact name:
                ADD     FAT32$PB_NAME, R8           ; ceil(length / 13) slots
                MOVE    @R8, R8
                MOVE    12, R4
_F32W_CR_LN     CMP     0, @R8++
                RBRA    _F32W_CR_LD, Z
                ADD     1, R4
                RBRA    _F32W_CR_LN, 1
_F32W_CR_LD     MOVE    R4, R8
                XOR     R4, R4
_F32W_CR_LDV    CMP     13, R8
                RBRA    _F32W_CR_TL2, N             ; (13 > R8)
                SUB     13, R8
                ADD     1, R4
                RBRA    _F32W_CR_LDV, 1
_F32W_CR_TL2    CMP     10000, R12
                RBRA    _F32W_CR_TLO, !Z
                MOVE    FAT32$ERR_DIRFULL, R9
                RBRA    _F32W_CR_END, 1
_F32W_CR_TLO    MOVE    R0, R8
                MOVE    R12, R9
                RSUB    _F32W_TAIL, 1
                RBRA    _F32W_CR_SCAN, 1

                ; write the entry: the long name slots, then the short name
_F32W_CR_PUT    MOVE    R6, R10                     ; the walker goes to the
                                                    ; place the scan found
                ADD     FAT32$DW_CL_LO, R10
                MOVE    R6, R9
                ADD     FAT32$SB_R, R9
                MOVE    @R9++, @R10++
                MOVE    @R9++, @R10++
                MOVE    @R9++, @R10++               ; DW_POS
                MOVE    @R9, @R10                   ; DW_ORD = SB_RORD
                MOVE    R6, R8
                ADD     FAT32$SB_RFOUND, R8
                CMP     0, @R8
                RBRA    _F32W_CR_W, !Z
                MOVE    R6, R8
                ADD     FAT32$SB_RLEN, R8
                CMP     0, @R8
                RBRA    _F32W_CR_W, !Z
                MOVE    R7, R8                      ; behind the last slot
                MOVE    R6, R9
                MOVE    1, R10
                RSUB    _F32W_DW_NEXT, 1
                CMP     0, R9
                RBRA    _F32W_CR_END, !Z
_F32W_CR_W      MOVE    R0, R8                      ; the checksum
                ADD     FAT32$PB_SFN, R8
                RSUB    FAT32$CHECKSUM, 1
                MOVE    R8, R5                      ; R5: checksum
_F32W_CR_LL     CMP     0, R4
                RBRA    _F32W_CR_S, Z
                MOVE    R7, R8
                MOVE    R6, R9
                RSUB    _F32W_DW_SLOT, 1
                CMP     0, R9
                RBRA    _F32W_CR_END, !Z
                MOVE    R0, R8
                MOVE    R10, R9                     ; slot offset
                MOVE    R4, R10                     ; sequence number
                MOVE    R5, R11                     ; checksum
                RSUB    _F32W_PUTLFN, 1
                MOVE    R7, R8
                MOVE    R6, R9
                MOVE    1, R10
                RSUB    _F32W_DW_NEXT, 1
                CMP     0, R9
                RBRA    _F32W_CR_END, !Z
                SUB     1, R4
                RBRA    _F32W_CR_LL, 1
_F32W_CR_S      MOVE    R7, R8
                MOVE    R6, R9
                RSUB    _F32W_DW_SLOT, 1
                CMP     0, R9
                RBRA    _F32W_CR_END, !Z
                MOVE    R0, R8
                MOVE    R10, R9
                RSUB    _F32W_PUTSFN, 1
                MOVE    R6, R9                      ; its entry address
                MOVE    R0, R10
                ADD     FAT32$PB_EA, R10
                RSUB    _F32W_EACPY, 1
                XOR     R9, R9
_F32W_CR_END    MOVE    R9, R4                      ; the first error counts
                MOVE    R7, R8
                RSUB    _F32W_END, 1
                CMP     0, R4
                RBRA    _F32W_CR_RET, Z
                MOVE    R4, R9
_F32W_CR_RET    MOVE    R0, R8
                MOVE    R1, R10
                MOVE    R2, R11
                MOVE    R3, R12
                DECRB
                RET

; the characters a short name may contain besides A-Z and 0-9
_F32W_SFNOK     .DW     0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29  ; !#$%&'()
                .DW     0x2D, 0x40, 0x5E, 0x5F, 0x60, 0x7B, 0x7D, 0x7E  ; -@^_`{}~
                .DW     0
; the characters a long name must not contain (besides 0x00-0x1F)
_F32W_LFNBAD    .DW     0x22, 0x2A, 0x2F, 0x3A, 0x3C, 0x3E, 0x3F, 0x5C  ; " * / : < > ? backslash
                .DW     0x7C, 0                                         ; |

;*****************************************************************************
;* _F32W_INSTR: C = 1 if R10 is one of the characters of the string R11.
;* Registers unchanged.
;*****************************************************************************
;
_F32W_INSTR     INCRB
                MOVE    R11, R0
_F32W_IS_L      CMP     0, @R0
                RBRA    _F32W_IS_NO, Z
                CMP     @R0++, R10
                RBRA    _F32W_IS_L, !Z
                DECRB
                OR      0x0004, SR
                RET
_F32W_IS_NO     DECRB
                AND     0xFFFB, SR
                RET

;*****************************************************************************
;* _F32W_SFNCH: R10 (upper case) as a character of a short name: R10 itself,
;* or '_' and C = 1 if it cannot be in a short name. Other registers kept.
;*****************************************************************************
;
_F32W_SFNCH     MOVE    R11, @--SP
                CMP     0x0041, R10                 ; 'A' .. 'Z'
                RBRA    _F32W_SH_D, N
                CMP     R10, 0x005A
                RBRA    _F32W_SH_OK, !N
_F32W_SH_D      CMP     0x0030, R10                 ; '0' .. '9'
                RBRA    _F32W_SH_X, N
                CMP     R10, 0x0039
                RBRA    _F32W_SH_OK, !N
_F32W_SH_X      MOVE    _F32W_SFNOK, R11
                RSUB    _F32W_INSTR, 1
                RBRA    _F32W_SH_OK, C
                MOVE    0x005F, R10                 ; '_'
                MOVE    @SP++, R11
                OR      0x0004, SR
                RET
_F32W_SH_OK     MOVE    @SP++, R11
                AND     0xFFFB, SR
                RET

;*****************************************************************************
;* _F32W_MKSFN checks the name of a parameter block and makes its short name
;*
;* PB_BASIS and PB_SFN := the basis of the short name: upper case, without
;* spaces and leading dots, characters a short name cannot hold replaced by
;* '_', cut to 8 + 3 characters.
;*
;* INPUT:  R8  parameter block
;* OUTPUT: R8  unchanged
;*         R9  0 or FAT32$ERR_NAME
;*         R10 1: the basis lost something (it needs a numeric tail)
;*         R11 the number of long name slots (0: the name is a short name)
;*         R12 unchanged
;*****************************************************************************
;
_F32W_MKSFN     INCRB
                MOVE    R8, R0                      ; R0: parameter block
                MOVE    R12, R7
                MOVE    R0, R1
                ADD     FAT32$PB_NAME, R1
                MOVE    @R1, R1                     ; R1: the name

                ; check it: R2 = length, R3 = position of the last dot
                XOR     R2, R2
                MOVE    0xFFFF, R3
                XOR     R4, R4                      ; R4: 1 = not a short name
                MOVE    R1, R5
_F32W_MK_CHK    MOVE    @R5++, R10
                CMP     0, R10
                RBRA    _F32W_MK_CE, Z
                CMP     0x0020, R10                 ; control characters
                RBRA    _F32W_MK_BAD, N
                CMP     R10, 0x00FF
                RBRA    _F32W_MK_BAD, N
                MOVE    _F32W_LFNBAD, R11
                RSUB    _F32W_INSTR, 1
                RBRA    _F32W_MK_BAD, C
                CMP     0x002E, R10                 ; "."
                RBRA    _F32W_MK_C1, !Z
                MOVE    R2, R3
_F32W_MK_C1     MOVE    R10, R11                    ; lower case or a char a
                RSUB    _F32W_UPC, 1                ; short name cannot hold:
                CMP     R10, R11                    ; not a short name
                RBRA    _F32W_MK_C2, Z
                MOVE    1, R4
_F32W_MK_C2     CMP     0x002E, R10
                RBRA    _F32W_MK_C3, Z
                RSUB    _F32W_SFNCH, 1
                RBRA    _F32W_MK_C3, !C
                MOVE    1, R4
_F32W_MK_C3     ADD     1, R2
                CMP     256, R2
                RBRA    _F32W_MK_CHK, !Z
                RBRA    _F32W_MK_BAD, 1             ; longer than 255
_F32W_MK_CE     CMP     0, R2                       ; empty
                RBRA    _F32W_MK_BAD, Z
                MOVE    R1, R5                      ; ends with "." or " "
                ADD     R2, R5
                SUB     1, R5
                CMP     0x002E, @R5
                RBRA    _F32W_MK_BAD, Z
                CMP     0x0020, @R5
                RBRA    _F32W_MK_BAD, Z

                ; a short name? base 1..8, at most one dot, extension 1..3
                CMP     0xFFFF, R3                  ; no dot
                RBRA    _F32W_MK_DOT, !Z
                CMP     R2, 8
                RBRA    _F32W_MK_SH, !N
                MOVE    1, R4
                RBRA    _F32W_MK_SH, 1
_F32W_MK_DOT    CMP     0, R3                       ; ".x": no base
                RBRA    _F32W_MK_D1, !Z
                MOVE    1, R4
_F32W_MK_D1     CMP     R3, 8
                RBRA    _F32W_MK_D2, !N
                MOVE    1, R4
_F32W_MK_D2     MOVE    R2, R5                      ; extension: 1..3 chars
                SUB     R3, R5
                SUB     1, R5
                CMP     R5, 3
                RBRA    _F32W_MK_D3, !N
                MOVE    1, R4
_F32W_MK_D3     MOVE    R1, R5                      ; one dot only
                XOR     R6, R6
_F32W_MK_D4     CMP     0, @R5
                RBRA    _F32W_MK_D5, Z
                CMP     0x002E, @R5++
                RBRA    _F32W_MK_D4, !Z
                ADD     1, R6
                RBRA    _F32W_MK_D4, 1
_F32W_MK_D5     CMP     1, R6
                RBRA    _F32W_MK_SH, Z
                MOVE    1, R4

                ; the basis: R5 = source, R6 = target, R9 = lossy
_F32W_MK_SH     XOR     R9, R9
                MOVE    R0, R6
                ADD     FAT32$PB_BASIS, R6
                MOVE    R6, R8                      ; all spaces first
                MOVE    11, R10
_F32W_MK_SP     MOVE    0x0020, @R8++
                SUB     1, R10
                RBRA    _F32W_MK_SP, !Z
                MOVE    R1, R5
_F32W_MK_LD     CMP     0x002E, @R5                 ; leading dots are lost
                RBRA    _F32W_MK_B, !Z
                ADD     1, R5
                MOVE    1, R9
                RBRA    _F32W_MK_LD, 1
_F32W_MK_B      MOVE    8, R12                      ; R12: room in the base
_F32W_MK_BL     MOVE    R5, R8                      ; at the last dot: the
                SUB     R1, R8                      ; extension
                CMP     R8, R3
                RBRA    _F32W_MK_EXT, Z
                MOVE    @R5++, R10
                CMP     0, R10
                RBRA    _F32W_MK_DONE, Z
                CMP     0x0020, R10                 ; spaces and dots are lost
                RBRA    _F32W_MK_BX, Z
                CMP     0x002E, R10
                RBRA    _F32W_MK_BX, Z
                RSUB    _F32W_UPC, 1
                RSUB    _F32W_SFNCH, 1
                RBRA    _F32W_MK_B1, !C
                MOVE    1, R9
_F32W_MK_B1     CMP     0, R12                      ; base full: lost
                RBRA    _F32W_MK_BX, Z
                MOVE    R10, @R6++
                SUB     1, R12
                RBRA    _F32W_MK_BL, 1
_F32W_MK_BX     MOVE    1, R9
                RBRA    _F32W_MK_BL, 1
_F32W_MK_EXT    ADD     1, R5                       ; behind the dot
                MOVE    R0, R6
                ADD     FAT32$PB_BASIS, R6
                ADD     8, R6
                MOVE    3, R12
_F32W_MK_EL     MOVE    @R5++, R10
                CMP     0, R10
                RBRA    _F32W_MK_DONE, Z
                CMP     0x0020, R10
                RBRA    _F32W_MK_EX, Z
                RSUB    _F32W_UPC, 1
                RSUB    _F32W_SFNCH, 1
                RBRA    _F32W_MK_E1, !C
                MOVE    1, R9
_F32W_MK_E1     CMP     0, R12
                RBRA    _F32W_MK_EX, Z
                MOVE    R10, @R6++
                SUB     1, R12
                RBRA    _F32W_MK_EL, 1
_F32W_MK_EX     MOVE    1, R9
                RBRA    _F32W_MK_EL, 1
_F32W_MK_DONE   MOVE    R0, R8                      ; an empty base: "_"
                ADD     FAT32$PB_BASIS, R8
                CMP     0x0020, @R8
                RBRA    _F32W_MK_CP, !Z
                MOVE    0x005F, @R8
                MOVE    1, R9
_F32W_MK_CP     MOVE    R0, R6                      ; PB_SFN := PB_BASIS
                ADD     FAT32$PB_SFN, R6
                MOVE    11, R12
_F32W_MK_CPL    MOVE    @R8++, @R6++
                SUB     1, R12
                RBRA    _F32W_MK_CPL, !Z
                MOVE    R9, R10                     ; R10: lossy
                XOR     R11, R11                    ; R11: long name slots
                CMP     0, R4
                RBRA    _F32W_MK_OK, Z
                MOVE    R2, R11                     ; ceil(length / 13)
                ADD     12, R11
                MOVE    R11, R8
                XOR     R11, R11
_F32W_MK_DIV    CMP     13, R8
                RBRA    _F32W_MK_OK, N              ; (13 > R8)
                SUB     13, R8
                ADD     1, R11
                RBRA    _F32W_MK_DIV, 1
_F32W_MK_OK     XOR     R9, R9
                RBRA    _F32W_MK_RET, 1
_F32W_MK_BAD    MOVE    FAT32$ERR_NAME, R9
_F32W_MK_RET    MOVE    R0, R8
                MOVE    R7, R12
                DECRB
                RET

;*****************************************************************************
;* _F32W_TAIL: PB_SFN := PB_BASIS with the numeric tail "~R9" (1..9999) in
;* the base (R8 = parameter block). Registers unchanged.
;*****************************************************************************
;
_F32W_TAIL      INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    R10, R2
                MOVE    R11, R3
                MOVE    R0, R4                      ; the digits, backwards,
                ADD     FAT32$PB_SB, R4             ; into a scratch area
                ADD     FAT32$SB_TMP, R4            ; (SB_TMP is free now)
                XOR     R5, R5                      ; R5: number of digits
                MOVE    R1, R8
_F32W_TA_D      MOVE    R8, R9                      ; R8 / 10
                XOR     R8, R8
_F32W_TA_DV     CMP     10, R9
                RBRA    _F32W_TA_DE, N              ; (10 > R9)
                SUB     10, R9
                ADD     1, R8
                RBRA    _F32W_TA_DV, 1
_F32W_TA_DE     ADD     0x0030, R9
                MOVE    R9, @R4++
                ADD     1, R5
                CMP     0, R8
                RBRA    _F32W_TA_D, !Z
                MOVE    R0, R6                      ; how much of the basis
                ADD     FAT32$PB_BASIS, R6          ; stays: R7
                XOR     R7, R7
_F32W_TA_BL     CMP     8, R7
                RBRA    _F32W_TA_BE, Z
                CMP     0x0020, @R6++
                RBRA    _F32W_TA_BE, Z
                ADD     1, R7
                RBRA    _F32W_TA_BL, 1
_F32W_TA_BE     MOVE    7, R8                       ; 8 - 1 ("~") - digits
                SUB     R5, R8
                CMP     R7, R8
                RBRA    _F32W_TA_K, !N              ; (R7 <= R8)
                MOVE    R8, R7
_F32W_TA_K      MOVE    R0, R6                      ; PB_SFN: the basis ...
                ADD     FAT32$PB_BASIS, R6
                MOVE    R0, R9
                ADD     FAT32$PB_SFN, R9
                MOVE    R7, R8
                CMP     0, R8
                RBRA    _F32W_TA_T, Z
_F32W_TA_CP     MOVE    @R6++, @R9++
                SUB     1, R8
                RBRA    _F32W_TA_CP, !Z
_F32W_TA_T      MOVE    0x007E, @R9++               ; ... "~" ...
_F32W_TA_TD     SUB     1, R4                       ; ... the digits ...
                MOVE    @R4, @R9++
                SUB     1, R5
                RBRA    _F32W_TA_TD, !Z
                MOVE    R0, R8                      ; ... spaces up to 8
                ADD     FAT32$PB_SFN, R8
                ADD     8, R8
_F32W_TA_SP     CMP     R9, R8
                RBRA    _F32W_TA_X, Z
                MOVE    0x0020, @R9++
                RBRA    _F32W_TA_SP, 1
_F32W_TA_X      MOVE    R0, R6                      ; the extension stays
                ADD     FAT32$PB_BASIS, R6
                ADD     8, R6
                MOVE    @R6++, @R9++
                MOVE    @R6++, @R9++
                MOVE    @R6, @R9
                MOVE    R0, R8
                MOVE    R1, R9
                MOVE    R2, R10
                MOVE    R3, R11
                DECRB
                RET

;*****************************************************************************
;* _F32W_PUTLFN writes a long name slot
;*
;* INPUT:  R8  parameter block (PB_NAME, PB_WS)
;*         R9  byte offset of the slot in the sector buffer
;*         R10 sequence number (1 = the first 13 characters)
;*         R11 checksum of the short name
;* OUTPUT: R8..R12 unchanged
;*****************************************************************************
;
_F32W_PUTLFN    INCRB
                MOVE    R8, R0
                MOVE    R9, R1                      ; R1: slot
                MOVE    R10, R2                     ; R2: sequence number
                MOVE    R11, R3
                MOVE    R12, R4
                MOVE    R0, R5
                ADD     FAT32$PB_NAME, R5
                MOVE    @R5, R5                     ; R5: name
                XOR     R6, R6                      ; R6: its length
                MOVE    R5, R7
_F32W_PL_LEN    CMP     0, @R7++
                RBRA    _F32W_PL_LE, Z
                ADD     1, R6
                RBRA    _F32W_PL_LEN, 1
_F32W_PL_LE     MOVE    @R0, R8                     ; R8: device handle
                MOVE    R2, R10                     ; byte 0: the sequence
                MOVE    R2, R7                      ; number, + 0x40 for
                MOVE    R7, R12                     ; the last slot: when
                SHL     2, R12                      ; seq * 13 >= length
                AND     0xFFFC, R12
                ADD     R12, R7
                ADD     R12, R7
                ADD     R12, R7                     ; R7 = seq * 13
                CMP     R6, R7                      ; length > seq * 13?
                RBRA    _F32W_PL_NL, N
                OR      0x0040, R10
_F32W_PL_NL     MOVE    R1, R9
                RSUB    FAT32$WRITE_B, 1
                ADD     11, R9                      ; attributes
                MOVE    0x000F, R10
                RSUB    FAT32$WRITE_B, 1
                ADD     1, R9                       ; type
                XOR     R10, R10
                RSUB    FAT32$WRITE_B, 1
                ADD     1, R9                       ; checksum
                MOVE    R3, R10
                RSUB    FAT32$WRITE_B, 1
                MOVE    R1, R9                      ; first cluster: 0
                ADD     26, R9
                XOR     R10, R10
                RSUB    _F32W_WW, 1
                SUB     13, R7                      ; R7: (seq - 1) * 13
                MOVE    _F32W_LFN_OFS, R11
                MOVE    13, R12
_F32W_PL_CH     MOVE    R1, R9
                ADD     @R11++, R9
                CMP     R6, R7                      ; position < length:
                RBRA    _F32W_PL_C1, !N             ; the character
                MOVE    R5, R10
                ADD     R7, R10
                MOVE    @R10, R10
                RBRA    _F32W_PL_W, 1
_F32W_PL_C1     MOVE    0xFFFF, R10                 ; = length: 0x0000,
                CMP     R7, R6                      ; behind it: 0xFFFF
                RBRA    _F32W_PL_W, !Z
                XOR     R10, R10
_F32W_PL_W      RSUB    _F32W_WW, 1
                ADD     1, R7
                SUB     1, R12
                RBRA    _F32W_PL_CH, !Z
                MOVE    R0, R8                      ; the sector changed
                ADD     FAT32$PB_WS, R8
                ADD     FAT32$WS_DIRTY, R8
                MOVE    1, @R8
                MOVE    R0, R8
                MOVE    R1, R9
                MOVE    R2, R10
                MOVE    R3, R11
                MOVE    R4, R12
                DECRB
                RET

;*****************************************************************************
;* _F32W_PUTSFN writes the short name slot of a new entry (PB_SFN, PB_ATTR,
;* PB_DATE, PB_TIME, PB_CL, PB_SZ) at byte R9 of the sector buffer (R8 =
;* parameter block). Registers unchanged.
;*****************************************************************************
;
_F32W_PUTSFN    INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    R10, R2
                MOVE    R11, R3
                MOVE    @R0, R8                     ; R8: device handle
                MOVE    R0, R4
                ADD     FAT32$PB_SFN, R4
                MOVE    11, R5
_F32W_PS_N      MOVE    @R4++, R10
                RSUB    FAT32$WRITE_B, 1
                ADD     1, R9
                SUB     1, R5
                RBRA    _F32W_PS_N, !Z
                MOVE    R0, R4                      ; 11: attributes
                ADD     FAT32$PB_ATTR, R4
                MOVE    @R4, R10
                RSUB    FAT32$WRITE_B, 1
                ADD     1, R9                       ; 12, 13: 0
                XOR     R10, R10
                RSUB    FAT32$WRITE_B, 1
                ADD     1, R9
                RSUB    FAT32$WRITE_B, 1
                MOVE    R0, R4
                ADD     FAT32$PB_DATE, R4
                MOVE    @R4++, R5                   ; R5: date
                MOVE    @R4++, R6                   ; R6: time
                ADD     1, R9                       ; 14: creation time
                MOVE    R6, R10
                RSUB    _F32W_WW, 1
                ADD     2, R9                       ; 16: creation date
                MOVE    R5, R10
                RSUB    _F32W_WW, 1
                ADD     2, R9                       ; 18: access date
                RSUB    _F32W_WW, 1
                ADD     2, R9                       ; 20: cluster high
                MOVE    R0, R4
                ADD     FAT32$PB_CL_HI, R4
                MOVE    @R4, R10
                RSUB    _F32W_WW, 1
                ADD     2, R9                       ; 22: write time
                MOVE    R6, R10
                RSUB    _F32W_WW, 1
                ADD     2, R9                       ; 24: write date
                MOVE    R5, R10
                RSUB    _F32W_WW, 1
                ADD     2, R9                       ; 26: cluster low
                MOVE    R0, R4
                ADD     FAT32$PB_CL_LO, R4
                MOVE    @R4, R10
                RSUB    _F32W_WW, 1
                ADD     2, R9                       ; 28: size
                MOVE    R0, R4
                ADD     FAT32$PB_SZ_LO, R4
                MOVE    @R4++, R6
                MOVE    @R4, R7
                RSUB    _F32W_WDW, 1
                MOVE    R0, R8                      ; the sector changed
                ADD     FAT32$PB_WS, R8
                ADD     FAT32$WS_DIRTY, R8
                MOVE    1, @R8
                MOVE    R0, R8
                MOVE    R1, R9
                MOVE    R2, R10
                MOVE    R3, R11
                DECRB
                RET

;*****************************************************************************
;* _F32W_DELETE deletes a directory entry
;*
;* Marks the short name slot and the long name slots in front of it as
;* deleted, then (PB_FLAGS: FAT32$WDF_FREE) frees the cluster chain of the
;* entry. The caller makes sure that a directory is empty.
;*
;* INPUT:  R8  parameter block: PB_DEV, PB_DIR, PB_EA, PB_FLAGS
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, FAT32$ERR_FILENOTFOUND if there is no entry at PB_EA,
;*             otherwise an error code
;*         R10..R12 unchanged
;*****************************************************************************
;
_F32W_DELETE  INCRB
                MOVE    R8, R0                      ; R0: parameter block
                MOVE    R10, R1
                MOVE    R11, R2
                MOVE    R12, R3
                MOVE    R0, R8
                ADD     FAT32$PB_WS, R8
                MOVE    @R0, R9
                RSUB    _F32W_BEGIN, 1
                CMP     0, R9
                RBRA    _F32W_DL_RET, !Z
                MOVE    R8, R7                      ; R7: session
                MOVE    R0, R6
                ADD     FAT32$PB_SB, R6             ; R6: scan block

                ; find the entry and the start of its long name
                MOVE    R6, R8
                ADD     FAT32$SB_MODE, R8
                MOVE    2, @R8
                MOVE    R0, R9                      ; SB_TEA := PB_EA
                ADD     FAT32$PB_EA, R9
                MOVE    R6, R10
                ADD     FAT32$SB_TEA, R10
                MOVE    @R9++, @R10++
                MOVE    @R9++, @R10++
                MOVE    @R9, @R10
                MOVE    R6, R8
                ADD     FAT32$SB_SFN, R8
                MOVE    0, @R8++
                MOVE    0, @R8                      ; SB_NEED
                MOVE    R7, R8
                MOVE    R6, R9
                MOVE    R0, R10
                ADD     FAT32$PB_DIR_LO, R10
                MOVE    @R10, R10
                MOVE    R0, R11
                ADD     FAT32$PB_DIR_HI, R11
                MOVE    @R11, R11
                RSUB    _F32W_SCAN, 1
                CMP     0, R9
                RBRA    _F32W_DL_END, !Z
                MOVE    R6, R8
                ADD     FAT32$SB_HIT, R8
                CMP     0, @R8
                RBRA    _F32W_DL_MARK, !Z
                MOVE    FAT32$ERR_FILENOTFOUND, R9
                RBRA    _F32W_DL_END, 1

                ; mark the slots from the first long name slot to the short
                ; name slot (the walker starts at SB_L)
_F32W_DL_MARK   MOVE    R6, R9
                ADD     FAT32$SB_L, R9
                MOVE    R6, R10
                ADD     FAT32$DW_CL_LO, R10
                MOVE    @R9++, @R10++
                MOVE    @R9++, @R10++
                MOVE    @R9, @R10++
                MOVE    0, @R10                     ; DW_ORD (not needed)
_F32W_DL_ML     MOVE    R7, R8
                MOVE    R6, R9
                RSUB    _F32W_DW_SLOT, 1
                CMP     0, R9
                RBRA    _F32W_DL_END, !Z
                MOVE    R10, R9
                MOVE    @R7, R8
                MOVE    0x00E5, R10
                RSUB    FAT32$WRITE_B, 1
                MOVE    R7, R8
                ADD     FAT32$WS_DIRTY, R8
                MOVE    1, @R8
                MOVE    R6, R8                      ; the short name slot?
                ADD     FAT32$DW_CL_LO, R8
                MOVE    R6, R9
                ADD     FAT32$SB_E, R9
                CMP     @R8++, @R9++
                RBRA    _F32W_DL_MN, !Z
                CMP     @R8++, @R9++
                RBRA    _F32W_DL_MN, !Z
                CMP     @R8, @R9
                RBRA    _F32W_DL_FR, Z
_F32W_DL_MN     MOVE    R7, R8
                MOVE    R6, R9
                XOR     R10, R10
                RSUB    _F32W_DW_NEXT, 1
                CMP     0, R9
                RBRA    _F32W_DL_ML, Z
                RBRA    _F32W_DL_END, 1

                ; then the clusters
_F32W_DL_FR     XOR     R9, R9
                MOVE    R0, R8
                ADD     FAT32$PB_FLAGS, R8
                MOVE    @R8, R8
                AND     FAT32$WDF_FREE, R8
                RBRA    _F32W_DL_END, Z
                MOVE    R6, R8
                ADD     FAT32$SB_FCL, R8
                MOVE    @R8++, R9
                MOVE    @R8, R10
                MOVE    R7, R8
                RSUB    _F32W_FREE, 1
_F32W_DL_END    MOVE    R9, R4
                MOVE    R7, R8
                RSUB    _F32W_END, 1
                CMP     0, R4
                RBRA    _F32W_DL_RET, Z
                MOVE    R4, R9
_F32W_DL_RET    MOVE    R0, R8
                MOVE    R1, R10
                MOVE    R2, R11
                MOVE    R3, R12
                DECRB
                RET

;*****************************************************************************
;* _F32W_SETDE changes fields of a directory entry
;*
;* INPUT:  R8  parameter block: PB_DEV, PB_EA, PB_FLAGS (FAT32$WSF_*: the
;*             fields to change), PB_SZ, PB_CL, PB_ATTR (in the high byte of
;*             PB_FLAGS), PB_DATE, PB_TIME
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, otherwise an error code
;*         R10..R12 unchanged
;*****************************************************************************
;
_F32W_SETDE   INCRB
                MOVE    R8, R0
                MOVE    R10, R1
                MOVE    R11, R2
                MOVE    R12, R3
                MOVE    R0, R8
                ADD     FAT32$PB_WS, R8
                MOVE    @R0, R9
                RSUB    _F32W_BEGIN, 1
                CMP     0, R9
                RBRA    _F32W_SD_RET, !Z
                MOVE    R8, R7                      ; R7: session
                MOVE    R0, R6
                ADD     FAT32$PB_SB, R6             ; R6: walker on PB_EA
                MOVE    R0, R9
                ADD     FAT32$PB_EA, R9
                MOVE    R6, R10
                ADD     FAT32$DW_CL_LO, R10
                MOVE    @R9++, @R10++
                MOVE    @R9++, @R10++
                MOVE    @R9, @R10
                MOVE    R7, R8
                MOVE    R6, R9
                RSUB    _F32W_DW_SLOT, 1
                CMP     0, R9
                RBRA    _F32W_SD_END, !Z
                MOVE    R10, R5                     ; R5: slot
                MOVE    @R7, R8
                MOVE    R0, R4
                ADD     FAT32$PB_FLAGS, R4
                MOVE    @R4, R4                     ; R4: flags
                MOVE    R4, R10
                AND     FAT32$WSF_SIZE, R10
                RBRA    _F32W_SD_C, Z
                MOVE    R0, R9
                ADD     FAT32$PB_SZ_LO, R9
                MOVE    @R9++, R6
                MOVE    @R9, R7
                MOVE    R5, R9
                ADD     28, R9
                RSUB    _F32W_WDW, 1
                MOVE    R0, R7                      ; (R7: session again)
                ADD     FAT32$PB_WS, R7
_F32W_SD_C      MOVE    R4, R10
                AND     FAT32$WSF_CLUS, R10
                RBRA    _F32W_SD_A, Z
                MOVE    R0, R6
                ADD     FAT32$PB_CL_LO, R6
                MOVE    R5, R9
                ADD     26, R9
                MOVE    @R6++, R10
                RSUB    _F32W_WW, 1
                SUB     6, R9
                MOVE    @R6, R10
                RSUB    _F32W_WW, 1
_F32W_SD_A      MOVE    R4, R10
                AND     FAT32$WSF_ATTR, R10
                RBRA    _F32W_SD_T, Z
                MOVE    R5, R9
                ADD     11, R9
                MOVE    R4, R10
                SWAP    R10, R10
                AND     0x00FF, R10
                RSUB    FAT32$WRITE_B, 1
_F32W_SD_T      MOVE    R4, R10
                AND     FAT32$WSF_TIME, R10
                RBRA    _F32W_SD_D, Z
                MOVE    R0, R6
                ADD     FAT32$PB_DATE, R6
                MOVE    R5, R9
                ADD     24, R9
                MOVE    @R6++, R10                  ; write date
                RSUB    _F32W_WW, 1
                SUB     2, R9
                MOVE    @R6, R10                    ; write time
                RSUB    _F32W_WW, 1
_F32W_SD_D      MOVE    R7, R8
                ADD     FAT32$WS_DIRTY, R8
                MOVE    1, @R8
                XOR     R9, R9
_F32W_SD_END    MOVE    R9, R4
                MOVE    R7, R8
                RSUB    _F32W_END, 1
                CMP     0, R4
                RBRA    _F32W_SD_RET, Z
                MOVE    R4, R9
_F32W_SD_RET    MOVE    R0, R8
                MOVE    R1, R10
                MOVE    R2, R11
                MOVE    R3, R12
                DECRB
                RET


;*****************************************************************************
;* DIRECTORIES AND RENAMING
;*****************************************************************************

;*****************************************************************************
;* _F32W_MKDIR creates a directory
;*
;* A new cluster gets the entries "." and ".." (dated PB_DATE, PB_TIME), then
;* the directory entry is created in PB_DIR. If that fails (for example: the
;* name exists), the cluster is freed again.
;*
;* INPUT:  R8  parameter block: PB_DEV, PB_DIR, PB_NAME, PB_DATE, PB_TIME
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, otherwise an error code (see FAT32$W_CREATE)
;*         PB_EA: the entry address, PB_CL: the first cluster of the new
;*         directory
;*         R10..R12 unchanged
;*****************************************************************************
;
_F32W_MKDIR   INCRB
                MOVE    R8, R0                      ; R0: parameter block
                MOVE    R10, R1
                MOVE    R11, R2
                MOVE    R12, R3
                MOVE    R0, R8
                ADD     FAT32$PB_WS, R8
                MOVE    @R0, R9
                RSUB    _F32W_BEGIN, 1
                CMP     0, R9
                RBRA    _F32W_MD_RET, !Z
                MOVE    R8, R7                      ; R7: session
                XOR     R9, R9                      ; the cluster
                XOR     R10, R10
                RSUB    _F32W_ALLOC, 1
                CMP     0, R9
                RBRA    _F32W_MD_END, !Z
                MOVE    R10, R5                     ; R6|R5: the cluster
                MOVE    R11, R6
                MOVE    R0, R4
                ADD     FAT32$PB_CL_LO, R4
                MOVE    R5, @R4++
                MOVE    R6, @R4
                MOVE    R5, R9
                MOVE    R6, R10
                RSUB    _F32W_ZEROCL, 1
                CMP     0, R9
                RBRA    _F32W_MD_END, !Z
                MOVE    R5, R9                      ; its first sector
                MOVE    R6, R10
                XOR     R11, R11
                RSUB    _F32W_CLSEC, 1
                RSUB    _F32W_SEC, 1
                CMP     0, R9
                RBRA    _F32W_MD_END, !Z

                ; "." points to the directory itself, ".." to its parent
                ; (0 if that is the root directory)
                MOVE    R0, R4                      ; (PB_SFN as scratch)
                ADD     FAT32$PB_SFN, R4
                MOVE    R4, R8
                MOVE    0x002E, @R8++
                MOVE    10, R9
_F32W_MD_SP     MOVE    0x0020, @R8++
                SUB     1, R9
                RBRA    _F32W_MD_SP, !Z
                MOVE    R0, R8
                ADD     FAT32$PB_ATTR, R8
                MOVE    FAT32$FA_DIR, @R8
                MOVE    R0, R8
                ADD     FAT32$PB_SZ_LO, R8
                MOVE    0, @R8++
                MOVE    0, @R8
                MOVE    R0, R8
                XOR     R9, R9
                RSUB    _F32W_PUTSFN, 1             ; slot 0: "." (PB_CL)
                ADD     1, R4
                MOVE    0x002E, @R4                 ; ".."
                MOVE    R0, R8                      ; PB_CL := the parent
                ADD     FAT32$PB_DIR_LO, R8
                MOVE    @R8++, R9
                MOVE    @R8, R10
                MOVE    @R0, R11
                ADD     FAT32$DEV_RD_1STCLUS_LO, R11
                CMP     @R11++, R9
                RBRA    _F32W_MD_P, !Z
                CMP     @R11, R10
                RBRA    _F32W_MD_P, !Z
                XOR     R9, R9
                XOR     R10, R10
_F32W_MD_P      MOVE    R0, R8
                ADD     FAT32$PB_CL_LO, R8
                MOVE    R9, @R8++
                MOVE    R10, @R8
                MOVE    R0, R8
                MOVE    32, R9
                RSUB    _F32W_PUTSFN, 1             ; slot 1: ".."
                MOVE    R0, R8                      ; PB_CL := the directory
                ADD     FAT32$PB_CL_LO, R8
                MOVE    R5, @R8++
                MOVE    R6, @R8
                MOVE    R7, R8
                RSUB    _F32W_END, 1                ; the cluster is ready
                CMP     0, R9
                RBRA    _F32W_MD_RET, !Z

                ; the entry
                MOVE    R0, R8
                RSUB    _F32W_CREATE, 1
                CMP     0, R9
                RBRA    _F32W_MD_RET, Z
                MOVE    R9, R4                      ; failed: free the cluster
                MOVE    R0, R8
                ADD     FAT32$PB_WS, R8
                MOVE    @R0, R9
                RSUB    _F32W_BEGIN, 1
                CMP     0, R9
                RBRA    _F32W_MD_FR, !Z
                MOVE    R5, R9
                MOVE    R6, R10
                RSUB    _F32W_FREE, 1
                RSUB    _F32W_END, 1
_F32W_MD_FR     MOVE    R4, R9
                RBRA    _F32W_MD_RET, 1
_F32W_MD_END    MOVE    R9, R4
                MOVE    R7, R8
                RSUB    _F32W_END, 1
                MOVE    R4, R9
_F32W_MD_RET    MOVE    R0, R8
                MOVE    R1, R10
                MOVE    R2, R11
                MOVE    R3, R12
                DECRB
                RET

;*****************************************************************************
;* _F32W_RENAME renames and/or moves a directory entry
;*
;* The entry PB_EA of the directory PB_DIR gets the name PB_NAME in the
;* directory PB_DIR2 (which may be PB_DIR). Its data (attributes, dates,
;* first cluster, size) stays the same: a new entry is created with it, then
;* the old one is deleted. A directory that moves to another directory gets
;* its ".." entry changed; it cannot move into itself or below.
;*
;* INPUT:  R8  parameter block: PB_DEV, PB_DIR, PB_EA, PB_NAME, PB_DIR2
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, FAT32$ERR_FILENOTFOUND, FAT32$ERR_EXISTS,
;*             FAT32$ERR_NAME, FAT32$ERR_LOOP or another error code
;*         PB_EA: the entry address of the renamed entry
;*         R10..R12 unchanged
;*****************************************************************************
;
_F32W_RENAME  INCRB
                MOVE    R8, R0                      ; R0: parameter block
                MOVE    R10, R1
                MOVE    R11, R2
                MOVE    R12, R3
                MOVE    R0, R8
                ADD     FAT32$PB_WS, R8
                MOVE    @R0, R9
                RSUB    _F32W_BEGIN, 1
                CMP     0, R9
                RBRA    _F32W_RN_RET, !Z
                MOVE    R8, R7                      ; R7: session
                MOVE    R0, R6
                ADD     FAT32$PB_SB, R6             ; R6: scan block

                ; the old entry: its raw data (bytes 11..31) to PB_RAW
                MOVE    R0, R8                      ; (PB_EA: old address)
                ADD     FAT32$PB_EA, R8
                MOVE    R0, R9
                ADD     FAT32$PB_OLDEA, R9
                MOVE    @R8++, @R9++
                MOVE    @R8++, @R9++
                MOVE    @R8, @R9
                MOVE    R6, R8
                ADD     FAT32$SB_MODE, R8
                MOVE    2, @R8
                MOVE    R0, R9
                ADD     FAT32$PB_OLDEA, R9
                MOVE    R6, R10
                ADD     FAT32$SB_TEA, R10
                MOVE    @R9++, @R10++
                MOVE    @R9++, @R10++
                MOVE    @R9, @R10
                MOVE    R6, R8
                ADD     FAT32$SB_SFN, R8
                MOVE    0, @R8++
                MOVE    0, @R8
                MOVE    R7, R8
                MOVE    R6, R9
                MOVE    R0, R10
                ADD     FAT32$PB_DIR_LO, R10
                MOVE    @R10, R10
                MOVE    R0, R11
                ADD     FAT32$PB_DIR_HI, R11
                MOVE    @R11, R11
                RSUB    _F32W_SCAN, 1
                CMP     0, R9
                RBRA    _F32W_RN_END, !Z
                MOVE    R6, R8
                ADD     FAT32$SB_HIT, R8
                CMP     0, @R8
                RBRA    _F32W_RN_GOT, !Z
                MOVE    FAT32$ERR_FILENOTFOUND, R9
                RBRA    _F32W_RN_END, 1
_F32W_RN_GOT    MOVE    R6, R8                      ; R5: attributes, the
                ADD     FAT32$SB_ATTR, R8           ; first cluster to PB_CL
                MOVE    @R8++, R5
                MOVE    R0, R9
                ADD     FAT32$PB_CL_LO, R9
                MOVE    @R8++, @R9++
                MOVE    @R8, @R9
                MOVE    R7, R8                      ; the raw bytes 11..31
                MOVE    R6, R9                      ; (the walker is on the
                RSUB    _F32W_DW_SLOT, 1            ; entry)
                CMP     0, R9
                RBRA    _F32W_RN_END, !Z
                MOVE    R10, R9
                ADD     11, R9
                MOVE    @R7, R8
                MOVE    R0, R11
                ADD     FAT32$PB_RAW, R11
                MOVE    21, R12
_F32W_RN_RD     RSUB    FAT32$READ_B, 1
                MOVE    R10, @R11++
                ADD     1, R9
                SUB     1, R12
                RBRA    _F32W_RN_RD, !Z

                ; a directory must not move into itself or below it: from
                ; the target directory up to the root, no directory may be
                ; the one that moves
                MOVE    R5, R8
                AND     FAT32$FA_DIR, R8
                RBRA    _F32W_RN_NEW, Z
                MOVE    R0, R8
                ADD     FAT32$PB_DIR2_LO, R8
                MOVE    @R8++, R9
                MOVE    @R8, R10
_F32W_RN_UP     MOVE    R0, R8                      ; this one moves?
                ADD     FAT32$PB_CL_LO, R8
                CMP     @R8++, R9
                RBRA    _F32W_RN_U1, !Z
                CMP     @R8, R10
                RBRA    _F32W_RN_U1, !Z
                MOVE    FAT32$ERR_LOOP, R9
                RBRA    _F32W_RN_END, 1
_F32W_RN_U1     MOVE    @R7, R8                     ; the root: done
                ADD     FAT32$DEV_RD_1STCLUS_LO, R8
                CMP     @R8++, R9
                RBRA    _F32W_RN_U2, !Z
                CMP     @R8, R10
                RBRA    _F32W_RN_NEW, Z
_F32W_RN_U2     MOVE    R7, R8                      ; its parent: ".." (slot
                XOR     R11, R11                    ; 1 of its first sector)
                RSUB    _F32W_CLSEC, 1
                CMP     0xFFFF, R11
                RBRA    _F32W_RN_U3, !Z
                MOVE    FAT32$ERR_ILLEGAL_CLUS, R9
                RBRA    _F32W_RN_END, 1
_F32W_RN_U3     RSUB    _F32W_SEC, 1
                CMP     0, R9
                RBRA    _F32W_RN_END, !Z
                MOVE    @R7, R8
                MOVE    52, R9                      ; 32 + 20: cluster high
                RSUB    FAT32$READ_W, 1
                MOVE    R10, R11
                MOVE    58, R9                      ; 32 + 26: cluster low
                RSUB    FAT32$READ_W, 1
                MOVE    R10, R9
                MOVE    R11, R10
                MOVE    R9, R8                      ; 0: the root
                OR      R10, R8
                RBRA    _F32W_RN_UP, !Z
                MOVE    @R7, R8
                ADD     FAT32$DEV_RD_1STCLUS_LO, R8
                MOVE    @R8++, R9
                MOVE    @R8, R10
                RBRA    _F32W_RN_UP, 1

                ; the new entry (in a session of its own, like every public
                ; function), with the old data
_F32W_RN_NEW    MOVE    R7, R8
                RSUB    _F32W_END, 1
                CMP     0, R9
                RBRA    _F32W_RN_RET, !Z
                MOVE    R0, R8                      ; PB_DIR <-> PB_DIR2:
                RSUB    _F32W_RN_SWAP, 1            ; create in the target,
                MOVE    R0, R8                      ; ignoring the old entry
                ADD     FAT32$PB_ATTR, R8
                MOVE    R5, @R8
                MOVE    R0, R8
                ADD     FAT32$PB_SZ_LO, R8
                MOVE    0, @R8++
                MOVE    0, @R8
                MOVE    R0, R8
                ADD     FAT32$PB_DATE, R8
                MOVE    0, @R8++
                MOVE    0, @R8
                MOVE    R0, R8
                ADD     FAT32$PB_IGN, R8            ; (ignored only when the
                MOVE    1, @R8                      ; directories are equal)
                MOVE    R0, R8
                RSUB    _F32W_CREATE, 1
                MOVE    R0, R8
                ADD     FAT32$PB_IGN, R8
                MOVE    0, @R8
                MOVE    R9, R4
                MOVE    R0, R8
                RSUB    _F32W_RN_SWAP, 1
                CMP     0, R4
                RBRA    _F32W_RN_E4, Z
                MOVE    R4, R9
                RBRA    _F32W_RN_RET, 1

                ; the old data into the new entry (bytes 11..31)
_F32W_RN_E4     MOVE    R0, R8
                ADD     FAT32$PB_WS, R8
                MOVE    @R0, R9
                RSUB    _F32W_BEGIN, 1
                CMP     0, R9
                RBRA    _F32W_RN_RET, !Z
                MOVE    R0, R9                      ; the walker on PB_EA
                ADD     FAT32$PB_EA, R9
                MOVE    R6, R10
                ADD     FAT32$DW_CL_LO, R10
                MOVE    @R9++, @R10++
                MOVE    @R9++, @R10++
                MOVE    @R9, @R10
                MOVE    R7, R8
                MOVE    R6, R9
                RSUB    _F32W_DW_SLOT, 1
                CMP     0, R9
                RBRA    _F32W_RN_END, !Z
                MOVE    R10, R9
                ADD     11, R9
                MOVE    @R7, R8
                MOVE    R0, R11
                ADD     FAT32$PB_RAW, R11
                MOVE    21, R12
_F32W_RN_WR     MOVE    @R11++, R10
                RSUB    FAT32$WRITE_B, 1
                ADD     1, R9
                SUB     1, R12
                RBRA    _F32W_RN_WR, !Z
                MOVE    R7, R8
                ADD     FAT32$WS_DIRTY, R8
                MOVE    1, @R8

                ; a directory that moved: its ".." entry
                MOVE    R5, R8
                AND     FAT32$FA_DIR, R8
                RBRA    _F32W_RN_DEL, Z
                MOVE    R0, R8
                ADD     FAT32$PB_DIR_LO, R8
                MOVE    R0, R9
                ADD     FAT32$PB_DIR2_LO, R9
                CMP     @R8++, @R9++
                RBRA    _F32W_RN_DD, !Z
                CMP     @R8, @R9
                RBRA    _F32W_RN_DEL, Z
_F32W_RN_DD     MOVE    R0, R8                      ; its first sector
                ADD     FAT32$PB_CL_LO, R8
                MOVE    @R8++, R9
                MOVE    @R8, R10
                XOR     R11, R11
                MOVE    R7, R8
                RSUB    _F32W_CLSEC, 1
                RSUB    _F32W_SEC, 1
                CMP     0, R9
                RBRA    _F32W_RN_END, !Z
                MOVE    R0, R8                      ; the new parent (0: the
                ADD     FAT32$PB_DIR2_LO, R8        ; root)
                MOVE    @R8++, R4
                MOVE    @R8, R12
                MOVE    @R7, R8
                ADD     FAT32$DEV_RD_1STCLUS_LO, R8
                CMP     @R8++, R4
                RBRA    _F32W_RN_D2, !Z
                CMP     @R8, R12
                RBRA    _F32W_RN_D2, !Z
                XOR     R4, R4
                XOR     R12, R12
_F32W_RN_D2     MOVE    @R7, R8
                MOVE    58, R9
                MOVE    R4, R10
                RSUB    _F32W_WW, 1
                MOVE    52, R9
                MOVE    R12, R10
                RSUB    _F32W_WW, 1
                MOVE    R7, R8
                ADD     FAT32$WS_DIRTY, R8
                MOVE    1, @R8
_F32W_RN_DEL    MOVE    R7, R8
                RSUB    _F32W_END, 1
                CMP     0, R9
                RBRA    _F32W_RN_RET, !Z

                ; then the old entry goes (its clusters stay)
                MOVE    R0, R8                      ; PB_EA <-> PB_OLDEA
                RSUB    _F32W_RN_XEA, 1
                MOVE    R0, R8
                ADD     FAT32$PB_FLAGS, R8
                MOVE    0, @R8
                MOVE    R0, R8
                RSUB    _F32W_DELETE, 1
                MOVE    R9, R4
                MOVE    R0, R8
                RSUB    _F32W_RN_XEA, 1
                MOVE    R4, R9
                RBRA    _F32W_RN_RET, 1
_F32W_RN_END    MOVE    R9, R4
                MOVE    R7, R8
                RSUB    _F32W_END, 1
                MOVE    R4, R9
_F32W_RN_RET    MOVE    R0, R8
                MOVE    R1, R10
                MOVE    R2, R11
                MOVE    R3, R12
                DECRB
                RET

; _F32W_RN_SWAP: swap PB_DIR and PB_DIR2 of the parameter block R8
_F32W_RN_SWAP   INCRB
                MOVE    R8, R0
                ADD     FAT32$PB_DIR_LO, R0
                MOVE    R8, R1
                ADD     FAT32$PB_DIR2_LO, R1
                MOVE    2, R2
_F32W_RS_L      MOVE    @R0, R3
                MOVE    @R1, @R0++
                MOVE    R3, @R1++
                SUB     1, R2
                RBRA    _F32W_RS_L, !Z
                DECRB
                RET

; _F32W_RN_XEA: swap PB_EA and PB_OLDEA of the parameter block R8
_F32W_RN_XEA    INCRB
                MOVE    R8, R0
                ADD     FAT32$PB_EA, R0
                MOVE    R8, R1
                ADD     FAT32$PB_OLDEA, R1
                MOVE    3, R2
_F32W_RX_L      MOVE    @R0, R3
                MOVE    @R1, @R0++
                MOVE    R3, @R1++
                SUB     1, R2
                RBRA    _F32W_RX_L, !Z
                DECRB
                RET
