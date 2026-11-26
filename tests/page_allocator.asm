; Linux test executable for the same NASM allocator linked into the kernel.
bits 64
default rel
%include "os_constants.inc"

extern page_init
extern page_alloc
extern page_free
extern pages_managed
extern pages_free
global _start
global console_write
global console_write_cstr
global console_putc

; The exit status reports the source line of a failed assertion.
%macro assert_eq 2
    cmp     %1, %2
    je      %%ok
    mov     edi, __?LINE?__
    jmp     exit
%%ok:
%endmacro

%macro assert_cannot_free 1
    mov     edi, %1
    call    page_free
    assert_eq eax, -1
%endmacro

%macro map_entry 3
    dd 20
    dq %1, %2
    dd %3
%endmacro

section .text
_start:
    lea     rdi, [rel mbi]
    call    page_init
    assert_eq qword [rel pages_managed], 5
    assert_eq qword [rel pages_free], 5

    ; Low memory, kernel image, reserved map overlap, retained boot data,
    ; module payload, MMIO, and never-allocated pages are protected.
    assert_cannot_free TRAMP_BASE
    assert_cannot_free 0x100000
    assert_cannot_free 0x103000
    assert_cannot_free 0x104000
    assert_cannot_free 0x105000
    assert_cannot_free boot_page
    assert_cannot_free (boot_page + PAGE_SIZE)
    assert_cannot_free mmap
    assert_cannot_free modules
    assert_cannot_free HIGH_MMIO_BASE
    assert_cannot_free 0x102000
    assert_eq qword [rel pages_free], 5

    call    page_alloc
    assert_eq rax, 0x102000
    call    page_alloc
    assert_eq rax, 0x201000
    call    page_alloc
    assert_eq rax, 0x202000
    call    page_alloc
    mov     edx, metadata_end
    assert_eq rax, rdx
    call    page_alloc
    mov     edx, HIGH_MMIO_BASE - PAGE_SIZE
    assert_eq rax, rdx
    assert_eq qword [rel pages_free], 0
    call    page_alloc
    assert_eq rax, 0

    assert_cannot_free 0x102001
    mov     edi, 0x102000
    call    page_free
    assert_eq eax, 0
    assert_cannot_free 0x102000
    assert_eq qword [rel pages_free], 1
    call    page_alloc
    assert_eq rax, 0x102000
    assert_eq qword [rel pages_free], 0

    ; Truncation during the first map pass cannot publish partial results.
    dec     dword [rel mbi + MBI_MMAP_LENGTH]
    lea     rdi, [rel mbi]
    call    page_init
    assert_eq qword [rel pages_managed], 0
    assert_eq qword [rel pages_free], 0
    assert_cannot_free 0x102000
    call    page_alloc
    assert_eq rax, 0

    ; An overflowing map range, invalid module list, and absent map all
    ; leave the allocator empty.
    inc     dword [rel mbi + MBI_MMAP_LENGTH]
    mov     qword [rel mmap + 12], -1
    lea     rdi, [rel mbi]
    call    page_init
    assert_eq qword [rel pages_managed], 0
    mov     qword [rel mmap + 12], 2
    mov     dword [rel mbi + MBI_MODS_ADDR], -1
    lea     rdi, [rel mbi]
    call    page_init
    assert_eq qword [rel pages_managed], 0
    mov     dword [rel mbi + MBI_FLAGS], 0
    lea     rdi, [rel mbi]
    call    page_init
    assert_eq qword [rel pages_managed], 0
    assert_eq qword [rel pages_free], 0
    call    page_alloc
    assert_eq rax, 0

    xor     edi, edi
exit:
    mov     eax, 60
    syscall

; The Multiboot walker shares an object with console formatting routines.
console_write:
console_write_cstr:
console_putc:
    ret

section .data
align PAGE_SIZE
boot_page:
    times PAGE_SIZE - 60 db 0
mbi:
    dd (1 << 6) | (1 << 3)
    times MBI_MODS_COUNT - ($ - mbi) db 0
    dd 1, modules
    times MBI_MMAP_LENGTH - ($ - mbi) db 0
    dd mmap_end - mmap, mmap
    times MBI_SIZE - ($ - mbi) db 0

align PAGE_SIZE
mmap:
    map_entry 0x103FFF, 2, 2
    map_entry TRAMP_BASE, PAGE_SIZE, 1
    map_entry 0x100000, 6 * PAGE_SIZE, 1
    map_entry 0x102000, PAGE_SIZE, 1
    map_entry 0x200001, 0x3FFE, 1
    map_entry boot_page, 5 * PAGE_SIZE, 1
    map_entry (HIGH_MMIO_BASE - PAGE_SIZE), 2 * PAGE_SIZE, 1
mmap_end:

align PAGE_SIZE
modules:
    dd 0x105800, 0x105801, 0, 0
align PAGE_SIZE
metadata_end:
