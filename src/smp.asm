; Discover processors through ACPI and bring application processors into long mode.

bits 64
default rel

%include "os_constants.inc"

extern pml4_table
extern gdt64_ptr
extern idt64_ptr
extern pit_delay_us
extern timer_ns

section .text

global smp_init
global g_smp_total_cpus
global g_smp_online_cpus

smp_init:
    push    rbx
    push    rbp
    push    r13
    push    r14
    push    r15

    mov     dword [rel smp_next_tid], 1
    mov     dword [rel g_smp_online_cpus], 1
    mov     dword [rel g_smp_total_cpus], 1

    ; Read Local APIC base address from IA32_APIC_BASE MSR (0x1B)
    mov     ecx, 0x1B
    rdmsr
    shl     rdx, 32
    or      rax, rdx
    and     rax, ~0xFFF
    test    rax, rax
    jnz     .have_apic_base
    mov     rax, APIC_DEFAULT_BASE
.have_apic_base:
    mov     [rel g_smp_apic_base], rax
    mov     r13, rax                    ; r13 = apic_base

    ; Software-enable Local APIC (SVR bit 8 = 0x100, spurious vector 0xFF)
    mov     eax, [r13 + APIC_REG_SVR]
    or      eax, 0x1FF
    mov     [r13 + APIC_REG_SVR], eax

    ; Read BSP Local APIC ID
    mov     eax, [r13 + APIC_REG_ID]
    shr     eax, 24
    mov     [rel bsp_apic_id], al
    movzx   rcx, al
    lea     rdx, [rel ap_started]
    mov     byte [rdx + rcx], 1

    call    acpi_discover_madt

    ; Copy 16-bit->32-bit->64-bit AP trampoline to 0x8000
    test    eax, eax
    jz      .wake_broadcast

    ; MADT found: check how many APs to wake
    mov     r15d, [rel n_ap_ids]
    test    r15d, r15d
    jz      .done
    call    install_trampoline

    ; Step 1: Send INIT IPI to all target APs
    xor     ebx, ebx
.init_lp:
    cmp     rbx, r15
    jae     .init_delay
    lea     rax, [rel ap_apic_ids]
    movzx   edi, byte [rax + rbx]
    mov     esi, 0x00004500             ; INIT, Level=Assert, Edge
    call    apic_send_ipi
    inc     rbx
    jmp     .init_lp

.init_delay:
    ; Step 2: 10 ms delay (Intel MP spec)
    mov     rdi, 10000
    call    pit_delay_us

    ; Step 3: Send 1st SIPI (vector = 0x08 -> physical 0x8000) to all target APs
    xor     ebx, ebx
.sipi1_lp:
    cmp     rbx, r15
    jae     .sipi1_delay
    lea     rax, [rel ap_apic_ids]
    movzx   edi, byte [rax + rbx]
    mov     esi, 0x00004600 | TRAMP_VECTOR
    call    apic_send_ipi
    inc     rbx
    jmp     .sipi1_lp

.sipi1_delay:
    ; Step 4: 200 us delay
    mov     rdi, 200
    call    pit_delay_us

    ; Step 5: Send 2nd SIPI ONLY to APs that have not yet checked in
    xor     ebx, ebx
.sipi2_lp:
    cmp     rbx, r15
    jae     .wait_aps
    lea     rax, [rel ap_apic_ids]
    movzx   edi, byte [rax + rbx]
    lea     rcx, [rel ap_started]
    cmp     byte [rcx + rdi], 0
    jne     .sipi2_next
    mov     esi, 0x00004600 | TRAMP_VECTOR
    call    apic_send_ipi
.sipi2_next:
    inc     rbx
    jmp     .sipi2_lp

.wait_aps:
    ; Step 6: Wait until g_smp_online_cpus == r15 + 1 (or 150 ms timeout)
    lea     rbp, [r15 + 1]
    call    timer_ns
    mov     r14, rax
    add     r14, 150000000              ; 150 ms deadline
.wait_lp:
    mov     eax, [rel g_smp_online_cpus]
    cmp     rax, rbp
    jae     .done
    call    timer_ns
    cmp     rax, r14
    jae     .done
    pause
    jmp     .wait_lp

