#undef RAM_MONITOR
#define EAE_NO_WAIT
                .ORG    0x0000
#include "sysdef.asm"
                ABRA    TEST_MAIN, 1
#include "io_library.asm"
#include "string_library.asm"
#include "mem_library.asm"
#include "debug_library.asm"
#include "misc_library.asm"
#include "uart_library.asm"
#include "usb_keyboard_library.asm"
#include "vga_library.asm"
#include "math_library.asm"
#include "sd_library.asm"
#include "fat32_library.asm"
QMON$LAST_ADDR  HALT
QMON$WARMSTART  HALT

TEST_MAIN       AND     0x00FF, SR
                MOVE    VAR$STACK_START, SP
                MOVE    _SD$DEVICEHANDLE, R8
                MOVE    1, R9
                RSUB    FAT32$MOUNT_SD, 1
                CMP     0, R9
                RBRA    T_MNT, Z
                MOVE    T_S_MNTERR, R8
                RSUB    IO$PUTS, 1
                HALT
T_MNT           MOVE    T_FDH, R9
                RSUB    FAT32$DIR_OPEN, 1
                MOVE    R8, R0                      ; R0: dir handle
                MOVE    T_S_SP, R8
                RSUB    IO$PUTS, 1
                MOVE    SP, R8
                RSUB    IO$PUT_W_HEX, 1
                RSUB    IO$PUT_CRLF, 1
T_LOOP          MOVE    R0, R8
                MOVE    T_DE, R9
                MOVE    FAT32$FA_DEFAULT, R10
                RSUB    FAT32$DIR_LIST, 1
T_RETADDR       MOVE    R10, R4
                MOVE    R11, R5
                MOVE    T_S_SP, R8
                RSUB    IO$PUTS, 1
                MOVE    SP, R8
                RSUB    IO$PUT_W_HEX, 1
                MOVE    T_S_R11, R8
                RSUB    IO$PUTS, 1
                MOVE    R5, R8
                RSUB    IO$PUT_W_HEX, 1
                MOVE    T_S_NM, R8
                RSUB    IO$PUTS, 1
                MOVE    T_DE, R8
                ADD     FAT32$DE_NAME, R8
                RSUB    IO$PUTS, 1
                RSUB    IO$PUT_CRLF, 1
                CMP     0, R5
                RBRA    T_END, !Z
                CMP     1, R4
                RBRA    T_LOOP, Z
T_END           MOVE    T_S_DONE, R8
                RSUB    IO$PUTS, 1
                HALT
T_S_MNTERR      .ASCII_W "mount error\n"
T_S_SP          .ASCII_W "SP="
T_S_R11         .ASCII_W " R11="
T_S_NM          .ASCII_W " name="
T_S_DONE        .ASCII_W "RESULT: DONE\n"
                .ORG    0xB000
T_FDH           .BLOCK  FAT32$FDH_STRUCT_SIZE
T_DE            .BLOCK  FAT32$DE_STRUCT_SIZE
#include "variables.asm"
