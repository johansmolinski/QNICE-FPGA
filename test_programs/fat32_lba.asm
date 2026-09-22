;
; FAT32 sector-address overflow and calling-convention regression test.
; Run with fat32_lba.py; generated includes refer to a freshly built Monitor.
; The dummy device records sector requests without accessing any storage.
;
; For MiSTer2MEGA65 and its ports of work by the MiSTer development team.
; QNICE-FPGA test, 2026, licensed under GPL v3.
;

#include "../monitor/sysdef.asm"
#include "monitor.def"
#include "fat32_lba_symbols.asm"

                .ORG 0x8000
                RBRA START, 1

#include "fat32_lba_cases.asm"

START           MOVE HANDLE_DEV, R0
                ADD FAT32$DEV_BLOCK_READ, R0
                MOVE READ_STUB, @R0
                MOVE HANDLE_DEV, R0
                ADD FAT32$DEV_BLOCK_WRITE, R0
                MOVE WRITE_STUB, @R0
                MOVE TEST_CASES, R0
                MOVE TEST_COUNT, R1

                ; Each row: cluster lo/hi, sectors per cluster, base lo/hi,
                ; sector within cluster, read/write mode, device return code.
TEST_LOOP       MOVE @R0++, R9
                MOVE @R0++, R10
                MOVE HANDLE_DEV, R2
                ADD FAT32$DEV_SECT_PER_CLUS, R2
                MOVE @R0++, @R2
                MOVE HANDLE_DEV, R2
                ADD FAT32$DEV_CLUSTER_LO, R2
                MOVE @R0++, @R2++
                MOVE @R0++, @R2
                MOVE @R0++, R11
                MOVE @R0++, R12
                MOVE DEVICE_ERROR, R2
                MOVE @R0++, @R2

                MOVE DEVICE_CALLS, R2
                MOVE 0, @R2++
                MOVE 0, @R2++
                MOVE 0, @R2++
                MOVE 0, @R2
                MOVE HANDLE_DEV, R8
                RSUB CHECK_CALL, 1

                ; Print return code, callback count, LBA hi/lo and mode.
                MOVE R9, R8
                SYSCALL(puthex, 1)
                MOVE DEVICE_CALLS, R2
                MOVE 4, R3
PRINT_FIELD     MOVE STR_SPACE, R8
                SYSCALL(puts, 1)
                MOVE @R2++, R8
                SYSCALL(puthex, 1)
                SUB 1, R3
                RBRA PRINT_FIELD, !Z
                SYSCALL(crlf, 1)
                SUB 1, R1
                RBRA TEST_LOOP, !Z

                MOVE STR_OK, R8
                SYSCALL(puts, 1)
                HALT

                ; Check preservation of the handle, R10..R12, stack and
                ; banked registers. R9 is the documented return value.
CHECK_CALL      INCRB
                MOVE R8, R0
                MOVE R10, R1
                MOVE R11, R2
                MOVE R12, R3
                MOVE SP, R4
                MOVE 0x1357, R5
                MOVE 0x2468, R6
                MOVE 0xA55A, R7
                ASUB TEST_RW_SIC, 1
                CMP R0, R8
                RBRA ABI_ERROR, !Z
                CMP R1, R10
                RBRA ABI_ERROR, !Z
                CMP R2, R11
                RBRA ABI_ERROR, !Z
                CMP R3, R12
                RBRA ABI_ERROR, !Z
                CMP R4, SP
                RBRA ABI_ERROR, !Z
                CMP 0x1357, R5
                RBRA ABI_ERROR, !Z
                CMP 0x2468, R6
                RBRA ABI_ERROR, !Z
                CMP 0xA55A, R7
                RBRA ABI_ERROR, !Z
                DECRB
                RET

ABI_ERROR       MOVE STR_ABI, R8
                SYSCALL(puts, 1)
                HALT

READ_STUB       INCRB
                MOVE 0, R1
                RBRA DEVICE_STUB, 1
WRITE_STUB      INCRB
                MOVE 1, R1
DEVICE_STUB     MOVE DEVICE_CALLS, R0
                ADD 1, @R0++
                MOVE R9, @R0++
                MOVE R8, @R0++
                MOVE R1, @R0
                MOVE DEVICE_ERROR, R8
                MOVE @R8, R8
                DECRB
                RET

HANDLE_DEV      .BLOCK FAT32$DEV_STRUCT_SIZE
DEVICE_CALLS    .DW 0
DEVICE_LBA_HI   .DW 0
DEVICE_LBA_LO   .DW 0
DEVICE_MODE     .DW 0
DEVICE_ERROR    .DW 0
STR_SPACE       .ASCII_W " "
STR_OK          .ASCII_W "FAT32-LBA-OK\n"
STR_ABI         .ASCII_W "FAT32-LBA-ABI-ERROR\n"
