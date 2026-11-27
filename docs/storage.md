# IDE storage

For direct QEMU boot, add `-machine pc -drive file=disk.raw,format=raw,if=ide,index=0`. For QCOW2, set `format=qcow2`. The driver uses the PIIX3 primary master and 512-byte sectors.

## Disk commands

| Command                             | Action                                               |
| ----------------------------------- | ---------------------------------------------------- |
| `disk info`                         | Show the ATA model and disk capacity.                |
| `disk crc32 LBA`                    | Checksum one sector by its zero-based decimal LBA.   |
| `disk gpt`                          | List partitions and identify the GPT copy in use.    |
| `disk check [PATH]`                 | Count orphaned FAT32 clusters without writing.       |
| `disk repair [PATH]`                | Reclaim unreferenced FAT32 clusters.                 |
| `mount [disk0pN /NAME]`             | List mounts or mount FAT32 partition `N` at `/NAME`. |
| `mount -t ext2 disk0pN /NAME`       | Mount a supported clean ext2 partition read-write.   |
| `mount -t ext2 -o ro disk0pN /NAME` | Mount a supported ext2 partition read-only.          |
| `umount /NAME`                      | Flush and unmount a named volume.                    |

## Ext2

The ext2 writer creates regular files up to 48 KiB with `touch`, `echo >`, and `cp`. Use `echo >` or `cp` to replace an existing file. Replacement updates the modification and change times from a valid UTC hardware clock, with one-second precision. Use `mkdir PATH` to create a directory and `rm PATH` to remove a file or an empty directory. Removing one of several hard links also uses the clock to update the surviving inode’s change time. Lookup is case-sensitive. Linear directories can grow up to 12 direct blocks. Replacement and final removal require direct data blocks.

This command creates a 64 MiB ext2 filesystem image with 4 KiB blocks and the supported feature set.

```sh
mke2fs -t ext2 -b 4096 -O none,filetype,sparse_super,large_file volume.img 64M
```

The guest example assumes GPT partition 2 contains an ext2 filesystem.

```text
mount -t ext2 disk0p2 /ext
echo "Saved on ext2" > /ext/note.txt
ls /ext
crc32range 0 14 /ext/note.txt
umount /ext
```

Use `-o ro` for read-only access, including supported images with features outside the writer profile. Cleanly unmount, reboot, or halt before removing a writable image. After a power cut or write error, run `e2fsck` on the offline volume before mounting it writable again.

Run `make test-ext2` for the read, write, and recovery checks. Run `make bench-ext2` on a KVM host to measure sequential reads.

## FAT32 example

This example assumes GPT partition 1 contains a FAT32 volume.

File commands work in existing FAT32 directories with ASCII 8.3 names. You can read and replace files through short aliases such as `LONGFI~1.TXT`. Use `mkdir PATH` to create one directory with an 8.3 name. Use `rm PATH` to remove a file or an empty directory. FAT32 entries with long-name records or the read-only attribute are protected from removal, as are the current directory and its ancestors.

```text
mount disk0p1 /disk
cd /disk
echo "Saved on disk" > note.txt
mkdir projects
ls
cat note.txt
cp note.txt /ram/note.txt
rm projects
cd /
umount /disk
```

GPT partition numbers start at 1. Use `mount disk0p2 /backup` for a second partition on the same disk. `disk check` and `disk repair` default to `/disk`. To select another volume, pass its mount point, such as `/backup` or `/backup/`.
