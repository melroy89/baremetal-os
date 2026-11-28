; Map allocated source blocks to destination logical blocks. This traversal
; skips entire missing subtrees and only records allocated destination ranges.
section .text
rw_plan_sparse:
    push    rbx
    push    r12
    push    r14
    push    r15
    sub     rsp, 8
    mov     dword [rel sparse_count], 0
    mov     dword [rel resize_tail], -1
    mov     rax, [rel file_inode + ext_inode.size]
    cmp     rax, [rel create_size]
    cmova   rax, [rel create_size]
    mov     [rel sparse_source_size], rax
    ext_block_index rax
    mov     [rel resize_boundary], eax
    mov     dword [rel sparse_last], -1
    mov     r15, [rel file_volume]
    mov     r14, [r15 + mount_volume.ext_block_size]
    xor     ebx, ebx
    xor     r12d, r12d
.next:
    cmp     r12, [rel sparse_source_size]
    jae     .count
    lea     rax, [rel file_inode + ext_inode.blocks]
    mov     edi, [rax + rbx * 4]
    test    edi, edi
    jz      .advance
    xor     esi, esi
    cmp     ebx, EXT_DIRECT
    jb      .scan
    lea     esi, [rbx - EXT_DIRECT + 1]
.scan:
    mov     rdx, r12
    call    rw_sparse_scan_tree
    test    rax, rax
    jnz     .done
.advance:
    add     r12, r14
    inc     ebx
    cmp     ebx, 15
    jae     .count
    cmp     ebx, EXT_DIRECT
    jb      .next
    mov     eax, [r15 + mount_volume.ext_ptrs]
    imul    r14, rax
    jmp     .next
.count:
    mov     byte [rel sparse_write], 0
    mov     dword [rel sparse_metadata], 0
    call    rw_sparse_mapping
    test    rax, rax
    jnz     .done
    mov     eax, [rel sparse_metadata]
    test    eax, eax
    setnz   byte [rel create_has_pointers]
    mov     ecx, [rel sparse_count]
    cmp     byte [rel create_resize], 0
    je      .allocation
    xor     ecx, ecx
    cmp     dword [rel resize_tail], -1
    setne   cl
.allocation:
    mov     [rel create_block_count], ecx
    add     eax, ecx
    mov     [rel create_owned_count], eax
    mov     eax, [rel sparse_count]
    add     eax, [rel sparse_metadata]
    imul    rax, [rbp + mount_volume.ext_sectors]
    shr     rax, 32
    jz      .done
    lea     rax, [rel ext_write_large]
.done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r12
    pop     rbx
    ret

; rdi = physical source block, esi = depth, rdx = source byte offset,
; r14 = byte span, r15 = source mount. rbp remains the destination.
rw_sparse_scan_tree:
    cmp     edi, [r15 + mount_volume.ext_blocks]
    jae     .invalid
    cmp     rdx, [rel sparse_source_size]
    jae     .empty
    test    esi, esi
    jz      rw_sparse_emit
    push    rbx
    push    r12
    push    r13
    push    r14
    push    rbp
    mov     r12, rdx
    mov     ebx, esi
    dec     ebx
    mov     eax, ebx
    shl     eax, 12
    lea     r13, [rel tree_data]
    add     r13, rax
    mov     rbp, r15
    mov     rsi, r13
    call    rw_read_block
    mov     rbp, [rsp]
    test    rax, rax
    jnz     .done
    mov     rax, r14
    xor     edx, edx
    mov     ecx, [r15 + mount_volume.ext_ptrs]
    div     rcx
    mov     r14, rax
    xor     ecx, ecx
.child:
    mov     edi, [r13 + rcx * 4]
    test    edi, edi
    jz      .advance
    mov     esi, ebx
    mov     rdx, r12
    push    rcx
    sub     rsp, 8
    call    rw_sparse_scan_tree
    add     rsp, 8
    pop     rcx
    test    rax, rax
    jnz     .done
.advance:
    add     r12, r14
    inc     ecx
    cmp     ecx, [r15 + mount_volume.ext_ptrs]
    jb      .child
    xor     eax, eax
.done:
    pop     rbp
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.empty:
    xor     eax, eax
    ret
.invalid:
    lea     rax, [rel corrupt_text]
    ret

