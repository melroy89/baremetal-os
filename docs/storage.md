# IDE storage

For direct QEMU boot, add `-machine pc -drive file=disk.raw,format=raw,if=ide,index=0`. For QCOW2, set `format=qcow2`. The driver uses the PIIX3 primary master and 512-byte sectors.

## Disk commands

| Command                     | Action                                                        |
| --------------------------- | ------------------------------------------------------------- |
| `disk info`                 | Show the ATA model and disk capacity.                         |
| `disk crc32 LBA`            | Checksum one sector by its zero-based decimal LBA.            |
| `disk gpt`                  | List partitions and identify the GPT copy in use.             |
| `disk mount N`              | Mount GPT partition `N` at `/disk`. Numbering starts at 1.    |
| `disk ls`                   | List files and directories at `/disk`.                        |
| `disk cat NAME`             | Print a file from `/disk`.                                    |
| `disk put RAMFILE DISKFILE` | Copy a file from `/ram` to `/disk`, creating or replacing it. |
| `disk check [PATH]`         | Count orphaned clusters without writing.                      |
| `disk repair [PATH]`        | Reclaim clusters proven to be unreferenced.                   |
| `disk unmount`              | Flush writes and unmount `/disk`.                             |
| `mount [disk0pN /NAME]`     | List mounts or mount an IDE partition at `/NAME`.             |
| `umount /NAME`              | Flush and unmount a named volume.                             |

## FAT32 example

File commands work in existing FAT32 directories with ASCII 8.3 names. You can read and replace files through short aliases such as `LONGFI~1.TXT`. Files with long-name entries are protected from `rm`.

```text
disk mount 1
cd /disk
echo "Saved on disk" > note.txt
ls
cat note.txt
cd /
disk unmount
```

Use `mount disk0p2 /backup` for a second partition on the same disk. `disk check` and `disk repair` default to `/disk`. To select another volume, pass its mount point, such as `/backup` or `/backup/`.
