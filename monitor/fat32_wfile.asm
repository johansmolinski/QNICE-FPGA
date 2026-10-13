;*****************************************************************************
;* FAT32 write layer, part 2: writing files
;*
;* Megamiga (johansmolinski/QNICE-FPGA, branch fat32-fastseek), October 2026.
;* Needs fat32_write.asm (the core). It calls the core through the _F32WX_*
;* names only: fat32_wglue.asm maps them to the core in a flat program, the
;* Megamiga firmware maps them to FAR_CALL stubs (the parts are in different
;* QNICE code banks). The public names FAT32$W_* come from there as well.
;*****************************************************************************

;*****************************************************************************
;* WRITING FILES
;*
;* A file is written through a file handle (FDH) that _F32W_FDH opened
;* from its entry address. For every piece of data: _F32W_PUT makes the
;* sector at the file position the content of the sector buffer (it adds a
;* cluster to the file when the position is behind its last cluster), the
;* caller writes up to R11 bytes into the buffer from byte R10 on (with
;* FAT32$WRITE_B or straight into the hardware buffer), and FAT32$W_ADV
;* moves the position on. _F32W_SYNC writes the buffer back and the new
;* size into the directory entry. Positions behind the end of the file are
;* not supported: write from the end on, or grow the file with W_SETSIZE.
;*****************************************************************************

;*****************************************************************************
;* _F32W_FDH opens a file from the entry address in a parameter block
;*
;* INPUT:  R8  parameter block: PB_DEV, PB_DIR, PB_EA
;*         R9  file handle to fill (FAT32$FDH_STRUCT_SIZE words)
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, FAT32$ERR_FILENOTFOUND or another error code
;*         R10 attributes of the file
;*         R11, R12 unchanged
;*****************************************************************************
;
_F32W_FDH     INCRB
                MOVE    R8, R0                      ; R0: parameter block
                MOVE    R9, R1                      ; R1: file handle
                MOVE    R11, R2
                MOVE    R12, R3
                MOVE    R0, R8
                ADD     FAT32$PB_WS, R8
                MOVE    @R0, R9
                RSUB    _F32WX_BEGIN, 1
                CMP     0, R9
                RBRA    _F32W_FH_RET, !Z
                MOVE    R8, R7                      ; R7: session
                MOVE    R0, R6
                ADD     FAT32$PB_SB, R6             ; R6: scan block
                MOVE    R6, R8
                ADD     FAT32$SB_MODE, R8
                MOVE    2, @R8
                MOVE    R0, R9
                ADD     FAT32$PB_EA, R9
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
                RSUB    _F32WX_SCAN, 1
                CMP     0, R9
                RBRA    _F32W_FH_END, !Z
                MOVE    R6, R8
                ADD     FAT32$SB_HIT, R8
                CMP     0, @R8
                RBRA    _F32W_FH_OK, !Z
                MOVE    FAT32$ERR_FILENOTFOUND, R9
                RBRA    _F32W_FH_END, 1

                ; fill the file handle
_F32W_FH_OK     MOVE    R1, R8
                MOVE    @R0, @R8++                  ; FDH_DEVICE
                MOVE    R6, R9
                ADD     FAT32$SB_FCL, R9
                MOVE    @R9++, @R8++                ; FDH_CLUSTER
                MOVE    @R9, @R8++
                MOVE    0, @R8++                    ; FDH_SECTOR
                MOVE    0, @R8++                    ; FDH_INDEX
                MOVE    R6, R9
                ADD     FAT32$SB_FSZ, R9
                MOVE    @R9++, @R8++                ; FDH_SIZE
                MOVE    @R9, @R8++
                MOVE    0, @R8++                    ; FDH_ACCESS
                MOVE    0, @R8++
                MOVE    R6, R9
                ADD     FAT32$SB_FCL, R9
                MOVE    @R9++, @R8++                ; FDH_START_CLUS
                MOVE    @R9, @R8++
                MOVE    0, @R8++                    ; FDH_FLAGS
                MOVE    R0, R9
                ADD     FAT32$PB_EA, R9
                MOVE    @R9++, @R8++                ; FDH_EA
                MOVE    @R9++, @R8++
                MOVE    @R9, @R8
                MOVE    R6, R8
                ADD     FAT32$SB_ATTR, R8
                MOVE    @R8, R5                     ; R5: attributes
                XOR     R9, R9
_F32W_FH_END    MOVE    R9, R4
                MOVE    R7, R8
                RSUB    _F32WX_END, 1
                CMP     0, R4
                RBRA    _F32W_FH_RT2, Z
                MOVE    R4, R9
