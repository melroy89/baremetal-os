; Block-number plans use bounded pages from the guest allocator. Each page
; contains a next pointer followed by packed 32-bit physical block numbers.
%define EXT_LIST_CAPACITY ((PAGE_SIZE - 8) / 4)
struc ext_list_state
    .head: resq 1
    .tail: resq 1
    .used: resd 1
    alignb 8
endstruc

section .text
; rdi = list, esi = block number. Return an error if the plan cannot grow.
ext_list_append:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    mov     rdx, [rbx + ext_list_state.tail]
    test    rdx, rdx
    jz      .new_page
    cmp     dword [rbx + ext_list_state.used], EXT_LIST_CAPACITY
    jb      .append
.new_page:
    call    page_alloc
    test    rax, rax
    jz      .full
    mov     qword [rax], 0
    mov     rdx, [rbx + ext_list_state.tail]
    test    rdx, rdx
    jnz     .link
    mov     [rbx + ext_list_state.head], rax
    jmp     .tail
.link:
    mov     [rdx], rax
.tail:
    mov     [rbx + ext_list_state.tail], rax
    mov     rdx, rax
    mov     dword [rbx + ext_list_state.used], 0
.append:
    mov     eax, [rbx + ext_list_state.used]
    mov     [rdx + 8 + rax * 4], r12d
    inc     dword [rbx + ext_list_state.used]
    xor     eax, eax
    jmp     .done
.full:
    lea     rax, [rel rw_memory_error]
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; rdi = list, esi = valid zero-based entry index. Return the entry address.
ext_list_cursor:
    mov     eax, esi
    xor     edx, edx
    mov     ecx, EXT_LIST_CAPACITY
    div     ecx
    mov     rcx, [rdi + ext_list_state.head]
.next:
    test    eax, eax
    jz      .entry
    mov     rcx, [rcx]
    dec     eax
    jmp     .next
.entry:
    lea     rax, [rcx + 8 + rdx * 4]
    ret

; rdi = cursor address. Read its block and advance to the next entry.
ext_list_next:
    mov     rcx, [rdi]
    mov     eax, [rcx]
    add     rcx, 4
    test    ecx, PAGE_SIZE - 1
    jnz     .save
    mov     rcx, [rcx - PAGE_SIZE]
    add     rcx, 8
.save:
    mov     [rdi], rcx
    ret

ext_list_free:
    push    rbx
    mov     rbx, rdi
.next:
    mov     rdi, [rbx + ext_list_state.head]
    test    rdi, rdi
    jz      .done
    mov     rax, [rdi]
    mov     [rbx + ext_list_state.head], rax
    call    page_free
    jmp     .next
.done:
    mov     qword [rbx + ext_list_state.tail], 0
    mov     dword [rbx + ext_list_state.used], 0
    pop     rbx
    ret

rw_free_plans:
    push    rax
    lea     rdi, [rel create_plan]
    call    ext_list_free
    lea     rdi, [rel reclaim_plan]
    call    ext_list_free
    lea     rdi, [rel sparse_plan]
    call    ext_list_free
    lea     rdi, [rel resize_data]
    call    ext_list_free
    pop     rax
    ret

; Data allocations precede pointer allocations. A separate cursor consumes
; each run. Only one block buffer per pointer depth is necessary.
rw_write_mapping:
    cmp     byte [rel create_sparse], 0
    jne     rw_write_sparse_mapping
    push    rbx
    push    r12
    push    r13
    lea     rdi, [rel create_roots]
    xor     eax, eax
    mov     ecx, 15
    rep     stosd
    mov     ebx, [rel create_block_count]
    test    ebx, ebx
    jz      .done
    mov     rax, [rel create_plan + ext_list_state.head]
    add     rax, 8
    mov     [rel tree_data_cursor], rax
    lea     r12, [rel create_roots]
    xor     r13d, r13d
.direct:
    lea     rdi, [rel tree_data_cursor]
    call    ext_list_next
    mov     [r12 + r13 * 4], eax
    inc     r13d
    dec     ebx
    jz      .ok
    cmp     r13d, EXT_DIRECT
    jb      .direct
    lea     rdi, [rel create_plan]
    mov     esi, [rel create_block_count]
    call    ext_list_cursor
    mov     [rel tree_meta_cursor], rax
.root:
    lea     edi, [r13 - EXT_DIRECT + 1]
    call    rw_write_pointer_tree
    test    rax, rax
    jnz     .done
    mov     [r12 + r13 * 4], edx
    inc     r13d
    test    ebx, ebx
    jnz     .root
