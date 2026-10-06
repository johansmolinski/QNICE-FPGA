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
#include "test_body.asm"
#include "tests.inc"
                .ORG    0xB000
T_FDH           .BLOCK  FAT32$FDH_STRUCT_SIZE
T_ORIG_RD       .BLOCK  1
T_READS         .BLOCK  1
T_RECNO         .BLOCK  1
T_NFAIL         .BLOCK  1
T_FAILPOS       .BLOCK  2
T_MAPBUF        .BLOCK  1025
T_SAVE_R0       .BLOCK  1
T_SAVE_R7       .BLOCK  1
T_SAVE_CS       .BLOCK  1
#include "variables.asm"
