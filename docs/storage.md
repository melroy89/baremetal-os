# IDE storage

For direct QEMU boot, add `-machine pc -drive file=disk.raw,format=raw,if=ide,index=0`. For QCOW2, set `format=qcow2`. The driver uses the PIIX3 primary master and 512-byte sectors.

## Disk commands

| Command                 | Action                                             |
| ----------------------- | -------------------------------------------------- |
| `disk info`             | Show the ATA model and disk capacity.              |
| `disk crc32 LBA`        | Checksum one sector by its zero-based decimal LBA. |
| `disk gpt`              | List partitions and identify the GPT copy in use.  |
| `disk check [PATH]`     | Count orphaned clusters without writing.           |
| `disk repair [PATH]`    | Reclaim clusters proven to be unreferenced.        |
| `mount [disk0pN /NAME]` | List mounts or mount GPT partition `N` at `/NAME`. |
| `umount /NAME`          | Flush and unmount a named volume.                  |

## FAT32 example

This example assumes GPT partition 1 contains a FAT32 volume.

File commands work in existing FAT32 directories with ASCII 8.3 names. You can read and replace files through short aliases such as `LONGFI~1.TXT`. Files with long-name entries are protected from `rm`.

```text
mount disk0p1 /disk
cd /disk
echo "Saved on disk" > note.txt
ls
cat note.txt
cp note.txt /ram/note.txt
cd /
umount /disk
```

GPT partition numbers start at 1. Use `mount disk0p2 /backup` for a second partition on the same disk. `disk check` and `disk repair` default to `/disk`. To select another volume, pass its mount point, such as `/backup` or `/backup/`.