_F32W_FH_RT2    MOVE    R5, R10
_F32W_FH_RET    MOVE    R0, R8
                MOVE    R2, R11
                MOVE    R3, R12
                DECRB
                RET

;*****************************************************************************
;* _F32W_PUT makes the sector at the position of a file the content of the
;* sector buffer, adding a cluster to the file if needed
;*
;* INPUT:  R8  file handle (from FAT32$W_FDH)
;*         R9  parameter block (scratch: its write session is used)
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, FAT32$ERR_DISKFULL or another error code
;*         R10 byte of the position in the sector buffer
;*         R11 bytes from there to the end of the sector
;*         R12 unchanged
;*****************************************************************************
;
_F32W_PUT     INCRB
                MOVE    R8, R0                      ; R0: file handle
                MOVE    R9, R1                      ; R1: parameter block
                MOVE    R12, R2
                MOVE    R0, R3
                ADD     FAT32$FDH_DEVICE, R3
                MOVE    @R3, R3                     ; R3: device handle

                ; an empty file gets its first cluster
                MOVE    R0, R4
                ADD     FAT32$FDH_START_CLUS_LO, R4
                MOVE    @R4++, R5
                OR      @R4, R5
                RBRA    _F32W_PT_END, !Z
                XOR     R9, R9                      ; (no cluster to link to)
                XOR     R10, R10
                RSUB    _F32W_PT_ALC, 1             ; R11|R10: the cluster
                CMP     0, R9
                RBRA    _F32W_PT_RET, !Z
                MOVE    R0, R4
                ADD     FAT32$FDH_CLUSTER_LO, R4
                MOVE    R10, @R4++
                MOVE    R11, @R4++
                MOVE    0, @R4++                    ; FDH_SECTOR
                MOVE    0, @R4                      ; FDH_INDEX
                MOVE    R0, R4
                ADD     FAT32$FDH_START_CLUS_LO, R4
                MOVE    R10, @R4++
                MOVE    R11, @R4
                MOVE    R0, R4
                ADD     FAT32$FDH_FLAGS, R4
                OR      FAT32$FDHF_SIZECHG, @R4
                RBRA    _F32W_PT_LOAD, 1

                ; at the end of the last cluster? Then add one.
_F32W_PT_END    MOVE    R0, R4
                ADD     FAT32$FDH_INDEX, R4
                CMP     FAT32$SECTOR_SIZE, @R4
                RBRA    _F32W_PT_LOAD, !Z
                MOVE    R0, R4
                ADD     FAT32$FDH_SECTOR, R4
                MOVE    @R4, R5
                ADD     1, R5
                MOVE    R3, R4
                ADD     FAT32$DEV_SECT_PER_CLUS, R4
                CMP     @R4, R5
                RBRA    _F32W_PT_LOAD, !Z
                MOVE    R1, R8                      ; the next cluster?
                ADD     FAT32$PB_WS, R8
                MOVE    R3, R9
                RSUB    _F32WX_BEGIN, 1
                CMP     0, R9
                RBRA    _F32W_PT_RET, !Z
                MOVE    R0, R4
                ADD     FAT32$FDH_CLUSTER_LO, R4
                MOVE    @R4++, R9
                MOVE    @R4, R10
                RSUB    _F32WX_FATGET, 1             ; R11|R10
                MOVE    R9, R6
                MOVE    R10, R9
                MOVE    R11, R10
                CMP     0, R6
                RBRA    _F32W_PT_E2, !Z
                RSUB    _F32WX_ISDATA, 1             ; there is one already
                RBRA    _F32W_PT_E2, C
                MOVE    R0, R4                      ; no: link a new one
                ADD     FAT32$FDH_CLUSTER_LO, R4
                MOVE    @R4++, R9
                MOVE    @R4, R10
                RSUB    _F32WX_ALLOC, 1
                MOVE    R9, R6
_F32W_PT_E2     RSUB    _F32WX_END, 1
                CMP     0, R6
                RBRA    _F32W_PT_E3, Z
                MOVE    R6, R9
                RBRA    _F32W_PT_RET, 1
_F32W_PT_E3     CMP     0, R9
                RBRA    _F32W_PT_RET, !Z

                ; the sector of the position into the buffer