; One allocated source extent covers one or more destination blocks.
rw_sparse_emit:
    push    rbx
    push    r12
    push    r13
    mov     r13d, edi
    mov     rbx, rdx
    lea     r12, [rdx + r14]
    cmp     r12, [rel sparse_source_size]
    cmova   r12, [rel sparse_source_size]
    dec     r12
    ext_block_index rbx
    ext_block_index r12
.next:
    cmp     ebx, [rel sparse_last]
    je      .advance
    lea     rdi, [rel sparse_plan]
    mov     esi, ebx
    call    ext_list_append
    test    rax, rax
    jnz     .done
    mov     [rel sparse_last], ebx
    inc     dword [rel sparse_count]
    cmp     byte [rel create_resize], 0
    je      .advance
    lea     rdi, [rel resize_data]
    mov     esi, r13d
    call    ext_list_append
    test    rax, rax
    jnz     .done
    cmp     ebx, [rel resize_boundary]
    jne     .advance
    mov     [rel resize_tail], ebx
.advance:
    inc     ebx
    cmp     ebx, r12d
    jbe     .next
    xor     eax, eax
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

rw_write_sparse_mapping:
    push    rax
    mov     byte [rel sparse_write], 1
    mov     rax, [rel create_plan + ext_list_state.head]
    add     rax, 8
    mov     [rel tree_data_cursor], rax
    mov     rax, [rel resize_data + ext_list_state.head]
    add     rax, 8
    mov     [rel resize_data_cursor], rax
    cmp     dword [rel sparse_metadata], 0
    je      .walk
    lea     rdi, [rel create_plan]
    mov     esi, [rel create_block_count]
    call    ext_list_cursor
    mov     [rel tree_meta_cursor], rax
.walk:
    pop     rax
    jmp     rw_sparse_mapping

; The same traversal counts required pointer blocks before allocation and
; emits them after the payload is written. Holes consume no allocations.
rw_sparse_mapping:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     eax, [rel sparse_count]
    mov     [rel sparse_remaining], eax
    mov     rax, [rel sparse_plan + ext_list_state.head]
    add     rax, 8
    mov     [rel sparse_map_cursor], rax
    lea     r15, [rel create_roots]
    mov     rdi, r15
    mov     ecx, 15
    xor     eax, eax
    rep     stosd
    call    rw_sparse_next
    xor     ebx, ebx
    xor     r12d, r12d
    mov     r13d, 1
.root:
    mov     eax, [rel sparse_index]
    cmp     eax, -1
    je      .ok
    lea     edx, [r12 + r13]
    cmp     eax, edx
    jae     .advance
    cmp     ebx, EXT_DIRECT
    jae     .indirect
    call    rw_sparse_data_pointer
    jmp     .store
.indirect:
    lea     edi, [rbx - EXT_DIRECT + 1]
    mov     esi, r12d
    mov     edx, r13d
    call    rw_sparse_pointer_tree
    test    rax, rax
    jnz     .done
.store:
    mov     [r15 + rbx * 4], edx
.advance:
    add     r12d, r13d
    inc     ebx
    cmp     ebx, 15
    jae     .ok
    cmp     ebx, EXT_DIRECT
    jb      .root
    imul    r13d, [rbp + mount_volume.ext_ptrs]
    jmp     .root
.ok:
    xor     eax, eax
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; edi = depth, esi = subtree start block, edx = subtree span.
rw_sparse_pointer_tree:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    call    console_cancel_check
    test    rax, rax
    jnz     .done
    mov     ebx, edi
    mov     r12d, esi
    mov     [rsp], edx
    mov     eax, edx
    xor     edx, edx
    div     dword [rbp + mount_volume.ext_ptrs]
    mov     r13d, eax
    lea     eax, [rbx - 1]
    shl     eax, 12
    lea     r14, [rel tree_data]
    add     r14, rax
    mov     dword [rsp + 4], 0
    cmp     byte [rel sparse_write], 0
    je      .count
    lea     rdi, [rel tree_meta_cursor]
    call    ext_list_next
    mov     [rsp + 4], eax
    mov     rdi, r14
    mov     ecx, [rbp + mount_volume.ext_block_size]
    shr     ecx, 3
    xor     eax, eax
    rep     stosq
    jmp     .next
.count:
    inc     dword [rel sparse_metadata]
