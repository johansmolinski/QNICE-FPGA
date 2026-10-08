;
; Regression test: FAT32 shared-sector-buffer ownership.
;
; There is exactly one 512-byte sector buffer, owned by whichever handle is
; recorded in FAT32$DEV_BUFFERED_FDH. Any code that repurposes that buffer has
; to write back the current owner first, otherwise a handle that is in the
; middle of writing a sector loses the bytes it has already deposited.
;
; This testbed drives two files at once the way a caller with two concurrently
; open write handles does: interleaved chunks, alternating handles. That alone
; is the pattern FAT32$READ_FDH has always handled correctly.
;
; The second pair additionally performs a directory open (change directory,
; open directory, list an entry, change back) while one of the handles sits
; dirty in the middle of a sector. FAT32$DIR_OPEN and FAT32$FILE_OPEN used to
; reload the buffer and claim ownership without flushing, which silently threw
; away the dirty bytes.
;
; Driven by fat32_multiwrite.py, which builds the FAT32 image, runs this
; program in the emulator and then compares both files byte by byte.
;
; done in August 2026 and licensed under GPL v3
;

#include "../dist_kit/sysdef.asm"
#include "../dist_kit/monitor.def"

FSIZE           .EQU 4000               ; bytes per file, a multiple of CHUNK
CHUNK           .EQU 100                ; mirrors VD_ITERATION_SIZE in M2M
INJ1            .EQU 500                ; inject after a chunk of file A
INJ2            .EQU 1500               ; inject after a chunk of file B

                .ORG 0x8000

                MOVE    STR_TITLE, R8
                SYSCALL(puts, 1)

                ; mount partition 1 of the attached image
                MOVE    HANDLE_DEV, R8
                MOVE    1, R9
                SYSCALL(f32_mnt_sd, 1)
                CMP     0, R9
                RBRA    MOUNT_OK, Z
                MOVE    STR_E_MNT, R8
                RBRA    DIE, 1

                ; pair 1: interleaved writes only (control)
MOUNT_OK        MOVE    STR_CTRL, R8
                SYSCALL(puts, 1)
                MOVE    HANDLE_A, R8
                MOVE    STR_CTRLA, R9
                RSUB    OPENF, 1
                MOVE    HANDLE_B, R8
                MOVE    STR_CTRLB, R9
                RSUB    OPENF, 1
                MOVE    HANDLE_A, R8
                MOVE    HANDLE_B, R9
                XOR     R10, R10                ; no injection
                RSUB    RUNPAIR, 1

                ; pair 2: interleaved writes plus a directory open mid-sector
                MOVE    STR_TEST, R8
                SYSCALL(puts, 1)
                MOVE    HANDLE_C, R8
                MOVE    STR_TESTA, R9
                RSUB    OPENF, 1
                MOVE    HANDLE_D, R8
                MOVE    STR_TESTB, R9
                RSUB    OPENF, 1
                MOVE    HANDLE_C, R8
                MOVE    HANDLE_D, R9
                MOVE    1, R10                  ; inject directory opens
                RSUB    RUNPAIR, 1

                ; close everything: exercises the ownership release in CLOSE,
                ; one of these handles still owns the sector buffer
                MOVE    HANDLE_A, R8
                RSUB    CLOSEH, 1
                MOVE    HANDLE_B, R8
                RSUB    CLOSEH, 1
                MOVE    HANDLE_C, R8
                RSUB    CLOSEH, 1
                MOVE    HANDLE_D, R8
                RSUB    CLOSEH, 1

                ; read one of the files back through a freshly opened handle
                MOVE    STR_VFY, R8
                SYSCALL(puts, 1)
                MOVE    HANDLE_A, R8
                MOVE    STR_TESTA, R9
                RSUB    OPENF, 1
                MOVE    HANDLE_A, R8
                MOVE    5, R9                   ; step of TESTA
                MOVE    3, R10                  ; seed of TESTA
                RSUB    VERIFY, 1

                MOVE    STR_OK, R8
                SYSCALL(puts, 1)
                SYSCALL(exit, 1)

; ----------------------------------------------------------------------------
; Close the handle in R8
; ----------------------------------------------------------------------------

CLOSEH          SYSCALL(f32_fclose, 1)
                CMP     0, R9
                RBRA    _CLOSEH_RET, Z
                MOVE    STR_E_CLOSE, R8
                RBRA    DIE, 1
_CLOSEH_RET     RET

; ----------------------------------------------------------------------------
; Read a whole file back and compare it against the generator pattern.
; R8: handle, R9: step, R10: seed
; ----------------------------------------------------------------------------

VERIFY          INCRB
                MOVE    R8, R0                  ; R0: handle
                MOVE    R9, R2                  ; R2: step
                MOVE    R10, R1                 ; R1: accumulator
                MOVE    FSIZE, R3               ; R3: bytes left to check

