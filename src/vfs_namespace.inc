section .text
global command_ln, command_readlink, command_stat, command_truncate
extern ext_try_symlink, ext_symlink, ext_link, ext_stat, ext_stat_inode, ext_resize

command_ln:
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    xor     r15d, r15d
    cmp     word [rdi], '-s'
    jne     .operands
    cmp     byte [rdi + 2], ' '
    jne     .operands
    add     rdi, 3
    mov     r15d, 1
.operands:
    call    copy_operand
    jc      .usage
    mov     r12, rdi
    mov     rdi, rsi
    call    copy_operand
    jc      .usage
    cmp     byte [rsi], 0
    jne     .usage
    mov     r13, rdi
    test    r15d, r15d
    jnz     .destination
    mov     rdi, r12
    mov     esi, PATH_NOFOLLOW
    call    resolve_ext_operand
    test    rax, rax
    jnz     .done
    mov     r14d, esi
    mov     r15, rbp
    lea     rdi, [rel link_source]
    lea     rsi, [rel component]
    mov     ecx, LINE_BUF_SIZE
    rep     movsb
.destination:
    mov     rdi, r13
    mov     esi, PATH_NOFOLLOW
    call    resolve_ext_operand
    test    rax, rax
    jnz     .done
    mov     ecx, esi
    cmp     r15d, 1
    je      .symbolic
    cmp     rbp, r15
    jne     .different_volume
    lea     rdi, [rel link_source]
    mov     esi, r14d
    lea     rdx, [rel component]
    call    ext_link
    jmp     .done
.symbolic:
    xor     edx, edx
.length:
    cmp     byte [r12 + rdx], 0
    je      .create
    inc     edx
    jmp     .length
.create:
    test    edx, edx
    jz      .usage
    lea     rdi, [rel component]
    mov     rsi, r12
    call    ext_symlink               ; Reports its own errors.
    xor     eax, eax
    jmp     .done
.different_volume:
    lea     rax, [rel link_volume_error]
    jmp     .done
.usage:
    lea     rax, [rel link_usage]
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    test    rax, rax
    jnz     print_error
    ret

command_readlink:
    push    rbp
    mov     esi, PATH_NOFOLLOW
    call    resolve_ext_operand
    test    rax, rax
    jnz     .done
    lea     rdx, [rel symlink_target]
    call    ext_try_symlink
    test    rax, rax
    jnz     .done
    test    edx, edx
    jz      .not_symlink
    pop     rbp
    lea     rdi, [rel symlink_target]
    jmp     print_line
.not_symlink:
    lea     rax, [rel not_symlink]
.done:
    pop     rbp
    jmp     print_error

command_stat:
    push    rbp
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    mov     esi, 1
    call    resolve_ext_operand
    test    rax, rax
    jz      .entry
    lea     rdx, [rel path_directory]
    cmp     rax, rdx
    jne     .done
    mov     rdi, r12
    xor     esi, esi
    call    resolve_ext_operand
    test    rax, rax
    jnz     .done
    mov     edi, esi
    test    edi, edi
    jnz     .directory_inode
    mov     edi, 2
.directory_inode:
    call    ext_stat_inode
    jmp     .done
.entry:
    call    ext_stat
.done:
    add     rsp, 8
    pop     r12
    pop     rbp
    test    rax, rax
    jnz     print_error
    ret

command_truncate:
    push    rbp
    push    r12
    push    r13
    call    copy_operand
    jc      .usage
    mov     r12, rdi
    mov     rdi, rsi
    call    copy_operand
    jc      .usage
    cmp     byte [rsi], 0
    jne     .usage
    call    parse_lba
    jc      .usage
    mov     r13, rax
    mov     rdi, r12
    mov     esi, 1
    call    resolve_ext_operand
    test    rax, rax
    jnz     .done
    mov     rdx, r13
    call    ext_resize
    jmp     .done
.usage:
    lea     rax, [rel truncate_usage]
.done:
    pop     r13
    pop     r12
    pop     rbp
    test    rax, rax
    jnz     print_error
    ret

; Return the mounted ext2 operand in rbp, rdi (name) and esi (parent).
resolve_ext_operand:
    sub     rsp, 8
    call    resolve_path
    test    rax, rax
    jnz     .done
    call    work_location
    cmp     rax, RAM_MOUNT
    jbe     .type
    cmp     byte [rax + mount_volume.type], FS_EXT2
    jne     .type
    mov     rbp, rax
    mov     esi, edx
    lea     rdi, [rel component]
    xor     eax, eax
    jmp     .done
.type:
    lea     rax, [rel ext_operand]
.done:
    add     rsp, 8
    ret

section .rodata
link_usage: db "Usage: ln [-s] SOURCE LINK", 10, 0
link_volume_error: db "Hard links require the same ext2 volume.", 10, 0
ext_operand: db "Expected a path on an ext2 volume.", 10, 0
not_symlink: db "Expected an ext2 symbolic link.", 10, 0
symlink_loop: db "Too many symbolic links.", 10, 0
truncate_usage: db "Usage: truncate PATH SIZE", 10, 0

section .bss
symlink_target: resb LINE_BUF_SIZE
symlink_path: resb LINE_BUF_SIZE
symlink_budget: resb 1
link_source: resb LINE_BUF_SIZE
