; Discover processors through ACPI and bring application processors into long mode.

bits 64
default rel

%include "os_constants.inc"

%define APIC_ID_COUNT 256
%define APIC_SVR_ENABLE (1 << 8)
%define PING_TIMEOUT_NS 100000000
%define PING_WAITING 1
%define PING_DRAINING 2
%define PING_IRR_REG (APIC_REG_IRR_BASE + (APIC_PING_VECTOR / 32) * 16)
%define PING_IRR_BIT (1 << (APIC_PING_VECTOR % 32))
%define CRC_TIMEOUT_NS 100000000
%define CRC_RUNNING 1
%define CRC_DONE 2
%define CRC_POSTED_BASE 256

extern pml4_table
extern gdt64_ptr
extern idt64_ptr
extern pit_delay_us
extern timer_ns
extern _kernel_end
extern page_init
extern page_alloc
extern pages_free
extern console_putc
extern console_write_cstr
extern write_u64
extern apic_wait_icr
extern apic_send_ipi
extern crc32_buffer, crc32_foreground
extern ip_checkpoint_at, acpi_find_table

section .text

global smp_init
global g_smp_total_cpus
global g_smp_online_cpus
global smp_stack_pages
global command_cpu_ping
global smp_ping_irq
global smp_ping_drain_irq
global smp_crc32
global smp_crc_irq

; rdi = Multiboot info.
smp_init:
    push    rbx
    push    rbp
    push    r13
    push    r14
    push    r15

    mov     r14, rdi
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
    or      eax, APIC_SVR_ENABLE | APIC_SPURIOUS_VECTOR
    mov     [r13 + APIC_REG_SVR], eax

    ; Read BSP Local APIC ID
    mov     eax, [r13 + APIC_REG_ID]
    shr     eax, 24
    mov     [rel bsp_apic_id], al
    movzx   rcx, al
    lea     rdx, [rel ap_started]
    mov     byte [rdx + rcx], 1

    call    acpi_discover_madt

    test    eax, eax
    jz      .wake_broadcast

    ; With known targets, a valid map can make the unused fallback area
    ; available to the allocator.
    mov     rdi, r14
    lea     rsi, [rel fallback_ap_stacks]
    call    page_init
    mov     r15d, [rel n_ap_ids]
    test    r15d, r15d
    jz      .done
    cmp     r15, [rel pages_free]
    ja      .targeted_fallback
    mov     edi, r15d
    call    reserve_ap_stacks
    cmp     eax, r15d
    je      .start_targeted

.targeted_fallback:
    ; Reserve the full loader stack area before publishing any fallback
    ; stacks. Reinitialization also discards any partial allocation.
    mov     rdi, r14
    lea     rsi, [rel _kernel_end]
    call    page_init
    mov     edi, r15d
    call    use_fallback_ap_stacks

.start_targeted:
    call    install_trampoline

    ; Step 1: Send INIT IPI to all target APs
    xor     ebx, ebx
.init_lp:
    cmp     rbx, r15
    jae     .init_delay
    lea     rax, [rel ap_apic_ids]
    movzx   edi, byte [rax + rbx]
    mov     esi, 0x00004500             ; INIT, Level=Assert, Edge
    mov     rdx, r13
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
    mov     rdx, r13
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
    mov     rdx, r13
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
    ; The number of CPUs that may arrive is unknown. Keep the loader's
    ; stack reserve outside the allocator for the whole boot.
    mov     rdi, r14
    lea     rsi, [rel _kernel_end]
    call    page_init
    mov     byte [rel ap_broadcast], 1
    mov     edi, OS_MAX_CPUS - 1
    call    use_fallback_ap_stacks
    call    install_trampoline
    mov     dword [r13 + APIC_REG_ESR], 0
    mov     dword [r13 + APIC_REG_ICR_HI], 0
    mov     dword [r13 + APIC_REG_ICR_LO], 0x000C4500 ; All Excl Self, INIT Assert
    mov     rdx, r13
    call    apic_wait_icr

    mov     rdi, 10000
    call    pit_delay_us

    mov     dword [r13 + APIC_REG_ESR], 0
    mov     dword [r13 + APIC_REG_ICR_HI], 0
    mov     dword [r13 + APIC_REG_ICR_LO], 0x000C4600 | TRAMP_VECTOR
    mov     rdx, r13
    call    apic_wait_icr

    ; Wait 25 ms for APs to boot and check in
    mov     rdi, 25000
    call    pit_delay_us

