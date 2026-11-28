NASM    ?= nasm
LD      ?= ld
OBJCOPY ?= objcopy
QEMU    ?= qemu-system-x86_64

BUILD   := build
KERNEL  := $(BUILD)/baremetal-os.elf
OBJECTS := $(addprefix $(BUILD)/,acpi.o ata.o block.o boot.o cpu.o crc32.o disk.o drivers.o echo.o ext2.o fat32.o gpt.o ip.o kernel.o net.o pages.o pci.o ramfs.o rtc.o runtime.o smp.o vfs.o virtio_pci.o virtio_blk.o virtio_net.o)
BUILD_ID_INPUTS := Makefile $(sort $(wildcard src/*.asm src/*.inc src/*.ld))
SMP_FIXTURES := $(addprefix $(BUILD)/smp-fixture-,missing_map.elf one_page.elf delayed_ap.elf lost_ping.elf crc32_work.elf)
FAT_FIXTURES := $(addprefix $(BUILD)/fat32-,interrupt.elf mkdir-linked.elf fault.elf overlap.elf)
EXT2_FAULTS := $(addprefix $(BUILD)/ext2-fixture-,ALLOC.elf PUBLISH.elf READ.elf FINAL.elf BEFORE.elf AFTER.elf CUT4.elf CUT5.elf CUT6.elf)
RAM     ?= 64M
SMP     ?= 1
INITRAMFS ?=

.PHONY: all os os-check os-run os-iso clean \
	test test-boot test-pages test-smp test-ramfs test-ata test-gpt test-fat32 test-storage \
	test-network test-network-e1000 test-network-virtio test-network-dhcp-e1000 \
	test-network-dhcp-virtio test-ext2 test-ext2-extended \
	test-network-irq test-console-and-storage test-acpi-power

all: os

os: $(KERNEL)

$(BUILD):
	mkdir -p $@

$(BUILD)/%.o: src/%.asm src/os_constants.inc | $(BUILD)
	$(NASM) -f elf64 -Isrc/ -I$(BUILD)/ $< -o $@

$(BUILD)/kernel.o: $(BUILD)/build_id.inc src/completion.inc src/completion_operand.inc
$(BUILD)/virtio_pci.o $(BUILD)/virtio_blk.o $(BUILD)/virtio_net.o: src/virtio_pci.inc
$(BUILD)/drivers.o: src/history.inc src/console_edit.inc src/console_input.inc
$(BUILD)/ip.o: src/udp.inc src/dhcp.inc src/dns.inc
$(BUILD)/ext2.o: src/ext2_verify.inc src/ext2_features.inc src/ext2_tree.inc src/ext2_sparse.inc src/ext2_write.inc src/ext2_remove.inc src/ext2_move.inc src/ext2_namespace.inc
$(BUILD)/fat32.o: src/fat32_check.inc src/fat32_copy.inc src/fat32_move.inc
$(BUILD)/vfs.o: src/vfs_copy.inc src/vfs_read.inc src/vfs_move.inc src/vfs_namespace.inc
$(BUILD)/disk.o $(BUILD)/ext2.o $(BUILD)/fat32.o $(BUILD)/vfs.o: src/volume.inc

$(BUILD)/build_id.inc: $(BUILD_ID_INPUTS) | $(BUILD)
	@hash=$$(sha256sum $(BUILD_ID_INPUTS)) && \
	id=$$(printf '%s\n' "$$hash" | sha256sum | cut -c1-12) && \
	printf '%%define BUILD_ID "%s"\n' "$$id" > $@

$(BUILD)/baremetal-os.elf64: $(OBJECTS) src/linker.ld
	$(LD) -m elf_x86_64 -T src/linker.ld -z max-page-size=0x1000 -z noexecstack $(OBJECTS) -o $@

$(KERNEL): $(BUILD)/baremetal-os.elf64
	$(OBJCOPY) --strip-all -O elf32-i386 $< $@

os-check: $(KERNEL)
	grub-file --is-x86-multiboot $(KERNEL)
	readelf -l $(KERNEL)

# Start the longer suites first when running with parallel make.
test: os-check test-ext2 test-storage test-network test-network-irq test-console-and-storage test-acpi-power test-boot test-pages test-smp test-ramfs

test-boot: $(BUILD)/baremetal-os.iso
	bash tests/boot_smoke.sh "$(BUILD)"

$(BUILD)/test_pages.o: tests/page_allocator.asm src/os_constants.inc | $(BUILD)
	$(NASM) -f elf64 -Isrc/ $< -o $@

$(BUILD)/test_pages: $(BUILD)/test_pages.o $(BUILD)/pages.o $(BUILD)/runtime.o
	$(LD) -m elf_x86_64 -z noexecstack --defsym=_kernel_start=0x100000 \
		--defsym=_kernel_end=0x102000 $^ -o $@

test-pages: $(BUILD)/test_pages
	$(BUILD)/test_pages

$(BUILD)/smp-fixture-%.o: tests/smp_boot_fixture.asm src/os_constants.inc | $(BUILD)
	$(NASM) -f elf64 -Isrc/ -DTEST_$* $< -o $@

$(BUILD)/smp-fixture-missing_map.elf64 $(BUILD)/smp-fixture-one_page.elf64: SMP_WRAPPERS := --wrap=smp_init
$(BUILD)/smp-fixture-delayed_ap.elf64: SMP_WRAPPERS := --wrap=pit_delay_us --wrap=console_readline --wrap=smp_ping_irq --wrap=apic_send_ipi
$(BUILD)/smp-fixture-lost_ping.elf64: SMP_WRAPPERS := --wrap=apic_send_ipi
$(BUILD)/smp-fixture-crc32_work.elf64: SMP_WRAPPERS := --wrap=apic_send_ipi --wrap=console_readline --wrap=crc32_buffer

$(BUILD)/smp-fixture-%.elf64: $(BUILD)/smp-fixture-%.o $(OBJECTS) src/linker.ld
	$(LD) -m elf_x86_64 -T src/linker.ld -z max-page-size=0x1000 -z noexecstack \
		$(SMP_WRAPPERS) $(filter %.o,$^) -o $@

$(BUILD)/smp-fixture-%.elf: $(BUILD)/smp-fixture-%.elf64
	$(OBJCOPY) --strip-all -O elf32-i386 $< $@

test-smp: $(SMP_FIXTURES)
	bash tests/smp_boot.sh "$(BUILD)"

test-ramfs: $(KERNEL) $(BUILD)/smp-fixture-one_page.elf
	bash tests/ramfs_boot.sh "$(BUILD)"

$(BUILD)/fat32-%.o: tests/fat32_%.asm | $(BUILD)
	$(NASM) -f elf64 $< -o $@

$(BUILD)/fat32-interrupt.elf64: FAT_WRAPPERS := --wrap=block_flush
$(BUILD)/fat32-mkdir-linked.elf64: FAT_WRAPPERS := --wrap=block_flush
$(BUILD)/fat32-mkdir-linked.o: tests/fat32_interrupt.asm | $(BUILD)
	$(NASM) -f elf64 -DCUT_FLUSH=3 $< -o $@
$(BUILD)/fat32-fault.elf64: FAT_WRAPPERS := --wrap=block_write --wrap=block_flush
$(BUILD)/fat32-overlap.elf64: FAT_WRAPPERS := --wrap=gpt_partition

$(BUILD)/fat32-%.elf64: $(BUILD)/fat32-%.o $(OBJECTS) src/linker.ld
	$(LD) -m elf_x86_64 -T src/linker.ld -z max-page-size=0x1000 -z noexecstack \
		$(FAT_WRAPPERS) $(filter %.o,$^) -o $@

$(BUILD)/fat32-%.elf: $(BUILD)/fat32-%.elf64
	$(OBJCOPY) --strip-all -O elf32-i386 $< $@

test-storage: $(KERNEL) $(FAT_FIXTURES)
	bash tests/storage_boot.sh "$(BUILD)"

test-ata test-gpt: test-%: $(KERNEL)
	bash tests/storage_boot.sh "$(BUILD)" "$*"

test-fat32: $(KERNEL) $(FAT_FIXTURES)
	bash tests/storage_boot.sh "$(BUILD)" fat32

test-ext2: $(KERNEL) $(EXT2_FAULTS)
	bash tests/ext2_boot.sh "$(BUILD)"
	bash tests/ext2_write.sh "$(BUILD)"
	bash tests/ext2_geometry.sh "$(BUILD)"

test-ext2-extended: test-ext2 $(addprefix $(BUILD)/ext2-fixture-,STREAM_READ.elf STREAM_WRITE.elf STREAM_FLUSH.elf)
	bash tests/ext2_recovery_extended.sh "$(BUILD)"

test-network-irq: $(BUILD)/net-irq.elf $(BUILD)/net-poll.elf
	bash tests/network_boot.sh "$(BUILD)" irq

test-console-and-storage: $(KERNEL) $(BUILD)/ext2-fixture-BEFORE.elf $(BUILD)/console-cancel.elf
	bash tests/console_storage_boot.sh "$(BUILD)"

test-acpi-power: $(KERNEL) $(BUILD)/acpi-power-fixture.elf
	bash tests/acpi_power.sh "$(BUILD)"

$(BUILD)/acpi-power-fixture.o: tests/acpi_power_fixture.asm | $(BUILD)
	$(NASM) -f elf64 $< -o $@

$(BUILD)/acpi-power-fixture.elf64: $(BUILD)/acpi-power-fixture.o $(OBJECTS) src/linker.ld
	$(LD) -m elf_x86_64 -T src/linker.ld -z max-page-size=0x1000 -z noexecstack \
		--wrap=block_write --wrap=block_flush --wrap=vfs_shutdown $(filter %.o,$^) -o $@

$(BUILD)/acpi-power-fixture.elf: $(BUILD)/acpi-power-fixture.elf64
	$(OBJCOPY) --strip-all -O elf32-i386 $< $@

$(BUILD)/console-cancel.o: tests/console_cancel.asm | $(BUILD)
	$(NASM) -f elf64 $< -o $@

$(BUILD)/console-cancel.elf64: $(BUILD)/console-cancel.o $(OBJECTS) src/linker.ld
	$(LD) -m elf_x86_64 -T src/linker.ld -z max-page-size=0x1000 -z noexecstack \
		--wrap=block_read --wrap=block_write --wrap=block_flush $(filter %.o,$^) -o $@

$(BUILD)/console-cancel.elf: $(BUILD)/console-cancel.elf64
	$(OBJCOPY) --strip-all -O elf32-i386 $< $@

$(BUILD)/net-irq.o: tests/net_irq.asm | $(BUILD)
	$(NASM) -f elf64 $< -o $@

$(BUILD)/net-poll.o: tests/net_irq.asm | $(BUILD)
	$(NASM) -f elf64 -DFALLBACK $< -o $@

$(BUILD)/net-poll.elf64: NET_IRQ_WRAPPERS := --wrap=pci_config_read32
$(BUILD)/net-irq.elf64 $(BUILD)/net-poll.elf64: %.elf64: %.o $(OBJECTS) src/linker.ld
	$(LD) -m elf_x86_64 -T src/linker.ld -z max-page-size=0x1000 -z noexecstack \
		--wrap=net_timer $(NET_IRQ_WRAPPERS) $(filter %.o,$^) -o $@

$(BUILD)/net-irq.elf $(BUILD)/net-poll.elf: %.elf: %.elf64
	$(OBJCOPY) --strip-all -O elf32-i386 $< $@

test-network: test-network-dhcp-e1000 test-network-dhcp-virtio test-network-e1000 test-network-virtio

# The DHCP lease timers can run alongside the I/O tests on private QEMU sockets.
test-network-dhcp-e1000 test-network-dhcp-virtio: test-network-%: $(BUILD)/network-fixture.elf
	bash tests/network_boot.sh "$(BUILD)" "$*"

test-network-e1000: $(KERNEL) $(BUILD)/dns-fault.elf
	bash tests/network_boot.sh "$(BUILD)" e1000

test-network-virtio: $(KERNEL) $(BUILD)/virtio-queue.elf $(BUILD)/virtio-retry.elf
	bash tests/network_boot.sh "$(BUILD)" virtio

os-run: $(KERNEL)
	$(QEMU) -enable-kvm -cpu host -m $(RAM) -smp $(SMP) -nic none \
		-kernel $(KERNEL) $(if $(INITRAMFS),-initrd "$(INITRAMFS)") \
		-display none -serial stdio -monitor none

os-iso: $(BUILD)/baremetal-os.iso

$(BUILD)/baremetal-os.iso: $(KERNEL) boot/grub.cfg
	mkdir -p $(BUILD)/iso/boot/grub
	cp $(KERNEL) $(BUILD)/iso/boot/
	cp boot/grub.cfg $(BUILD)/iso/boot/grub/
	grub-mkrescue -o $@ $(BUILD)/iso

clean:
	rm -rf $(BUILD)

$(BUILD)/ip-fixture.o: src/ip.asm src/udp.inc src/dhcp.inc src/dns.inc | $(BUILD)
	$(NASM) -f elf64 -Isrc/ -DTEST_UDP_ECHO=49152 $< -o $@

$(BUILD)/net-dma-fault.o: tests/net_dma_fault.asm | $(BUILD)
	$(NASM) -f elf64 $< -o $@

$(BUILD)/network-fixture.elf64: $(filter-out $(BUILD)/ip.o,$(OBJECTS)) $(BUILD)/ip-fixture.o $(BUILD)/net-dma-fault.o src/linker.ld
	$(LD) -m elf_x86_64 -T src/linker.ld -z max-page-size=0x1000 -z noexecstack --wrap=page_alloc $(filter %.o,$^) -o $@

$(BUILD)/network-fixture.elf: $(BUILD)/network-fixture.elf64
	$(OBJCOPY) --strip-all -O elf32-i386 $< $@

$(BUILD)/virtio-dma-fault.o: tests/net_dma_fault.asm | $(BUILD)
	$(NASM) -f elf64 -DTEST_VIRTIO_DMA $< -o $@

$(BUILD)/virtio-retry.elf64: $(OBJECTS) $(BUILD)/virtio-dma-fault.o src/linker.ld
	$(LD) -m elf_x86_64 -T src/linker.ld -z max-page-size=0x1000 -z noexecstack --wrap=page_alloc --wrap=pci_config_read32 $(filter %.o,$^) -o $@

$(BUILD)/virtio-retry.elf: $(BUILD)/virtio-retry.elf64
	$(OBJCOPY) --strip-all -O elf32-i386 $< $@

$(BUILD)/ip-dns-fault.o: src/ip.asm src/udp.inc src/dhcp.inc src/dns.inc | $(BUILD)
	$(NASM) -f elf64 -Isrc/ -DTEST_UDP_ECHO=49152 -DTEST_DNS_RNG $< -o $@

$(BUILD)/dns-fault.o: tests/dns_fault.asm | $(BUILD)
	$(NASM) -f elf64 $< -o $@

$(BUILD)/dns-fault.elf64: $(filter-out $(BUILD)/ip.o,$(OBJECTS)) $(BUILD)/ip-dns-fault.o $(BUILD)/dns-fault.o src/linker.ld
	$(LD) -m elf_x86_64 -T src/linker.ld -z max-page-size=0x1000 -z noexecstack $(filter %.o,$^) -o $@

$(BUILD)/dns-fault.elf: $(BUILD)/dns-fault.elf64
	$(OBJCOPY) --strip-all -O elf32-i386 $< $@

.PHONY: bench-ext2
bench-ext2: $(addprefix $(BUILD)/ext2-bench-,4.elf 16.elf 64.elf)
	bash tests/ext2_bench.sh "$(BUILD)"

$(BUILD)/ext2-bench.o: tests/ext2_bench.asm | $(BUILD)
	$(NASM) -f elf64 $< -o $@

$(BUILD)/vfs-bench-%.o: src/vfs.asm src/vfs_copy.inc src/vfs_read.inc src/vfs_move.inc src/vfs_namespace.inc src/volume.inc src/os_constants.inc | $(BUILD)
	$(NASM) -f elf64 -Isrc/ -DEXT_RANGE_BUFFER='($* * 1024)' $< -o $@

$(BUILD)/ext2-bench-%.elf64: $(BUILD)/vfs-bench-%.o $(BUILD)/ext2-bench.o $(filter-out $(BUILD)/vfs.o,$(OBJECTS)) src/linker.ld
	$(LD) -m elf_x86_64 -T src/linker.ld -z max-page-size=0x1000 -z noexecstack --wrap=ext_read_at $(filter %.o,$^) -o $@

$(BUILD)/ext2-bench-%.elf: $(BUILD)/ext2-bench-%.elf64
	$(OBJCOPY) --strip-all -O elf32-i386 $< $@

.PHONY: test-network-tap
test-network-tap: $(KERNEL)
	unshare --user --map-root-user --net bash tests/network_tap.sh "$(BUILD)"


$(BUILD)/ext2-fixture-BEFORE.o: EXT2_FLAGS := -DCUT=2
$(BUILD)/ext2-fixture-AFTER.o: EXT2_FLAGS := -DCUT=3
$(BUILD)/ext2-fixture-CUT4.o: EXT2_FLAGS := -DCUT=4
$(BUILD)/ext2-fixture-CUT5.o: EXT2_FLAGS := -DCUT=5
$(BUILD)/ext2-fixture-CUT6.o: EXT2_FLAGS := -DCUT=6

$(BUILD)/ext2-fixture-%.o: tests/ext2_fault.asm | $(BUILD)
	$(NASM) -f elf64 -D$* $(EXT2_FLAGS) $< -o $@

$(BUILD)/ext2-fixture-%.elf64: $(BUILD)/ext2-fixture-%.o $(OBJECTS) src/linker.ld
	$(LD) -m elf_x86_64 -T src/linker.ld -z max-page-size=0x1000 -z noexecstack \
		--wrap=block_read --wrap=block_read_range --wrap=block_write --wrap=block_flush $(filter %.o,$^) -o $@

$(BUILD)/ext2-fixture-%.elf: $(BUILD)/ext2-fixture-%.elf64
	$(OBJCOPY) --strip-all -O elf32-i386 $< $@

.PHONY: bench-network
bench-network: $(KERNEL)
	unshare --user --map-root-user --net bash tests/network_bench.sh "$(BUILD)"

$(BUILD)/virtio-net-test.o: src/virtio_net.asm src/os_constants.inc src/virtio_pci.inc | $(BUILD)
	$(NASM) -f elf64 -Isrc/ -DTEST_VIRTIO_TX $< -o $@

$(BUILD)/virtio-queue.o: tests/virtio_queue.asm | $(BUILD)
	$(NASM) -f elf64 $< -o $@

$(BUILD)/virtio-queue.elf64: $(filter-out $(BUILD)/virtio_net.o,$(OBJECTS)) $(BUILD)/virtio-net-test.o $(BUILD)/virtio-queue.o src/linker.ld
	$(LD) -m elf_x86_64 -T src/linker.ld -z max-page-size=0x1000 -z noexecstack \
		--wrap=console_readline $(filter %.o,$^) -o $@

$(BUILD)/virtio-queue.elf: $(BUILD)/virtio-queue.elf64
	$(OBJCOPY) --strip-all -O elf32-i386 $< $@