; Fallback when ACPI MADT is unavailable (e.g. UEFI Multiboot 1 without BIOS RSDP):
; Uses Local APIC "All Excluding Self" shorthand INIT + SIPI.
.wake_broadcast:
    call    install_trampoline
    mov     dword [r13 + APIC_REG_ESR], 0
    mov     dword [r13 + APIC_REG_ICR_HI], 0
    mov     dword [r13 + APIC_REG_ICR_LO], 0x000C4500 ; All Excl Self, INIT Assert
    call    apic_wait_icr

    mov     rdi, 10000
    call    pit_delay_us

    mov     dword [r13 + APIC_REG_ESR], 0
    mov     dword [r13 + APIC_REG_ICR_HI], 0
    mov     dword [r13 + APIC_REG_ICR_LO], 0x000C4600 | TRAMP_VECTOR
    call    apic_wait_icr

    ; Wait 25 ms for APs to boot and check in
    mov     rdi, 25000
    call    pit_delay_us

    mov     eax, [rel g_smp_online_cpus]
    mov     [rel g_smp_total_cpus], eax

.done:
    pop     r15
    pop     r14
    pop     r13
    pop     rbp
    pop     rbx
    ret

; ----------------------------------------------------------------------------
; Internal: wait for APIC ICR Delivery Status bit (bit 12) to clear
; Assumes r13 = apic_base.
; ----------------------------------------------------------------------------
apic_wait_icr:
    mov     ecx, 1000000
.lp:
    mov     eax, [r13 + APIC_REG_ICR_LO]
    test    eax, (1 << 12)
    jz      .ok
    pause
    dec     ecx
    jnz     .lp
.ok:
    ret

; ----------------------------------------------------------------------------
; Internal: apic_send_ipi(uint8 dest_apic_id in dil, uint32 icr_lo in esi)
; Assumes r13 = apic_base.
; ----------------------------------------------------------------------------
apic_send_ipi:
    mov     dword [r13 + APIC_REG_ESR], 0
    movzx   eax, dil
    shl     eax, 24
    mov     [r13 + APIC_REG_ICR_HI], eax
    mov     [r13 + APIC_REG_ICR_LO], esi
    jmp     apic_wait_icr

; ----------------------------------------------------------------------------
; Internal: Copy 16->32->64 trampoline to 0x8000 and populate mailbox fields
; ----------------------------------------------------------------------------
install_trampoline:
    lea     rsi, [rel ap_trampoline_start]
    mov     rdi, TRAMP_BASE
    mov     rcx, ap_trampoline_end - ap_trampoline_start
    rep     movsb

    lea     rax, [rel pml4_table]
    mov     dword [abs TRAMP_PML4], eax

    lea     rax, [rel ap_entry64]
    mov     qword [abs TRAMP_ENTRY64], rax
    mfence
    ret

; ----------------------------------------------------------------------------
; Internal: Discover ACPI RSDP -> RSDT/XSDT -> MADT ("APIC") -> ap_apic_ids[]
; Returns eax = 1 if MADT found and parsed, 0 otherwise.
; ----------------------------------------------------------------------------
acpi_discover_madt:
    push    rbx
    push    rbp
    push    r12
    push    r13
    mov     dword [rel n_ap_ids], 0
    mov     dword [rel g_smp_total_cpus], 1

    ; 1. Scan EBDA (BDA 0x40E << 4, 1 KiB)
    movzx   rdi, word [abs 0x40E]
    shl     rdi, 4
    cmp     rdi, 0x80000
    jb      .scan_bios
    cmp     rdi, 0xA0000
    jae     .scan_bios
    mov     rsi, 1024
    call    find_rsdp_in_range
    test    rax, rax
    jnz     .have_rsdp

.scan_bios:
    ; 2. Scan BIOS ROM area 0xE0000 .. 0xFFFFF (128 KiB)
    mov     rdi, 0x000E0000
    mov     rsi, 0x00020000
    call    find_rsdp_in_range
    test    rax, rax
    jz      .not_found

.have_rsdp:
    mov     rbx, rax                    ; rbx = RSDP ptr
    ; Check ACPI revision >= 2 and valid 32-bit-accessible XSDT
    cmp     byte [rbx + 15], 2
    jb      .use_rsdt
    mov     r12, [rbx + 24]             ; XSDT phys addr
    test    r12, r12
    jz      .use_rsdt
    mov     rax, 0xF0000000
    cmp     r12, rax
    jae     .use_rsdt

    ; Scan XSDT (8-byte entries starting at +36)
    mov     ebp, [r12 + 4]              ; XSDT length
    cmp     ebp, 36
    jb      .use_rsdt
    sub     ebp, 36
    shr     ebp, 3                      ; entry count
    xor     ecx, ecx
.xsdt_lp:
    cmp     ecx, ebp
    jae     .use_rsdt
    mov     rax, [r12 + 36 + rcx*8]
    test    rax, rax
    jz      .xsdt_next
    mov     rdx, 0xF0000000
    cmp     rax, rdx
    jae     .xsdt_next
    cmp     dword [rax], 0x43495041     ; "APIC"
    je      .parse_madt