.done:
    pop     r15
    pop     r14
    pop     r13
    pop     rbp
    pop     rbx
    ret

; Publish stacks before sending IPIs. Keep their pages even if a target
; is still starting when the boot CPU stops waiting.
reserve_ap_stacks:
    push    rbx
    push    r12
    push    r14
    mov     ebx, edi
    xor     r12d, r12d
    lea     r14, [rel ap_stack_tops]
.next:
    cmp     r12d, ebx
    jae     .ready
    call    page_alloc
    test    rax, rax
    jz      .ready
    add     rax, PAGE_SIZE
    mov     [r14 + r12 * 8], rax
    inc     r12d
    jmp     .next
.ready:
    mov     [rel ap_stack_count], r12d
    mov     eax, r12d
    pop     r14
    pop     r12
    pop     rbx
    ret

use_fallback_ap_stacks:
    mov     byte [rel ap_fallback_mode], 1
    mov     [rel ap_stack_count], edi
    ret

; On the fallback path, report stack pages in use rather than the size of
; the loader's reserve. Allocator-backed pages count as used once assigned.
smp_stack_pages:
    mov     eax, [rel ap_stack_count]
    cmp     byte [rel ap_fallback_mode], 0
    je      .done
    mov     eax, [rel g_smp_online_cpus]
    dec     eax
.done:
    ret

; rdi = data, rsi = byte length, edx != 0 for a writable file.
; Return CRC-32 in eax. The boot CPU can calculate locally if the worker
; is unavailable. It owns the slot and publishes all job data before posting.
smp_crc32:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13, rsi
    mov     r14d, edx
    mov     eax, [rel crc_job_state]
    test    eax, eax
    jz      .find_worker
    cmp     eax, CRC_DONE
    jne     .local
    mov     dword [rel crc_job_state], 0

.find_worker:
    xor     ebx, ebx
    lea     rax, [rel ap_started]
.next_worker:
    cmp     bl, [rel bsp_apic_id]
    je      .advance
    cmp     byte [rax + rbx], 0
    jne     .prepare
.advance:
    inc     ebx
    cmp     ebx, APIC_ID_COUNT
    jb      .next_worker
    jmp     .local

.prepare:
    ; The console can overwrite or remove a writable file after timeout.
    ; Keep a snapshot in the slot until the worker is done reading it.
    test    r14d, r14d
    jz      .publish
    cmp     r13, PAGE_SIZE
    ja      .local
    lea     rdi, [rel crc_job_snapshot]
    mov     rsi, r12
    mov     rcx, r13
    rep     movsb
    lea     rdi, [rel crc_job_snapshot]
.publish:
    mov     [rel crc_job_data], rdi
    mov     [rel crc_job_size], r13
    lea     r15d, [rbx + CRC_POSTED_BASE]
    mov     [rel crc_job_state], r15d

    mov     edi, ebx
    mov     esi, APIC_CRC_VECTOR
    mov     rdx, [rel g_smp_apic_base]
    call    apic_send_ipi
    cmp     eax, APIC_IPI_NOT_SENT
    je      .fallback
    call    timer_ns
    lea     r14, [rax + CRC_TIMEOUT_NS]
.wait:
    cmp     dword [rel crc_job_state], CRC_DONE
    je      .result
    call    timer_ns
    cmp     rax, r14
    jae     .fallback
    call    ip_checkpoint_at
    pause
    jmp     .wait

.fallback:
    ; Cancel an unclaimed job. A running job retains its slot and data
    ; until completion, even though the boot CPU returns its own result.
    mov     eax, r15d
    xor     edx, edx
    lock cmpxchg [rel crc_job_state], edx
    cmp     eax, CRC_DONE
    je      .result
.local:
    mov     rdi, r12
    mov     rsi, r13
    call    crc32_foreground
    jmp     .done
.result:
    mov     eax, [rel crc_job_result]
    mov     dword [rel crc_job_state], 0
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

smp_crc_irq:
    push    rax
    mov     rax, [rel g_smp_apic_base]
    mov     dword [rax + APIC_REG_EOI], 0
    pop     rax
    iretq

