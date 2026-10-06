#!/bin/bash
# Run the FAT32 seek / extent map test suite in the QNICE emulator.
#
#   ./run.sh                 all cluster sizes (512 B, 4 KB, 32 KB) with the
#                            library of this working tree
#   ./run.sh --compare REV   additionally run a seek-only workload with the
#                            library of git revision REV and compare speed
#   ./run.sh --mutants       mutation tests (every mutant must fail)
#
# Needs: cc, python3, perl, mkfs.vfat + fsck.vfat (dosfstools), mtools.
# Everything is built and generated below ./work (images up to ~2.2 GB,
# sparse).
set -e
H=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$H/../.." && pwd)
W=${WORK:-$H/work}
mkdir -p "$W"

# --- tools: assembler and emulator, built from this tree --------------------
if [ ! -x "$W/qasm" ]; then
    cc -O2 -w -o "$W/qasm" "$ROOT/assembler/qasm.c"
fi
if [ ! -x "$W/emu/qnice" ]; then
    rm -rf "$W/emu" "$W/dist_kit"; mkdir -p "$W/emu" "$W/dist_kit"
    cp "$ROOT"/emulator/*.c "$ROOT"/emulator/*.h "$W/emu/"
    perl "$ROOT/monitor/sysdef2header.pl" "$ROOT/monitor/sysdef.asm" "$W/dist_kit/sysdef.h"
    (cd "$W/emu" && cc qnice.c uart.c sd.c timer.c -O3 -fcommon -DUSE_SD -DUSE_UART -DUSE_TIMER \
        -UUSE_VGA -UUSE_IDE -U__EMSCRIPTEN__ -UDEBUG -lpthread -o qnice 2>/dev/null)
fi

# run_case <library dir> <case dir> <build name>
run_case() {
    local LIBDIR=$1 CASE=$2 B=$2/build-$3
    rm -rf "$B"; mkdir -p "$B"
    cp "$LIBDIR"/*.asm "$B/"
    cp "$H/harness.asm" "$H/test_body.asm" "$CASE/tests.inc" "$B/"
    if ! grep -q 'FAT32$FILE_MAP ' "$B/fat32_library.asm"; then
        # a library without extent maps: stubs, never called by --seek-only tables
        printf 'FAT32$FILE_MAP  HALT\nFAT32$FILE_SEEK_MAP HALT\n' >> "$B/fat32_library.asm"
    fi
    (cd "$B" && cc -xc -E harness.asm 2>cpp.err | sed '/^#.*/d' > __t.asm &&
        "$W/qasm" __t.asm test.out test.lis > qasm.log 2>&1) || { tail -20 "$B/qasm.log"; return 1; }
    cp --sparse=always "$CASE/sd.img" "$B/sd.img"
    (cd "$B" && timeout ${TMO:-3000} "$W/emu/qnice" -a sd.img test.out < /dev/null > emu.log 2>&1) || true
    python3 "$H/hostcheck.py" "$B/sd.img" "$CASE/expected.txt" >> "$B/emu.log"
    rm -f "$B/sd.img"
    grep -a -o -E "RESULT: [A-Z]+( count [0-9A-F]+)?|HOSTCHECK: [A-Z]+( \([0-9]+ files\))?" "$B/emu.log" | tr "\n" " "
}

MODE=${1:-all}
case $MODE in
all)
    for spc in 1 8 64; do
        C=$W/case$spc
        [ -f "$C/sd.img" ] || python3 "$H/gen.py" "$C" $spc > "$C.gen.log"
        echo "cluster $((spc * 512)) bytes: $(run_case "$ROOT/monitor" "$C" new)"
    done ;;
--compare)
    REV=${2:?revision}
    OLD=$W/lib-old; rm -rf "$OLD"; mkdir -p "$OLD"
    git -C "$ROOT" archive "$REV" monitor | tar -x -C "$OLD" --strip-components=1
    for spc in 1 8 64; do
        C=$W/so$spc
        [ -f "$C/sd.img" ] || python3 "$H/gen.py" "$C" $spc --seek-only > "$C.gen.log"
        run_case "$OLD" "$C" old > /dev/null; run_case "$ROOT/monitor" "$C" new > /dev/null
        python3 "$H/compare.py" "$C"
    done ;;
--mutants)
    for spc in 1 8 64; do
        C=$W/case$spc
        [ -f "$C/sd.img" ] || python3 "$H/gen.py" "$C" $spc > "$C.gen.log"
    done
    python3 "$H/mutants.py" "$ROOT/monitor" "$W" ;;
*)  echo "usage: $0 [--compare REV | --mutants]"; exit 1 ;;
esac
