; Resolve both paths before changing either directory entry.
global command_mv
extern fat_rename, ext_move

section .text
command_mv:
    call    console_cancel_begin
    test    rax, rax
    jnz     print_error
    push    rbp
    push    r12
    push    r13
    sub     rsp, 16
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
    mov     esi, PATH_MOVE
    call    resolve_path
    test    rax, rax
    jnz     .done
    mov     [rsp], r8d
    call    work_location
    cmp     rax, RAM_MOUNT
    je      .scope
    mov     rbp, rax
    mov     r12d, edx
    lea     rsi, [rel component]
    lea     rdi, [rel move_source]
    mov     ecx, LINE_BUF_SIZE
    rep     movsb
    mov     rdi, r13
    mov     esi, PATH_MOVE
    call    resolve_path
    test    rax, rax
    jnz     .done
    or      r8d, [rsp]
    call    work_location
    cmp     rax, rbp
    jne     .scope
    mov     ecx, edx
    mov     edx, r12d
    lea     rdi, [rel move_source]
    lea     rsi, [rel component]
    cmp     byte [rbp + mount_volume.type], FS_EXT2
    je      .ext
    test    r8d, r8d
    jnz     .directory
    cmp     ecx, edx
    jne     .scope
    call    fat_rename
    jmp     .done
.ext:
    call    ext_move
    jmp     .done
.directory:
    lea     rax, [rel path_not_directory]
    jmp     .done
.scope:
    lea     rax, [rel move_scope]
    jmp     .done
.usage:
    lea     rax, [rel move_usage]
.done:
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbp
    test    rax, rax
    jnz     print_error
    ret

section .rodata
move_usage: db "Usage: mv SOURCE DEST", 10, 0
move_scope: db "mv requires one mounted volume. FAT32 also requires the same directory.", 10, 0

section .bss
move_source: resb LINE_BUF_SIZE