.ok:
    xor     eax, eax
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; edi = depth, ebx = remaining data blocks. Consume at most one subtree.
; Return its physical root in edx and decrement ebx by the data consumed.
rw_write_pointer_tree:
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     r12d, edi
    lea     rax, [r12 - 1]
    shl     eax, 12                   ; Scratch stride, independent of volume.
    lea     r13, [rel tree_data]
    add     r13, rax
    lea     rdi, [rel tree_meta_cursor]
    call    ext_list_next
    mov     r14d, eax
    mov     rdi, r13
    mov     ecx, [rbp + mount_volume.ext_block_size]
    shr     ecx, 3
    xor     eax, eax
    rep     stosq
    xor     r15d, r15d
.child:
    cmp     r12d, 1
    jne     .interior
    lea     rdi, [rel tree_data_cursor]
    call    ext_list_next
    mov     edx, eax
    dec     ebx
    jmp     .store
.interior:
    lea     edi, [r12 - 1]
    call    rw_write_pointer_tree
    test    rax, rax
    jnz     .done
.store:
    mov     [r13 + r15 * 4], edx
    inc     r15d
    test    ebx, ebx
    jz      .write
    cmp     r15d, [rbp + mount_volume.ext_ptrs]
    jb      .child
.write:
    mov     edi, r14d
    mov     rsi, r13
    call    rw_write_block
    mov     edx, r14d
.done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

section .bss
alignb 8
create_plan: resb ext_list_state_size
reclaim_plan: resb ext_list_state_size
tree_data_cursor: resq 1
tree_meta_cursor: resq 1
create_roots: resd 15

section .text
; Identify and validate the pointer path for one append at EOF. Reserve
; workspace for a detached copy of the path before overwriting anything.
rw_plan_directory_path:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    sub     edi, EXT_DIRECT
    mov     r12d, edi
    mov     eax, [rbp + mount_volume.ext_ptrs]
    mov     r13d, eax
    mov     ebx, 1
    cmp     r12d, eax
    jb      .root
    sub     r12d, eax
    imul    eax, eax
    inc     ebx
    cmp     r12d, eax
    jb      .root
    sub     r12d, eax
    inc     ebx
.root:
    mov     [rel growth_depth], ebx
    lea     eax, [rbx + EXT_DIRECT - 1]
    mov     [rel growth_index], eax
    lea     rdx, [rel dir_inode + ext_inode.blocks]
    mov     r14d, [rdx + rax * 4]
.next:
    dec     ebx
    mov     eax, [rbp + mount_volume.ext_block_shift]
    sub     eax, 2
    imul    eax, ebx
    mov     ecx, eax
    mov     eax, r12d
    shr     eax, cl
    lea     edx, [r13 - 1]
    and     eax, edx
    lea     rdx, [rel growth_slots]
    mov     [rdx + rbx * 4], eax
    lea     rdx, [rel growth_old]
    mov     [rdx + rbx * 4], r14d
    test    r14d, r14d
    jz      .advance
    mov     edi, r14d
    call    rw_test_block
    test    rax, rax
    jnz     .done
    test    edx, edx
    jz      .invalid
    mov     edi, r14d
    lea     rsi, [rel tree_data]
    call    rw_read_block
    test    rax, rax
    jnz     .done
    lea     rdx, [rel growth_slots]
    mov     eax, [rdx + rbx * 4]
    lea     rdx, [rel tree_data]
    mov     r14d, [rdx + rax * 4]
    inc     dword [rel growth_old_count]
.advance:
    test    ebx, ebx
    jnz     .next
    test    r14d, r14d
    jnz     .invalid
    mov     eax, [rel growth_depth]
    inc     eax
    add     [rel create_total], eax
    ; Reserve reclaim workspace before the first write as well.
    xor     ebx, ebx
    mov     dword [rel reclaim_count], 0
    mov     dword [rel reclaim_inode], 0
    mov     byte [rel reclaim_is_dir], 0
.collect:
    cmp     ebx, [rel growth_depth]
    jae     .ok
    lea     rdx, [rel growth_old]
    mov     esi, [rdx + rbx * 4]
    test    esi, esi
    jz      .skip
    call    rw_append_reclaim
    test    rax, rax
    jnz     .done
.skip:
    inc     ebx
    jmp     .collect
.ok:
    xor     eax, eax
    jmp     .done
