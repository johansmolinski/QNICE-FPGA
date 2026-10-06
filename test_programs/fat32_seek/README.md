FAT32 seek and extent map tests
===============================

Tests for `FAT32$FILE_SEEK`, `FAT32$FILE_MAP` and `FAT32$FILE_SEEK_MAP` of
`monitor/fat32_library.asm`, run in the QNICE emulator against real FAT32 SD
card images.

```
./run.sh                    # all tests, cluster sizes 512 B, 4 KB and 32 KB
./run.sh --compare 2eb27dd  # speed: same seek workload, library of a git revision vs. this one
./run.sh --mutants          # mutation tests: every mutant must make the tests fail
```

Needs `cc`, `python3`, `perl`, dosfstools (`mkfs.vfat`, `fsck.vfat`) and
mtools. The assembler, the emulator and the images (sparse, up to 2.2 GB) are
built below `./work`.

What is tested
--------------

`gen.py` creates an SD card image (MBR + FAT32) per cluster size with these
files. The content of every file is a sequence of 32-bit big-endian counters,
so any byte can be checked from its position alone:

| File  | Content |
|-------|---------|
| T.BIN | large and contiguous (6 MB, 24 MB with 32 KB clusters) |
| F.BIN | fragmented: its clusters are moved to scattered free clusters in random order, also backwards (26 to 31 extents) |
| S.BIN | 1000 bytes, not a multiple of 512 |
| E.BIN | exactly 3 clusters |
| Z.BIN | empty |
| C.BIN | damaged chain: ends with an end-of-chain marker after 10 of 20 clusters |
| D.BIN | damaged chain: the 10th cluster points to a free cluster |

`fsck.vfat` must report the image as clean before C.BIN and D.BIN are damaged.
`gen.py` parses the FAT itself to know the extents of every file and writes a
table of operations, which `test_body.asm` executes:

* seeks with and without an extent map to every cluster boundary (and +/-1),
  sector boundaries, the first and the last byte, the end of the file and past
  it, plus random positions in random order (backwards and forwards) and
  ascending runs; after every seek up to 1100 bytes are read and compared
* building maps, including a buffer that is one extent too small
  (`FAT32$ERR_MAPSIZE`, and the extent count is still returned)
* writes: the inverted pattern is written, read back, the original pattern is
  written again and read back
* damaged chains: data in front of the damage reads fine, seeks behind it and
  map builds fail with `FAT32$ERR_CHAIN`

The test program also checks its own integrity on every operation (a checksum
over its code and table, its register bank and its registers). After the run,
`hostcheck.py` extracts every intact file from the image and compares it with
the expected content, which catches writes to wrong places.
