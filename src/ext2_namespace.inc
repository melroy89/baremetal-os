section .text
global ext_symlink, ext_try_symlink, ext_link, ext_stat, ext_stat_inode, ext_resize
extern write_u64, write_hex32_raw

; rdi = name, esi = parent, rdx = path buffer. Return length in edx when
; this entry is a symlink, zero when absent or a different inode type.
ext_try_symlink:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdx
    call    scan_dir
    test    rax, rax
    jz      .load
    lea     rcx, [rel missing_entry]
    cmp     rax, rcx
    je      .not_link
    jmp     .done
.load:
    mov     edi, edx
    lea     rsi, [rel entry_inode]
    call    load_inode
    test    rax, rax
    jnz     .done
    cmp     dword [rel entry_inode + ext_inode.mode], EXT_SYMLINK
    jne     .not_link
    mov     rbx, [rel entry_inode + ext_inode.size]
    test    rbx, rbx
    jz      .invalid
    cmp     rbx, [rbp + mount_volume.ext_block_size]
    jae     .invalid
    cmp     rbx, LINE_BUF_SIZE
    jae     .invalid
    lea     rsi, [rel entry_inode + ext_inode.blocks]
    cmp     dword [rel entry_inode + ext_inode.data_sectors], 0
    jne     .block_link
    cmp     ebx, 60
    ja      .invalid
    jmp     .copy
.block_link:
    mov     edi, [rsi]
    test    edi, edi
    jz      .invalid
    cmp     edi, [rbp + mount_volume.ext_blocks]
    jae     .invalid
    lea     rsi, [rel link_data]
    call    rw_read_block
    test    rax, rax
    jnz     .done
    lea     rsi, [rel link_data]
.copy:
    mov     rdi, r12
    mov     ecx, ebx
    rep     movsb
    mov     byte [rdi], 0
    mov     rdi, r12
    mov     ecx, ebx
    xor     eax, eax
    repne   scasb
    je      .invalid
    mov     edx, ebx
    jmp     .done
.not_link:
    xor     eax, eax
    xor     edx, edx
    jmp     .done
.invalid:
    lea     rax, [rel corrupt_text]
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; rdi = source name, esi = source parent, rdx = new name, ecx = new parent.
ext_link:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    cmp     byte [rbp + mount_volume.read_only], 0
    jne     .readonly
    cmp     byte [rbp + mount_volume.write_error], 0
    jne     .blocked
    mov     r12, rdx
    mov     r13d, ecx
    call    rw_prepare_target
    test    rax, rax
    jnz     .done
    mov     ebx, [rel target_inode]
    test    ebx, ebx
    jz      .missing
    mov     edi, ebx
    lea     rsi, [rel entry_inode]
    call    load_inode
    test    rax, rax
    jnz     .done
    cmp     dword [rel entry_inode + ext_inode.mode], EXT_REG
    jne     .type
    test    dword [rel entry_inode + ext_inode.flags], EXT_PROTECTED_FLAGS
    jnz     .blocked
    mov     eax, [rel entry_inode + ext_inode.links]
    cmp     eax, EXT_LINK_MAX
    jae     .limit
    mov     [rel remove_links], eax
    mov     byte [rel reclaim_is_dir], 0
    call    rw_scan_references
    test    rax, rax
    jnz     .done
    mov     rdi, r12
    mov     esi, r13d
    call    rw_prepare_target
    test    rax, rax
    jnz     .done
    test    dword [rel dir_inode + ext_inode.flags], EXT_PROTECTED_FLAGS
    jnz     .blocked
    cmp     dword [rel target_inode], 0
    jne     .occupied
    mov     dword [rel create_owned_count], 0
    mov     byte [rel create_inode_needed], 0
    call    rw_plan_growth
    test    rax, rax
    jnz     .done
    call    rw_select_free
    test    rax, rax
    jnz     .done
    call    rtc_unix_seconds
    jc      .clock
    mov     r14d, eax
    call    rw_clear_parent_index
    test    rax, rax
    jnz     .failed
    call    rw_grow_directory
    test    rax, rax
    jnz     .failed
    mov     edi, ebx
    mov     esi, 1
    mov     edx, r14d
    call    rw_change_links_timestamp
    test    rax, rax
    jnz     .failed
    mov     [rel create_inode], ebx
    mov     byte [rel create_type], 1
    call    rw_publish
    test    rax, rax
    jnz     .failed
    call    ext_flush
    test    rax, rax
    jnz     .failed
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
.occupied:
    lea     rax, [rel ext_exists]
    jmp     .done
