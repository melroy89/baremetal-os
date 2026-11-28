; BIOS ACPI tables and fixed power-button events on QEMU PC machines.
bits 64
default rel

%include "os_constants.inc"

%define ACPI_TABLE_LIMIT 0xF0000000
%define SDT_HEADER 36
%define FADT_MIN 116
%define ACPI_SCI_IRQ 9
%define ACPI_SCI_MASK (1 << (ACPI_SCI_IRQ - 8))
%define ELCR_SLAVE 0x4d1
%define POWER_BUTTON (1 << 8)

extern timer_ns
global acpi_find_table, acpi_power_init, acpi_power_irq
global acpi_power_poll, acpi_power_take

section .text

; edi = SDT signature. Return a checksummed table or zero.
acpi_find_table:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     ebx, edi
    movzx   edi, word [abs 0x40e]
    shl     edi, 4
    cmp     edi, 0x80000
    jb      .bios
    cmp     edi, 0xa0000
    jae     .bios
    mov     esi, 1024
    call    find_rsdp_in_range
    test    rax, rax
    jnz     .found
.bios:
    mov     edi, 0xe0000
    mov     esi, 0x20000
    call    find_rsdp_in_range
    test    rax, rax
    jz      .done
.found:
    mov     r12, rax
    cmp     rax, 0x100000 - 36
    ja      .rsdt
    cmp     byte [rax + 15], 2
    jb      .rsdt
    cmp     dword [rax + 20], 36
    jne     .rsdt
    mov     rdi, rax
    mov     ecx, 36
    call    acpi_checksum
    jnz     .rsdt
    mov     rdi, [r12 + 24]
    mov     edx, 'XSDT'
    mov     r14d, 8
    call    .walk
    test    rax, rax
    jnz     .done
.rsdt:
    mov     edi, [r12 + 16]
    mov     edx, 'RSDT'
    mov     r14d, 4
    call    .walk
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.walk:
    call    acpi_validate_sdt
    jc      .missing
    lea     r8, [rdi + rcx]
    lea     r13, [rdi + SDT_HEADER]
    sub     ecx, SDT_HEADER
    lea     eax, [r14 - 1]
    test    ecx, eax
    jnz     .missing
.entry:
    cmp     r13, r8
    jae     .missing
    mov     edi, [r13]
    cmp     r14d, 4
    je      .validate
    mov     rdi, [r13]
.validate:
    mov     edx, ebx
    call    acpi_validate_sdt
    jnc     .match
    add     r13, r14
    jmp     .entry
.match:
    mov     rax, rdi
    ret
.missing:
    xor     eax, eax
    ret

; rdi = table, edx = expected signature. Return length in ecx, CF on failure.
acpi_validate_sdt:
    test    rdi, rdi
    jz      .bad
    mov     eax, ACPI_TABLE_LIMIT - SDT_HEADER
    cmp     rdi, rax
    ja      .bad
    cmp     [rdi], edx
    jne     .bad
    mov     ecx, [rdi + 4]
    cmp     ecx, SDT_HEADER
    jb      .bad
    cmp     ecx, 65536
    ja      .bad
    lea     rax, [rdi + rcx]
    mov     edx, ACPI_TABLE_LIMIT
    cmp     rax, rdx
    ja      .bad
    push    rcx
    call    acpi_checksum
    pop     rcx
    jnz     .bad
    clc
    ret
.bad:
    stc
    ret

acpi_checksum:
    xor     eax, eax
.next:
    add     al, [rdi + rcx - 1]
    dec     ecx
    jnz     .next
    test    al, al
    ret

; Internal: find_rsdp_in_range(uint64 start in rdi, uint64 len in rsi) -> rax or 0
find_rsdp_in_range:
    mov     r8, 0x2052545020445352      ; "RSD PTR " little-endian
    lea     r9, [rdi + rsi]
.lp:
    lea     rax, [rdi + 20]
    cmp     rax, r9
    ja     .none
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

