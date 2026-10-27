#!/bin/bash
# FAT32$DIR_LIST with damaged long names in the QNICE emulator: ./run.sh
# LIB=<dir> takes the library from another monitor directory (mutants.py).
set -e
H=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$H/../.." && pwd)
W=${WORK:-$H/work}
mkdir -p "$W"
export PATH=$PATH:/usr/sbin
if [ ! -x "$W/qasm" ]; then cc -O2 -w -o "$W/qasm" "$ROOT/assembler/qasm.c"; fi
if [ ! -x "$W/emu/qnice" ]; then
    rm -rf "$W/emu" "$W/dist_kit"; mkdir -p "$W/emu" "$W/dist_kit"
    cp "$ROOT"/emulator/*.c "$ROOT"/emulator/*.h "$W/emu/"
    perl "$ROOT/monitor/sysdef2header.pl" "$ROOT/monitor/sysdef.asm" "$W/dist_kit/sysdef.h"
    (cd "$W/emu" && cc qnice.c uart.c sd.c timer.c -O3 -fcommon -DUSE_SD -DUSE_UART -DUSE_TIMER \
        -UUSE_VGA -UUSE_IDE -U__EMSCRIPTEN__ -UDEBUG -lpthread -o qnice 2>/dev/null)
fi
B=$W/build; rm -rf "$B"; mkdir -p "$B"
cp "${LIB:-$ROOT/monitor}"/*.asm "$H/harness.asm" "$B/"
(cd "$B" && cc -xc -E harness.asm 2>cpp.err | sed '/^#.*/d' > __t.asm &&
    "$W/qasm" __t.asm test.out test.lis > qasm.log 2>&1) || { tail -20 "$B/qasm.log"; exit 1; }
fail=0
for c in ok l255 seq last chk zero big n21 n63; do
    want=$(python3 "$H/gen.py" "$W/$c.img" $c)
    timeout ${TMO:-20} "$W/emu/qnice" -a "$W/$c.img" "$B/test.out" < /dev/null > "$W/$c.log" 2>&1 || true
    if python3 "$H/check.py" "$W/$c.log" "$want"; then echo "$c: OK"; else echo "$c: FAIL"; fail=1; fi
done
[ $fail = 0 ] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }
