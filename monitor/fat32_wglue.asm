;*****************************************************************************
;* FAT32 write layer: the entry points in a flat program
;*
;* The write layer is fat32_write.asm (the core) and fat32_wfile.asm (writing
;* files). A program that has them in its normal address space (the tests, a
;* monitor) includes this file as well: it maps the public names to the
;* routines, and the names the file part uses for the core to the core.
;*
;* The Megamiga firmware does not include this file: it puts the two parts
;* into QNICE code banks and defines the same names as FAR_CALL stubs (see
;* CORE/m2m-rom/m2m-rom.asm), because code in one bank cannot call another.
;*
;* (The assembler cannot .EQU one label to another, hence the jumps: the
;* routine returns straight to the caller.)
;*****************************************************************************

; public: the core
FAT32$W_CREATE  ABRA    _F32W_CREATE, 1
FAT32$W_DELETE  ABRA    _F32W_DELETE, 1
FAT32$W_SETDE   ABRA    _F32W_SETDE, 1
FAT32$W_MKDIR   ABRA    _F32W_MKDIR, 1
FAT32$W_RENAME  ABRA    _F32W_RENAME, 1
; public: writing files
FAT32$W_FDH     ABRA    _F32W_FDH, 1
FAT32$W_PUT     ABRA    _F32W_PUT, 1
FAT32$W_ADV     ABRA    _F32W_ADV, 1
FAT32$W_SYNC    ABRA    _F32W_SYNC, 1
FAT32$W_SETSIZE ABRA    _F32W_SETSIZE, 1
; the core routines that the file part uses
_F32WX_BEGIN    ABRA    _F32W_BEGIN, 1
_F32WX_END      ABRA    _F32W_END, 1
_F32WX_SCAN     ABRA    _F32W_SCAN, 1
_F32WX_FATGET   ABRA    _F32W_FATGET, 1
_F32WX_FATSET   ABRA    _F32W_FATSET, 1
_F32WX_ISDATA   ABRA    _F32W_ISDATA, 1
_F32WX_ALLOC    ABRA    _F32W_ALLOC, 1
_F32WX_FREE     ABRA    _F32W_FREE, 1
_F32WX_ZEROCL   ABRA    _F32W_ZEROCL, 1
_F32WX_CLSEC    ABRA    _F32W_CLSEC, 1
_F32WX_SEC      ABRA    _F32W_SEC, 1
_F32WX_SETDE    ABRA    _F32W_SETDE, 1
