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
#include "fat32_write.asm"
#include "fat32_wfile.asm"
#include "fat32_wglue.asm"
QMON$LAST_ADDR  HALT
QMON$WARMSTART  HALT
#include "test_body.asm"
#include "tests.inc"
                .ORG    0xB000
T_WS            .BLOCK  FAT32$WS_SIZE
T_SLOTS         .BLOCK  32                          ; 8 x (first lo/hi, last lo/hi)
T_CNT           .BLOCK  2
T_PB            .BLOCK  FAT32$PB_SIZE
T_EAS           .BLOCK  768                         ; 256 x entry address
T_FDHS          .BLOCK  32                          ; 2 file handles
#include "variables.asm"
