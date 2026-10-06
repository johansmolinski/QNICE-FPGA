#!/usr/bin/env python3
"""After a run: every intact file on the image must still hold exactly its
pattern. The write tests restore what they overwrite, so a write to a wrong
place shows up here."""
import os, struct, subprocess, sys, tempfile
img, exp = sys.argv[1], sys.argv[2]
bad = 0
for line in open(exp):
    name, size = line.split()
    size = int(size)
    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, name)
        subprocess.run(["mcopy", "-i", f"{img}@@{2048 * 512}", "::" + name, out], check=True)
        data = open(out, "rb").read()
    want = b"".join(struct.pack(">I", i) for i in range((size + 3) // 4))[:size]
    if data != want:
        bad += 1
        print(f"HOSTCHECK: {name} differs")
print("HOSTCHECK:", "PASS" if bad == 0 else f"FAIL ({bad} files)")
