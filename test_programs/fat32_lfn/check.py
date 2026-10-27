#!/usr/bin/env python3
"""check.py <emulator log> <long name>: the harness listed first.adf, the long
entry as <long name>, last.adf, no error, and the stack pointer never moved."""
import sys
lines = open(sys.argv[1], "rb").read().decode("latin-1").splitlines()
want = ["first.adf", sys.argv[2], "last.adf", "last.adf"]   # the end repeats the last entry
sp = [l for l in lines if l.startswith("SP=")]
if "RESULT: DONE" not in lines or len(sp) != 1 + len(want):
    print("  no clean end:", lines[:6]); sys.exit(1)
start = sp[0][3:7]
for l, w in zip(sp[1:], want):
    if l != "SP=%s R11=0000 name=%s" % (start, w):
        print("  got", l[:100], "want", w[:40]); sys.exit(1)