_F32W_PT_LOAD   MOVE    R0, R8
                XOR     R9, R9
                RSUB    FAT32$READ_FDH, 1
                CMP     0, R9
                RBRA    _F32W_PT_RET, !Z
                MOVE    R0, R4
                ADD     FAT32$FDH_INDEX, R4
                MOVE    @R4, R10
                MOVE    FAT32$SECTOR_SIZE, R11
                SUB     R10, R11
                XOR     R9, R9
_F32W_PT_RET    MOVE    R0, R8
                MOVE    R2, R12
                DECRB
                RET

; _F32W_PT_ALC: allocate a cluster in a session of its own, linked behind
; R10|R9 unless that is 0 (R1 = parameter block, R3 = device handle of the
; caller's bank). R9 = error, R11|R10 = the cluster.
_F32W_PT_ALC    MOVE    R9, @--SP
                MOVE    R10, @--SP
                MOVE    R1, R8
                ADD     FAT32$PB_WS, R8
                MOVE    R3, R9
                RSUB    _F32WX_BEGIN, 1
                MOVE    @SP++, R10
                CMP     0, R9
                RBRA    _F32W_PA_ERR, !Z
                MOVE    @SP++, R9
                RSUB    _F32WX_ALLOC, 1
                MOVE    R9, @--SP
                RSUB    _F32WX_END, 1
                MOVE    @SP++, R12
                CMP     0, R12
                RBRA    _F32W_PA_RET, Z
                MOVE    R12, R9
_F32W_PA_RET    MOVE    R0, R8
                RET
_F32W_PA_ERR    ADD     1, SP
                MOVE    R0, R8
                RET

;*****************************************************************************
;* _F32W_ADV moves the position of a file on after the caller wrote R9
;* bytes into the sector buffer (at most up to the end of the sector)
;*
;* INPUT:  R8  file handle
;*         R9  number of bytes
;* OUTPUT: R8..R12 unchanged
;*****************************************************************************
;
_F32W_ADV     INCRB
                MOVE    R8, R0
                ADD     FAT32$FDH_INDEX, R0
                ADD     R9, @R0
                MOVE    R8, R0
                ADD     FAT32$FDH_FLAGS, R0
                OR      FAT32$FDHF_DIRTY, @R0
                MOVE    R8, R1
                ADD     FAT32$FDH_ACCESS_LO, R1
                ADD     R9, @R1++
                ADDC    0, @R1
                MOVE    @R1, R3                     ; R3|R2: the new position
                SUB     1, R1
                MOVE    @R1, R2
                MOVE    R8, R1
                ADD     FAT32$FDH_SIZE_LO, R1
                MOVE    @R1++, R4
                MOVE    @R1, R5                     ; R5|R4: the size
                CMP     R3, R5                      ; position > size?
                RBRA    _F32W_AV_GROW, N            ; (R3 > R5)
                RBRA    _F32W_AV_RET, !Z
                CMP     R2, R4
                RBRA    _F32W_AV_RET, !N            ; (R2 <= R4)
_F32W_AV_GROW   MOVE    R3, @R1                     ; the file grows
                SUB     1, R1
                MOVE    R2, @R1
                OR      FAT32$FDHF_SIZECHG, @R0
_F32W_AV_RET    DECRB
                RET

;*****************************************************************************
;* _F32W_SYNC writes the sector buffer of a file back and, if its size or
;* first cluster changed, the new values into its directory entry together
;* with the date and time of the last write (PB_DATE, PB_TIME)
;*
;* INPUT:  R8  file handle
;*         R9  parameter block (PB_DATE, PB_TIME set - PB_DATE 0: the date
;*             of the entry stays; the rest is scratch)
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, otherwise an error code
;*         R10..R12 unchanged
;*****************************************************************************
;
_F32W_SYNC    INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    R10, R2
                RSUB    FAT32$FLUSH, 1
                CMP     0, R9
                RBRA    _F32W_SY_RET, !Z
                MOVE    R0, R3
                ADD     FAT32$FDH_FLAGS, R3
                MOVE    @R3, R4
                AND     FAT32$FDHF_SIZECHG, R4
                RBRA    _F32W_SY_RET, Z
                MOVE    R1, R4                      ; the parameter block
                MOVE    R0, R5
                ADD     FAT32$FDH_DEVICE, R5
                MOVE    @R5, @R4                    ; PB_DEV
                MOVE    R1, R4
                ADD     FAT32$PB_FLAGS, R4
                MOVE    FAT32$WSF_SIZE, @R4
                OR      FAT32$WSF_CLUS, @R4
                MOVE    R1, R5                      ; a date (PB_DATE not 0):
                ADD     FAT32$PB_DATE, R5           ; the last write; else the
                CMP     0, @R5                      ; old date stays
                RBRA    _F32W_SY_ND, Z
                OR      FAT32$WSF_TIME, @R4
_F32W_SY_ND     MOVE    R0, R5
                ADD     FAT32$FDH_START_CLUS_LO, R5
                MOVE    R1, R4
                ADD     FAT32$PB_CL_LO, R4
                MOVE    @R5++, @R4++
                MOVE    @R5, @R4++
                MOVE    R0, R5                      ; (PB_SZ follows PB_CL)
                ADD     FAT32$FDH_SIZE_LO, R5
                MOVE    @R5++, @R4++
                MOVE    @R5, @R4++
                MOVE    R0, R5                      ; (PB_EA follows PB_SZ)
                ADD     FAT32$FDH_EA_CL_LO, R5
                MOVE    @R5++, @R4++
                MOVE    @R5++, @R4++
                MOVE    @R5, @R4
                MOVE    R1, R8
                RSUB    _F32WX_SETDE, 1
                CMP     0, R9
                RBRA    _F32W_SY_RET, !Z
                MOVE    FAT32$FDHF_SIZECHG, R4
                NOT     R4, R4
                AND     R4, @R3
_F32W_SY_RET    MOVE    R0, R8
                MOVE    R2, R10
                DECRB
                RET

;*****************************************************************************
;* _F32W_SETSIZE makes a file shorter or longer
;*
;* Shorter: the clusters behind the new end are freed. Longer: clusters are
;* added; the new bytes (including the rest of the old last cluster) are
;* zeros. The position of the file handle is 0 afterwards.
;*
;* INPUT:  R8  file handle (from FAT32$W_FDH)
;*         R9  parameter block (PB_DATE, PB_TIME set; the rest is scratch)
;*         R10 new size: low word
;*         R11 new size: high word
;* OUTPUT: R8  unchanged
;*         R9  0 if OK, FAT32$ERR_DISKFULL or another error code
;*         R10..R12 unchanged
;*****************************************************************************
;
_F32W_SETSIZE INCRB
                MOVE    R8, R0                      ; R0: file handle
                MOVE    R9, R1                      ; R1: parameter block
                MOVE    R10, R2                     ; R3|R2: new size
                MOVE    R11, R3
                MOVE    R12, R4
                MOVE    R1, R8                      ; the session (it takes
                ADD     FAT32$PB_WS, R8             ; the buffer away from
                MOVE    R0, R9                      ; the file handle: its
                ADD     FAT32$FDH_DEVICE, R9        ; dirty sector is
                MOVE    @R9, R9                     ; written back first)
                RSUB    _F32WX_BEGIN, 1
                CMP     0, R9
                RBRA    _F32W_SS_RET, !Z
                MOVE    R8, R7                      ; R7: session

                ; clusters needed = (size + cluster - 1) >> k, k = 9 +
                ; log2(spc), into the counter (2 scratch words of the
                ; parameter block: its scan block is not used here)
                MOVE    R2, R8
                MOVE    R3, R9
                MOVE    @R7, R10
                ADD     FAT32$DEV_SECT_PER_CLUS, R10
                MOVE    @R10, R6                    ; R6: spc
                MOVE    R6, R10                     ; R11|R10 := spc * 512 - 1
                SHL     9, R10
                AND     0xFE00, R10
                MOVE    R6, R11
                SHR     7, R11
                AND     0x0001, R11
                SUB     1, R10
                SUBC    0, R11
                ADD     R10, R8
                ADDC    R11, R9
                MOVE    9, R5
_F32W_SS_K      CMP     1, R6
                RBRA    _F32W_SS_SH, Z
                SHR     1, R6
                AND     0x7FFF, R6
                ADD     1, R5
                RBRA    _F32W_SS_K, 1
_F32W_SS_SH     MOVE    R9, R10                     ; R9|R8 >>= 1, k times
                AND     1, R10
                SHR     1, R8
                AND     0x7FFF, R8
                CMP     0, R10
                RBRA    _F32W_SS_S1, Z
                OR      0x8000, R8
_F32W_SS_S1     SHR     1, R9
                AND     0x7FFF, R9
                SUB     1, R5
                RBRA    _F32W_SS_SH, !Z
                MOVE    R1, R10
                ADD     FAT32$PB_SB, R10            ; the counter
                MOVE    R8, @R10++
                MOVE    R9, @R10

                ; no clusters at all: free the chain
                OR      R9, R8
                RBRA    _F32W_SS_KEEP, !Z
                MOVE    R0, R5
                ADD     FAT32$FDH_START_CLUS_LO, R5
                MOVE    @R5++, R9
                MOVE    @R5, R10
                MOVE    R7, R8
                RSUB    _F32WX_FREE, 1
                CMP     0, R9
                RBRA    _F32W_SS_END, !Z
                MOVE    R0, R5
                ADD     FAT32$FDH_START_CLUS_LO, R5
                MOVE    0, @R5++
                MOVE    0, @R5
                RBRA    _F32W_SS_FDH, 1

                ; keep or add clusters up to the needed number: R6|R5 = the
                ; cluster, R12 = 1 while the chain is being extended
_F32W_SS_KEEP   XOR     R12, R12
                MOVE    R0, R8
                ADD     FAT32$FDH_START_CLUS_LO, R8
                MOVE    @R8++, R5
                MOVE    @R8, R6
                MOVE    R5, R8
                OR      R6, R8
                RBRA    _F32W_SS_C1, !Z
                MOVE    R7, R8                      ; an empty file: the
                XOR     R9, R9                      ; first cluster
                XOR     R10, R10
                RSUB    _F32WX_ALLOC, 1
                CMP     0, R9
                RBRA    _F32W_SS_END, !Z
                MOVE    R10, R5
                MOVE    R11, R6
                RSUB    _F32W_SS_Z, 1
                CMP     0, R9
                RBRA    _F32W_SS_END, !Z
                MOVE    R0, R8
                ADD     FAT32$FDH_START_CLUS_LO, R8
                MOVE    R5, @R8++
                MOVE    R6, @R8
                MOVE    1, R12
_F32W_SS_C1     MOVE    R1, R8                      ; the counter - 1
                ADD     FAT32$PB_SB, R8
                SUB     1, @R8++
                SUBC    0, @R8
                MOVE    @R8, R9
                SUB     1, R8
                OR      @R8, R9
                RBRA    _F32W_SS_LAST, Z
                MOVE    R7, R8                      ; the next cluster
                MOVE    R5, R9
                MOVE    R6, R10
                RSUB    _F32WX_FATGET, 1
                CMP     0, R9
                RBRA    _F32W_SS_END, !Z
                MOVE    R10, R9
                MOVE    R11, R10
                RSUB    _F32WX_ISDATA, 1
                RBRA    _F32W_SS_ADD, !C
                MOVE    R9, R5
                MOVE    R10, R6
                RBRA    _F32W_SS_C1, 1
_F32W_SS_ADD    CMP     0, R12                      ; the chain ends here: the
                RBRA    _F32W_SS_A2, !Z             ; rest of the old last
                RSUB    _F32W_SS_TAIL, 1            ; cluster becomes zeros
                CMP     0, R9
                RBRA    _F32W_SS_END, !Z
                MOVE    1, R12
_F32W_SS_A2     MOVE    R7, R8
                MOVE    R5, R9
                MOVE    R6, R10
                RSUB    _F32WX_ALLOC, 1
                CMP     0, R9
                RBRA    _F32W_SS_END, !Z
                MOVE    R10, R5
                MOVE    R11, R6
                RSUB    _F32W_SS_Z, 1
                CMP     0, R9
                RBRA    _F32W_SS_END, !Z
                RBRA    _F32W_SS_C1, 1

                ; R6|R5 is the last cluster: cut the chain behind it, or
                ; zero the rest of it if the file grows inside it
_F32W_SS_LAST   MOVE    R7, R8
                MOVE    R5, R9
                MOVE    R6, R10
                RSUB    _F32WX_FATGET, 1
                CMP     0, R9
                RBRA    _F32W_SS_END, !Z
                MOVE    R10, R9
                MOVE    R11, R10
                RSUB    _F32WX_ISDATA, 1
                RBRA    _F32W_SS_CUT, C
                CMP     0, R12                      ; same last cluster: zero
                RBRA    _F32W_SS_FDH0, !Z           ; from the old end on if
                RSUB    _F32W_SS_TAIL, 1            ; the file grows
                CMP     0, R9
                RBRA    _F32W_SS_END, !Z
                RBRA    _F32W_SS_FDH0, 1
_F32W_SS_CUT    MOVE    R9, @--SP                   ; the rest of the chain
                MOVE    R10, @--SP
                MOVE    R7, R8
                MOVE    R5, R9
                MOVE    R6, R10
                MOVE    0xFFFF, R11
                MOVE    0x0FFF, R12
                RSUB    _F32WX_FATSET, 1
                MOVE    @SP++, R10
                MOVE    @SP++, R11
                CMP     0, R9
                RBRA    _F32W_SS_END, !Z
                MOVE    R11, R9
                RSUB    _F32WX_FREE, 1
                CMP     0, R9
                RBRA    _F32W_SS_END, !Z

                ; the file handle: new size, position 0
_F32W_SS_FDH0
_F32W_SS_FDH    MOVE    R0, R8
                ADD     FAT32$FDH_START_CLUS_LO, R8
                MOVE    @R8++, R5
                MOVE    @R8, R6
                MOVE    R0, R8
                ADD     FAT32$FDH_CLUSTER_LO, R8
                MOVE    R5, @R8++
                MOVE    R6, @R8++
                MOVE    0, @R8++                    ; FDH_SECTOR
                MOVE    0, @R8++                    ; FDH_INDEX
                MOVE    R2, @R8++                   ; FDH_SIZE
                MOVE    R3, @R8++
                MOVE    0, @R8++                    ; FDH_ACCESS
                MOVE    0, @R8
                MOVE    R0, R8
                ADD     FAT32$FDH_FLAGS, R8
                MOVE    FAT32$FDHF_SIZECHG, @R8     ; (not dirty any more)
                XOR     R9, R9
_F32W_SS_END    MOVE    R9, R5
                MOVE    R7, R8
                RSUB    _F32WX_END, 1
                CMP     0, R5
                RBRA    _F32W_SS_E1, Z
                MOVE    R5, R9
                RBRA    _F32W_SS_RET, 1
_F32W_SS_E1     CMP     0, R9
                RBRA    _F32W_SS_RET, !Z
                MOVE    R0, R8                      ; the directory entry
                MOVE    R1, R9
                RSUB    _F32W_SYNC, 1
_F32W_SS_RET    MOVE    R0, R8
                MOVE    R2, R10
                MOVE    R3, R11
                MOVE    R4, R12
                DECRB
                RET

; _F32W_SS_Z: zero the cluster R6|R5 (session R7). R9 = error.
_F32W_SS_Z      MOVE    R7, R8
                MOVE    R5, R9
                MOVE    R6, R10
                RSUB    _F32WX_ZEROCL, 1
                RET

; _F32W_SS_TAIL: zero the cluster R6|R5 from the old end of the file (FDH
; R0: FDH_SIZE) on, if that end is inside it (session R7). R9 = error.
_F32W_SS_TAIL   MOVE    R0, R8                      ; offset of the old end
                ADD     FAT32$FDH_SIZE_LO, R8       ; in its cluster:
                MOVE    @R8, R9                     ; size % (spc * 512)
                MOVE    @R7, R10
                ADD     FAT32$DEV_SECT_PER_CLUS, R10
                MOVE    @R10, R10
                SHL     9, R10                      ; (spc 128: 0 = 65536)
                SUB     1, R10
                AND     R10, R9                     ; R9: offset (0: the end
                CMP     0, R9                       ; is a cluster boundary,
                RBRA    _F32W_ST_OK, Z              ; nothing to zero)
                MOVE    R9, @--SP
                MOVE    R9, R11                     ; the sector of the end
                SWAP    R11, R11
                SHR     1, R11
                AND     0x007F, R11
_F32W_ST_SEC    MOVE    R5, R9
                MOVE    R6, R10
                MOVE    R7, R8
                RSUB    _F32WX_CLSEC, 1              ; R10|R9: LBA
                RSUB    _F32WX_SEC, 1
                CMP     0, R9
                RBRA    _F32W_ST_ERR, !Z
                MOVE    @SP, R9                     ; from the byte of the
                AND     0x01FF, R9                  ; end (first sector) or
                MOVE    @R7, R8                     ; 0 (the others)
                XOR     R10, R10
_F32W_ST_B      RSUB    FAT32$WRITE_B, 1
                ADD     1, R9
                CMP     512, R9
                RBRA    _F32W_ST_B, !Z
                MOVE    R7, R8
                ADD     FAT32$WS_DIRTY, R8
                MOVE    1, @R8
                MOVE    0, @SP                      ; whole sectors from now
                ADD     1, R11
                MOVE    @R7, R8
                ADD     FAT32$DEV_SECT_PER_CLUS, R8
                CMP     @R8, R11
                RBRA    _F32W_ST_SEC, !Z
                XOR     R9, R9
_F32W_ST_ERR    ADD     1, SP
                RET
_F32W_ST_OK     XOR     R9, R9
                RET
