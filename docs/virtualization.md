# Virtual machine setup

## Run with libvirt

To create the guest, run these commands beside `baremetal-os.elf`. You need `virt-install`, access to `qemu:///system`, and an active file-based pool named `default`.

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

Open the guest in Virtual Machine Manager or connect with `virsh -c qemu:///system console baremetal-os`. Press Enter for the prompt and `Ctrl+]` to detach. To start and connect in one step, use `virsh -c qemu:///system start baremetal-os --console`.

To update the kernel, power off the guest and upload the new ELF.

```sh
virsh -c qemu:///system vol-upload --pool default baremetal-os-kernel.elf baremetal-os.elf
```

## Boot the ISO in Proxmox VE

1. Upload `baremetal-os.iso` to storage that accepts **ISO Images**.
2. Create a VM with one vCPU and 512 MiB of RAM. Set its CD/DVD drive to boot the ISO first.
3. Select **SeaBIOS** for the graphical console.

For **OVMF**, disable Secure Boot and leave **Pre-Enroll keys** unchecked if you add an EFI disk. Add a socket-backed serial port and connect with `qm terminal VMID`. [Proxmox VM configuration](https://pve.proxmox.com/pve-docs/chapter-qm.html)