.next:
    mov     eax, [rel sparse_index]
    sub     eax, r12d
    cmp     eax, [rsp]
    jae     .write
    xor     edx, edx
    div     r13d
    mov     r15d, eax
    cmp     ebx, 1
    jne     .interior
    call    rw_sparse_data_pointer
    jmp     .store
.interior:
    lea     edi, [rbx - 1]
    imul    eax, r13d
    lea     esi, [r12 + rax]
    mov     edx, r13d
    call    rw_sparse_pointer_tree
    test    rax, rax
    jnz     .done
.store:
    cmp     byte [rel sparse_write], 0
    je      .next
    mov     [r14 + r15 * 4], edx
    jmp     .next
.write:
    xor     eax, eax
    cmp     byte [rel sparse_write], 0
    je      .result
    mov     edi, [rsp + 4]
    mov     rsi, r14
    call    rw_write_block
.result:
    mov     edx, [rsp + 4]
.done:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

rw_sparse_data_pointer:
    sub     rsp, 8
    xor     eax, eax
    cmp     byte [rel sparse_write], 0
    je      .next
    cmp     byte [rel create_resize], 0
    je      .new
    lea     rdi, [rel resize_data_cursor]
    call    ext_list_next
    mov     ecx, [rel sparse_index]
    cmp     ecx, [rel resize_tail]
    jne     .next
.new:
    lea     rdi, [rel tree_data_cursor]
    call    ext_list_next
.next:
    mov     [rsp], eax
    call    rw_sparse_next
    mov     edx, [rsp]
    add     rsp, 8
    ret

rw_sparse_next:
    mov     eax, -1
    cmp     dword [rel sparse_remaining], 0
    je      .save
    dec     dword [rel sparse_remaining]
    lea     rdi, [rel sparse_map_cursor]
    call    ext_list_next
.save:
    mov     [rel sparse_index], eax
    ret

section .bss
alignb 8
sparse_plan: resb ext_list_state_size
resize_data: resb ext_list_state_size
resize_data_cursor: resq 1
sparse_source_size: resq 1
sparse_payload_cursor: resq 1
sparse_payload_offset: resq 1
sparse_map_cursor: resq 1
sparse_metadata: resd 1
sparse_count: resd 1
resize_boundary: resd 1
resize_tail: resd 1
sparse_index: resd 1
sparse_remaining: resd 1
sparse_last: resd 1
sparse_write: resb 1

section .text
; A shrink needs no new disk blocks. Build the shorter map in memory,
; keeping only the one partially retained pointer path for later writes.
rw_plan_shrink:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    xor     eax, eax
    mov     dword [rel shrink_tail], eax
    mov     qword [rel shrink_tables], rax
    mov     dword [rel shrink_tables + 8], eax
    mov     dword [rel reclaim_count], eax
    mov     dword [rel reclaim_inode], eax
    mov     byte [rel reclaim_is_dir], al
    mov     byte [rel create_resize], al
    mov     dword [rel create_inode], eax
    mov     dword [rel create_block_count], eax
    mov     rax, [rel create_size]
    mov     ecx, [rbp + mount_volume.ext_block_mask]
    and     ecx, eax
    mov     [rel shrink_tail_offset], ecx
    ext_block_index rax
    mov     [rel shrink_limit], eax
    test    ecx, ecx
    jz      .roots
    inc     dword [rel shrink_limit]
    mov     rdi, rax
    lea     rsi, [rel entry_inode]
    call    map_block
    test    rax, rax
    jnz     .done
    mov     [rel shrink_tail], edx
.roots:
    lea     r12, [rel entry_inode + ext_inode.blocks]
    lea     r15, [rel create_roots]
    xor     ebx, ebx
    xor     r13d, r13d
    mov     r14d, 1
.next:
    mov     edi, [r12 + rbx * 4]
    xor     esi, esi
    cmp     ebx, EXT_DIRECT
    jb      .prune
    lea     esi, [rbx - EXT_DIRECT + 1]
.prune:
    mov     edx, r13d
    mov     ecx, r14d
    call    rw_prune_shrink_tree
    test    rax, rax
    jnz     .done
    mov     [r15 + rbx * 4], edx
    add     r13d, r14d
    inc     ebx
    cmp     ebx, 15
    jae     .account
    cmp     ebx, EXT_DIRECT
    jb      .next
    imul    r14d, [rbp + mount_volume.ext_ptrs]
    jmp     .next
