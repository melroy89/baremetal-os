; rdi and rsi name entries in parent inode edx on the same volume.
global ext_rename
extern str_eq
section .text
ext_rename:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    cmp     byte [rbp + mount_volume.read_only], 0
    jne     .readonly
    cmp     byte [rbp + mount_volume.write_error], 0
    jne     .blocked
    mov     r13, rsi
    mov     r14, rdi
    mov     ebx, edx
    mov     esi, edx
    call    rw_prepare_target
    test    rax, rax
    jnz     .done
    mov     edi, [rel target_inode]
    test    edi, edi
    jz      .missing
    mov     r15d, [rel target_block]
    mov     r12d, [rel target_offset]
    lea     rsi, [rel entry_inode]
    call    load_inode
    test    rax, rax
    jnz     .done
    cmp     dword [rel entry_inode + ext_inode.mode], EXT_REG
    jne     .type
    mov     eax, [rel entry_inode + ext_inode.flags]
    or      eax, [rel dir_inode + ext_inode.flags]
    test    eax, EXT_PROTECTED_FLAGS
    jnz     .blocked
    mov     rdi, r14
    mov     rsi, r13
    call    str_eq
    test    eax, eax
    jnz     .ok
    mov     rdi, r13
    mov     esi, ebx
    call    rw_prepare_target
    test    rax, rax
    jnz     .done
    cmp     dword [rel target_inode], 0
    jne     .occupied
    shl     r15, 3
    mov     eax, r12d
    shr     eax, 9
    add     r15, rax
    and     r12d, BLOCK_SIZE - 1
    mov     eax, [rel create_rec_min]
    add     eax, r12d
    cmp     eax, BLOCK_SIZE
    ja      .fit
    mov     rdi, r15
    lea     rsi, [rel write_sector_buffer]
    call    read_sector
    test    rax, rax
    jnz     .done
    lea     rbx, [rel write_sector_buffer]
    add     rbx, r12
    movzx   eax, word [rbx + 4]
    cmp     eax, [rel create_rec_min]
    jb      .fit
    mov     ecx, [rel create_name_length]
    mov     [rbx + 6], cl
    lea     rdi, [rbx + 8]
    mov     rsi, r13
    rep     movsb
    mov     rdi, r15
    lea     rsi, [rel write_sector_buffer]
    call    rw_write_sector
    test    rax, rax
    jnz     .failed
    call    ext_flush
    test    rax, rax
    jnz     .failed
.ok:
    xor     eax, eax
    jmp     .done
.failed:
    mov     byte [rbp + mount_volume.write_error], 1
    jmp     .done
.readonly:
    lea     rax, [rel ext_readonly_error]
    jmp     .done
.blocked:
    lea     rax, [rel ext_write_blocked]
    jmp     .done
.missing:
    lea     rax, [rel missing_entry]
    jmp     .done
.type:
    lea     rax, [rel ext_rename_type]
    jmp     .done
.occupied:
    lea     rax, [rel ext_exists]
    jmp     .done
.fit:
    lea     rax, [rel ext_rename_fit]
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

section .rodata
ext_rename_type: db "mv requires a regular file.", 10, 0
ext_rename_fit: db "The new ext2 name cannot fit in the original sector and record.", 10, 0
