; rdi and rsi name entries in parent inode edx on the same volume.
global ext_move
extern str_eq
section .text

; rdi/rsi = names, edx/ecx = source and destination parents on one mount.
ext_move:
    test    r8d, r8d
    jnz     ext_move_general
    cmp     ecx, edx
    jne     ext_move_general
    push    rdi
    push    rsi
    push    rdx
    call    ext_rename
    pop     rdx
    pop     rsi
    pop     rdi
    mov     ecx, edx
    xor     r8d, r8d
    lea     r9, [rel ext_rename_fit]
    cmp     rax, r9
    je      ext_move_general
    lea     r9, [rel ext_exists]
    cmp     rax, r9
    je      ext_move_general
    lea     r9, [rel ext_rename_type]
    cmp     rax, r9
    je      ext_move_general
    ret

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
    mov     eax, [rel entry_inode + ext_inode.mode]
    cmp     eax, EXT_REG
    je      .source_type
    cmp     eax, EXT_SYMLINK
    jne     .type
.source_type:
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
    imul    r15, [rbp + mount_volume.ext_sectors]
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
    call    console_cancel_commit
    test    rax, rax
    jnz     .done
    test    dword [rel dir_inode + ext_inode.flags], EXT_INDEX_FL
    jz      .rename
    call    rw_clear_parent_index
    test    rax, rax
    jnz     .failed
    mov     rdi, r15
    lea     rsi, [rel write_sector_buffer]
    call    read_sector
    test    rax, rax
    jnz     .failed
.rename:
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
ext_rename_type: db "mv requires an ext2 regular file or symbolic link.", 10, 0
ext_rename_fit: db "The new ext2 name cannot fit in the original sector and record.", 10, 0

section .text
ext_move_general:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     byte [rel create_resize], 0
    cmp     byte [rbp + mount_volume.read_only], 0
    jne     .readonly
    cmp     byte [rbp + mount_volume.write_error], 0
    jne     .blocked
    mov     r12, rsi
    mov     r13d, ecx
    mov     r15d, r8d
    mov     esi, edx
    call    rw_prepare_target
    test    rax, rax
    jnz     .done
    mov     eax, [rel parent_inode]
    mov     [rel move_src_parent], eax
    mov     eax, [rel target_block]
    mov     [rel move_src_block], eax
    mov     eax, [rel target_offset]
    mov     [rel move_src_offset], eax
    mov     eax, [rel dir_inode + ext_inode.links]
    mov     [rel move_src_links], eax
    mov     ebx, [rel target_inode]
    test    ebx, ebx
    jz      .missing
    test    dword [rel dir_inode + ext_inode.flags], EXT_PROTECTED_FLAGS
    jnz     .blocked
    mov     edi, ebx
    lea     rsi, [rel entry_inode]
    call    load_inode
    test    rax, rax
    jnz     .done
    test    dword [rel entry_inode + ext_inode.flags], EXT_PROTECTED_FLAGS
    jnz     .blocked
    mov     eax, [rel entry_inode + ext_inode.mode]
    test    r15d, r15d
    jz      .source_type
    cmp     eax, EXT_DIR
    jne     .needs_directory
.source_type:
    mov     byte [rel move_type], 1
    cmp     eax, EXT_REG
    je      .destination
    mov     byte [rel move_type], 7
    cmp     eax, EXT_SYMLINK
    je      .destination
    cmp     eax, EXT_DIR
    jne     .type
    mov     byte [rel move_type], 2
    cmp     dword [rel move_src_links], 2
    jbe     .invalid
    mov     edi, ebx
    call    vfs_dir_busy
    test    eax, eax
    jnz     .busy
    mov     eax, [rel entry_inode + ext_inode.blocks]
    test    eax, eax
    jz      .invalid
    mov     [rel move_dot_block], eax
    call    rw_check_move_parents
    test    rax, rax
    jnz     .done
.destination:
    mov     rdi, r12
    mov     esi, r13d
    call    rw_prepare_target
    test    rax, rax
    jnz     .done
    mov     r13d, [rel parent_inode]
    mov     r14d, [rel target_inode]
    cmp     r14d, ebx
    je      .ok
    test    dword [rel dir_inode + ext_inode.flags], EXT_PROTECTED_FLAGS
    jnz     .blocked
    mov     byte [rel move_drop_dir], 0
    mov     byte [rel move_drop_final], 0
    mov     dword [rel reclaim_xattr], 0
    mov     dword [rel reclaim_inode], 0
    mov     byte [rel reclaim_is_dir], 0
    test    r14d, r14d
    jz      .new_entry
    mov     edi, r14d
    lea     rsi, [rel entry_inode]
    call    load_inode
    test    rax, rax
    jnz     .done
    test    dword [rel entry_inode + ext_inode.flags], EXT_PROTECTED_FLAGS
    jnz     .blocked
    mov     eax, [rel entry_inode + ext_inode.mode]
    mov     ecx, [rel entry_inode + ext_inode.links]
    mov     [rel remove_links], ecx
    cmp     eax, EXT_DIR
    jne     .replacement_file
    cmp     byte [rel move_type], 2
    jne     .type
    cmp     dword [rel dir_inode + ext_inode.links], 2
    jbe     .invalid
    cmp     ecx, 2
    jne     .nonempty
    mov     byte [rel move_drop_dir], 1
    mov     byte [rel reclaim_is_dir], 1
    mov     edi, r14d
    call    vfs_dir_busy
    test    eax, eax
    jnz     .busy
    mov     edi, r14d
    mov     esi, -2
    call    rw_dir_count
    test    rax, rax
    jnz     .done
    jmp     .capture
