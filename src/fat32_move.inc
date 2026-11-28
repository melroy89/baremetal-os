; rdi and rsi name entries in parent cluster edx on the same volume.
global fat_rename
section .text
fat_rename:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rsi
    mov     ebx, edx
    cmp     byte [rbp + mount_volume.read_only], 0
    jne     .readonly
    cmp     byte [rbp + mount_volume.write_error], 0
    jne     .blocked
    call    short_name
    jc      .name
    mov     r14, [rel name_buf]
    mov     r15d, [rel name_buf + 8]
    and     r15d, 0x00ffffff
    mov     esi, ebx
    xor     edi, edi
    call    scan_directory
    test    rax, rax
    jnz     .done
    cmp     byte [rel slot_found], 1
    jne     .missing
    call    verify_file_slot
    test    rax, rax
    jnz     .done
    cmp     byte [rel slot_lfn], 0
    jne     .lfn
    mov     r13, [rel slot_lba]
    mov     rdi, r12
    mov     r12d, [rel slot_offset]
    call    short_name
    jc      .name
    cmp     r14, [rel name_buf]
    jne     .scan
    mov     eax, [rel name_buf + 8]
    and     eax, 0x00ffffff
    cmp     r15d, eax
    je      .ok
.scan:
    mov     esi, ebx
    mov     edi, 2
    call    scan_directory
    test    rax, rax
    jnz     .done
    cmp     byte [rel slot_found], 0
    jne     .exists
    call    verify_mutation_tree
    test    rax, rax
    jnz     .done
    mov     rdi, r13
    call    read_sector
    test    rax, rax
    jnz     .done
    lea     rdi, [rel sector_buffer]
    add     rdi, r12
    and     byte [rdi + 12], 0xe7     ; The new short name is uppercase.
    lea     rsi, [rel name_buf]
    mov     ecx, 11
    rep     movsb
    call    console_cancel_commit
    test    rax, rax
    jnz     .done
    mov     byte [rbp + mount_volume.pending_write], 1
    mov     rdi, r13
    call    write_sector
    test    rax, rax
    jnz     .failed
    call    fat_flush
    test    rax, rax
    jnz     .failed
    mov     byte [rbp + mount_volume.pending_write], 0
.ok:
    xor     eax, eax
    jmp     .done
.failed:
    mov     byte [rbp + mount_volume.write_error], 1
    jmp     .done
.readonly:
    lea     rax, [rel fat_readonly]
    jmp     .done
.blocked:
    lea     rax, [rel blocked_text]
    jmp     .done
.name:
    lea     rax, [rel invalid_name]
    jmp     .done
.missing:
    lea     rax, [rel file_missing]
    jmp     .done
.exists:
    lea     rax, [rel fat_rename_exists]
    jmp     .done
.lfn:
    lea     rax, [rel fat_rename_lfn]
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

section .rodata
fat_rename_exists: db "FAT32 destination already exists.", 10, 0
fat_rename_lfn: db "Cannot rename a FAT32 file with long-name entries.", 10, 0
fat_rename_unverified: db "Cannot verify FAT32 destination uniqueness in a directory with long-name entries.", 10, 0