; The PIC has already been remapped. Support the PC fixed-hardware layout
; with one 16-bit PM1 status and enable pair and the legacy SCI IRQ.
acpi_power_init:
    push    rbx
    push    r12
    mov     edi, 'FACP'
    call    acpi_find_table
    test    rax, rax
    jz      .done
    mov     rbx, rax
    cmp     dword [rbx + 4], FADT_MIN
    jb      .done
    cmp     word [rbx + 46], ACPI_SCI_IRQ
    jne     .done
    test    dword [rbx + 112], (1 << 4) | (1 << 20) ; Control-method button or HW-reduced.
    jnz     .done
    cmp     byte [rbx + 88], 4
    jne     .done
    cmp     byte [rbx + 89], 2
    jb      .done
    mov     eax, [rbx + 56]
    test    eax, eax
    jz      .done
    cmp     eax, 0xfffc
    ja      .done
    cmp     dword [rbx + 60], 0        ; No second PM1 event block.
    jne     .done
    mov     r12d, eax
    mov     edx, [rbx + 64]
    test    edx, edx
    jz      .done
    cmp     edx, 0xfffe
    ja      .done
    mov     [rel acpi_control_port], dx
    in      ax, dx
    test    al, 1                      ; SCI_EN
    jnz     .enable
    mov     edx, [rbx + 48]
    test    edx, edx
    jz      .done
    cmp     edx, 0xffff
    ja      .done
    mov     al, [rbx + 52]
    test    al, al
    jz      .done
    out     dx, al
    call    timer_ns
    lea     rbx, [rax + 100000000]
.wait:
    call    timer_ns
    cmp     rax, rbx
    jae     .done
    mov     dx, [rel acpi_control_port]
    in      ax, dx
    test    al, 1
    jz      .wait
.enable:
    mov     [rel acpi_event_port], r12w
    mov     edx, r12d
    mov     ax, POWER_BUTTON
    out     dx, ax                      ; Discard stale power-button status.
    add     edx, 2
    out     dx, ax                      ; Enable only the fixed power button.
    mov     dx, ELCR_SLAVE
    in      al, dx
    or      al, ACPI_SCI_MASK
    out     dx, al
    in      al, PIC_SLAVE_DATA
    and     al, ~ACPI_SCI_MASK
    out     PIC_SLAVE_DATA, al
    in      al, PIC_MASTER_DATA
    and     al, ~(1 << 2)
    out     PIC_MASTER_DATA, al
.done:
    pop     r12
    pop     rbx
    ret

acpi_power_irq:
    push    rax
    push    rdx
    call    acpi_power_claim
    jc      .eoi
    ; An unhandled level assertion must not trap the BSP in the handler.
    in      al, PIC_SLAVE_DATA
    or      al, ACPI_SCI_MASK
    out     PIC_SLAVE_DATA, al
.eoi:
    mov     al, PIC_EOI
    out     PIC_SLAVE_CMD, al
    out     PIC_MASTER_CMD, al
    pop     rdx
    pop     rax
    iretq

; Latch a sticky power-button event, including when commands held IF clear.
acpi_power_poll:
    call    acpi_power_claim
    movzx   eax, byte [rel acpi_power_pending]
    ret

; Return CF only when this call acknowledged the power button.
acpi_power_claim:
    movzx   edx, word [rel acpi_event_port]
    test    edx, edx
    jz      .unclaimed
    in      ax, dx
    test    ax, POWER_BUTTON
    jz      .unclaimed
    mov     ax, POWER_BUTTON
    out     dx, ax
    mov     byte [rel acpi_power_pending], 1
    stc
    ret
.unclaimed:
    clc
    ret

acpi_power_take:
    call    acpi_power_poll
    mov     byte [rel acpi_power_pending], 0
    ret

section .bss
alignb 2
acpi_control_port: resw 1
acpi_event_port: resw 1
acpi_power_pending: resb 1
