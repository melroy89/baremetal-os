NASM    ?= nasm
LD      ?= ld
OBJCOPY ?= objcopy
QEMU    ?= qemu-system-x86_64

BUILD   := build
KERNEL  := $(BUILD)/baremetal-os.elf
OBJECTS := $(addprefix $(BUILD)/,boot.o cpu.o drivers.o echo.o kernel.o pages.o ramfs.o runtime.o smp.o)
BUILD_ID_INPUTS := Makefile $(sort $(wildcard src/*.asm src/*.inc src/*.ld))
SMP_FIXTURES := $(addprefix $(BUILD)/smp-fixture-,missing_map.elf one_page.elf delayed_ap.elf lost_ping.elf)
RAM     ?= 64M
SMP     ?= 1
INITRAMFS ?=

.PHONY: all os os-check os-run os-iso test-pages test-smp test-ramfs clean

all: os

os: $(KERNEL)

$(BUILD):
	mkdir -p $@

$(BUILD)/%.o: src/%.asm src/os_constants.inc | $(BUILD)
	$(NASM) -f elf64 -Isrc/ -I$(BUILD)/ $< -o $@

$(BUILD)/kernel.o: $(BUILD)/build_id.inc

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

$(BUILD)/test_pages.o: tests/page_allocator.asm src/os_constants.inc | $(BUILD)
	$(NASM) -f elf64 -Isrc/ $< -o $@

$(BUILD)/test_pages: $(BUILD)/test_pages.o $(BUILD)/pages.o $(BUILD)/runtime.o
	$(LD) -m elf_x86_64 -z noexecstack --defsym=_kernel_start=0x100000 \
		--defsym=_kernel_end=0x102000 $^ -o $@

test-pages: $(BUILD)/test_pages
	./$(BUILD)/test_pages

$(BUILD)/smp-fixture-%.o: tests/smp_boot_fixture.asm src/os_constants.inc | $(BUILD)
	$(NASM) -f elf64 -Isrc/ -DTEST_$* $< -o $@

$(BUILD)/smp-fixture-missing_map.elf64 $(BUILD)/smp-fixture-one_page.elf64: SMP_WRAPPERS := --wrap=smp_init
$(BUILD)/smp-fixture-delayed_ap.elf64: SMP_WRAPPERS := --wrap=pit_delay_us --wrap=console_readline --wrap=smp_ping_irq --wrap=apic_send_ipi
$(BUILD)/smp-fixture-lost_ping.elf64: SMP_WRAPPERS := --wrap=apic_send_ipi

$(BUILD)/smp-fixture-%.elf64: $(BUILD)/smp-fixture-%.o $(OBJECTS) src/linker.ld
	$(LD) -m elf_x86_64 -T src/linker.ld -z max-page-size=0x1000 -z noexecstack \
		$(SMP_WRAPPERS) $(filter %.o,$^) -o $@

$(BUILD)/smp-fixture-%.elf: $(BUILD)/smp-fixture-%.elf64
	$(OBJCOPY) --strip-all -O elf32-i386 $< $@

test-smp: $(SMP_FIXTURES)
	bash tests/smp_boot.sh "$(BUILD)"

test-ramfs: $(KERNEL) $(BUILD)/smp-fixture-one_page.elf
	bash tests/ramfs_boot.sh "$(BUILD)"

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
