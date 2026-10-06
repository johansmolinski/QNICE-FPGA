import re, sys
for d in sys.argv[1:]:
    print(f"== {d}")
    for lib in ("old", "new"):
        try:
            log = open(f"{d}/build-{lib}/emu.log", errors="replace").read()
        except FileNotFoundError:
            print(f"  {lib}: no log"); continue
        res = re.search(r"RESULT: (\w+)", log)
        fails = len(re.findall(r"FAIL rec", log))
        reads = [int(x, 16) for x in re.findall(r"stats \w{4} block reads (\w{4})", log)]
        ins = re.search(r"(\d+) instructions have been executed", log)
        print(f"  {lib}: result {res.group(1) if res else 'none (timeout?)'}, failures printed {fails}, "
              f"instructions {int(ins.group(1)) if ins else '?':,}, block reads per file {reads}, total {sum(reads)}")
