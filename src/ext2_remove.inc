; Unlink the name before dropping links or reclaiming allocated storage.
section .text
global ext_rm
extern vfs_dir_busy, path_not_directory

; rdi = name, esi = parent inode, edx = require a directory.
ext_rm:
    mov     byte [rel create_resize], 0
    push    rbx
    push    r12
    sub     rsp, 8
    mov     r12d, edx
    cmp     byte [rbp + mount_volume.read_only], 0
    jne     .readonly
    cmp     byte [rbp + mount_volume.write_error], 0
    jne     .blocked
    call    rw_prepare_target
    test    rax, rax
    jnz     .error
    mov     ebx, [rel target_inode]
    test    ebx, ebx
    jz      .missing
    test    dword [rel dir_inode + ext_inode.flags], EXT_PROTECTED_FLAGS
    jnz     .blocked
    cmp     ebx, [rbp + mount_volume.ext_first_inode]
    jb      .invalid
    mov     edi, ebx
    lea     rsi, [rel entry_inode]
    call    load_inode
    test    rax, rax
    jnz     .error
    test    dword [rel entry_inode + ext_inode.flags], EXT_PROTECTED_FLAGS
    jnz     .blocked
    mov     eax, [rel entry_inode + ext_inode.links]
    mov     [rel remove_links], eax
    mov     dword [rel reclaim_xattr], 0
    mov     dword [rel reclaim_inode], 0
    mov     byte [rel reclaim_is_dir], 0
    cmp     dword [rel entry_inode + ext_inode.mode], EXT_DIR
    je      .directory
    test    r12d, r12d
    jnz     .not_directory
    cmp     dword [rel entry_inode + ext_inode.mode], EXT_SYMLINK
    je      .link
    cmp     dword [rel entry_inode + ext_inode.mode], EXT_REG
    jne     .wrong_type
    cmp     eax, 1
    jne     .references
    jmp     .collect
.link:
    cmp     eax, 1
    jne     .references
    mov     [rel reclaim_inode], ebx
    mov     edi, ebx
    call    rw_read_inode_sector
    test    rax, rax
    jnz     .error
    mov     eax, [rcx + 28]
    cmp     dword [rcx + 104], 0
    je      .link_data
    sub     eax, [rbp + mount_volume.ext_sectors]
.link_data:
    test    eax, eax
    jnz     .collect
    mov     dword [rel reclaim_count], 0
    jmp     .attributes
.directory:
    mov     byte [rel reclaim_is_dir], 1
    cmp     dword [rel dir_inode + ext_inode.links], 2
    jbe     .invalid
    mov     edi, ebx
    call    vfs_dir_busy
    test    eax, eax
    jnz     .busy
    mov     edi, ebx
    mov     esi, -2
    call    rw_dir_count
    test    rax, rax
    jnz     .error
.collect:
    mov     [rel reclaim_inode], ebx
    call    rw_collect_blocks
    test    rax, rax
    jnz     .error
.attributes:
    mov     edi, ebx
    call    rw_plan_xattr_release
    test    rax, rax
    jnz     .error
.references:
    call    rw_scan_references
    test    rax, rax
    jnz     .error
    cmp     dword [rel reclaim_inode], 0
    jne     .unlink
    call    rtc_unix_seconds
    jc      .clock_error
    mov     r12d, eax
.unlink:
    call    rw_unpublish
    test    rax, rax
    jnz     .write_error
    cmp     byte [rel reclaim_is_dir], 0
    je      .regular
    mov     edi, [rel parent_inode]
    mov     esi, -1
    call    rw_change_links
    test    rax, rax
    jnz     .write_error
    jmp     .final
.regular:
    cmp     dword [rel reclaim_inode], 0
    jne     .final
    mov     edi, ebx
    mov     esi, -1
    mov     edx, r12d
    call    rw_change_links_timestamp
    test    rax, rax
    jnz     .write_error
    jmp     .saved
.final:
    mov     edi, ebx
    call    rw_drop_inode
    test    rax, rax
    jnz     .write_error
