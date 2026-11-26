NASM    ?= nasm
LD      ?= ld
OBJCOPY ?= objcopy
QEMU    ?= qemu-system-x86_64

BUILD   := build
KERNEL  := $(BUILD)/baremetal-os.elf
OBJECTS := $(addprefix $(BUILD)/,ata.o boot.o cpu.o crc32.o disk.o drivers.o echo.o fat32.o gpt.o kernel.o net.o pages.o pci.o ramfs.o runtime.o smp.o)
BUILD_ID_INPUTS := Makefile $(sort $(wildcard src/*.asm src/*.inc src/*.ld))
SMP_FIXTURES := $(addprefix $(BUILD)/smp-fixture-,missing_map.elf one_page.elf delayed_ap.elf lost_ping.elf crc32_work.elf)
RAM     ?= 64M
SMP     ?= 1
INITRAMFS ?=

.PHONY: all os os-check os-run os-iso clean \
	test test-boot test-pages test-smp test-ramfs test-ata test-gpt test-fat32 test-storage test-network

all: os

os: $(KERNEL)

$(BUILD):
	mkdir -p $@

$(BUILD)/%.o: src/%.asm src/os_constants.inc | $(BUILD)
	$(NASM) -f elf64 -Isrc/ -I$(BUILD)/ $< -o $@

$(BUILD)/kernel.o: $(BUILD)/build_id.inc
$(BUILD)/fat32.o: src/fat32_check.inc

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

test: os-check test-boot test-pages test-smp test-ramfs test-storage test-network

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

$(BUILD)/fat32-interrupt.o: tests/fat32_interrupt.asm | $(BUILD)
	$(NASM) -f elf64 $< -o $@

$(BUILD)/fat32-interrupt.elf64: $(BUILD)/fat32-interrupt.o $(OBJECTS) src/linker.ld
	$(LD) -m elf_x86_64 -T src/linker.ld -z max-page-size=0x1000 -z noexecstack \
		--wrap=block_flush $(filter %.o,$^) -o $@

$(BUILD)/fat32-interrupt.elf: $(BUILD)/fat32-interrupt.elf64
	$(OBJCOPY) --strip-all -O elf32-i386 $< $@

test-storage: $(KERNEL) $(BUILD)/fat32-interrupt.elf
	bash tests/storage_boot.sh "$(BUILD)"

test-ata test-gpt: test-%: $(KERNEL)
	bash tests/storage_boot.sh "$(BUILD)" "$*"

test-fat32: $(KERNEL) $(BUILD)/fat32-interrupt.elf
	bash tests/storage_boot.sh "$(BUILD)" fat32

test-network: $(KERNEL)
	bash tests/network_boot.sh "$(BUILD)"

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
