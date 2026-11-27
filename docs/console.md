# Console commands

Type `help` at the `baremetal>` prompt for the full command list.

At the VGA prompt, use **Page Up** and **Page Down** to browse up to 256 previous rows. Typing returns to the live screen, and `clear` discards the VGA history. On serial, use the host terminal's scrollback. Use **Up** and **Down** to recall the last 16 commands on either console. Recall redraws the editable command at a fresh prompt.

## System and session

| Command                | Action                                                        |
| ---------------------- | ------------------------------------------------------------- |
| `help`                 | Show console commands.                                        |
| `info`                 | Show started CPUs and usable RAM.                             |
| `cpu`                  | Show the boot CPU model and capabilities.                     |
| `cpu ping`             | Check which secondary CPUs respond.                           |
| `mem`                  | Show used and free 4 KiB pages.                               |
| `memmap`               | Show the Multiboot memory map.                                |
| `lspci`                | List PCI addresses, IDs, and classes.                         |
| `lspci --all`          | Probe every PCI function, including slots without function 0. |
| `uptime`               | Show time since boot.                                         |
| `log`                  | Show boot milestones.                                         |
| `version`              | Show the kernel version and build ID.                         |
| `clear`                | Clear the console.                                            |
| `reboot`               | Restart the guest.                                            |
| `halt`, `quit`, `exit` | Power off the guest.                                          |

## Disk storage

Use `disk info` to inspect the disk and `disk gpt` to list its partitions. Use `mount disk0pN /disk` for FAT32 or `mount -t ext2 disk0pN /ext` for ext2. Replace `N` with the GPT partition number. Use `disk1` for modern virtio-blk.

See the [storage guide](storage.md) for mount options and disk commands.

## Ethernet

DHCP starts automatically when `virtio-net` or `e1000` initializes. Use `net info` to check the address and `ping HOST` to check connectivity. Use `net static` for manual addressing or `net off` for raw Ethernet.

See the [networking guide](networking.md) for setup and examples.

## Files and directories

The console starts at `/`. Use `ls` there to see mounted volumes, or `cd /ram` to work with temporary files. Relative paths start in the current directory.

| Command                         | Action                                                      |
| ------------------------------- | ----------------------------------------------------------- |
| `ls [PATH]`                     | List the current directory or `PATH`.                       |
| `cd PATH`                       | Change directory. Use `cd ..` to go up.                     |
| `pwd`                           | Show the current directory.                                 |
| `cat PATH`                      | Print a file.                                               |
| `echo [TEXT]`                   | Print text and a newline.                                   |
| `echo [TEXT] > PATH`            | Write text and a newline to a file.                         |
| `cp SOURCE DEST`                | Copy a file between or within mounted volumes.              |
| `touch PATH`                    | Create an empty file. Existing files stay unchanged.        |
| `mkdir PATH`                    | Create one directory on a writable FAT32 or ext2 volume.    |
| `mv SOURCE DEST`                | Rename a regular file within the same disk directory.       |
| `rm PATH`                       | Remove a file or an empty directory.                        |
| `crc32 FILE`                    | Checksum a file in `/ram` from anywhere.                    |
| `crc32range OFFSET LENGTH PATH` | Checksum up to 64 MiB of a file using decimal byte offsets. |

```text
cd /ram
echo "3 > 2" > comparison.txt
cat comparison.txt
crc32 comparison.txt
rm comparison.txt
```

Double quotes let you include a literal `>` in the text. Files in `/ram` disappear on reboot.

For `cp` and `mv`, put paths containing spaces in double quotes. Inside quotes, use `\"` for a literal double quote and `\\` for a literal backslash.

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
