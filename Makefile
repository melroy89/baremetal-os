NASM    ?= nasm
LD      ?= ld
OBJCOPY ?= objcopy
QEMU    ?= qemu-system-x86_64

BUILD   := build
KERNEL  := $(BUILD)/baremetal-os.elf
OBJECTS := $(addprefix $(BUILD)/,boot.o cpu.o drivers.o kernel.o pages.o runtime.o smp.o)
BUILD_ID_INPUTS := Makefile $(sort $(wildcard src/*.asm src/*.inc src/*.ld))
RAM     ?= 64M
SMP     ?= 1

.PHONY: all os os-check os-run os-iso test-pages clean

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

os-run: $(KERNEL)
	$(QEMU) -enable-kvm -cpu host -m $(RAM) -smp $(SMP) -nic none \
		-kernel $(KERNEL) -display none -serial stdio -monitor none

os-iso: $(BUILD)/baremetal-os.iso

$(BUILD)/baremetal-os.iso: $(KERNEL) boot/grub.cfg
	mkdir -p $(BUILD)/iso/boot/grub
	cp $(KERNEL) $(BUILD)/iso/boot/
	cp boot/grub.cfg $(BUILD)/iso/boot/grub/
	grub-mkrescue -o $@ $(BUILD)/iso

clean:
	rm -rf $(BUILD)
