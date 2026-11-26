; Read-only PCI discovery through x86 PCI configuration mechanism 1.
bits 64
default rel

%define PCI_CONFIG_ADDRESS 0xCF8
%define PCI_CONFIG_DATA    0xCFC
%define PCI_CONFIG_ENABLE  (1 << 31)
%define PCI_BUS_COUNT      256
%define PCI_SLOT_COUNT     32
%define PCI_FUNCTION_COUNT 8
%define PCI_VENDOR_DEVICE  0
%define PCI_CLASS_REVISION 8
%define PCI_HEADER_DWORD   12
%define PCI_MULTIFUNCTION  (1 << 23) ; Header type byte, bit 7
%define PCI_NO_VENDOR      0xFFFF

extern console_write
extern console_write_cstr
extern format_hex_raw
extern str_eq

section .text
global command_lspci
global pci_walk
global pci_config_read32
global pci_config_write16

command_lspci:
    push    0                          ; Listed device flag
    xor     r8d, r8d
    cmp     byte [rdi], 0
    je      .walk
    lea     rsi, [rel pci_all_option]
    call    str_eq
    test    eax, eax
    jz      .usage
    mov     r8d, 1
.walk:
    lea     rdi, [rel pci_list_entry]
    mov     rsi, rsp
    mov     edx, r8d
    call    pci_walk
    test    eax, eax
    js      .unavailable
    cmp     qword [rsp], 0
    jne     .done
    lea     rdi, [rel pci_heading]
    call    console_write_cstr
    lea     rdi, [rel pci_empty]
    jmp     .message
.unavailable:
    lea     rdi, [rel pci_unavailable]
    jmp     .message
.usage:
    lea     rdi, [rel pci_usage]
.message:
    call    console_write_cstr
.done:
    add     rsp, 8
    ret

; rdi = visitor, rsi = context, edx != 0 for exhaustive scan.
; Visitor receives edi = packed BDF, esi = vendor/device, rdx = context.
; A nonzero visitor result stops the walk. Return 1 on stop, 0 on
; completion, or -1 if configuration access is unavailable.
pci_walk:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, rdi
    mov     rbp, rsi
    mov     r14d, edx

    mov     dx, PCI_CONFIG_ADDRESS
    in      eax, dx
    mov     r15d, eax
    mov     eax, PCI_CONFIG_ENABLE
    out     dx, eax
    in      eax, dx
    cmp     eax, PCI_CONFIG_ENABLE
    jne     .unavailable

    xor     r12d, r12d
.slot:
    mov     r13d, r12d
    call    .visit_function
    test    eax, eax
    jg      .stopped
    test    r14d, r14d
    jnz     .next_function
    test    eax, eax
    js      .next_slot
    mov     edi, r12d
    mov     esi, PCI_HEADER_DWORD
    call    pci_read_config32
    test    eax, PCI_MULTIFUNCTION
    jz      .next_slot
.next_function:
    inc     r13d
    test    r13d, PCI_FUNCTION_COUNT - 1
    jz      .next_slot
    call    .visit_function
    test    eax, eax
    jle     .next_function
    jmp     .stopped
.next_slot:
    add     r12d, PCI_FUNCTION_COUNT
    cmp     r12d, PCI_BUS_COUNT * PCI_SLOT_COUNT * PCI_FUNCTION_COUNT
    jb      .slot
    xor     eax, eax
    jmp     .restore
.stopped:
    mov     eax, 1
    jmp     .restore
.unavailable:
    mov     eax, -1
.restore:
    mov     ecx, eax
    mov     dx, PCI_CONFIG_ADDRESS
    mov     eax, r15d
    out     dx, eax
    mov     eax, ecx
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

.visit_function:
    sub     rsp, 8
    mov     edi, r13d
    mov     esi, PCI_VENDOR_DEVICE
    call    pci_read_config32
    cmp     ax, PCI_NO_VENDOR
    je      .absent
    mov     edi, r13d
    mov     esi, eax
    mov     rdx, rbp
    call    rbx
    test    eax, eax
    setnz   al
    movzx   eax, al
    jmp     .visited