.saved:
    lea     rdi, [rel ext_removed]
    jmp     .print
.write_error:
    mov     byte [rbp + mount_volume.write_error], 1
.error:
    mov     rdi, rax
.print:
    push    rdi
    call    rw_free_plans
    pop     rdi
    add     rsp, 8
    pop     r12
    pop     rbx
    jmp     console_write_cstr
.clock_error:
    lea     rax, [rel ext_unlink_clock_error]
    jmp     .error
.readonly:
    lea     rax, [rel ext_readonly_error]
    jmp     .error
.blocked:
    lea     rax, [rel ext_write_blocked]
    jmp     .error
.missing:
    lea     rax, [rel missing_entry]
    jmp     .error
.busy:
    lea     rax, [rel ext_directory_busy]
    jmp     .error
.not_directory:
    lea     rax, [rel path_not_directory]
    jmp     .error
.wrong_type:
    lea     rax, [rel ext_remove_type]
    jmp     .error
.invalid:
    lea     rax, [rel rw_allocation_error]
    jmp     .error

rw_drop_inode:
    sub     rsp, 8
    call    rw_read_inode_sector
    test    rax, rax
    jnz     .done
    mov     rdi, rcx
    mov     ecx, [rbp + mount_volume.ext_inode_size]
    xor     eax, eax
    rep     stosb
    call    rw_save_inode_sector
    test    rax, rax
    jnz     .done
    call    ext_flush
    test    rax, rax
    jnz     .done
    call    rw_release_xattr
    test    rax, rax
    jnz     .done
    call    rw_reclaim
.done:
    add     rsp, 8
    ret

rw_unpublish:
    push    rbx
    call    rw_clear_parent_index
    test    rax, rax
    jnz     .done
    mov     ebx, [rel target_block]
    imul    rbx, [rbp + mount_volume.ext_sectors]
    mov     eax, [rel target_offset]
    shr     eax, 9
    add     rbx, rax
    mov     rdi, rbx
    lea     rsi, [rel write_sector_buffer]
    call    read_sector
    test    rax, rax
    jnz     .done
    mov     eax, [rel target_offset]
    and     eax, BLOCK_SIZE - 1
    lea     rsi, [rel write_sector_buffer]
    mov     dword [rsi + rax], 0
    mov     rdi, rbx
    call    rw_write_sector
    test    rax, rax
    jnz     .done
    call    ext_flush
.done:
    pop     rbx
    ret

; Count references from the allocated inode set, including directories
; outside the current path. A surviving regular-file alias keeps its inode.
rw_scan_references:
    push    rbx
    mov     dword [rel reference_count], 0
    mov     byte [rel reference_dots], 0
    mov     ebx, EXT_ROOT
.next:
    test    bl, 63
    jnz     .allocated
    call    ip_checkpoint
.allocated:
    mov     edi, ebx
    call    rw_test_inode
    test    rax, rax
    jnz     .done
    test    edx, edx
    jz      .advance
    mov     edi, ebx
    lea     rsi, [rel entry_inode]
    call    load_inode
    test    rax, rax
    jnz     .done
    cmp     dword [rel entry_inode + ext_inode.mode], EXT_DIR
    jne     .advance
    mov     [rel reference_directory], ebx
    mov     edi, ebx
    lea     rsi, [rel rw_reference_record]
    call    rw_walk_dir
    test    rax, rax
    jnz     .done
.advance:
    cmp     ebx, [rbp + mount_volume.ext_inodes]
    je      .finish
    cmp     ebx, EXT_ROOT
    jne     .next_inode
    mov     ebx, [rbp + mount_volume.ext_first_inode]
    jmp     .next
.next_inode:
    inc     ebx
    jmp     .next
.finish:
    mov     eax, [rel reference_count]
    cmp     eax, [rel remove_links]
    jne     .invalid
    cmp     byte [rel reclaim_is_dir], 0
    je      .ok
    cmp     byte [rel reference_dots], 3
    jne     .invalid