command_cpu_ping:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r13, [rel g_smp_apic_base]
    xor     ebx, ebx                   ; Local APIC ID
    xor     r12d, r12d                 ; Secondary CPUs tested
    xor     r14d, r14d                 ; Replies
.next:
    cmp     bl, [rel bsp_apic_id]
    je      .advance
    lea     rax, [rel ap_started]
    cmp     byte [rax + rbx], 0
    je      .advance
    inc     r12d
    mov     edi, ebx
    call    ping_ap
    mov     r15, rax
    test    r15, r15
    jnz     .report
    inc     r14d
    lea     r15, [rel ping_reply]
.report:
    lea     rdi, [rel ping_apic_label]
    call    console_write_cstr
    mov     edi, ebx
    call    write_u64
    mov     rdi, r15
    call    console_write_cstr
.advance:
    inc     ebx
    cmp     ebx, APIC_ID_COUNT
    jb      .next

    test    r12d, r12d
    jz      .no_targets
    lea     rdi, [rel ping_summary]
    call    console_write_cstr
    mov     edi, r14d
    call    write_u64
    mov     edi, '/'
    call    console_putc
    mov     edi, r12d
    call    write_u64
    mov     edi, 10
    call    console_putc
    jmp     .done
.no_targets:
    lea     rdi, [rel ping_no_targets]
    call    console_write_cstr
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; rdi = target APIC ID, r13 = BSP APIC base. Return zero for a reply
; or a status suffix for an unsuccessful request.
ping_ap:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edi
    lea     rbx, [rel ap_ping_pending]
    add     rbx, rdi

    ; Before retiring any previous ping, ensure its IPI is no longer in
    ; transit from this APIC.
    mov     rdx, r13
    call    apic_wait_icr
    test    eax, APIC_ICR_BUSY
    jnz     .busy
    cmp     byte [rbx], 0
    je      .send_ping

    ; The lower-priority interrupt runs after any queued ping. Either
    ; handler can retire the old request, but only a fresh ping can reply.
    mov     byte [rbx], PING_DRAINING
    mov     esi, APIC_DRAIN_VECTOR
    mov     rdx, r13
    call    apic_send_ipi
    cmp     eax, APIC_IPI_NOT_SENT
    je      .send_failed
    call    wait_ping_slot
    test    eax, eax
    jnz     .drain_timeout

.send_ping:
    mov     byte [rbx], PING_WAITING
    mov     edi, r12d
    mov     esi, APIC_PING_VECTOR
    mov     rdx, r13
    call    apic_send_ipi
    cmp     eax, APIC_IPI_NOT_SENT
    je      .reset
    call    wait_ping_slot
    test    eax, eax
    jz      .done
    lea     rax, [rel ping_timeout]
    jmp     .done
.reset:
    mov     byte [rbx], 0
.send_failed:
    lea     rax, [rel ping_send_failed]
    jmp     .done
.drain_timeout:
    lea     rax, [rel ping_drain_timeout]
    jmp     .done
.busy:
    lea     rax, [rel ping_busy]
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; rbx = per-CPU slot. Return zero when it is cleared or one on timeout.
wait_ping_slot:
    push    r12
    call    timer_ns
    lea     r12, [rax + PING_TIMEOUT_NS]
.wait:
    cmp     byte [rbx], 0
    je      .idle
    call    timer_ns
    cmp     rax, r12
    jae     .timeout
    pause
    jmp     .wait
.idle:
    xor     eax, eax
    pop     r12
    ret
.timeout:
    mov     eax, 1
    pop     r12
    ret

smp_ping_irq:
    push    rax
    push    rcx
    mov     rcx, [rel g_smp_apic_base]
    mov     dword [rcx + APIC_REG_EOI], 0
    mov     eax, [rcx + APIC_REG_ID]
    shr     eax, 24
    lea     rcx, [rel ap_ping_pending]
    mov     byte [rcx + rax], 0
    pop     rcx
    pop     rax
    iretq

smp_ping_drain_irq:
    push    rax
    push    rcx
    push    rdx
    mov     rdx, [rel g_smp_apic_base]
    mov     dword [rdx + APIC_REG_EOI], 0
    mov     eax, [rdx + APIC_REG_ID]
    shr     eax, 24
    lea     rcx, [rel ap_ping_pending]
    cmp     byte [rcx + rax], PING_DRAINING
    jne     .done
    ; A drain from a previous attempt could already be running when a new
    ; recovery begins. Leave retirement to the ping if it is still queued.
    test    dword [rdx + PING_IRR_REG], PING_IRR_BIT
    jnz     .done
    mov     byte [rcx + rax], 0