.account:
    mov     eax, [rel entry_inode + ext_inode.data_sectors]
    xor     edx, edx
    div     dword [rbp + mount_volume.ext_sectors]
    sub     eax, [rel reclaim_count]
    jc      .invalid
    mov     [rel create_owned_count], eax
    xor     eax, eax
    jmp     .done
.invalid:
    call    rw_invalid
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; edi = physical block, esi = depth, edx = logical start, ecx = span.
; Return the retained block (or zero) in edx.
rw_prune_shrink_tree:
    test    edi, edi
    jz      .empty
    cmp     edx, [rel shrink_limit]
    jae     .detach
    lea     eax, [rdx + rcx]
    cmp     eax, [rel shrink_limit]
    jbe     .keep
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     ebx, edi
    mov     r12d, esi
    dec     r12d
    mov     r14d, edx
    mov     eax, ecx
    xor     edx, edx
    div     dword [rbp + mount_volume.ext_ptrs]
    mov     [rsp], eax
    mov     dword [rsp + 4], 0
    mov     eax, r12d
    shl     eax, 12
    lea     r13, [rel shrink_tree]
    add     r13, rax
    mov     rsi, r13
    call    rw_read_block
    test    rax, rax
    jnz     .done
    mov     r15d, [rbp + mount_volume.ext_ptrs]
.child:
    mov     edi, [r13]
    mov     esi, r12d
    mov     edx, r14d
    mov     ecx, [rsp]
    call    rw_prune_shrink_tree
    test    rax, rax
    jnz     .done
    mov     [r13], edx
    or      [rsp + 4], edx
    add     r14d, [rsp]
    add     r13, 4
    dec     r15d
    jnz     .child
    cmp     dword [rsp + 4], 0
    je      .drop_parent
    lea     rdi, [rel shrink_tables]
    mov     [rdi + r12 * 4], ebx
    mov     edx, ebx
    jmp     .done
.drop_parent:
    mov     esi, ebx
    call    rw_append_reclaim
    xor     edx, edx
.done:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.detach:
    sub     rsp, 8
    call    rw_capture_tree
    add     rsp, 8
    xor     edx, edx
    ret
.empty:
    xor     eax, eax
    xor     edx, edx
    ret
.keep:
    mov     edx, edi
    xor     eax, eax
    ret

; Make the smaller size durable before touching bytes that were visible
; at the old size. Repair may restore the old extent while the old pointer
; table is still attached. Flush modified pointers before recycling blocks.
rw_publish_shrink:
    push    rbx
    mov     edi, [rel target_inode]
    call    rw_write_inode
    test    rax, rax
    jnz     .done
    call    ext_flush
    test    rax, rax
    jnz     .done
    xor     ebx, ebx
.table:
    lea     rax, [rel shrink_tables]
    mov     edi, [rax + rbx * 4]
    test    edi, edi
    jz      .next
    mov     eax, ebx
    shl     eax, 12
    lea     rsi, [rel shrink_tree]
    add     rsi, rax
    call    rw_write_block
    test    rax, rax
    jnz     .done
.next:
    inc     ebx
    cmp     ebx, 3
    jb      .table
    mov     ebx, [rel shrink_tail]
    test    ebx, ebx
    jz      .flush
    mov     edi, ebx
    lea     rsi, [rel dir_data]
    call    rw_read_block
    test    rax, rax
    jnz     .done
    mov     edx, [rel shrink_tail_offset]
    mov     ecx, [rbp + mount_volume.ext_block_size]
    sub     ecx, edx
    lea     rdi, [rel dir_data]
    add     rdi, rdx
    xor     eax, eax
    rep     stosb
    lea     rsi, [rel dir_data]
    mov     edi, ebx
    call    rw_write_block
    test    rax, rax
    jnz     .done
.flush:
    call    ext_flush
    test    rax, rax
    jnz     .done
    call    rw_reclaim
.done:
    pop     rbx
    ret

section .bss
alignb 8
shrink_tree: resb 3 * EXT_BLOCK
shrink_tables: resd 3
shrink_limit: resd 1
shrink_tail: resd 1
shrink_tail_offset: resd 1