.absent:
    mov     eax, -1
.visited:
    add     rsp, 8
    ret

pci_list_entry:
    cmp     qword [rdx], 0
    jne     .entry
    mov     qword [rdx], 1
    push    rdi
    push    rsi
    sub     rsp, 8
    lea     rdi, [rel pci_heading]
    call    console_write_cstr
    add     rsp, 8
    pop     rsi
    pop     rdi
.entry:
    sub     rsp, 8
    call    pci_print_entry
    add     rsp, 8
    xor     eax, eax
    ret

; edi = (bus << 8) | (slot << 3) | function, esi = aligned offset.
; Public accesses restore the selector. Raw reads are used inside pci_walk.
pci_config_read32:
    mov     dx, PCI_CONFIG_ADDRESS
    in      eax, dx
    push    rax
    call    pci_read_config32
    mov     ecx, eax
    pop     rax
    mov     dx, PCI_CONFIG_ADDRESS
    out     dx, eax
    mov     eax, ecx
    ret

; edi = packed BDF, esi = word offset, edx = value.
pci_config_write16:
    mov     r8d, edx
    mov     dx, PCI_CONFIG_ADDRESS
    in      eax, dx
    mov     r9d, eax
    mov     eax, edi
    shl     eax, 8
    or      eax, esi
    and     eax, -4
    or      eax, PCI_CONFIG_ENABLE
    out     dx, eax
    and     esi, 2
    lea     edx, [rsi + PCI_CONFIG_DATA]
    mov     eax, r8d
    out     dx, ax
    mov     dx, PCI_CONFIG_ADDRESS
    mov     eax, r9d
    out     dx, eax
    ret

pci_read_config32:
    mov     eax, edi
    shl     eax, 8
    or      eax, esi
    or      eax, PCI_CONFIG_ENABLE
    mov     dx, PCI_CONFIG_ADDRESS
    out     dx, eax
    mov     dx, PCI_CONFIG_DATA
    in      eax, dx
    ret

; edi = packed PCI address, esi = vendor and device dword.
pci_print_entry:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     r12d, edi
    mov     r13d, esi
    mov     esi, PCI_CLASS_REVISION
    call    pci_read_config32
    mov     ebx, eax
    shr     ebx, 8                      ; Class, subclass, programming interface

    lea     rsi, [rel pci_entry]
    mov     rdi, rsp
    mov     ecx, pci_entry_len
    rep     movsb
    mov     edi, r12d
    shr     edi, 8
    mov     esi, 2
    mov     rdx, rsp
    call    format_hex_raw
    mov     edi, r12d
    shr     edi, 3
    and     edi, PCI_SLOT_COUNT - 1
    mov     esi, 2
    lea     rdx, [rsp + pci_entry.device - pci_entry]
    call    format_hex_raw
    mov     edi, r12d
    and     edi, PCI_FUNCTION_COUNT - 1
    mov     esi, 1
    lea     rdx, [rsp + pci_entry.function - pci_entry]
    call    format_hex_raw
    movzx   edi, r13w
    mov     esi, 4
    lea     rdx, [rsp + pci_entry.vendor - pci_entry]
    call    format_hex_raw
    mov     edi, r13d
    shr     edi, 16
    mov     esi, 4
    lea     rdx, [rsp + pci_entry.device_id - pci_entry]
    call    format_hex_raw
    mov     edi, ebx
    mov     esi, 6
    lea     rdx, [rsp + pci_entry.class - pci_entry]
    call    format_hex_raw
    mov     rdi, rsp
    mov     esi, pci_entry_len
    call    console_write
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

section .rodata
pci_all_option:  db "--all", 0
pci_usage:       db "Usage: lspci [--all]", 10, 0
pci_heading:     db "Address  Vendor:ID  Class", 10, 0
pci_empty:       db "No PCI devices found.", 10, 0
pci_unavailable: db "PCI configuration access unavailable.", 10, 0
pci_entry:       db "00:"
.device:         db "00."
.function:       db "0  "
.vendor:         db "0000:"
.device_id:      db "0000  "
.class:          db "000000", 10
pci_entry_len equ $ - pci_entry
