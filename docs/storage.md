# IDE storage

For direct QEMU boot, add `-machine pc -drive file=disk.raw,format=raw,if=ide,index=0`. For QCOW2, set `format=qcow2`. The driver uses the PIIX3 primary master and 512-byte sectors.

## Disk commands

| Command                     | Action                                                 |
| --------------------------- | ------------------------------------------------------ |
| `disk info`                 | Show the ATA model and disk capacity.                  |
| `disk crc32 LBA`            | Checksum one sector by its zero-based decimal LBA.     |
| `disk gpt`                  | List partitions and identify the GPT copy in use.      |
| `disk mount N`              | Mount FAT32 on GPT partition `N`, starting at 1.       |
| `disk ls`                   | List files on the mounted volume.                      |
| `disk cat NAME`             | Print a file from disk.                                |
| `disk put RAMFILE DISKFILE` | Copy a RAM file to disk, creating or replacing a file. |
| `disk check`                | Count orphaned clusters without writing.               |
| `disk repair`               | Reclaim clusters proven to be unreferenced.            |
| `disk unmount`              | Flush writes and unmount the volume.                   |

## FAT32 example

File commands use ASCII 8.3 names in the root directory, including aliases such as `LONGFI~1.TXT`.

```text
disk mount 1
echo Saved on disk > note.txt
disk put note.txt NOTE.TXT
disk ls
disk cat NOTE.TXT
disk unmount
```
