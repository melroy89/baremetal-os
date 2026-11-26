# IDE storage

For direct QEMU boot, add `-machine pc -drive file=disk.raw,format=raw,if=ide,index=0`. For QCOW2, set `format=qcow2`. The driver uses the PIIX3 primary master and 512-byte sectors.

## Inspect a disk

| Command          | Action                                             |
| ---------------- | -------------------------------------------------- |
| `disk info`      | Show the ATA model and capacity.                   |
| `disk crc32 LBA` | Checksum one sector. Use a zero-based decimal LBA. |
| `disk gpt`       | List partitions and identify the GPT copy in use.  |

## Mount and use FAT32

Mount an existing FAT32 partition by its one-based GPT number. File commands use ASCII 8.3 names in the root directory, including aliases such as `LONGFI~1.TXT`.

```text
disk mount 1
disk ls
disk cat HELLO.TXT
echo Saved on disk > note.txt
disk put note.txt NOTE.TXT
disk unmount
```

`disk put` creates or replaces a file. Replacement requires exclusive ownership of the old clusters. Unmount to flush writes before powering off.

After an interrupted write, use `disk check` to count orphaned clusters without writing to the volume. Run `disk repair` to reclaim them. Repair requires a complete directory scan and agreement between FAT copies. You can also recover space on the host with `fsck.fat`.