.invalid:
    call    rw_invalid
.done:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

rw_write_directory_path:
    push    rbx
    push    r12
    push    r13
    xor     ebx, ebx
    lea     r13, [rel tree_data]
.next:
    lea     rdx, [rel growth_old]
    mov     edi, [rdx + rbx * 4]
    test    edi, edi
    jz      .zero
    mov     rsi, r13
    call    rw_read_block
    test    rax, rax
    jnz     .done
    jmp     .store
.zero:
    mov     rdi, r13
    xor     eax, eax
    mov     ecx, [rbp + mount_volume.ext_block_size]
    shr     ecx, 3
    rep     stosq
.store:
    lea     rdx, [rel growth_slots]
    mov     ecx, [rdx + rbx * 4]
    mov     eax, [rel growth_root]
    mov     [r13 + rcx * 4], eax
    lea     esi, [rbx + 1]
    add     esi, [rel create_owned_count]
    lea     rdi, [rel create_plan]
    call    ext_list_cursor
    mov     r12d, [rax]
    mov     edi, r12d
    mov     rsi, r13
    call    rw_write_block
    test    rax, rax
    jnz     .done
    mov     eax, r12d
    xor     esi, esi
    xor     edx, edx
    call    rw_change_bit
    test    rax, rax
    jnz     .done
    mov     [rel growth_root], r12d
    inc     ebx
    cmp     ebx, [rel growth_depth]
    jb      .next
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

rw_release_directory_path:
    sub     rsp, 8
    call    rw_reclaim
    add     rsp, 8
    ret

section .bss
alignb 4
growth_depth: resd 1
growth_root: resd 1
growth_old_count: resd 1
growth_old: resd 3
growth_slots: resd 3

; Process runs of blocks from the same group using one bitmap and descriptor
; update. rdi = list, esi = length, edx = rw_change_bit operation.
section .text
rw_apply_block_runs:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     rax, [rdi + ext_list_state.head]
    add     rax, 8
    mov     [rsp], rax
    mov     r12d, esi
    mov     r13d, edx
.group:
    mov     rax, [rsp]
    mov     eax, [rax]
    sub     eax, [rbp + mount_volume.ext_first_data]
    jc      .invalid
    xor     edx, edx
    div     dword [rbp + mount_volume.ext_blocks_group]
    mov     edi, eax
    cmp     r13d, 2
    je      .geometry
    mov     dword [rel block_bitmap_group], -1
    call    rw_load_block_bitmap
    jmp     .loaded
.geometry:
    call    rw_load_group
.loaded:
    test    rax, rax
    jnz     .done
    xor     r14d, r14d
    lea     r15, [rel block_bitmap]
    mov     ebx, [rel group_start]
.entry:
    mov     rax, [rsp]
    mov     eax, [rax]
    sub     eax, ebx
    cmp     eax, [rel group_blocks]
    jae     .flush
    cmp     r13d, 2
    je      .advance
    test    r13d, r13d
    jnz     .remove
    bts     dword [r15], eax
    jc      .invalid
    jmp     .advance
.remove:
    btr     dword [r15], eax
    jnc     .invalid
.advance:
    mov     rdi, rsp
    call    ext_list_next
    inc     r14d
    dec     r12d
    jnz     .entry
.flush:
    cmp     r13d, 2
    je      .descriptor
    mov     edi, [rel group_blockmap]
    mov     rsi, r15
    call    rw_write_block
    test    rax, rax
    jnz     .done
    cmp     r13d, 1
    je      .next_group
.descriptor:
    mov     edi, [rel group_desc_sector]
    lea     rsi, [rel write_sector_buffer]
    call    read_sector
    test    rax, rax
    jnz     .done
    mov     eax, [rel group_desc_offset]
    lea     rsi, [rel write_sector_buffer]
    lea     rcx, [rsi + rax + 12]
    movzx   eax, word [rcx]
    test    r13d, r13d
    jnz     .release_count
    sub     eax, r14d
    jc      .invalid
    jmp     .store
.release_count:
    add     eax, r14d
    cmp     eax, [rel group_blocks]
    ja      .invalid
.store:
    mov     [rcx], ax
    mov     edi, [rel group_desc_sector]
    call    rw_write_sector
    test    rax, rax
    jnz     .done
.next_group:
    call    rw_drop_cache
    call    ip_checkpoint
    test    r12d, r12d
    jnz     .group
    xor     eax, eax
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