.ok:
    xor     eax, eax
    jmp     .done
.invalid:
    call    rw_invalid
.done:
    pop     rbx
    ret

rw_reference_record:
    mov     eax, [rdi]
    test    eax, eax
    jz      .ok
    mov     ecx, [rel target_inode]
    cmp     ecx, [rel reference_directory]
    je      .own_directory
    cmp     eax, ecx
    jne     .ok
    ; Dot entries outside the target are never an external file or
    ; directory name. For an empty target directory none may point to it.
    cmp     byte [rdi + 6], 1
    jne     .maybe_parent
    cmp     byte [rdi + 8], '.'
    je      .invalid
.maybe_parent:
    cmp     byte [rdi + 6], 2
    jne     .external
    cmp     word [rdi + 8], '..'
    je      .invalid
.external:
    cmp     byte [rel reclaim_is_dir], 0
    je      .count
    mov     eax, [rel parent_inode]
    cmp     eax, [rel reference_directory]
    jne     .invalid
    cmp     esi, [rel target_block]
    jne     .invalid
    cmp     edx, [rel target_offset]
    jne     .invalid
    jmp     .count
.own_directory:
    cmp     byte [rdi + 6], 1
    jne     .parent
    cmp     byte [rdi + 8], '.'
    jne     .nonempty
    cmp     eax, ecx
    jne     .invalid
    test    byte [rel reference_dots], 1
    jnz     .invalid
    or      byte [rel reference_dots], 1
    jmp     .count
.parent:
    cmp     byte [rdi + 6], 2
    jne     .nonempty
    cmp     word [rdi + 8], '..'
    jne     .nonempty
    cmp     eax, [rel parent_inode]
    jne     .invalid
    test    byte [rel reference_dots], 2
    jnz     .invalid
    or      byte [rel reference_dots], 2
    jmp     .ok
.count:
    mov     eax, [rel reference_count]
    inc     eax
    cmp     eax, [rel remove_links]
    ja      .invalid
    mov     [rel reference_count], eax
.ok:
    xor     eax, eax
    ret
.nonempty:
    lea     rax, [rel ext_directory_not_empty]
    ret
.invalid:
    jmp     rw_invalid

; Capture the old pointer list before changing the inode. The writable
; mount verifier has already proven exclusive ownership of these blocks.
rw_collect_blocks:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    xor     ebx, ebx
    xor     r13d, r13d
    mov     r14d, 1
    mov     dword [rel reclaim_count], 0
    lea     r12, [rel entry_inode + ext_inode.blocks]
.root:
    mov     edi, [r12 + rbx * 4]
    test    edi, edi
    jz      .next
    xor     esi, esi
    cmp     ebx, EXT_DIRECT
    jb      .capture
    lea     esi, [rbx - EXT_DIRECT + 1]
.capture:
    mov     edx, r13d
    mov     ecx, r14d
    call    rw_capture_tree
    test    rax, rax
    jnz     .done
.next:
    add     r13d, r14d
    inc     ebx
    cmp     ebx, 15
    jae     .ok
    cmp     ebx, EXT_DIRECT
    jb      .root
    imul    r14d, [rbp + mount_volume.ext_ptrs]
    jmp     .root
.ok:
    xor     eax, eax
.done:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; Capture children before their parent. A resize retains all whole data
; blocks before the tail and builds a new tree over those existing blocks.
rw_capture_tree:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     ebx, edi
    mov     r12d, esi
    mov     r15d, edx
    mov     [rsp], ecx
    call    rw_test_block
    test    rax, rax
    jnz     .done
    test    edx, edx
    jz      .invalid
    test    r12d, r12d
    jnz     .pointer
    cmp     byte [rel create_resize], 0
    je      .append
    cmp     r15d, [rel resize_boundary]
    jb      .done
    jmp     .append
