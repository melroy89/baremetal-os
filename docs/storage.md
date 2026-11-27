# Disk storage

`disk0` is the PIIX3 primary master. `disk1` is the first usable modern virtio-blk device, even when it is the only disk. Both drivers use 512-byte logical sectors. Disk inspection commands default to the first available disk.

For direct QEMU boot with `-machine pc`, add one of these drives. Use `format=qcow2` for a QCOW2 image.

```sh
# IDE
-drive file=disk.raw,if=ide,index=0,format=raw
# Modern virtio-blk
-drive file=disk.raw,if=none,id=vd,format=raw -device virtio-blk-pci,drive=vd,disable-legacy=on
```

## Disk commands

| Command                               | Action                                             |
| ------------------------------------- | -------------------------------------------------- |
| `disk info [diskN]`                   | Show the disk model and capacity.                  |
| `disk crc32 [diskN] LBA`              | Checksum one sector by its zero-based decimal LBA. |
| `disk gpt [diskN]`                    | List partitions and identify the GPT copy in use.  |
| `disk check [PATH]`                   | Count orphaned FAT32 clusters.                     |
| `disk repair [PATH]`                  | Reclaim unreferenced FAT32 clusters.               |
| `mount`                               | List mounted volumes.                              |
| `mount [-o ro] diskNpM /NAME`         | Mount FAT32 GPT partition `M` of disk `N`.         |
| `mount -t ext2 [-o ro] diskNpM /NAME` | Mount a supported ext2 partition.                  |
| `umount /NAME`                        | Flush and unmount a named volume.                  |

Use `-o ro` to mount read-only. Writable mounts require a device that can flush writes. Use `mv SOURCE DEST` to rename a regular file within one directory when the destination is unused. The new ext2 name must fit in the original record and sector. FAT32 rename accepts short names in directories without live long-name records.

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
