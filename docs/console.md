# Console commands

Type `help` at the `baremetal>` prompt for the full command list.

At the VGA prompt, use **Page Up** and **Page Down** to browse up to 256 previous rows. Typing returns to the live screen, and `clear` discards the VGA history. On serial, use the host terminal's scrollback.

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

## IDE storage

Use `disk info` to inspect the disk and `disk gpt` to list its partitions. Use `mount disk0pN /disk`, where `N` is the GPT partition number of the FAT32 volume you want to mount.

For more info read: [IDE storage and file commands](storage.md).

## Ethernet

Use `net info` to check the link, `net recv` to read a frame, and `net send` to send one.

For more info read: [Ethernet setup and frame commands](networking.md).

## Files and directories

The console starts at `/`. Use `ls` there to see mounted volumes, or `cd /ram` to work with temporary files. Relative paths start in the current directory.

| Command              | Action                                               |
| -------------------- | ---------------------------------------------------- |
| `ls [PATH]`          | List the current directory or `PATH`.                |
| `cd PATH`            | Change directory. Use `cd ..` to go up.              |
| `pwd`                | Show the current directory.                          |
| `cat PATH`           | Print a file.                                        |
| `echo [TEXT]`        | Print text and a newline.                            |
| `echo [TEXT] > PATH` | Write text and a newline to a file.                  |
| `cp SOURCE DEST`     | Copy a file between or within mounted volumes.       |
| `touch PATH`         | Create an empty file. Existing files stay unchanged. |
| `rm PATH`            | Remove a writable file.                              |
| `crc32 FILE`         | Checksum a file in `/ram` from anywhere.             |

```text
cd /ram
echo "3 > 2" > comparison.txt
cat comparison.txt
crc32 comparison.txt
rm comparison.txt
```

Double quotes let you include a literal `>` in the text. Files in `/ram` disappear on reboot.

For `cp`, put paths containing spaces in double quotes. Inside quotes, use `\"` for a literal double quote and `\\` for a literal backslash.

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
