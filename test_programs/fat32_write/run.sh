#!/bin/bash
# FAT32 write layer tests in the QNICE emulator: ./run.sh [spc ...] (default 1 8 64)
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

# phase <case dir> <phase>
phase() {
    local C=$1 P=$2 B=$1/build-$2
    rm -rf "$B"; mkdir -p "$B"
    python3 "$H/gen.py" "$C" table "$P" "$C/build-A/emu.log"
    cp "${LIB:-$ROOT/monitor}"/*.asm "$H/harness.asm" "$H/test_body.asm" "$C/tests.inc" "$B/"
    (cd "$B" && cc -xc -E harness.asm 2>cpp.err | sed '/^#.*/d' > __t.asm &&
        "$W/qasm" __t.asm test.out test.lis > qasm.log 2>&1) || { tail -20 "$B/qasm.log"; return 1; }
    (cd "$C" && timeout ${TMO:-3000} "$W/emu/qnice" -a sd.img "$B/test.out" < /dev/null > "$B/emu.log" 2>&1) || true
    python3 "$H/check.py" "$C" "$P" "$B/emu.log"
}

for spc in ${@:-1 8 64}; do
    C=$W/case$spc
    rm -rf "$C"; python3 "$H/gen.py" "$C" $spc
    python3 -c "
import sys; sys.path.insert(0, '$H'); from fatimg import Vol
open('$C/free0.txt', 'w').write(str(Vol('$C/sd.img').free_count()))"
    echo "== cluster $((spc * 512)) bytes"
    phase "$C" A
    phase "$C" B
    phase "$C" C
    phase "$C" D
    phase "$C" E
done