_VFY_LOOP       MOVE    R0, R8
                SYSCALL(f32_fread, 1)           ; R9: byte, R10: status
                CMP     0, R10
                RBRA    _VFY_CMP, Z
                MOVE    STR_E_READ, R8
                MOVE    R10, R9
                RBRA    DIE, 1

_VFY_CMP        MOVE    R1, R4
                AND     0x00FF, R4              ; expected byte
                CMP     R4, R9
                RBRA    _VFY_NEXT, Z
                MOVE    STR_E_VFY, R8
                MOVE    R3, R9                  ; remaining count as a hint
                RBRA    DIE, 1

_VFY_NEXT       ADD     R2, R1
                SUB     1, R3
                RBRA    _VFY_LOOP, !Z

                DECRB
                RET

; ----------------------------------------------------------------------------
; Open a file. R8: file handle, R9: zero terminated path
; ----------------------------------------------------------------------------

OPENF           INCRB
                MOVE    R8, R0
                MOVE    R9, R1
                MOVE    HANDLE_DEV, R8
                MOVE    R0, R9
                MOVE    R1, R10
                XOR     R11, R11                ; use / as path separator
                SYSCALL(f32_fopen, 1)
                CMP     0, R10
                RBRA    _OPENF_RET, Z
                MOVE    STR_E_OPEN, R8
                RBRA    DIE, 1
_OPENF_RET      DECRB
                RET

; ----------------------------------------------------------------------------
; Write one interleaved pair.
; R8: handle A, R9: handle B, R10: 0=no injection, 1=inject directory opens
; ----------------------------------------------------------------------------

RUNPAIR         INCRB
                MOVE    R8, R0                  ; R0: handle A
                MOVE    R9, R1                  ; R1: handle B
                MOVE    R10, R5                 ; R5: injection flag

                MOVE    R0, R8                  ; rewind both handles
                RSUB    SEEK0, 1
                MOVE    R1, R8
                RSUB    SEEK0, 1

                MOVE    3, R3                   ; R3: byte accumulator of A
                MOVE    7, R4                   ; R4: byte accumulator of B
                XOR     R2, R2                  ; R2: bytes written per file

_RP_LOOP        MOVE    R0, R8                  ; next chunk into A
                MOVE    R3, R9
                MOVE    5, R10
                RSUB    WCHUNK, 1
                MOVE    R9, R3

                ADD     CHUNK, R2

                CMP     0, R5                   ; injection wanted?
                RBRA    _RP_NI1, Z
                CMP     INJ1, R2                ; reached the first point?
                RBRA    _RP_NI1, !Z
                RSUB    INJECT, 1               ; A is dirty mid-sector here

_RP_NI1         MOVE    R1, R8                  ; next chunk into B
                MOVE    R4, R9
                MOVE    11, R10
                RSUB    WCHUNK, 1
                MOVE    R9, R4

                CMP     0, R5
                RBRA    _RP_NI2, Z
                CMP     INJ2, R2                ; reached the second point?
                RBRA    _RP_NI2, !Z
                RSUB    INJECT, 1               ; B is dirty mid-sector here

_RP_NI2         CMP     FSIZE, R2
                RBRA    _RP_LOOP, !Z

                MOVE    R0, R8                  ; write out the tail
                RSUB    FLUSHH, 1
                MOVE    R1, R8
                RSUB    FLUSHH, 1

                DECRB
                RET

; ----------------------------------------------------------------------------
; Seek handle in R8 back to position zero
; ----------------------------------------------------------------------------

SEEK0           XOR     R9, R9
                XOR     R10, R10
                SYSCALL(f32_fseek, 1)
                CMP     0, R9
                RBRA    _SEEK0_RET, Z
                MOVE    STR_E_SEEK, R8
                RBRA    DIE, 1
_SEEK0_RET      RET

; ----------------------------------------------------------------------------
; Flush handle in R8
; ----------------------------------------------------------------------------

FLUSHH          SYSCALL(f32_fflush, 1)
                CMP     0, R9
                RBRA    _FLUSHH_RET, Z
                MOVE    STR_E_FLUSH, R8
                RBRA    DIE, 1
_FLUSHH_RET     RET

; ----------------------------------------------------------------------------
; Write CHUNK bytes to the handle in R8.
; R9: byte accumulator, R10: step. Returns the updated accumulator in R9.
; Byte i of the file ends up as (i * step + seed) AND 0xFF.
; ----------------------------------------------------------------------------

WCHUNK          INCRB
                MOVE    R8, R0                  ; R0: handle
                MOVE    R9, R1                  ; R1: accumulator
                MOVE    R10, R2                 ; R2: step
                MOVE    CHUNK, R3               ; R3: bytes to go

