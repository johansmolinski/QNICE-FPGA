#!/usr/bin/env python3
"""Test FAT32$RW_SIC address bounds using a freshly assembled Monitor.

Run: python3 test_programs/fat32_lba.py
Requires cc, assembler/qasm and emulator/qnice. All build products go into a
temporary directory. No SD image or physical storage device is accessed.

For MiSTer2MEGA65 and its ports of work by the MiSTer development team.
QNICE-FPGA test, 2026, licensed under GPL v3.
"""

from dataclasses import dataclass
from pathlib import Path
import re
import subprocess
import sys
import tempfile


QNICE = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Case:
    name: str
    cluster: int
    sectors_per_cluster: int
    base: int
    sector: int = 0
    mode: int = 0
    device_error: int = 0

    def words(self):
        return (
            self.cluster & 0xFFFF, self.cluster >> 16,
            self.sectors_per_cluster, self.base & 0xFFFF, self.base >> 16,
            self.sector, self.mode, self.device_error,
        )

    def expected(self):
        # Independent integer arithmetic: the device accepts a 32-bit LBA.
        if self.sector >= self.sectors_per_cluster:
            return (0xEE16, 0, 0, 0, 0)
        if self.cluster < 2:
            return (0xEE17, 0, 0, 0, 0)
        lba = (self.cluster - 2) * self.sectors_per_cluster + self.base + self.sector
        if lba > 0xFFFFFFFF:
            return (0xEE14, 0, 0, 0, 0)
        return (self.device_error, 1, lba >> 16, lba & 0xFFFF, self.mode)


def cases():
    result = []
    for mode in (0, 1):
        # All legal FAT32 cluster sizes, including carries into the LBA high word.
        for spc in (1, 2, 4, 8, 16, 32, 64, 128):
            result.append(Case(f"normal_spc{spc}_mode{mode}", 0x1234, spc,
                               0xFFFF, spc - 1, mode))
        for name, cluster, spc, base, sector, error in (
            ("first_cluster", 2, 8, 0x800, 0, 0),
            ("high_cluster_word", 0x10002, 8, 0x800, 0, 0),
            ("last_32bit_lba", 0x02000001, 128, 0x7F, 0, 0),
            ("product_overflow", 0x02000002, 128, 0x800, 0, 0),
            ("base_addition_overflow", 3, 1, 0xFFFFFFFF, 0, 0),
            ("sector_addition_overflow", 2, 8, 0xFFFFFFFF, 1, 0),
            ("invalid_cluster_zero", 0, 8, 0x800, 0, 0),
            ("invalid_cluster_one", 1, 8, 0x800, 0, 0),
            ("invalid_sector", 2, 8, 0x800, 8, 0),
            ("device_error", 0x1234, 8, 0x800, 3, 0x1234),
        ):
            result.append(Case(f"{name}_mode{mode}", cluster, spc, base,
                               sector, mode, error))
    return result


def assemble(source, output, includes=()):
    command = ["cc", "-xc", "-E"]
    for directory in includes:
        command.extend(["-I", str(directory)])
    pre = subprocess.run(command + [str(source)], check=True,
                         capture_output=True, text=True, timeout=30)
    preprocessed = output.with_suffix(".asm")
    preprocessed.write_text("\n".join(
        line for line in pre.stdout.splitlines() if not line.startswith("#")
    ) + "\n")
    subprocess.run([str(QNICE / "assembler/qasm"), str(preprocessed), str(output)],
                   check=True, capture_output=True, text=True, timeout=30)


def main():
    for tool in ("assembler/qasm", "emulator/qnice"):
        if not (QNICE / tool).is_file():
            print(f"FAIL: missing {QNICE / tool}; build the QNICE toolchain first")
            return 1

    tests = cases()
    with tempfile.TemporaryDirectory(prefix="qnice-fat32-lba-") as directory:
        work = Path(directory)
        monitor = work / "monitor.out"
        assemble(QNICE / "monitor/monitor.asm", monitor)
        listing = monitor.with_suffix(".lis").read_text()
        match = re.search(r"FAT32\$RW_SIC\s+:\s+(0x[0-9A-Fa-f]+)", listing)
        if not match:
            raise RuntimeError("FAT32$RW_SIC missing from Monitor symbol table")
        (work / "fat32_lba_symbols.asm").write_text(
            f"TEST_RW_SIC .EQU {match.group(1)}\n"
        )
        rows = [f"TEST_COUNT .EQU {len(tests)}", "TEST_CASES"]
        for case in tests:
            rows.append("    .DW " + ", ".join(f"0x{word:04X}" for word in case.words()))
        (work / "fat32_lba_cases.asm").write_text("\n".join(rows) + "\n")
        testbed = work / "testbed.out"
        assemble(Path(__file__).with_suffix(".asm"), testbed, includes=(work,))
        run = subprocess.run(
            [str(QNICE / "emulator/qnice"), "-b", "0x8000", str(monitor), str(testbed)],
            check=True, stdin=subprocess.DEVNULL, capture_output=True, text=True,
            timeout=30,
        )

    observed = [tuple(int(word, 16) for word in line.split())
                for line in run.stdout.splitlines()
                if re.fullmatch(r"[0-9A-Fa-f]{4}(?: [0-9A-Fa-f]{4}){4}", line)]
    if "FAT32-LBA-OK" not in run.stdout or len(observed) != len(tests):
        print(run.stdout + run.stderr)
        print("FAIL: missing results or register/stack preservation failure")
        return 1
    failures = []
    for case, actual in zip(tests, observed):
        expected = case.expected()
        if actual != expected:
            failures.append(case.name)
            print(f"FAIL {case.name}: expected {expected}, got {actual}")
    if failures:
        return 1
    print(f"PASS: {len(tests)} read/write cases; addresses, errors, callback suppression "
          "and register/stack preservation")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"FAIL: {error}")
        if isinstance(error, subprocess.CalledProcessError):
            print((error.stdout or "") + (error.stderr or ""))
        sys.exit(1)
