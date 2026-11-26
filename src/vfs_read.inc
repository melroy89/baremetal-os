; Single foreground reader. FAT32 provides a sequential sector cursor;
; ext2 can start at any offset and shares its reader with cat and cp.
%ifndef EXT_RANGE_BUFFER
%define EXT_RANGE_BUFFER PAGE_SIZE
%endif

section .text
extern fat_copy_seek, crc32_foreground
global command_crc32range

disk_reader_open:
    lea     rax, [rel fat_copy_chunk]
    cmp     byte [rbp + mount_volume.type], FS_EXT2
    je      .ext
    mov     [rel reader_chunk], rax
    jmp     fat_copy_open
.ext:
    lea     rax, [rel ext_chunk]
    mov     [rel reader_chunk], rax
    mov     qword [rel reader_offset], 0
    jmp     ext_open

ext_chunk:
    sub     rsp, 8
    mov     rsi, [rel reader_offset]
    mov     rdx, [rel reader_size]
    sub     rdx, rsi
    mov     eax, BLOCK_SIZE
    cmp     rdx, rax
    cmova   rdx, rax
    add     [rel reader_offset], rdx
    call    ext_read_at
    add     rsp, 8
    ret

ext_cat:
    push    rbx
    push    r12
    sub     rsp, 8
    call    disk_reader_open
    test    rax, rax
    jnz     .error
    mov     [rel reader_size], rdx
    mov     r12, rdx
    xor     ebx, ebx
.next:
    test    r12, r12
    jz      .end
    lea     rdi, [rel read_buffer]
    call    ext_chunk
    test    rax, rax
    jnz     .error
    mov     esi, BLOCK_SIZE
    cmp     r12, rsi
    cmovb   rsi, r12
    lea     rdi, [rel read_buffer]
    movzx   ebx, byte [rdi + rsi - 1]
    sub     r12, rsi
    call    console_write
    jmp     .next
.end:
    cmp     bl, 10
    je      .done
    cmp     qword [rel reader_size], 0
    je      .done
    mov     edi, 10
    call    console_putc
    jmp     .done
.error:
    mov     rdi, rax
    call    console_write_cstr
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

command_crc32range:
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    call    range_number
    jc      .usage
    mov     r12, rax
    call    range_number
    jc      .usage
    mov     r13, rax
    mov     esi, 1
    call    resolve_path
    test    rax, rax
    jnz     .error
    call    work_location
    mov     rbp, rax
    mov     esi, edx
    lea     rdi, [rel component]
    cmp     rbp, RAM_MOUNT
    jne     .disk
    call    ramfs_lookup
    test    rax, rax
    jz      .missing_ram
    mov     rbx, rax
    jmp     .bounds
.disk:
    call    disk_reader_open
    test    rax, rax
    jnz     .error
.bounds:
    cmp     r12, rdx
    ja      .out_of_range
    mov     [rel reader_size], rdx
    sub     rdx, r12
    cmp     r13, rdx
    ja      .out_of_range
    cmp     r13, 64 * 1024 * 1024
    ja      .too_large
    xor     r14d, r14d
    test    r13, r13
    jz      .print
    cmp     rbp, RAM_MOUNT
    jne     .disk_read
    lea     rdi, [rbx + r12]
    mov     rsi, r13
    call    crc32_foreground
    mov     r14d, eax
    jmp     .print
.disk_read:
    cmp     byte [rbp + mount_volume.type], FS_EXT2
    jne     .fat_seek
.ext_read:
    mov     r15d, EXT_RANGE_BUFFER
    cmp     r13, r15
    cmovb   r15, r13
    lea     rdi, [rel read_buffer]
    mov     rsi, r12
    mov     edx, r15d
    call    ext_read_at
    test    rax, rax
    jnz     .error
    lea     rdi, [rel read_buffer]
    mov     esi, r15d
    mov     edx, r14d
    call    crc32_update
    mov     r14d, eax
    add     r12, r15
    sub     r13, r15
    jnz     .ext_read
    jmp     .print
.fat_seek:
    mov     r15, r12
    and     r15d, BLOCK_SIZE - 1
    mov     rdi, r12
    shr     rdi, 9
    call    fat_copy_seek
    test    rax, rax
    jnz     .error
.read:
    lea     rdi, [rel read_buffer]
    call    [rel reader_chunk]
    test    rax, rax
    jnz     .error
    lea     rdi, [rel read_buffer]
    add     rdi, r15
    mov     esi, BLOCK_SIZE
    sub     rsi, r15
    xor     r15d, r15d
    cmp     rsi, r13
    cmova   rsi, r13
    sub     r13, rsi
    mov     edx, r14d
    call    crc32_update
    mov     r14d, eax
    test    r13, r13
    jnz     .read
.print:
    mov     edi, r14d
    call    write_hex32_raw
    mov     edi, 10
    call    console_putc
    jmp     .done
.missing_ram:
    call    ramfs_not_found
    jmp     .done
.usage:
    lea     rax, [rel range_usage]
    jmp     .error
.out_of_range:
    lea     rax, [rel range_bounds]
    jmp     .error
.too_large:
    lea     rax, [rel range_limit]
.error:
    mov     rdi, rax
    call    console_write_cstr
.done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

; Parse one decimal word and leave rdi at the next non-space byte.
range_number:
    mov     rsi, rdi
.next:
    cmp     byte [rsi], 0
    je      .bad
    cmp     byte [rsi], ' '
    je      .split
    inc     rsi
    jmp     .next
.split:
    mov     byte [rsi], 0
    sub     rsp, 8
    call    parse_lba
    lea     rsp, [rsp + 8]
    jc      .bad
    mov     rdi, rsi
.skip:
    inc     rdi
    cmp     byte [rdi], ' '
    je      .skip
    cmp     byte [rdi], 0
    je      .bad
    clc
    ret
.bad:
    stc
    ret

section .rodata
range_usage: db "Usage: crc32range OFFSET LENGTH PATH", 10, 0
range_bounds: db "Checksum range is outside the file.", 10, 0
range_limit: db "Checksum range exceeds 64 MiB.", 10, 0

section .bss
alignb 8
reader_size: resq 1
reader_offset: resq 1
reader_chunk: resq 1
read_buffer: resb EXT_RANGE_BUFFER
