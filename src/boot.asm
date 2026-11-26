; Multiboot 1 bootstrap, x86-64 long-mode transition, and CPU exception handlers.

%include "os_constants.inc"

extern _bss_start
extern _bss_end
extern kernel_main
extern console_putc
extern console_write_cstr
extern console_input_irq
extern smp_ping_irq
extern smp_ping_drain_irq
extern write_hex64_raw

global _start
global gdt64_ptr
global idt64_ptr
global pml4_table
global g_mb_magic
global g_mb_info
global g_boot_tsc

; ============================================================================
; Multiboot 1 Header (must reside in first 8192 bytes of ELF file)
; ============================================================================
section .multiboot align=4
    dd MB_HEADER_MAGIC
    dd MB_HEADER_FLAGS
    dd MB_HEADER_CHECKSUM

; ============================================================================
; 32-bit Protected Mode Bootstrap
; ============================================================================
section .text.boot
bits 32
default abs

_start:
    cli
    cld

    ; Preserve Multiboot magic (eax) and info ptr (ebx) across .bss zeroing
    mov     esi, eax
    mov     ebp, ebx

    ; Explicitly zero .bss so every Multiboot loader (QEMU, GRUB BIOS/UEFI) starts clean
    mov     edi, _bss_start
    mov     ecx, _bss_end
    sub     ecx, edi
    shr     ecx, 2
    xor     eax, eax
    rep     stosd

    ; Set up temporary 32-bit stack at top of BSP stack
    mov     esp, bsp_stack_top

    ; Save Multiboot 1 magic and info pointer
    mov     [g_mb_magic], esi
    mov     [g_mb_info], ebp

    ; Capture earliest possible RDTSC right at boot entry
    rdtsc
    mov     [g_boot_tsc], eax
    mov     [g_boot_tsc + 4], edx

    ; PML4[0] -> pdpt_table | Present | Writable (0x03)
    mov     eax, pdpt_table
    or      eax, 0x03
    mov     [pml4_table], eax

    ; PDPT[0..3] -> pd_tables[0..3] | Present | Writable (0x03)
    mov     eax, pd_tables
    or      eax, 0x03
    mov     [pdpt_table + 0], eax
    add     eax, 4096
    mov     [pdpt_table + 8], eax
    add     eax, 4096
    mov     [pdpt_table + 16], eax
    add     eax, 4096
    mov     [pdpt_table + 24], eax

    ; Fill all 4 * 512 = 2048 PD entries with 2 MiB huge pages (0..4 GiB)
    ; Entries 0..2031 (0x00000000..0xFDFFFFFF): flags 0x83 (P | RW | PS)
    ; Entries 2032..2047 (0xFE000000..0xFFFFFFFF): flags 0x9B (P | RW | PWT | PCD | PS)
    ;   -> Strong Uncacheable (UC) for Local APIC (0xFEE00000) & IOAPIC MMIO!
    mov     edi, pd_tables
    xor     ebx, ebx                    ; physical address = 0
    xor     ecx, ecx                    ; entry index = 0..2047
.fill_pd:
    mov     eax, ebx
    cmp     ecx, HIGH_MMIO_BASE >> 21
    jae     .mmio_flags
    or      eax, 0x83
    jmp     .store_pde
.mmio_flags:
    or      eax, 0x9B
.store_pde:
    mov     [edi], eax
    mov     dword [edi + 4], 0          ; upper 32 bits = 0 (all < 4 GiB)
    add     edi, 8
    add     ebx, 0x00200000             ; +2 MiB
    inc     ecx
    cmp     ecx, 2048
    jb      .fill_pd

    ; Load CR3 with PML4 physical address
    mov     eax, pml4_table
    mov     cr3, eax

    ; Enable PAE (CR4.PAE = bit 5)
    mov     eax, cr4
    or      eax, (1 << 5)
    mov     cr4, eax

    ; Enable Long Mode in IA32_EFER MSR (0xC0000080, bit 8 = LME)
    mov     ecx, 0xC0000080
    rdmsr
    or      eax, (1 << 8)
    wrmsr

    ; Enable Paging (CR0.PG = bit 31, CR0.PE = bit 0)
    mov     eax, cr0
    or      eax, 0x80000001
    mov     cr0, eax

    ; Load 64-bit GDT and far jump into 64-bit Long Mode
    lgdt    [gdt64_ptr]
    jmp     0x08:long_mode_start

; ============================================================================
; 64-bit Long Mode Entry
; ============================================================================
section .text
bits 64
default rel

long_mode_start:
    mov     ax, 0x10
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     fs, ax
    mov     gs, ax

    lea     rsp, [rel bsp_stack_top]
    and     rsp, -16

    ; Clean RFLAGS (IF=0, DF=0)
    push    0
    popfq

    ; Install CPU exception and legacy input interrupt handlers.
    call    idt_setup_and_load

    ; Enter the kernel with interrupts masked.
    call    kernel_main

.halt_forever:
    cli
    hlt
    jmp     .halt_forever

