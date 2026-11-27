; Binary file copy using the shared path resolver and filesystem writers.
extern ramfs_lookup, ramfs_not_found
extern fat_copy_open, fat_copy_chunk, fat_copy_write

section .text
global command_cp

command_cp:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     dword [rsp], 0            ; Source inode for same-volume ext2 copies.
    call    copy_operand
    jc      .usage
    mov     r12, rdi
    mov     rdi, rsi
    call    copy_operand
    jc      .usage
    cmp     byte [rsi], 0
    jne     .usage
    mov     r13, rdi
    mov     rdi, r12
    mov     esi, 1
    call    resolve_path
    test    rax, rax
    jnz     .error
    call    work_location
    mov     r15, rax
    lea     rdi, [rel component]
    cmp     rax, RAM_MOUNT
    jne     .open_disk
    call    ramfs_lookup
    test    rax, rax
    jz      .missing_ram
    mov     rbx, rax
    jmp     .destination
.open_disk:
    mov     rbp, rax
    mov     esi, edx
    call    disk_reader_open
    test    rax, rax
    jnz     .error
    cmp     byte [rbp + mount_volume.type], FS_EXT2
    jne     .destination
    mov     [rsp], ecx
.destination:
    mov     r14, rdx
    mov     [rel reader_size], rdx
    mov     rdi, r13
    mov     esi, 1
    call    resolve_path
    test    rax, rax
    jnz     .error
    call    work_location
    lea     rdi, [rel component]
    cmp     rax, RAM_MOUNT
    je      .to_ram
    mov     rbp, rax
    cmp     byte [rbp + mount_volume.type], FS_EXT2
    je      .to_ext
    mov     ecx, edx
    mov     rdx, r14
    cmp     r15, RAM_MOUNT
    jne     .stream_disk
    mov     rsi, rbx
    call    fat_write
    jmp     .done
.stream_disk:
    mov     rsi, [rel reader_chunk]
    call    fat_copy_write
    jmp     .done
.to_ram:
    cmp     r15, RAM_MOUNT
    jne     .stage_disk
    call    ramfs_lookup
    cmp     rax, rbx
    je      .same_file
    jmp     .write_ram
.stage_disk:
    cmp     r14, PAGE_SIZE
    ja      .too_large
    lea     rbx, [rel copy_ram_buffer]
    mov     r12, rbx
    lea     r13, [rbx + r14]
.stage_sector:
    cmp     r12, r13
    jae     .write_ram
    mov     rdi, r12
    call    [rel reader_chunk]
    test    rax, rax
    jnz     .error
    add     r12, BLOCK_SIZE
    jmp     .stage_sector
.write_ram:
    lea     rdi, [rel component]
    mov     rsi, rbx
    mov     rdx, r14
    call    ramfs_write
    jmp     .done
.to_ext:
    mov     ecx, edx
    mov     rdx, r14
    xor     r9d, r9d
    cmp     rbp, r15
    cmove   r9d, [rsp]
    cmp     r15, RAM_MOUNT
    jne     .stream_ext
    mov     rsi, rbx
    call    ext_copy_write
    jmp     .done
.stream_ext:
    cmp     byte [r15 + mount_volume.type], FS_EXT2
    je      .sparse_ext
    mov     rsi, [rel reader_chunk]
    call    ext_copy_stream
    jmp     .done
.sparse_ext:
    call    ext_copy_sparse
    jmp     .done
.missing_ram:
    call    ramfs_not_found
    jmp     .done
.same_file:
    lea     rax, [rel copy_same_ram]
    jmp     .error
.too_large:
    lea     rax, [rel copy_large_ram]
    jmp     .error
.usage:
    lea     rax, [rel copy_usage]
.error:
    mov     rdi, rax
    call    console_write_cstr
.done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

; Only an opening quote starts quoted syntax. Decode \" and \\ inside quotes.
; Return the operand in rdi, remaining input in rsi, and CF on bad syntax.
copy_operand:
    cmp     byte [rdi], '"'
    je      .quoted
    mov     rsi, rdi
.word:
    mov     al, [rsi]
    test    al, al
    jz      .end
    cmp     al, ' '
    je      .split
    inc     rsi
    jmp     .word
.quoted:
    inc     rdi
    mov     rsi, rdi
    mov     rdx, rdi
.quote:
    mov     al, [rsi]
    test    al, al
    je      .bad
    cmp     al, '"'
    je      .quote_end
    cmp     al, 0x5C                 ; Backslash
    jne     .copy
    cmp     byte [rsi + 1], '"'
    je      .escaped
    cmp     byte [rsi + 1], 0x5C
    jne     .copy
.escaped:
    inc     rsi
    mov     al, [rsi]
.copy:
    mov     [rdx], al
    inc     rdx
    inc     rsi
    jmp     .quote
.quote_end:
    cmp     byte [rsi + 1], ' '
    je      .end_quote
    cmp     byte [rsi + 1], 0
    jne     .bad
.end_quote:
    mov     byte [rdx], 0
    jmp     .skip
.split:
    mov     byte [rsi], 0
.skip:
    inc     rsi
    cmp     byte [rsi], ' '
    je      .skip
.end:
    cmp     byte [rdi], 0
    je      .bad
    clc
    ret
.bad:
    stc
    ret

section .rodata
copy_usage:     db "Usage: cp SOURCE DEST", 10, 0
copy_same_ram:  db "Source and destination are the same file.", 10, 0
copy_large_ram: db "File is too large for the RAM filesystem.", 10, 0

section .bss
alignb 16
copy_ram_buffer: resb PAGE_SIZE
