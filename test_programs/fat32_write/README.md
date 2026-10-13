FAT32 write layer tests
=======================

Tests for `monitor/fat32_write.asm` (the core: write sessions, FAT, clusters,
directory entries) and `monitor/fat32_wfile.asm` (writing files), run in the
QNICE emulator against real FAT32 SD card images.

```
./run.sh             # cluster sizes 512 B, 4 KB and 32 KB, phases A..E
./run.sh 8           # only 4 KB clusters
python3 mutants.py   # mutation tests (every mutant must make run.sh fail)
```

Needs `cc`, `python3`, `perl`, dosfstools (`mkfs.vfat`, `fsck.vfat` in
`/usr/sbin`) and mtools. `gen.py` makes the image (files, holes from deleted
files, a directory `SUB`, a deleted file of garbage bytes) and one table of
operations per phase; `test_body.asm` runs it; `check.py` checks the image.

| Phase | What                                                                    |
|-------|-------------------------------------------------------------------------|
| A     | allocate and free chains (across FAT sectors, a search that wraps):     |
|       | the chains, FAT1 = FAT2, the FSInfo free count, the files intact        |
| B     | free what is left, fill the card completely (512 B clusters), free it: |
|       | free count back, `fsck.fat` clean                                       |
| C     | create and delete entries: long names, short names and their numeric   |
|       | tails, names that FAT refuses, existing names (also by short name),     |
|       | a directory that grows across clusters, reuse of deleted slots, set    |
|       | date and attributes; every entry address, `fsck.fat` clean             |
| D     | write files: across sectors and clusters, overwrite, append, cut,     |
|       | extend (zeros, also the rest of the old last cluster), empty; the     |
|       | contents via mtools, the chain lengths, `fsck.fat` clean               |
| E     | directories and renaming: mkdir, move a file with its data, another   |
|       | case of the same name, an existing name, a directory into itself,    |
|       | a directory to the root (its ".."), delete a directory                |