.replacement_file:
    cmp     byte [rel move_type], 2
    je      .type
    cmp     eax, EXT_SYMLINK
    je      .replacement_links
    cmp     eax, EXT_REG
    jne     .type
.replacement_links:
    cmp     ecx, 1
    jne     .check_refs
.capture:
    mov     byte [rel move_drop_final], 1
    mov     [rel reclaim_inode], r14d
    mov     dword [rel reclaim_count], 0
    cmp     dword [rel entry_inode + ext_inode.mode], EXT_SYMLINK
    jne     .blocks
    cmp     dword [rel entry_inode + ext_inode.data_sectors], 0
    je      .attributes
.blocks:
    call    rw_collect_blocks
    test    rax, rax
    jnz     .done
.attributes:
    mov     edi, r14d
    call    rw_plan_xattr_release
    test    rax, rax
    jnz     .done
.check_refs:
    call    rw_scan_references
    test    rax, rax
    jnz     .done
    jmp     .clock
.new_entry:
    cmp     byte [rel move_type], 2
    jne     .slot
    cmp     r13d, [rel move_src_parent]
    je      .slot
    cmp     dword [rel dir_inode + ext_inode.links], EXT_LINK_MAX
    jae     .link_limit
.slot:
    mov     dword [rel create_owned_count], 0
    mov     byte [rel create_inode_needed], 0
    call    rw_plan_growth
    test    rax, rax
    jnz     .done
    call    rw_select_free
    test    rax, rax
    jnz     .done
.clock:
    call    rtc_unix_seconds
    jc      .clock_error
    mov     r15d, eax
    call    console_cancel_commit
    test    rax, rax
    jnz     .done
    call    rw_clear_parent_index
    test    rax, rax
    jnz     .failed
    test    r14d, r14d
    jnz     .redirect
    call    rw_grow_directory
    test    rax, rax
    jnz     .failed
    mov     [rel create_inode], ebx
    mov     al, [rel move_type]
    mov     [rel create_type], al
    call    rw_publish
    jmp     .flush
.redirect:
    call    rw_redirect_move
.flush:
    test    rax, rax
    jnz     .failed
    call    ext_flush
    test    rax, rax
    jnz     .failed
    cmp     byte [rel move_type], 2
    jne     .unpublish
    cmp     r13d, [rel move_src_parent]
    je      .unpublish
    call    rw_set_move_dotdot
    test    rax, rax
    jnz     .failed
    test    r14d, r14d
    jnz     .unpublish
    mov     edi, r13d
    mov     esi, 1
    call    rw_change_links
    test    rax, rax
    jnz     .failed
.unpublish:
    mov     eax, [rel move_src_parent]
    mov     [rel parent_inode], eax
    mov     eax, [rel move_src_block]
    mov     [rel target_block], eax
    mov     eax, [rel move_src_offset]
    mov     [rel target_offset], eax
    call    rw_unpublish
    test    rax, rax
    jnz     .failed
    cmp     byte [rel move_type], 2
    jne     .moved_inode
    cmp     r13d, [rel move_src_parent]
    jne     .parent_links
    cmp     byte [rel move_drop_dir], 0
    je      .moved_inode
.parent_links:
    mov     edi, [rel move_src_parent]
    mov     esi, -1
    call    rw_change_links
    test    rax, rax
    jnz     .failed
.moved_inode:
    mov     edi, ebx
    xor     esi, esi
    mov     edx, r15d
    call    rw_change_links_timestamp
    test    rax, rax
    jnz     .failed
    test    r14d, r14d
    jz      .ok
    mov     edi, r14d
    cmp     byte [rel move_drop_final], 0
    jne     .drop_inode
    mov     esi, -1
    mov     edx, r15d
    call    rw_change_links_timestamp
    jmp     .finish
.drop_inode:
    call    rw_drop_inode
.finish:
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
    lea     rax, [rel ext_move_type]
    jmp     .done
.needs_directory:
    lea     rax, [rel path_not_directory]
    jmp     .done
.busy:
    lea     rax, [rel ext_directory_busy]
    jmp     .done
.invalid:
    lea     rax, [rel rw_allocation_error]
    jmp     .done