.xsdt_next:
    inc     ecx
    jmp     .xsdt_lp

.use_rsdt:
    mov     r12d, [rbx + 16]            ; RSDT phys addr (32-bit)
    test    r12, r12
    jz      .not_found
    mov     rax, 0xF0000000
    cmp     r12, rax
    jae     .not_found

    mov     ebp, [r12 + 4]              ; RSDT length
    cmp     ebp, 36
    jb      .not_found
    sub     ebp, 36
    shr     ebp, 2                      ; entry count
    xor     ecx, ecx
.rsdt_lp:
    cmp     ecx, ebp
    jae     .not_found
    mov     eax, [r12 + 36 + rcx*4]
    test    eax, eax
    jz      .rsdt_next
    cmp     eax, 0xF0000000
    jae     .rsdt_next
    cmp     dword [rax], 0x43495041     ; "APIC"
    je      .parse_madt
.rsdt_next:
    inc     ecx
    jmp     .rsdt_lp

.parse_madt:
    ; rax = MADT ("APIC") table pointer
    mov     dword [rel g_smp_total_cpus], 0
    mov     ebx, [rax + 4]              ; MADT total length
    lea     rbp, [rax + rbx]            ; end ptr
    lea     r12, [rax + 44]             ; first entry (after 36B SDT + 8B MADT hdr)
    movzx   r13d, byte [rel bsp_apic_id]

.madt_lp:
    lea     rax, [r12 + 2]
    cmp     rax, rbp
    ja      .madt_done
    movzx   ecx, byte [r12 + 0]         ; entry type
    movzx   edx, byte [r12 + 1]         ; entry length
    cmp     edx, 2
    jb      .madt_done
    lea     rax, [r12 + rdx]
    cmp     rax, rbp
    ja      .madt_done

    cmp     ecx, 0                      ; Type 0: Processor Local APIC
    je      .madt_lapic
    cmp     ecx, 9                      ; Type 9: Processor Local x2APIC
    je      .madt_x2apic
    jmp     .madt_next

.madt_lapic:
    cmp     edx, 8
    jb      .madt_next
    mov     eax, [r12 + 4]              ; flags (bit 0 = enabled, bit 1 = online capable)
    test    eax, 3
    jz      .madt_next
    movzx   eax, byte [r12 + 3]         ; APIC ID
    jmp     .madt_record_cpu

.madt_x2apic:
    cmp     edx, 16
    jb      .madt_next
    mov     eax, [r12 + 8]              ; flags
    test    eax, 3
    jz      .madt_next
    mov     eax, [r12 + 4]              ; x2APIC ID
    cmp     eax, 255
    ja      .madt_next

.madt_record_cpu:
    inc     dword [rel g_smp_total_cpus]
    cmp     eax, r13d                   ; skip BSP
    je      .madt_next
    mov     ecx, [rel n_ap_ids]
    cmp     ecx, OS_MAX_CPUS - 1
    jae     .madt_next
    lea     r8, [rel ap_apic_ids]
    mov     [r8 + rcx], al
    inc     ecx
    mov     [rel n_ap_ids], ecx

.madt_next:
    add     r12, rdx
    jmp     .madt_lp

.madt_done:
    cmp     dword [rel g_smp_total_cpus], 0
    jne     .madt_ok
    mov     dword [rel g_smp_total_cpus], 1
.madt_ok:
    mov     eax, 1
    jmp     .ret

.not_found:
    xor     eax, eax
.ret:
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; Internal: find_rsdp_in_range(uint64 start in rdi, uint64 len in rsi) -> rax or 0
find_rsdp_in_range:
    mov     r8, 0x2052545020445352      ; "RSD PTR " little-endian
    lea     r9, [rdi + rsi]
.lp:
    cmp     rdi, r9
    jae     .none
    cmp     [rdi], r8
    jne     .next
    ; Verify 20-byte RSDP checksum
    xor     ecx, ecx
    xor     eax, eax
.chk:
    add     al, [rdi + rcx]
    inc     ecx
    cmp     ecx, 20
    jb      .chk
    test    al, al
    jnz     .next
    mov     rax, rdi
    ret
.next:
    add     rdi, 16
    jmp     .lp
.none:
    xor     eax, eax
    ret