.pointer:
    dec     r12d
    mov     eax, r12d
    shl     eax, 12
    lea     r13, [rel tree_data]
    add     r13, rax
    mov     edi, ebx
    mov     rsi, r13
    call    rw_read_block
    test    rax, rax
    jnz     .done
    mov     eax, [rsp]
    xor     edx, edx
    div     dword [rbp + mount_volume.ext_ptrs]
    mov     [rsp], eax
    mov     r14d, [rbp + mount_volume.ext_ptrs]
.next:
    mov     edi, [r13]
    test    edi, edi
    jz      .skip
    mov     esi, r12d
    mov     edx, r15d
    mov     ecx, [rsp]
    call    rw_capture_tree
    test    rax, rax
    jnz     .done
.skip:
    add     r13, 4
    add     r15d, [rsp]
    dec     r14d
    jnz     .next
.append:
    mov     esi, ebx
    call    rw_append_reclaim
    jmp     .done
.invalid:
    call    rw_invalid
.done:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

rw_append_reclaim:
    sub     rsp, 8
    lea     rdi, [rel reclaim_plan]
    call    ext_list_append
    add     rsp, 8
    test    rax, rax
    jnz     .done
    inc     dword [rel reclaim_count]
.done:
    ret

; Flush deallocation bits before updating the summary counts.
rw_reclaim:
    mov     eax, [rel reclaim_count]
    or      eax, [rel reclaim_inode]
    jz      .return
    sub     rsp, 8
    mov     edi, 1
    call    rw_release_records
    test    rax, rax
    jnz     .done
    call    ext_flush
    test    rax, rax
    jnz     .done
    mov     edi, 2
    call    rw_release_records
    test    rax, rax
    jnz     .done
    cmp     byte [rel reclaim_is_dir], 0
    je      .super
    mov     edi, [rel reclaim_inode]
    mov     esi, -1
    call    rw_dir_count
    test    rax, rax
    jnz     .done
.super:
    mov     edi, [rel reclaim_count]
    xor     esi, esi
    cmp     dword [rel reclaim_inode], 0
    setne   sil
    call    rw_adjust_super
    test    rax, rax
    jnz     .done
    call    ext_flush
.done:
    add     rsp, 8
.return:
    ret

rw_release_records:
    push    rbx
    push    r12
    push    r13
    mov     r13d, edi
    mov     r12d, [rel reclaim_count]
    cmp     r12d, EXT_DIRECT + 1
    jbe     .individual
    lea     rdi, [rel reclaim_plan]
    mov     esi, r12d
    mov     edx, r13d
    call    rw_apply_block_runs
    test    rax, rax
    jnz     .done
    jmp     .inode
.individual:
    mov     rax, [rel reclaim_plan + ext_list_state.head]
    lea     rbx, [rax + 8]
.block:
    test    r12d, r12d
    jz      .inode
    mov     eax, [rbx]
    add     rbx, 4
    test    ebx, PAGE_SIZE - 1
    jnz     .sector
    mov     rbx, [rbx - PAGE_SIZE]
    add     rbx, 8
.sector:
    xor     esi, esi
    mov     edx, r13d
    call    rw_change_bit
    test    rax, rax
    jnz     .done
    dec     r12d
    jmp     .block
.inode:
    mov     eax, [rel reclaim_inode]
    test    eax, eax
    jz      .done
    dec     eax
    mov     esi, 1
    mov     edx, r13d
    call    rw_change_bit
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

section .rodata
ext_remove_type: db "Expected a regular file or an empty ext2 directory.", 10, 0
ext_directory_busy: db "Ext2 directory is in use.", 10, 0
ext_directory_not_empty: db "Ext2 directory is not empty.", 10, 0
ext_unlink_clock_error: db "Unlinking an ext2 hard link requires a valid UTC hardware clock.", 10, 0
ext_removed: db "Ext2 entry removed.", 10, 0

section .bss
alignb 4
reclaim_count: resd 1
reclaim_inode: resd 1
remove_links: resd 1
reference_count: resd 1
reference_directory: resd 1
reference_dots: resb 1
reclaim_is_dir: resb 1