.done:
    pop     rdx
    pop     rcx
    pop     rax
    iretq

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

    mov     edi, 'APIC'
    call    acpi_find_table
    test    rax, rax
    jz      .not_found
    cmp     dword [rax + 4], 44
    jb      .not_found

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

; ============================================================================
; 64-bit Application Processor Entry (jumped to from 0x8000 trampoline)
; ============================================================================
ap_entry64:
    ; Claim a published stack before executing any stack instructions.
    mov     eax, 1
    lock xadd dword [rel ap_next_stack], eax
    cmp     eax, [rel ap_stack_count]
    jae     .ap_halt
    cmp     byte [rel ap_fallback_mode], 0
    jne     .fallback_stack
    lea     rdx, [rel ap_stack_tops]
    mov     rsp, [rdx + rax * 8]
    jmp     .stack_ready
.fallback_stack:
    shl     rax, PAGE_SHIFT
    lea     rsp, [rel fallback_ap_stacks + PAGE_SIZE]
    add     rsp, rax

.stack_ready:
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

    ; INIT reset leaves local sources masked. Enable the APIC for IPIs
    ; before announcing that this CPU can receive them.
    mov     rax, [rel g_smp_apic_base]
    mov     dword [rax + APIC_REG_SVR], APIC_SVR_ENABLE | APIC_SPURIOUS_VECTOR
    mov     eax, [rax + APIC_REG_ID]
    shr     eax, 24
    lea     r12d, [rax + CRC_POSTED_BASE]
    lea     rcx, [rel ap_started]
    mov     byte [rcx + rax], 1
    cmp     byte [rel ap_broadcast], 0
    je      .online
    lock inc dword [rel g_smp_total_cpus]
.online:
    lock inc dword [rel g_smp_online_cpus]

.ap_idle:
    cli
    ; The APIC ID is part of the expected state, so a delayed claim
    ; cannot take a job that was cancelled and posted to another AP.
    cmp     [rel crc_job_state], r12d
    jne     .ap_sleep
    mov     eax, r12d
    mov     ecx, CRC_RUNNING
    lock cmpxchg [rel crc_job_state], ecx
    jne     .ap_sleep
    sti
    mov     rdi, [rel crc_job_data]
    mov     rsi, [rel crc_job_size]
    call    crc32_buffer
    mov     [rel crc_job_result], eax
    mov     dword [rel crc_job_state], CRC_DONE
    jmp     .ap_idle
.ap_sleep:
    sti
    hlt
    jmp     .ap_idle

.ap_halt:
    cli
    hlt
    jmp     .ap_halt

; ============================================================================
; Position-Independent 16-bit -> 32-bit -> 64-bit AP Trampoline (copied to 0x8000)
; ZERO relocations inside this block — all offsets evaluated at assembly time!
; ============================================================================
section .rodata
ping_apic_label:    db "APIC ID ", 0
ping_reply:         db ": replied", 10, 0
ping_timeout:       db ": timed out", 10, 0
ping_drain_timeout: db ": timed out waiting to retry", 10, 0
ping_send_failed:   db ": IPI send failed", 10, 0
ping_busy:          db ": IPI controller busy", 10, 0
ping_summary:       db "Secondary CPUs replied: ", 0
ping_no_targets:    db "No online secondary CPUs.", 10, 0

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
ap_next_stack:    resd 1
ap_stack_count:   resd 1
n_ap_ids:          resd 1
bsp_apic_id:       resb 1
ap_apic_ids:       resb OS_MAX_CPUS
ap_started:        resb APIC_ID_COUNT
ap_fallback_mode:  resb 1
ap_broadcast:      resb 1
ap_ping_pending:  resb APIC_ID_COUNT

alignb 8
ap_stack_tops:     resq OS_MAX_CPUS - 1
crc_job_data:      resq 1
crc_job_size:      resq 1
crc_job_state:     resd 1
crc_job_result:    resd 1
crc_job_snapshot:  resb PAGE_SIZE

section .ap_fallback nobits alloc noexec write align=4096
fallback_ap_stacks: resb (OS_MAX_CPUS - 1) * PAGE_SIZE
