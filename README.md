# Bare Metal OS

[![Boot smoke tests](https://github.com/melroy89/baremetal-os/actions/workflows/boot-smoke.yml/badge.svg)](https://github.com/melroy89/baremetal-os/actions/workflows/boot-smoke.yml)

Bare Metal OS is a small operating system written in x86-64 assembly and designed for speed and simplicity. It boots directly to an interactive text console and idles the CPU while waiting for input.

**Key features**

- Fast direct kernel boot in QEMU/KVM, plus ISO boot on BIOS and UEFI.
- GPT partition inspection and volume mounting, with writable FAT32, ext2, and a built-in RAM filesystem.
- Browse multiple mounted volumes with `cd` and `ls`, read files with `cat`, and copy them between volumes with `cp`.
- Multicore startup and tools to inspect CPUs, memory, and PCI devices.
- IPv4 networking over virtio-net or e1000, with ARP, UDP, `ping`, DHCP, and DNS lookups.

## Download

Download the latest release from [GitHub Releases](https://github.com/melroy89/baremetal-os/releases).

- `baremetal-os.elf` boots directly as a kernel in QEMU/KVM.
- `baremetal-os.iso` boots as a CD/DVD image with BIOS or UEFI firmware.
- `SHA256SUMS` lets you verify the downloads.

![Bare Metal OS 1.1.0 running in QEMU/KVM, showing console help, CPU details, and page counts](assets/baremetal-os.png)

## Quick start

Run these commands from the directory containing the downloaded file.

### Run directly with QEMU/KVM

For a quick boot in QEMU/KVM, load the kernel ELF directly with `-kernel`.

```sh
sudo apt install qemu-system-x86
qemu-system-x86_64 -enable-kvm -cpu host -m 64M -smp 1 -nic none \
  -kernel baremetal-os.elf -display none -serial stdio -monitor none
```

This starts one vCPU with 64 MiB of RAM. Use `-smp 4` for four virtual CPUs.

### Boot the ISO

Alternatively, attach `baremetal-os.iso` as a CD/DVD image and boot from it.

- **SeaBIOS** is the choice for a graphical first boot. With 64 MiB of RAM, the prompt appears on both VGA and serial.
- **UEFI (OVMF)** requires the serial console. Select x86-64 UEFI firmware with Secure Boot disabled, allocate 128 MiB of RAM, and open the VM's serial console. OVMF can report `no suitable video mode found` on the graphical display while the kernel runs on serial.

This QEMU command boots the ISO with SeaBIOS and opens the serial console in your terminal.

```sh
qemu-system-x86_64 -m 64M -nic none -cdrom baremetal-os.iso \
  -display none -serial stdio -monitor none
```

For UEFI, install `ovmf`, replace `-m 64M` with `-m 128M`, and add `-bios /usr/share/ovmf/OVMF.fd`. The firmware path may vary by distribution.

## Console quick reference

The console starts at `/`. Run `help` for commands or `ls` to see available volumes.

| Command                    | Action                                             |
| -------------------------- | -------------------------------------------------- |
| `help`                     | List console commands.                             |
| `info`, `cpu`, `mem`       | Inspect the guest, CPU, and memory.                |
| `lspci`                    | List PCI devices.                                  |
| `disk info`                | Inspect the attached IDE disk.                     |
| `net info`                 | Show the Ethernet adapter and IPv4 configuration.  |
| `ls [PATH]`                | List files in RAM or on a mounted volume.          |
| `cd PATH`, `pwd`           | Change or show the current directory.              |
| `cat PATH`, `rm PATH`      | Read or remove a file.                             |
| `echo [TEXT] > PATH`       | Write text to a file.                              |
| `touch PATH`               | Create an empty file.                              |
| `cp SOURCE DEST`           | Copy a file.                                       |
| `mount [disk0pN /NAME]`    | List volumes or mount an IDE partition.            |
| `umount /NAME`             | Unmount a named volume.                            |
| `uptime`, `log`, `version` | Check runtime, boot milestones, and build details. |
| `reboot`, `halt`           | Restart or power off the guest.                    |

## Documentation

- [Console commands and RAM files](docs/console.md)
- [IDE storage, GPT, FAT32, and ext2](docs/storage.md)
- [IPv4 setup and Ethernet commands](docs/networking.md)
- [Run with libvirt or Proxmox VE](docs/virtualization.md)

---

## Build from source

The build uses NASM. On Debian, Ubuntu, or Linux Mint, install the build tools, then run `make` from the project checkout.

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

### Run the tests

Run `make test` for the same suite as GitHub Actions, or use a focused target such as `make test-fat32` or `make test-boot`. The full suite needs the build and ISO tools above, plus QEMU, OVMF, `qemu-img`, `sgdisk`, `dosfstools`, `e2fsprogs`, and `socat`.

### Kernel overview

At startup, a Multiboot 1 bootloader hands control to the kernel in 32-bit mode. The kernel switches the CPU to 64-bit mode before starting the console.

The kernel sets up paging and CPU exception handlers and starts additional CPUs through the local APIC. When the CPU list is known and enough pages are available, the allocator supplies one 4 KiB stack page per secondary CPU, counted in `mem`. Other boot paths use stack space reserved by the loader. The boot CPU runs the console and sleeps between input interrupts. When IPv4 is enabled, a timer also wakes it to service Ethernet. Storage uses polled I/O.

## Credits

Bootstrap and drivers adapted from Alexey Fateev's [llm.asm (MIT)](https://github.com/alesha-pro/llm.asm).
