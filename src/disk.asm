; Console entry point for the block device.
bits 64
default rel

%include "os_constants.inc"
%include "volume.inc"

extern block_init
extern block_read
extern block_capacity, block_selected
extern block_model
extern command_gpt, gpt_load_initialized, gpt_partition
extern fat_geometry, ext_geometry
extern disk_check_volume
extern disk_repair_volume
extern crc32_buffer
extern console_write, console_write_cstr
extern console_putc
extern str_eq
extern write_u64, format_u64
extern console_cancel_check
extern write_hex32_raw

section .text
global command_disk
global parse_lba, disk_probe, disk_probe_labels, disk_visit_partitions

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
    cmp     qword [rbx + 16], 3        ; Listing takes no device or arguments.
    jne     .volume
    cmp     byte [r13], 0
    je      .dispatch
    jmp     .usage
.volume:
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

; rdi = first LBA, rsi = last LBA. The selected device is initialized.
; Return FS_* without changing the selector or publishing a mount.
disk_probe:
    push    rbp
    push    rbx
    lea     rbp, [rel probe_volume]
    mov     [rbp + mount_volume.volume_base], rdi
    mov     [rbp + mount_volume.partition_last], rsi
    call    fat_geometry
    jc      .unreadable
    mov     rbx, rax
    call    ext_geometry
    jc      .unreadable
    test    rbx, rbx
    jnz     .not_fat
    test    rax, rax
    mov     eax, FS_AMBIGUOUS
    jz      .done
    mov     eax, FS_FAT32
    jmp     .done
.not_fat:
    test    rax, rax
    mov     eax, FS_UNKNOWN
    mov     ebx, FS_EXT2
    cmovz   eax, ebx
    jmp     .done
.unreadable:
    mov     eax, FS_UNREADABLE
.done:
    pop     rbx
    pop     rbp
    ret

disk_list:
    xor     edi, edi
; rdi = optional partition-name visitor. Both modes use the same GPT walk.
disk_visit_partitions:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     [rsp], rdi
    mov     r14d, [rel block_selected]
    xor     r12d, r12d
    xor     r15d, r15d
.device:
    cmp     qword [rsp], 0
    je      .init
    call    console_cancel_check
    test    rax, rax
    jnz     .restore
.init:
    mov     [rel block_selected], r12d
    call    block_init
    test    rax, rax
    jnz     .next_device
    inc     r15d
    cmp     qword [rsp], 0
    jne     .load_gpt
    call    .device_name
    lea     rdi, [rel ata_text]
    test    r12d, r12d
    jz      .heading
    lea     rdi, [rel virtio_text]
.heading:
    call    console_write_cstr
.load_gpt:
    call    gpt_load_initialized
    test    rax, rax
    jnz     .gpt_error
    mov     r13d, 1
    xor     ebx, ebx
.partition:
    mov     edi, r13d
    call    gpt_partition
    test    rax, rax
    jz      .advance
    cmp     qword [rsp], 0
    jne     .visit
    mov     rdi, rax
    mov     rsi, rdx
    call    disk_probe
    mov     [rsp + 8], eax
    call    .indent
    call    .partition_name
    call    console_write
    mov     eax, [rsp + 8]
    lea     rdi, [rel list_labels]
    mov     rdi, [rdi + rax * 8]
    call    console_write_cstr
    inc     ebx
    jmp     .advance
.visit:
    call    .partition_name
    xor     edx, edx
    call    [rsp]
    test    rax, rax
    jnz     .restore
.advance:
    inc     r13d
    cmp     r13d, GPT_MAX_ENTRIES
    jbe     .partition
    cmp     qword [rsp], 0
    jne     .next_device
    test    ebx, ebx
    jnz     .next_device
    lea     rax, [rel empty_gpt]
.gpt_error:
    cmp     qword [rsp], 0
    jne     .next_device
    mov     rbx, rax
    call    .indent
    mov     rdi, rbx
    call    console_write_cstr
.next_device:
    inc     r12d
    cmp     r12d, 1
    jbe     .device
    cmp     qword [rsp], 0
    jne     .done
    test    r15d, r15d
    jnz     .done
    lea     rdi, [rel no_disks]
    call    console_write_cstr
.done:
    xor     eax, eax
.restore:
    mov     [rel block_selected], r14d
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.device_name:
    lea     rdi, [rel disk_name]
    call    console_write_cstr
    mov     edi, r12d
    jmp     write_u64
.indent:
    lea     rdi, [rel list_indent]
    jmp     console_write_cstr

.partition_name:
    lea     rsi, [rsp + 32]             ; End of the digit buffer in the caller's frame.
    mov     edi, r13d
    call    format_u64
    lea     rdi, [rsi - 6]
    mov     dword [rdi], 'disk'
    lea     eax, [r12 + '0']
    mov     [rdi + 4], al
    mov     byte [rdi + 5], 'p'
    lea     esi, [rdx + 6]
    ret

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
disk_name:      db "disk", 0
list_name:      db "list", 0
list_indent:    db "    ", 0
ata_text:       db "  ATA", 10, 0
virtio_text:    db "  Virtio", 10, 0
empty_gpt:      db "GPT contains no partitions.", 10, 0
no_disks:       db "No usable disks.", 10, 0
info_name:      db "info", 0
crc_name:       db "crc32", 0
gpt_name:       db "gpt", 0
check_name:     db "check", 0
repair_name:    db "repair", 0
disk_usage:     db "Usage: disk info [diskN] | crc32 [diskN] LBA | gpt [diskN] | check [PATH] | repair [PATH] | list", 10, 0
invalid_lba:    db "Invalid decimal LBA.", 10, 0

align 8
operations:
    dq list_name, disk_list, 3
    dq info_name, disk_info, 0
    dq crc_name, disk_crc, 1
    dq gpt_name, command_gpt, 0
    dq check_name, disk_check_volume, 2
    dq repair_name, disk_repair_volume, 2
    dq 0
virtio_label:   db "Virtio disk: ", 0
model_label:    db "ATA disk: ", 0
geometry_label: db 10, "Logical sector size: 512 bytes", 10, "Sectors: ", 0

align 8
disk_probe_labels:
    dq fat_label + 2, ext_label + 2, unknown_label + 2, ambiguous_label + 2, unreadable_label + 2
list_labels:
    dq fat_label, ext_label, unknown_label, ambiguous_label, unreadable_label
fat_label:        db "  FAT32", 10, 0
ext_label:        db "  Ext2", 10, 0
unknown_label:    db "  unknown", 10, 0
ambiguous_label:  db "  ambiguous", 10, 0
unreadable_label: db "  unreadable", 10, 0

section .bss
alignb 16
disk_buffer: resb BLOCK_SIZE

alignb 8
probe_volume: resb mount_volume_size