.nonempty:
    lea     rax, [rel ext_directory_not_empty]
    jmp     .done
.link_limit:
    lea     rax, [rel ext_dir_link_limit]
    jmp     .done
.clock_error:
    lea     rax, [rel ext_move_clock]
.done:
    call    rw_free_plans
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; Validate the source's dot entries and reject descendant destinations.
; ebx = source inode, r13d = destination parent or zero for root.
rw_check_move_parents:
    push    r12
    push    r14
    sub     rsp, 8
    mov     edi, [rel move_dot_block]
    imul    rdi, [rbp + mount_volume.ext_sectors]
    lea     rsi, [rel write_sector_buffer]
    call    read_sector
    test    rax, rax
    jnz     .done
    lea     rdx, [rel write_sector_buffer]
    cmp     [rdx], ebx
    jne     .invalid
    cmp     word [rdx + 4], 12
    jne     .invalid
    cmp     byte [rdx + 6], 1
    jne     .invalid
    cmp     byte [rdx + 8], '.'
    jne     .invalid
    mov     eax, [rel move_src_parent]
    cmp     [rdx + 12], eax
    jne     .invalid
    cmp     byte [rdx + 18], 2
    jne     .invalid
    cmp     word [rdx + 20], '..'
    jne     .invalid
    mov     r12d, r13d
    mov     r14d, [rbp + mount_volume.ext_inodes]
.next:
    cmp     r12d, ebx
    je      .descendant
    test    r12d, r12d
    jz      .ok
    cmp     r12d, EXT_ROOT
    je      .ok
    dec     r14d
    jz      .invalid
    lea     rdi, [rel move_dotdot]
    mov     esi, r12d
    call    scan_dir
    test    rax, rax
    jnz     .done
    cmp     r12d, edx
    je      .invalid
    mov     r12d, edx
    jmp     .next
.ok:
    xor     eax, eax
    jmp     .done
.invalid:
    lea     rax, [rel rw_allocation_error]
    jmp     .done
.descendant:
    lea     rax, [rel ext_move_descendant]
.done:
    add     rsp, 8
    pop     r14
    pop     r12
    ret

rw_set_move_dotdot:
    push    rbx
    mov     ebx, [rel move_dot_block]
    imul    rbx, [rbp + mount_volume.ext_sectors]
    mov     rdi, rbx
    lea     rsi, [rel write_sector_buffer]
    call    read_sector
    test    rax, rax
    jnz     .done
    mov     [rel write_sector_buffer + 12], r13d
    mov     rdi, rbx
    lea     rsi, [rel write_sector_buffer]
    call    rw_write_sector
    test    rax, rax
    jnz     .done
    call    ext_flush
.done:
    pop     rbx
    ret

; ebx = new inode. Keep the existing destination name and record length.
rw_redirect_move:
    push    r12
    mov     r12d, [rel target_block]
    imul    r12, [rbp + mount_volume.ext_sectors]
    mov     eax, [rel target_offset]
    shr     eax, 9
    add     r12, rax
    mov     rdi, r12
    lea     rsi, [rel write_sector_buffer]
    call    read_sector
    test    rax, rax
    jnz     .done
    mov     eax, [rel target_offset]
    and     eax, BLOCK_SIZE - 1
    lea     rsi, [rel write_sector_buffer]
    mov     [rsi + rax], ebx
    test    dword [rbp + mount_volume.ext_features], EXT_FILETYPE
    jz      .write
    mov     dl, [rel move_type]
    cmp     eax, BLOCK_SIZE - 8
    ja      .cross_sector
    mov     [rsi + rax + 7], dl
.write:
    mov     rdi, r12
    call    rw_write_sector
    jmp     .done
.cross_sector:
    ; An aligned dirent may start in the final four bytes of a sector.
    ; Preserve the inode update while changing the type byte in the next one.
    add     r12, 1
    mov     rdi, r12
    lea     rsi, [rel xattr_sector]
    call    read_sector
    test    rax, rax
    jnz     .done
    mov     dl, [rel move_type]
    mov     [rel xattr_sector + 3], dl
    mov     rdi, r12
    lea     rsi, [rel xattr_sector]
    call    rw_write_sector
    test    rax, rax
    jnz     .done
    sub     r12, 1
    lea     rsi, [rel write_sector_buffer]
    jmp     .write
.done:
    pop     r12
    ret

section .rodata
move_dotdot: db "..", 0
ext_move_type: db "Incompatible ext2 move operands.", 10, 0
ext_move_descendant: db "Cannot move an ext2 directory into itself.", 10, 0
ext_move_clock: db "Ext2 move requires a valid UTC hardware clock.", 10, 0

section .bss
alignb 4
move_src_parent: resd 1
move_src_links: resd 1
move_src_block: resd 1
move_src_offset: resd 1
move_dot_block: resd 1
move_type: resb 1
move_drop_dir: resb 1
move_drop_final: resb 1
