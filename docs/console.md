# Console commands

Type `help` at the `baremetal>` prompt for the full command list.

The VGA and serial editors support these shortcuts. Use an ANSI serial terminal with at least 80 columns.

| Keys                                   | Action                                                                               |
| -------------------------------------- | ------------------------------------------------------------------------------------ |
| **Left**, **Right**, **Home**, **End** | Move the cursor. **Ctrl+A** and **Ctrl+E** also move to the start and end.           |
| **Backspace**, **Delete**              | Erase before or after the cursor.                                                    |
| **Up**, **Down**                       | Recall up to 16 commands. Going past the newest entry restores the draft and cursor. |
| **Ctrl+W**, **Ctrl+U**, **Ctrl+K**     | Erase the preceding word, to the start, or to the end, respectively.                 |
| **Ctrl+L**                             | Clear the visible screen and redraw the draft. Keeps scrollback.                     |
| **Ctrl+D**                             | Delete forward in a draft. At an empty prompt, halt cleanly.                         |
| **Ctrl+C**                             | Discard the draft or interrupt `cat`, `echo`, `cp`, or `mv`.                       |
| **Tab**                                | Complete a command, path, or mount partition using the text before the cursor.       |
| **Page Up**, **Page Down**             | Browse up to 256 rows of VGA scrollback.                                             |

Long lines scroll horizontally and can be up to 1,023 bytes. In a serial session, use your terminal’s scrollback. File updates continue once they can no longer be cancelled safely.

## System and session

| Command                | Action                                                                  |
| ---------------------- | ----------------------------------------------------------------------- |
| `help`                 | Show console commands.                                                  |
| `info`                 | Show started CPUs and usable RAM.                                       |
| `cpu`                  | Show the boot CPU model and capabilities.                               |
| `cpu ping`             | Check which secondary CPUs respond.                                     |
| `mem`                  | Show used and free 4 KiB pages.                                         |
| `memmap`               | Show the Multiboot memory map.                                          |
| `lspci`                | List PCI addresses, IDs, and classes.                                   |
| `lspci --all`          | Probe every PCI function, including slots without function 0.           |
| `uptime`               | Show time since boot.                                                   |
| `log`                  | Show boot milestones.                                                   |
| `history`              | Show up to 16 recent commands, oldest first, including this invocation. |
| `version`              | Show the kernel version and build ID.                                   |
| `clear`                | Clear the console and VGA scrollback.                                    |
| `reboot`               | Restart the guest.                                                      |
| `halt`, `quit`, `exit` | Power off the guest.                                                    |

## Disk storage

Use `disk list` to find partition names, then mount one with a command such as `mount disk1p1 /src`. The shell detects FAT32 and ext2 automatically.

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
| `mv SOURCE DEST`                | Rename or move an entry within one volume.                  |
| `ln [-s] SOURCE LINK`           | Create an ext2 hard or symbolic link.                       |
| `readlink PATH`                 | Print an ext2 symbolic link target.                         |
| `stat PATH`                     | Inspect ext2 inode metadata.                                |
| `truncate PATH SIZE`            | Set the length of an ext2 regular file in bytes.            |
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
