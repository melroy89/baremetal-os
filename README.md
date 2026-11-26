# Bare Metal OS

A small standalone operating system written in x86-64 assembly (NASM). At startup, a Multiboot 1 bootloader hands control to the kernel in 32-bit mode. The kernel switches the CPU to 64-bit mode and opens a text console you can use with a screen and keyboard or through a serial terminal.

## Installation and prerequisites

On Debian, Ubuntu, or Linux Mint, install the build tools, then run `make` from the project directory.

```sh
sudo apt install nasm binutils make coreutils
make
```

The kernel is `build/baremetal-os.elf`. It runs on x86-64 and can boot in a diskless VM.

### Run directly with QEMU/KVM

This option needs QEMU and access to `/dev/kvm`.

```sh
sudo apt install qemu-system-x86
make os-run
```

The terminal console uses one virtual CPU and 64 MiB of RAM by default. Use `make os-run SMP=4` to start four virtual CPUs.

### Build a BIOS and UEFI bootable ISO

Install both GRUB platforms to build a hybrid image. GRUB uses the platform modules available on the build host. QEMU is optional for building the ISO.

```sh
sudo apt install grub-common grub-pc-bin grub-efi-amd64-bin mtools xorriso
make os-iso
```

Boot `build/baremetal-os.iso` as a CD/DVD image. If you added a GRUB platform after building the ISO, run `make -B os-iso` to rebuild it.

- **SeaBIOS** is the choice for a graphical first boot. With 64 MiB of RAM, the prompt appears on both VGA and serial.
- **UEFI (OVMF)** requires the serial console. Select x86-64 UEFI firmware with Secure Boot disabled, allocate 128 MiB of RAM, and open the VM's serial console. OVMF can report `no suitable video mode found` on the graphical display while the kernel runs on serial.

This QEMU command boots the ISO with SeaBIOS and opens the serial console in your terminal.

```sh
qemu-system-x86_64 -m 64M -nic none -cdrom build/baremetal-os.iso \
  -display none -serial stdio -monitor none
```

For UEFI, install `ovmf`, replace `-m 64M` with `-m 128M`, and add `-bios /usr/share/ovmf/OVMF.fd`. The firmware path may vary by distribution.

## Virtual Machine Manager

### Create the guest

With `virt-install`, access to `qemu:///system`, and an active file-based libvirt pool named `default`, run these commands from the project directory. They store the ELF in the pool and start a KVM guest with one vCPU, 64 MiB of RAM, and direct kernel boot.

```sh
make
virsh -c qemu:///system vol-create-as default baremetal-os-kernel.elf \
  "$(stat -c %s build/baremetal-os.elf)" --format raw
virsh -c qemu:///system vol-upload --pool default baremetal-os-kernel.elf build/baremetal-os.elf
kernel_path=$(virsh -c qemu:///system vol-path --pool default baremetal-os-kernel.elf)
virt-install --connect qemu:///system --name baremetal-os --import \
  --virt-type kvm --machine pc --memory 64 --vcpus 1 --cpu host-passthrough \
  --osinfo generic --disk none --network none --memballoon model=none \
  --graphics spice,listen=none --video vga --serial pty \
  --boot "kernel=$kernel_path" --noautoconsole
```

Open **baremetal-os** under the **QEMU/KVM** system connection in Virtual Machine Manager. The guest has no attached disk or ISO. Click **Run** to start it again after shutdown. Enter `halt` at the `baremetal>` prompt to power off.

### Update the kernel

Power off the existing guest before uploading a rebuilt ELF to its volume.

```sh
make
virsh -c qemu:///system vol-upload --pool default baremetal-os-kernel.elf build/baremetal-os.elf
```

## Console

| Command   | Action                                                              |
| --------- | ------------------------------------------------------------------- |
| `help`    | List commands                                                       |
| `info`    | Show the number of CPUs started and the usable RAM reported at boot |
| `cpu`     | Show the boot CPU vendor, model, and capabilities                   |
| `memmap`  | Show the memory ranges and types reported by Multiboot              |
| `uptime`  | Show time since boot in milliseconds                                |
| `log`     | Replay milestones from the current boot                             |
| `version` | Show the kernel version and source build identifier                 |
| `clear`   | Clear VGA and ANSI-compatible serial terminals                      |
| `reboot`  | Restart the QEMU guest                                              |
| `halt`    | Power off the machine                                               |

The kernel sets up paging and CPU exception handlers and starts additional CPUs through the local APIC. The boot CPU runs the console and sleeps between keyboard and serial interrupts. There is currently no user space, filesystem, or networking stack.

## Credits

The bootstrap and hardware drivers are derived from Alexey Fateev's MIT-licensed project. [Upstream source](https://github.com/alesha-pro/llm.asm)
