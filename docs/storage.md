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

Use `-o ro` for read-only mounts. Writable mounts require a device that can flush writes.

## Ext2

On Linux, create a 64 MiB ext2 image.

```sh
mke2fs -t ext2 volume.img 64M
```

If the ext2 volume is on GPT partition 2 of `disk0`, mount it in the guest.

```text
mount -t ext2 disk0p2 /ext
echo "Saved on ext2" > /ext/note.txt
cat /ext/note.txt
umount /ext
```

**Compatibility.** Ext2 supports 1, 2, and 4 KiB blocks and 128- or 256-byte inodes. Writable features include `filetype`, `sparse_super`, `large_file`, `resize_inode`, `ext_attr`, and `dir_index`. Editing an indexed directory converts it to linear records. Existing extended attributes are preserved. Linux handles ACLs.

**Files and paths.** `cp` streams large files and preserves holes between ext2 volumes at the destination block size. Writes beyond 2 GiB − 1 require `large_file`. Names are case-sensitive. `mv` works within one volume. Leave a directory tree before moving it. File replacement, cross-directory moves, and link-count changes use the guest’s UTC hardware clock. See [console commands](console.md) for links, `stat`, and `truncate`.

**Recovery.** Unmount, reboot, or halt before removing a writable volume. After a power cut or write error, run `e2fsck` offline before mounting it writable again. For an interrupted move, check both paths and `lost+found`.

Run `make test-ext2` for core checks, `make test-ext2-extended` for more recovery cases, or `make bench-ext2` for sequential read timings on KVM.

## FAT32 example

This example assumes GPT partition 1 contains a FAT32 volume.

File commands work in existing FAT32 directories with ASCII 8.3 names. You can read and replace files through short aliases such as `LONGFI~1.TXT`. Use `mkdir PATH` to create one directory with an 8.3 name. Use `rm PATH` to remove a file or an empty directory. FAT32 entries with long-name records or the read-only attribute are protected from removal, as are the current directory and its ancestors.

`mv` accepts short names in the same directory when the destination is unused and the directory has no live long-name entries.

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
