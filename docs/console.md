# Console commands

Type `help` at the `baremetal>` prompt for the full command list.

## System and session

| Command       | Action                                                        |
| ------------- | ------------------------------------------------------------- |
| `info`        | Show started CPUs and usable RAM.                             |
| `cpu`         | Show the boot CPU model and capabilities.                     |
| `cpu ping`    | Check which secondary CPUs respond.                           |
| `mem`         | Show used and free 4 KiB pages.                               |
| `memmap`      | Show the Multiboot memory map.                                |
| `lspci`       | List PCI addresses, IDs, and classes.                         |
| `lspci --all` | Probe every PCI function, including slots without function 0. |
| `uptime`      | Show time since boot.                                         |
| `log`         | Show boot milestones.                                         |
| `version`     | Show the kernel version and build ID.                         |
| `clear`       | Clear the console.                                            |
| `reboot`      | Restart the guest.                                            |
| `halt`        | Power off the guest.                                          |

## IDE storage

Use `disk info` to inspect the disk, `disk gpt` to find partitions, and `disk mount N` to open a FAT32 volume.

For more info read: [IDE storage and file commands](storage.md).

## Ethernet

Use `net info` to check the link, `net recv` to read a frame, and `net send` to send one.

For more info read: [Ethernet setup and frame commands](networking.md).

## RAM files

RAM disks are not persistent. Use `ls` to list files, `cat FILE` to read one, and `crc32 FILE` to print its checksum.

```text
echo "3 > 2" > comparison.txt
cat comparison.txt
crc32 comparison.txt
rm comparison.txt
```

Quotes around the text are optional.

### Optional boot archive

Create a USTAR archive with root-level files and printable ASCII names up to 99 characters.

```sh
printf 'Hello from RAM\n' > hello.txt
tar --format=ustar -cf ramfs.tar hello.txt
qemu-system-x86_64 -enable-kvm -cpu host -m 64M -nic none \
  -kernel baremetal-os.elf -initrd ramfs.tar -display none -serial stdio -monitor none
```

From source, use `make os-run INITRAMFS=ramfs.tar`. In GRUB, add `module /boot/ramfs.tar` immediately after `multiboot` as the first boot module.

Archive files (like this `hello.txt` example file) are read-only. Removing a writable replacement restores the archived file. For duplicate archive names, the last entry wins.
