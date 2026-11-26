# Bare Metal OS

[![Boot smoke tests](https://github.com/melroy89/baremetal-os/actions/workflows/boot-smoke.yml/badge.svg)](https://github.com/melroy89/baremetal-os/actions/workflows/boot-smoke.yml)

A small standalone operating system written in x86-64 assembly (NASM). At startup, a Multiboot 1 bootloader hands control to the kernel in 32-bit mode. The kernel switches the CPU to 64-bit mode and opens a text console you can use with a screen and keyboard or through a serial terminal.

## Download

Download the latest release from [GitHub Releases](https://github.com/melroy89/baremetal-os/releases).

- `baremetal-os.elf` boots directly as a kernel in QEMU/KVM.
- `baremetal-os.iso` boots as a CD/DVD image with BIOS or UEFI firmware.
- `SHA256SUMS` lets you verify the downloads.

![Bare Metal OS 1.1.0 running in QEMU/KVM, showing console help, CPU details, and page counts](assets/baremetal-os.png)

## Quick start

Run these commands from the directory containing the downloaded file.

### Run directly with QEMU/KVM

This option runs entirely in your terminal and needs QEMU and access to `/dev/kvm`.

```sh
sudo apt install qemu-system-x86
qemu-system-x86_64 -enable-kvm -cpu host -m 64M -smp 1 -nic none \
  -kernel baremetal-os.elf -display none -serial stdio -monitor none
```

This starts one vCPU with 64 MiB of RAM. Use `-smp 4` for four virtual CPUs.

### Boot the ISO

Attach `baremetal-os.iso` as a CD/DVD image and boot from it.

- **SeaBIOS** is the choice for a graphical first boot. With 64 MiB of RAM, the prompt appears on both VGA and serial.
- **UEFI (OVMF)** requires the serial console. Select x86-64 UEFI firmware with Secure Boot disabled, allocate 128 MiB of RAM, and open the VM's serial console. OVMF can report `no suitable video mode found` on the graphical display while the kernel runs on serial.

This QEMU command boots the ISO with SeaBIOS and opens the serial console in your terminal.

```sh
qemu-system-x86_64 -m 64M -nic none -cdrom baremetal-os.iso \
  -display none -serial stdio -monitor none
```

For UEFI, install `ovmf`, replace `-m 64M` with `-m 128M`, and add `-bios /usr/share/ovmf/OVMF.fd`. The firmware path may vary by distribution.

## Console

| Command    | Action                                                           |
| ---------- | ---------------------------------------------------------------- |
| `help`     | List commands                                                    |
| `info`     | Show CPUs started, secondary stack pages, and usable RAM         |
| `cpu`      | Show the boot CPU vendor, model, and capabilities                |
| `cpu ping` | Check which online secondary CPUs respond                        |
| `mem`      | Show how many 4 KiB pages the kernel manages, uses, and has free |
| `memmap`   | Show the memory ranges and types reported by Multiboot           |
| `ls`       | List files in the RAM filesystem                                 |
| `cat FILE` | Print a file from the RAM filesystem                             |
| `echo`     | Print text or write it to a RAM file with `> FILE`               |
| `rm FILE`  | Remove a writable RAM file                                       |
| `uptime`   | Show time since boot in milliseconds                             |
| `log`      | Replay milestones from the current boot                          |
| `version`  | Show the kernel version and source build identifier              |
| `clear`    | Clear VGA and ANSI-compatible serial terminals                   |
| `reboot`   | Restart the QEMU guest                                           |
| `halt`     | Power off the machine                                            |

`cpu ping` sends an interrupt to each online secondary CPU and reports its reply or timeout. Run it again to retry after a timeout. In a four-vCPU guest, expect three replies. A one-vCPU guest has no secondary CPUs to ping.

## Run with libvirt

Use `virt-install` and `virsh` to manage a QEMU/KVM guest from the terminal. Virtual Machine Manager (`virt-manager`) is an optional graphical interface for the same libvirt guest.

### Create the guest

With `virt-install`, access to `qemu:///system`, and an active file-based libvirt pool named `default`, run these commands from the directory containing `baremetal-os.elf`. They store the ELF in the pool and start a KVM guest with one vCPU, 64 MiB of RAM, and direct kernel boot.

```sh
virsh -c qemu:///system vol-create-as default baremetal-os-kernel.elf \
  "$(stat -c %s baremetal-os.elf)" --format raw
virsh -c qemu:///system vol-upload --pool default baremetal-os-kernel.elf baremetal-os.elf
kernel_path=$(virsh -c qemu:///system vol-path --pool default baremetal-os-kernel.elf)
virt-install --connect qemu:///system --name baremetal-os --import \
  --virt-type kvm --machine pc --memory 64 --vcpus 1 --cpu host-passthrough \
  --osinfo generic --disk none --network none --memballoon model=none \
  --graphics spice,listen=none --video vga --serial pty \
  --boot "kernel=$kernel_path" --noautoconsole
```

Connect to the running guest's serial console with `virsh -c qemu:///system console baremetal-os`. Press Enter to show the prompt and `Ctrl+]` to detach. To start a powered-off guest and connect in one step, run `virsh -c qemu:///system start baremetal-os --console`.

For the graphical console, open **baremetal-os** under the **QEMU/KVM** system connection in Virtual Machine Manager. Enter `halt` at the `baremetal>` prompt to power off from either console.

### Update the kernel

Power off the existing guest before uploading a newer `baremetal-os.elf` to its volume.

```sh
virsh -c qemu:///system vol-upload --pool default baremetal-os-kernel.elf baremetal-os.elf
```

## Boot the ISO in Proxmox VE

1. Upload `baremetal-os.iso` to storage that accepts **ISO Images**.
2. Create a VM with one vCPU, 512 MiB of RAM, and a CD/DVD drive using the uploaded ISO. You can omit the guest hard disk and network device. Put the CD/DVD drive first in the boot order.
3. Choose **SeaBIOS**, start the VM, and open its graphical console.

For **OVMF (UEFI)**, disable Secure Boot, leave **Pre-Enroll keys** unchecked if you add an EFI disk, and add a serial port backed by a socket. Start the VM and connect from the Proxmox host with `qm terminal VMID`, replacing `VMID` with the VM's ID. [Proxmox VE VM configuration guide](https://pve.proxmox.com/pve-docs/chapter-qm.html)

## Advanced features

### Write files in RAM

You can create a RAM file at the console without loading a boot archive.

```text
echo "This is some text"
echo "3 > 2" > comparison.txt
ls
cat comparison.txt
rm comparison.txt
```

Double quotes around the text are optional. Use them to preserve surrounding spaces or print a literal `>`. The `> FILE` redirection creates or replaces a file and adds a newline. Enter the filename without quotes and leave `>` and `"` out of the name. Each writable file takes one 4 KiB page, which `rm` returns to the kernel. Writable files disappear on reboot.

### Load an optional RAM filesystem archive

To start with files already available, create an uncompressed USTAR archive of regular files at the archive root. File names in RAM and in the archive can contain up to 99 printable ASCII characters, with no slashes or leading or trailing spaces. Pass the archive to QEMU as a boot module.

```sh
printf 'Hello from RAM\n' > hello.txt
tar --format=ustar -cf ramfs.tar hello.txt
qemu-system-x86_64 -enable-kvm -cpu host -m 64M -nic none \
  -kernel baremetal-os.elf -initrd ramfs.tar -display none -serial stdio -monitor none
```

At the prompt, try `ls` and `cat hello.txt`. Archive files are read-only. Writing to an archive filename creates a writable copy that takes precedence. Removing the copy makes the original visible again.

The kernel indexes the archive at boot so `ls` and `cat` can find files quickly. The archive and its index share guest RAM. If the kernel reports that the index ran out of free pages, boot with more RAM. If an archive repeats a filename, `cat` reads the last entry and `ls` lists the filename once.

When building from source, use `make os-run INITRAMFS=ramfs.tar` for the same setup. In a custom GRUB image, load the archive as the first boot module with `module /boot/ramfs.tar` after the `multiboot` command.

---

## Build from source

On Debian, Ubuntu, or Linux Mint, install the build tools, then run `make` from the project checkout.

```sh
sudo apt install nasm binutils make coreutils
make
```

The kernel is `build/baremetal-os.elf`. With QEMU/KVM set up, use `make os-run` to build and boot it directly, or `make os-run SMP=4` for four vCPUs.

### Build a BIOS and UEFI bootable ISO

Install both GRUB platform packages for a hybrid image. GRUB uses the platform modules available when it builds the ISO.

```sh
sudo apt install grub-common grub-pc-bin grub-efi-amd64-bin mtools xorriso
make os-iso
```

The image is `build/baremetal-os.iso`. If you added a GRUB platform after building it, run `make -B os-iso` to rebuild it. To use the ELF or ISO with the run instructions above, run them from the `build/` directory.

### Kernel overview

The kernel sets up paging and CPU exception handlers and starts additional CPUs through the local APIC. When the CPU list is known and enough pages are available, the allocator supplies one 4 KiB stack page per secondary CPU, counted in `mem`. Other boot paths use stack space reserved by the loader. The boot CPU runs the console and sleeps between keyboard and serial interrupts. There is currently no user space, disk filesystem, or networking stack.

## Credits

The bootstrap and hardware drivers are derived from Alexey Fateev's MIT-licensed project. [Upstream source](https://github.com/alesha-pro/llm.asm)