; ============================================================================
; 64-bit Application Processor Entry (jumped to from 0x8000 trampoline)
; ============================================================================
ap_entry64:
    ; Atomically claim unique processor index = 1, 2, 3, ...
    mov     eax, 1
    lock xadd dword [rel smp_next_tid], eax
    mov     r12d, eax                   ; r12 = processor index
    cmp     r12, OS_MAX_CPUS
    jae     .ap_halt

    ; Assign private 32 KiB 16-byte-aligned stack
    mov     rax, r12
    shl     rax, 15                     ; processor index * 32768
    lea     rsp, [rel ap_stacks]
    add     rsp, rax
    add     rsp, AP_STACK_SIZE          ; top of stack (16B aligned)

    ; Switch to kernel's permanent GDT & exception IDT
    lgdt    [rel gdt64_ptr]
    mov     ax, 0x10
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     fs, ax
    mov     gs, ax
    lidt    [rel idt64_ptr]

    ; Clean RFLAGS
    push    0
    popfq

    ; Record own APIC ID in ap_started[] and announce online
    mov     rax, [rel g_smp_apic_base]
    mov     eax, [rax + APIC_REG_ID]
    shr     eax, 24
    lea     rcx, [rel ap_started]
    mov     byte [rcx + rax], 1
    lock inc dword [rel g_smp_online_cpus]

.ap_halt:
    cli
    hlt
    jmp     .ap_halt

; ============================================================================
; Position-Independent 16-bit -> 32-bit -> 64-bit AP Trampoline (copied to 0x8000)
; ZERO relocations inside this block — all offsets evaluated at assembly time!
; ============================================================================
section .rodata
align 16
ap_trampoline_start:
bits 16
default abs
    cli
    cld
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    mov     ss, ax

    ; Load self-contained trampoline GDT (selectors match kernel's 0x08 / 0x10!)
    o32 lgdt [TRAMP_BASE + (tramp_gdtr - ap_trampoline_start)]

    ; Enable Protected Mode (CR0.PE = 1)
    mov     eax, cr0
    or      eax, 1
    mov     cr0, eax

    ; Far jump to 32-bit Protected Mode (selector 0x18 = 32-bit code)
    jmp     dword 0x18:(TRAMP_BASE + (ap_pm32 - ap_trampoline_start))

align 4
bits 32
ap_pm32:
    mov     ax, 0x20                    ; 32-bit data selector
    mov     ds, ax
    mov     es, ax
    mov     ss, ax

    ; Load BSP's 4-level PML4 page table
    mov     eax, [TRAMP_PML4]
    mov     cr3, eax

    ; Enable PAE (CR4.PAE = bit 5)
    mov     eax, cr4
    or      eax, (1 << 5)
    mov     cr4, eax

    ; Enable Long Mode (IA32_EFER.LME = bit 8)
    mov     ecx, 0xC0000080
    rdmsr
    or      eax, (1 << 8)
    wrmsr

    ; Enable Paging (CR0.PG = bit 31)
    mov     eax, cr0
    or      eax, 0x80000000
    mov     cr0, eax

    ; Far jump to 64-bit Long Mode (selector 0x08 = 64-bit code, matching gdt64!)
    jmp     0x08:(TRAMP_BASE + (ap_lm64 - ap_trampoline_start))

align 8
bits 64
ap_lm64:
    mov     ax, 0x10                    ; 64-bit data selector (matching gdt64!)
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     fs, ax
    mov     gs, ax

    mov     eax, TRAMP_ENTRY64          ; zero-extended to 64-bit 0x8F88
    mov     rax, [rax]                  ; load 64-bit ap_entry64
    jmp     rax

align 8
tramp_gdt:
    dq 0x0000000000000000               ; 0x00: Null
    dq 0x00AF9A000000FFFF               ; 0x08: 64-bit Code (L=1)
    dq 0x00CF92000000FFFF               ; 0x10: 64-bit Data
    dq 0x00CF9A000000FFFF               ; 0x18: 32-bit Code (D=1)
    dq 0x00CF92000000FFFF               ; 0x20: 32-bit Data
tramp_gdt_end:

tramp_gdtr:
    dw tramp_gdt_end - tramp_gdt - 1
    dd TRAMP_BASE + (tramp_gdt - ap_trampoline_start)
ap_trampoline_end:

; Restore default rel for any trailing code
bits 64
default rel

; ============================================================================
; SMP state
; ============================================================================
section .bss
alignb 64
g_smp_apic_base:   resq 1
g_smp_total_cpus:  resd 1
g_smp_online_cpus: resd 1
smp_next_tid:      resd 1
n_ap_ids:          resd 1
bsp_apic_id:       resb 1
ap_apic_ids:       resb OS_MAX_CPUS
ap_started:        resb 256

alignb 64
ap_stacks:         resb OS_MAX_CPUS * AP_STACK_SIZE