.type:
    lea     rax, [rel not_regular]
    jmp     .done
.limit:
    lea     rax, [rel ext_link_limit]
    jmp     .done
.clock:
    lea     rax, [rel ext_unlink_clock_error]
.done:
    call    rw_free_plans
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; rdi = existing regular file, esi = parent, rdx = new length.
ext_resize:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13, rdx
    call    ext_open
    test    rax, rax
    jnz     .done
    mov     rdi, rbx
    mov     ecx, r12d
    xor     esi, esi
    mov     rdx, r13
    mov     r8d, 6
    call    ext_create_plain       ; Reports mutation errors itself.
    xor     eax, eax
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; rdi = name, esi = parent. Print Linux inode fields in the guest console.
ext_stat:
    sub     rsp, 8
    call    scan_dir
    add     rsp, 8
    test    rax, rax
    jnz     .done
    mov     edi, edx
    jmp     ext_stat_inode
.done:
    ret

ext_stat_inode:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    lea     rsi, [rel entry_inode]
    call    load_inode
    test    rax, rax
    jnz     .done
    mov     edi, ebx
    call    rw_read_inode_sector
    test    rax, rax
    jnz     .done
    mov     r12, rcx
    lea     rdi, [rel stat_type]
    call    console_write_cstr
    mov     eax, [rel entry_inode + ext_inode.mode]
    shr     eax, 12
    lea     rcx, [rel stat_types]
    mov     rdi, [rcx + rax * 8]
    call    console_write_cstr
    lea     rdi, [rel stat_inode]
    mov     esi, ebx
    call    stat_field
    lea     rdi, [rel stat_size]
    mov     rsi, [rel entry_inode + ext_inode.size]
    call    stat_field
    lea     rdi, [rel stat_blocks]
    mov     esi, [r12 + 28]
    call    stat_field
    lea     rdi, [rel stat_links]
    movzx   esi, word [r12 + 26]
    call    stat_field
    lea     rdi, [rel stat_mode]
    call    console_write_cstr
    movzx   edi, word [r12]
    call    write_hex32_raw
    mov     edi, 10
    call    console_putc
    lea     rdi, [rel stat_uid]
    movzx   esi, word [r12 + 120]
    shl     esi, 16
    mov     si, [r12 + 2]
    call    stat_field
    lea     rdi, [rel stat_gid]
    movzx   esi, word [r12 + 122]
    shl     esi, 16
    mov     si, [r12 + 24]
    call    stat_field
    lea     rdi, [rel stat_atime]
    mov     esi, [r12 + 8]
    call    stat_field
    lea     rdi, [rel stat_mtime]
    mov     esi, [r12 + 16]
    call    stat_field
    lea     rdi, [rel stat_ctime]
    mov     esi, [r12 + 12]
    call    stat_field
    xor     eax, eax
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

stat_field:
    push    rsi
    call    console_write_cstr
    pop     rdi
    sub     rsp, 8
    call    write_u64
    add     rsp, 8
    mov     edi, 10
    jmp     console_putc

section .rodata
ext_link_limit: db "Ext2 file link limit reached.", 10, 0
stat_type: db "Type: ", 0
stat_unknown: db "unknown", 10, 0
stat_fifo: db "FIFO", 10, 0
stat_character: db "character device", 10, 0
stat_directory: db "directory", 10, 0
stat_device: db "block device", 10, 0
stat_regular: db "regular file", 10, 0
stat_symbolic: db "symbolic link", 10, 0
stat_socket: db "socket", 10, 0
align 8
stat_types:
    dq stat_unknown, stat_fifo, stat_character, stat_unknown
    dq stat_directory, stat_unknown, stat_device, stat_unknown
    dq stat_regular, stat_unknown, stat_symbolic, stat_unknown
    dq stat_socket, stat_unknown, stat_unknown, stat_unknown
stat_inode: db "Inode: ", 0
stat_size: db "Size: ", 0
stat_blocks: db "Allocated sectors: ", 0
stat_links: db "Links: ", 0
stat_mode: db "Mode (hex): ", 0
stat_uid: db "UID: ", 0
stat_gid: db "GID: ", 0
stat_atime: db "Access time (Unix seconds): ", 0
stat_mtime: db "Modification time (Unix seconds): ", 0
stat_ctime: db "Change time (Unix seconds): ", 0

section .bss
link_data: resb EXT_BLOCK