_WC_LOOP        MOVE    R0, R8
                MOVE    R1, R9
                AND     0x00FF, R9              ; byte to be written
                SYSCALL(f32_fwrite, 1)
                CMP     0, R9
                RBRA    _WC_NEXT, Z
                MOVE    STR_E_WRITE, R8
                RBRA    DIE, 1

_WC_NEXT        ADD     R2, R1
                SUB     1, R3
                RBRA    _WC_LOOP, !Z

                MOVE    R1, R9                  ; R9 is global, survives DECRB
                DECRB
                RET

; ----------------------------------------------------------------------------
; Walk into a subdirectory and back, exactly like a file browser does.
; This is what used to steal the sector buffer from a dirty write handle.
; ----------------------------------------------------------------------------

INJECT          INCRB
                MOVE    HANDLE_DEV, R8
                MOVE    STR_SUB, R9
                XOR     R10, R10
                SYSCALL(f32_cd, 1)
                CMP     0, R9
                RBRA    _INJ_OD, Z
                MOVE    STR_E_CD, R8
                RBRA    DIE, 1

_INJ_OD         MOVE    HANDLE_DEV, R8
                MOVE    HANDLE_DIR, R9
                SYSCALL(f32_od, 1)
                CMP     0, R9
                RBRA    _INJ_LD, Z
                MOVE    STR_E_OD, R8
                RBRA    DIE, 1

_INJ_LD         MOVE    HANDLE_DIR, R8
                MOVE    DIRENTRY, R9
                MOVE    FAT32$FA_DEFAULT, R10
                SYSCALL(f32_ld, 1)
                CMP     0, R11
                RBRA    _INJ_BACK, Z
                MOVE    STR_E_LD, R8
                RBRA    DIE, 1

_INJ_BACK       MOVE    HANDLE_DEV, R8
                MOVE    STR_ROOT, R9
                XOR     R10, R10
                SYSCALL(f32_cd, 1)
                CMP     0, R9
                RBRA    _INJ_RET, Z
                MOVE    STR_E_CD, R8
                RBRA    DIE, 1

_INJ_RET        DECRB
                RET

; ----------------------------------------------------------------------------
; Print the message in R8 together with the error code in R9 and stop
; ----------------------------------------------------------------------------

DIE             MOVE    R9, R0
                SYSCALL(puts, 1)
                MOVE    R0, R8
                SYSCALL(puthex, 1)
                SYSCALL(crlf, 1)
                SYSCALL(exit, 1)

; ----------------------------------------------------------------------------
; Variables
; ----------------------------------------------------------------------------

HANDLE_DEV      .BLOCK FAT32$DEV_STRUCT_SIZE
HANDLE_A        .BLOCK FAT32$FDH_STRUCT_SIZE
HANDLE_B        .BLOCK FAT32$FDH_STRUCT_SIZE
HANDLE_C        .BLOCK FAT32$FDH_STRUCT_SIZE
HANDLE_D        .BLOCK FAT32$FDH_STRUCT_SIZE
HANDLE_DIR      .BLOCK FAT32$FDH_STRUCT_SIZE
DIRENTRY        .BLOCK FAT32$DE_STRUCT_SIZE

; ----------------------------------------------------------------------------
; Strings
; ----------------------------------------------------------------------------

STR_TITLE       .ASCII_W "FAT32 multi-handle write test\n"
STR_CTRL        .ASCII_W "  pair 1: interleaved writes\n"
STR_TEST        .ASCII_W "  pair 2: interleaved writes plus directory opens\n"
STR_VFY         .ASCII_W "  reading one file back after closing all handles\n"
STR_OK          .ASCII_W "TESTBED-OK\n"

STR_ROOT        .ASCII_W "/"
STR_SUB         .ASCII_W "/subdir"
STR_CTRLA       .ASCII_W "/ctrla.bin"
STR_CTRLB       .ASCII_W "/ctrlb.bin"
STR_TESTA       .ASCII_W "/testa.bin"
STR_TESTB       .ASCII_W "/testb.bin"

STR_E_MNT       .ASCII_W "mount error: "
STR_E_OPEN      .ASCII_W "open error: "
STR_E_SEEK      .ASCII_W "seek error: "
STR_E_WRITE     .ASCII_W "write error: "
STR_E_FLUSH     .ASCII_W "flush error: "
STR_E_CD        .ASCII_W "cd error: "
STR_E_OD        .ASCII_W "opendir error: "
STR_E_LD        .ASCII_W "listdir error: "
STR_E_CLOSE     .ASCII_W "close error: "
STR_E_READ      .ASCII_W "read error: "
STR_E_VFY       .ASCII_W "read back mismatch, bytes left: "
