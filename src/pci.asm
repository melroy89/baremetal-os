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

command_lspci:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    xor     ebx, ebx                   ; Exhaustive scan requested
    cmp     byte [rdi], 0
    je      .start
    lea     rsi, [rel pci_all_option]
    call    str_eq
    test    eax, eax
    jz      .usage
    mov     ebx, 1
.start:
    ; Check the address register and restore its original value on exit.
    mov     dx, PCI_CONFIG_ADDRESS
    in      eax, dx
    mov     r15d, eax
    mov     eax, PCI_CONFIG_ENABLE
    out     dx, eax
    in      eax, dx
    cmp     eax, PCI_CONFIG_ENABLE
    jne     .unavailable

    lea     rdi, [rel pci_heading]
    call    console_write_cstr
    xor     r12d, r12d                 ; Bus and device, with function zero
    xor     r14d, r14d                 ; At least one function was found
.slot:
    mov     edi, r12d
    mov     esi, PCI_VENDOR_DEVICE
    call    pci_read_config32
    cmp     ax, PCI_NO_VENDOR
    je      .no_function_zero
    mov     r14d, 1
    mov     edi, r12d
    mov     esi, eax
    call    pci_print_entry

    test    ebx, ebx
    jnz     .scan_functions
    mov     edi, r12d
    mov     esi, PCI_HEADER_DWORD
    call    pci_read_config32
    test    eax, PCI_MULTIFUNCTION
    jz      .next_slot
    jmp     .scan_functions
.no_function_zero:
    test    ebx, ebx
    jz      .next_slot
.scan_functions:
    mov     r13d, r12d
.next_function:
    inc     r13d
    test    r13d, PCI_FUNCTION_COUNT - 1
    jz      .next_slot
    mov     edi, r13d
    mov     esi, PCI_VENDOR_DEVICE
    call    pci_read_config32
    cmp     ax, PCI_NO_VENDOR
    je      .next_function             ; Functions can be sparse.
    mov     r14d, 1
    mov     edi, r13d
    mov     esi, eax
    call    pci_print_entry
    jmp     .next_function

.next_slot:
    add     r12d, PCI_FUNCTION_COUNT
    cmp     r12d, PCI_BUS_COUNT * PCI_SLOT_COUNT * PCI_FUNCTION_COUNT
    jb      .slot
    test    r14d, r14d
    jnz     .restore
    lea     rdi, [rel pci_empty]
    jmp     .message
.unavailable:
    lea     rdi, [rel pci_unavailable]
.message:
    call    console_write_cstr
.restore:
    mov     dx, PCI_CONFIG_ADDRESS
    mov     eax, r15d
    out     dx, eax
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.usage:
    lea     rdi, [rel pci_usage]
    call    console_write_cstr
    jmp     .done

; edi = (bus << 8) | (device << 3) | function. esi = dword-aligned offset.
; Return the configuration dword in eax. The console is the only caller.
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
