FAT32 long name tests
=====================

Tests for the long name handling of `FAT32$DIR_LIST` (`monitor/fat32_library.asm`)
with damaged directories, run in the QNICE emulator against FAT32 SD card images.

```
./run.sh             # all cases
python3 mutants.py   # mutation tests (every mutant must make run.sh fail)
```

Needs `cc`, `python3`, `perl`, dosfstools (`mkfs.vfat`) and mtools; the image
helpers are those of `../fat32_write` (`fatimg.py`). `gen.py` makes an image with
`first.adf`, one long name and `last.adf` in the root and damages the long name;
`harness.asm` lists the root and prints the stack pointer after every call;
`check.py` checks the names and that the stack pointer never moved.

| Case   | The long name                                   | Expected          |
|--------|-------------------------------------------------|-------------------|
| `ok`   | intact, 4 records                               | the long name     |
| `l255` | intact, 255 characters = 20 records (maximum)   | the long name     |
| `seq`  | 2nd record: wrong sequence number               | the short name    |
| `last` | last record: wrong sequence number              | the short name    |
| `chk`  | 2nd record: wrong checksum                      | the short name    |
| `zero` | 1st record claims 0 records                     | the short name    |
| `big`  | 1st record claims 63 records                    | the short name    |
| `n21`  | consistent run of 21 records                    | the short name    |
| `n63`  | consistent run of 63 records                    | the short name    |

Before the fix, every damaged case left 13 stack words per record already read
on the stack, so `FAT32$DIR_LIST` returned to a character of the name and the
CPU ran into garbage; a consistent run of more than 20 records overran the
257-word name buffer of the directory entry and the caller's stack.
