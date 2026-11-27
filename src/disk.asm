; Console entry point for the block device.
bits 64
default rel

%include "os_constants.inc"

extern block_init
extern block_read
extern block_capacity, block_selected
extern block_model
extern command_gpt
extern disk_check_volume
extern disk_repair_volume
extern crc32_buffer
extern console_write_cstr
extern console_putc
extern str_eq
extern write_u64
extern write_hex32_raw

section .text
global command_disk
global parse_lba

command_disk:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, rdi
.token:
    cmp     byte [r13], 0
    je      .lookup
    cmp     byte [r13], ' '
    je      .split
    inc     r13
    jmp     .token
.split:
    mov     byte [r13], 0
.skip_space:
    inc     r13
    cmp     byte [r13], ' '
    je      .skip_space
.lookup:
    lea     rbx, [rel operations]
.next:
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .usage
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     .found
    add     rbx, 24
    jmp     .next
.found:
    cmp     qword [rbx + 16], 2        ; Volume operations take a mount path.
    je      .dispatch
    cmp     dword [r13], 'disk'
    jne     .implicit
    movzx   eax, byte [r13 + 4]
    sub     eax, '0'
    cmp     eax, 1
    ja      .usage
    mov     [rel block_selected], eax
    add     r13, 5
    cmp     byte [r13], 0
    je      .arguments
    cmp     byte [r13], ' '
    jne     .usage
.disk_space:
    inc     r13
    cmp     byte [r13], ' '
    je      .disk_space
    jmp     .arguments
.implicit:
    mov     dword [rel block_selected], -1
.arguments:
    xor     eax, eax
    cmp     byte [r13], 0
    setne   al
    cmp     rax, [rbx + 16]
    jne     .usage
.dispatch:
    mov     rax, [rbx + 8]
    mov     rdi, r13
    pop     r13
    pop     r12
    pop     rbx
    jmp     rax
.usage:
    lea     rdi, [rel disk_usage]
    pop     r13
    pop     r12
    pop     rbx
    jmp     console_write_cstr

disk_crc:
    push    rbx
    call    parse_lba
    jc      disk_bad_lba
    mov     rbx, rax
    call    block_init
    test    rax, rax
    jnz     disk_error
    mov     rdi, rbx
    lea     rsi, [rel disk_buffer]
    call    block_read
    test    rax, rax
    jnz     disk_error
    lea     rdi, [rel disk_buffer]
    mov     esi, BLOCK_SIZE
    call    crc32_buffer
    mov     edi, eax
    call    write_hex32_raw
    jmp     disk_newline

disk_info:
    push    rbx
    call    block_init
    test    rax, rax
    jnz     disk_error
    lea     rdi, [rel model_label]
    cmp     dword [rel block_selected], 0
    je      .label
    lea     rdi, [rel virtio_label]
.label:
    call    console_write_cstr
    call    block_model
    mov     rdi, rax
    call    console_write_cstr
    lea     rdi, [rel geometry_label]
    call    console_write_cstr
    call    block_capacity
    mov     rdi, rax
    call    write_u64
disk_newline:
    mov     edi, 10
    pop     rbx
    jmp     console_putc

disk_bad_lba:
    lea     rax, [rel invalid_lba]
disk_error:
    mov     rdi, rax
    pop     rbx
    jmp     console_write_cstr

; Return unsigned decimal LBA in rax. CF marks empty, invalid or overflow.
parse_lba:
    cmp     byte [rdi], 0
    je      .bad
    xor     eax, eax
    mov     r8d, 10
.next:
    movzx   ecx, byte [rdi]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      .bad
    mul     r8
    test    rdx, rdx
    jnz     .bad
    add     rax, rcx
    jc      .bad
    inc     rdi
    cmp     byte [rdi], 0
    jne     .next
    clc
    ret
.bad:
    stc
    ret

section .rodata
info_name:      db "info", 0
crc_name:       db "crc32", 0
gpt_name:       db "gpt", 0
check_name:     db "check", 0
repair_name:    db "repair", 0
disk_usage:     db "Usage: disk info [diskN] | crc32 [diskN] LBA | gpt [diskN] | check [PATH] | repair [PATH]", 10, 0
invalid_lba:    db "Invalid decimal LBA.", 10, 0

align 8
operations:
    dq info_name, disk_info, 0
    dq crc_name, disk_crc, 1
    dq gpt_name, command_gpt, 0
    dq check_name, disk_check_volume, 2
    dq repair_name, disk_repair_volume, 2
    dq 0
virtio_label:   db "Virtio disk: ", 0
model_label:    db "ATA disk: ", 0
geometry_label: db 10, "Logical sector size: 512 bytes", 10, "Sectors: ", 0

section .bss
alignb 16
disk_buffer: resb BLOCK_SIZE