; ----------------------------------------------------------------------------
; CPU exceptions, master PIC interrupts, and local APIC interrupts
; ----------------------------------------------------------------------------
idt_setup_and_load:
    lea     rdi, [rel idt64]
    lea     rsi, [rel isr_stub_table]
    xor     ecx, ecx
.fill:
    cmp     ecx, IDT_ENTRIES
    jae     .load
    mov     rax, [rsi + rcx*8]          ; handler address
    test    rax, rax
    jz      .next                     ; Unused gates stay zero in BSS.
    mov     [rdi + 0], ax               ; offset 15..0
    mov     word [rdi + 2], 0x08        ; 64-bit code selector
    mov     byte [rdi + 4], 0           ; IST = 0
    mov     byte [rdi + 5], 0x8E        ; Present | DPL=0 | Interrupt Gate
    shr     rax, 16
    mov     [rdi + 6], ax               ; offset 31..16
    shr     rax, 16
    mov     [rdi + 8], eax              ; offset 63..32
    mov     dword [rdi + 12], 0         ; reserved
.next:
    add     rdi, 16
    inc     ecx
    jmp     .fill
.load:
    lidt    [rel idt64_ptr]
    ret

; A spurious local APIC interrupt does not require an EOI.
apic_spurious_irq:
    iretq

; Common CPU exception reporter (prints vector + RIP + error code to COM1 & halts)
isr_common:
    ; Stack: [rsp] = vec, [rsp+8] = err, [rsp+16] = rip, [rsp+24] = cs, [rsp+32] = rflags
    mov     r12, [rsp + 0]              ; vec
    mov     r13, [rsp + 8]              ; err
    mov     r14, [rsp + 16]             ; rip
    and     rsp, -16
    lea     rdi, [rel msg_exc_hdr]
    call    console_write_cstr
    mov     rdi, r12
    call    write_hex64_raw
    lea     rdi, [rel msg_exc_rip]
    call    console_write_cstr
    mov     rdi, r14
    call    write_hex64_raw
    lea     rdi, [rel msg_exc_err]
    call    console_write_cstr
    mov     rdi, r13
    call    write_hex64_raw
    lea     rdi, [rel msg_exc_cr2]
    call    console_write_cstr
    mov     rdi, cr2
    call    write_hex64_raw
    mov     edi, 10
    call    console_putc
.hang:
    cli
    hlt
    jmp     .hang

%macro ISR_NOERR 1
isr_stub_%1:
    push    qword 0
    push    qword %1
    jmp     isr_common
%endmacro

%macro ISR_ERR 1
isr_stub_%1:
    push    qword %1
    jmp     isr_common
%endmacro

ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR   8
ISR_NOERR 9
ISR_ERR   10
ISR_ERR   11
ISR_ERR   12
ISR_ERR   13
ISR_ERR   14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR   17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_ERR   21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_ERR   29
ISR_ERR   30
ISR_NOERR 31

; ============================================================================
; Read-only tables & GDT
; ============================================================================
section .rodata
align 16
gdt64:
    dq 0x0000000000000000               ; 0x00: Null descriptor
    dq 0x00AF9A000000FFFF               ; 0x08: 64-bit Code (L=1, P=1, DPL=0, RX)
    dq 0x00CF92000000FFFF               ; 0x10: 64-bit Data (P=1, DPL=0, RW)
gdt64_end:

align 8
gdt64_ptr:
    dw gdt64_end - gdt64 - 1
    dq gdt64

align 8
idt64_ptr:
    dw IDT_ENTRIES * 16 - 1
    dq idt64

align 8
isr_stub_table:
%assign i 0
%rep 32
    dq isr_stub_%+i
%assign i i+1
%endrep
%rep 8
    dq console_input_irq
%endrep
    times APIC_DRAIN_VECTOR - ($ - isr_stub_table) / 8 dq 0
    dq smp_ping_drain_irq
    times APIC_PING_VECTOR - ($ - isr_stub_table) / 8 dq 0
    dq smp_ping_irq
    times APIC_SPURIOUS_VECTOR - ($ - isr_stub_table) / 8 dq 0
    dq apic_spurious_irq
IDT_ENTRIES equ ($ - isr_stub_table) / 8

msg_exc_hdr:    db 10, "[PANIC] CPU Exception vec=0x", 0
msg_exc_rip:    db " RIP=0x", 0
msg_exc_err:    db " ERR=0x", 0
msg_exc_cr2:    db " CR2=0x", 0

; ============================================================================
; Uninitialized Data (.bss — zero bytes on disk)
; ============================================================================
section .bss
alignb 4096
pml4_table:     resb 4096
pdpt_table:     resb 4096
pd_tables:      resb 4 * 4096           ; 4 x 512 x 2 MiB = 4 GiB identity map

alignb 16
idt64:          resb IDT_ENTRIES * 16

alignb 16
bsp_stack:      resb BSP_STACK_SIZE
bsp_stack_top:

alignb 8
g_boot_tsc:     resq 1
g_mb_magic:     resd 1
g_mb_info:      resd 1
