; Multiboot memory reporting and integer output for the console.
bits 64
default rel

%include "os_constants.inc"

extern console_write
extern console_write_cstr
extern console_putc

section .text
global memory_usable_bytes
global memory_map_print
global memory_map_walk
global str_eq
global write_u64
global write_hex64_raw
global write_hex32_raw
global format_hex_raw

; Walk the Multiboot map and call the visitor for each entry.
; rdi = Multiboot info, rsi = visitor, rdx = visitor context.
; Returns 1 for a valid map, 0 if absent, or -1 for a malformed map.
memory_map_walk:
    test    dword [rdi + MBI_FLAGS], 1 << 6
    jz      .missing

    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r14, rsi
    mov     r15, rdx
    mov     r12d, [rdi + MBI_MMAP_ADDR]
    mov     r13d, [rdi + MBI_MMAP_LENGTH]
    test    r12, r12
    jz      .malformed
    test    r13, r13
    jz      .malformed
    add     r13, r12
    mov     rax, PHYS_MAP_END
    cmp     r13, rax
    ja      .malformed

.next:
    lea     rax, [r12 + 24]
    cmp     rax, r13
    ja      .malformed
    mov     eax, [r12]
    cmp     eax, 20
    jb      .malformed
    lea     rbx, [r12 + rax + 4]
    cmp     rbx, r13
    ja      .malformed
    mov     rax, [r12 + 4]
    add     rax, [r12 + 12]
    jc      .malformed

    mov     rdi, r12
    mov     rsi, r15
    call    r14
    mov     r12, rbx
    cmp     r12, r13
    jb      .next
    mov     eax, 1
    jmp     .done

.malformed:
    mov     eax, -1
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.missing:
    xor     eax, eax
    ret

memory_usable_bytes:
    push    rbx
    sub     rsp, 16
    mov     rbx, rdi
    mov     qword [rsp], 0
    lea     rsi, [rel sum_usable_entry]
    mov     rdx, rsp
    call    memory_map_walk
    cmp     eax, 1
    jne     .basic_memory
    mov     rax, [rsp]
    jmp     .done
.basic_memory:
    xor     eax, eax
    test    dword [rbx + MBI_FLAGS], 1
    jz      .done
    mov     eax, [rbx + MBI_MEM_UPPER]
    mov     edx, [rbx + MBI_MEM_LOWER]
    add     rax, rdx
    shl     rax, 10
.done:
    add     rsp, 16
    pop     rbx
    ret

sum_usable_entry:
    cmp     dword [rdi + 20], 1
    jne     .done
    mov     rax, [rdi + 12]
    add     [rsi], rax
.done:
    ret

memory_map_print:
    push    rbx
    mov     rbx, rdi
    test    dword [rbx + MBI_FLAGS], 1 << 6
    jz      .missing
    lea     rdi, [rel map_header]
    call    console_write_cstr
    mov     rdi, rbx
    lea     rsi, [rel print_map_entry]
    xor     edx, edx
    call    memory_map_walk
    cmp     eax, 1
    je      .done
    lea     rdi, [rel map_malformed]
    pop     rbx
    jmp     console_write_cstr
.missing:
    lea     rdi, [rel map_missing]
    pop     rbx
    jmp     console_write_cstr
.done:
    pop     rbx
    ret

print_map_entry:
    push    rbx
    mov     rbx, rdi
    lea     rdi, [rel hex_prefix]
    call    console_write_cstr
    mov     rdi, [rbx + 4]
    call    write_hex64_raw
    lea     rdi, [rel map_length_prefix]
    call    console_write_cstr
    mov     rdi, [rbx + 12]
    call    write_hex64_raw
    lea     rdi, [rel map_type_separator]
    call    console_write_cstr

    mov     eax, [rbx + 20]
    dec     eax
    cmp     eax, 4
    ja      .unknown
    lea     rdx, [rel map_type_names]
    mov     rdi, [rdx + rax * 8]
    call    console_write_cstr
    jmp     .newline
.unknown:
    lea     rdi, [rel map_unknown]
    call    console_write_cstr
    mov     edi, [rbx + 20]
    call    write_u64
.newline:
    mov     edi, 10
    pop     rbx
    jmp     console_putc

str_eq:
.next:
    mov     al, [rdi]
    cmp     al, [rsi]
    jne     .different
    test    al, al
    jz      .equal
    inc     rdi
    inc     rsi
    jmp     .next
.different:
    xor     eax, eax
    ret
.equal:
    mov     eax, 1
    ret

; Print an unsigned integer in decimal.
write_u64:
    sub     rsp, 24
    lea     rsi, [rsp + 24]
    mov     rax, rdi
    mov     ecx, 10
.next:
    xor     edx, edx
    div     rcx
    add     dl, '0'
    dec     rsi
    mov     [rsi], dl
    test    rax, rax
    jnz     .next
    lea     rdx, [rsp + 24]
    sub     rdx, rsi
    mov     rdi, rsi
    mov     rsi, rdx
    call    console_write
    add     rsp, 24
    ret

; Print a fixed-width address or exception value.
write_hex64_raw:
    mov     esi, 16
    jmp     write_hex_raw

write_hex32_raw:
    mov     esi, 8

write_hex_raw:
    sub     rsp, 24
    mov     rdx, rsp
    call    format_hex_raw
    mov     rdi, rsp
    call    console_write
    add     rsp, 24
    ret

; rdi = value, esi = digit count (1..16), rdx = output buffer.
; Writes exactly that many digits and preserves rsi and rdx.
format_hex_raw:
    lea     r8, [rel hex_digits]
    mov     ecx, esi
.next:
    mov     eax, edi
    and     eax, 0x0F
    mov     al, [r8 + rax]
    mov     [rdx + rcx - 1], al
    shr     rdi, 4
    loop    .next
    ret

section .rodata
hex_digits: db "0123456789ABCDEF"

map_header:           db "Base                Length (bytes)      Type", 10, 0
hex_prefix:           db "0x", 0
map_length_prefix:    db "  0x", 0
map_type_separator:   db "  ", 0
map_missing:          db "Multiboot memory map unavailable.", 10, 0
map_malformed:        db "Malformed Multiboot memory map.", 10, 0
map_unknown:          db "Unknown type ", 0
map_usable:           db "Usable", 0
map_reserved:         db "Reserved", 0
map_acpi_reclaimable: db "ACPI reclaimable", 0
map_acpi_nvs:         db "ACPI NVS", 0
map_bad_memory:       db "Bad memory", 0

align 8
map_type_names: dq map_usable, map_reserved, map_acpi_reclaimable, map_acpi_nvs, map_bad_memory
