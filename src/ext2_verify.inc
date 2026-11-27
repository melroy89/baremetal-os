; Validate the allocation maps and establish unique block ownership before a
; writable mount. All scratch is disposable and only used by the boot CPU.
%define EXT_SPARSE_SUPER (1 << 16)
%define SEEN_BYTES (PAGE_SIZE - 16)
%define SEEN_BITS (SEEN_BYTES * 8)

section .text

ext_verify_allocations:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    xor     r12d, r12d
    xor     r13d, r13d
    call    rw_drop_cache
    mov     eax, [rbp + mount_volume.ext_first_inode]
    cmp     eax, 11
    jb      .invalid
    cmp     eax, [rbp + mount_volume.ext_inodes]
    ja      .invalid
    xor     ebx, ebx
.groups:
    mov     edi, ebx
    call    rw_load_group
    test    rax, rax
    jnz     .finish
    call    verify_group
    test    rax, rax
    jnz     .finish
    add     r12d, [rel group_free_blocks]
    add     r13d, [rel group_free_inodes]
    inc     ebx
    cmp     ebx, [rbp + mount_volume.ext_groups]
    jb      .groups

    mov     edi, 2
    lea     rsi, [rel verify_sector]
    call    read_sector
    test    rax, rax
    jnz     .finish
    cmp     r12d, [rel verify_sector + 12]
    jne     .invalid
    cmp     r13d, [rel verify_sector + 16]
    jne     .invalid

    mov     ebx, 1
    xor     r13d, r13d
    mov     r14d, [rbp + mount_volume.ext_inodes_group]
.inodes:
    mov     edi, ebx
    call    rw_test_inode
    test    rax, rax
    jnz     .finish
    test    edx, edx
    jz      .next_inode
    mov     edi, ebx
    call    verify_inode
    test    rax, rax
    jnz     .finish
    add     r13d, edx
.next_inode:
    test    ebx, 1023
    jnz     .advance
    call    ip_checkpoint
.advance:
    dec     r14d
    jz      .count_dirs
    cmp     ebx, [rbp + mount_volume.ext_inodes]
    jb      .next
.count_dirs:
    lea     eax, [rbx - 1]
    xor     edx, edx
    div     dword [rbp + mount_volume.ext_inodes_group]
    mov     edi, eax
    call    rw_load_group
    test    rax, rax
    jnz     .finish
    cmp     r13d, [rel group_used_dirs]
    jne     .invalid
    cmp     ebx, [rbp + mount_volume.ext_inodes]
    jae     .ok
    xor     r13d, r13d
    mov     r14d, [rbp + mount_volume.ext_inodes_group]
.next:
    inc     ebx
    jmp     .inodes
.ok:
    xor     eax, eax
    jmp     .finish
.invalid:
    lea     rax, [rel rw_allocation_error]
.finish:
    mov     r12, rax
.free:
    mov     rdi, [rel seen_head]
    test    rdi, rdi
    jz      .done
    mov     rax, [rdi]
    mov     [rel seen_head], rax
    call    page_free
    jmp     .free
.done:
    mov     qword [rel seen_recent], 0
    mov     rax, r12
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; Verify per-group free counts and reserve all metadata as already owned.
verify_group:
    push    rbx
    push    r12
    push    r13
    mov     edi, [rel group_number]
    call    rw_load_block_bitmap
    test    rax, rax
    jnz     .done
    mov     edi, [rel group_number]
    call    rw_load_inode_bitmap
    test    rax, rax
    jnz     .done
    lea     rdi, [rel block_bitmap]
    mov     esi, [rel group_blocks]
    mov     edx, [rbp + mount_volume.ext_blocks_group]
    call    count_free
    jc      .invalid
    cmp     eax, [rel group_free_blocks]
    jne     .invalid
    lea     rdi, [rel inode_bitmap]
    mov     esi, [rel group_inodes]
    mov     edx, [rbp + mount_volume.ext_inodes_group]
    call    count_free
    jc      .invalid
    cmp     eax, [rel group_free_inodes]
    jne     .invalid

    mov     ebx, [rel group_start]
    mov     r12d, [rel group_reserved]
    mov     edi, ebx
    mov     esi, r12d
    call    verify_reserved_range
    test    rax, rax
    jnz     .done
    mov     edi, [rel group_blockmap]
    mov     esi, 1
    call    verify_reserved_range
    test    rax, rax
    jnz     .done
    mov     edi, [rel group_inodemap]
    mov     esi, 1
    call    verify_reserved_range
    test    rax, rax
    jnz     .done
    mov     edi, [rel group_table]
    mov     esi, [rbp + mount_volume.ext_inode_blocks]
    call    verify_reserved_range
    test    rax, rax
    jnz     .done
    cmp     dword [rel group_number], 0
    jne     .done
    mov     ecx, [rbp + mount_volume.ext_first_inode]
    dec     ecx
    cmp     ecx, [rel group_inodes]
    ja      .invalid
    lea     r13, [rel inode_bitmap]
.reserved_inode:
    dec     ecx
    bt      dword [r13], ecx
    jnc     .invalid
    test    ecx, ecx
    jnz     .reserved_inode
    jmp     .done
.invalid:
    lea     rax, [rel rw_allocation_error]
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; rdi = bitmap, esi = valid bits, edx = group capacity. Out-of-volume bits
; inside the group must be in use. Return free count and CF on violation.
count_free:
    xor     ecx, ecx
    xor     eax, eax
.next:
    cmp     ecx, esi
    jae     .padding
    bt      dword [rdi], ecx
    jc      .allocated
    inc     eax
.allocated:
    inc     ecx
    jmp     .next
.padding:
    cmp     ecx, edx
    jae     .ok
    bt      dword [rdi], ecx
    jnc     .bad
    inc     ecx
    jmp     .padding
.ok:
    clc
    ret
.bad:
    stc
    ret

verify_reserved_range:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
.next:
    xor     eax, eax
    test    r12d, r12d
    jz      .done
    mov     edi, ebx
    call    verify_owned_block
    test    rax, rax
    jnz     .done
    inc     ebx
    dec     r12d
    jmp     .next
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; Do not let allocated inodes point at reserved metadata or one another's
; blocks. Inline symlinks and special inodes have no disk block pointers.
verify_inode:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    call    rw_inode_location
    test    rax, rax
    jnz     .done
    mov     r12d, ecx
    mov     rdi, rdx
    lea     rsi, [rel verify_sector]
    call    read_sector
    test    rax, rax
    jnz     .done
    lea     rax, [rel verify_sector]
    add     r12, rax
    cmp     dword [r12 + 104], 0      ; External EA block is outside this profile.
    jne     .bad
    movzx   r13d, word [r12]
    and     r13d, 0xF000
    cmp     ebx, EXT_ROOT
    je      .normal
    cmp     ebx, [rbp + mount_volume.ext_first_inode]
    jae     .normal
    cmp     word [r12], 0
    jne     .bad
    cmp     dword [r12 + 28], 0
    jne     .bad                     ; Includes a populated bad-block inode.
    lea     rdi, [r12 + 40]
    mov     ecx, 15
    xor     eax, eax
    repe    scasd
    jne     .bad
    jmp     .ok
.normal:
    cmp     word [r12 + 26], 0
    je      .bad
    cmp     dword [r12 + 20], 0
    jne     .bad
    test    dword [r12 + 32], 0x10081C04
    jnz     .bad
    cmp     r13d, EXT_REG
    je      .pointers
    cmp     r13d, EXT_DIR
    je      .pointers
    cmp     r13d, 0xA000
    je      .symlink
    cmp     r13d, 0x1000
    je      .special
    cmp     r13d, 0x2000
    je      .special
    cmp     r13d, 0x6000
    je      .special
    cmp     r13d, 0xC000
    jne     .bad
.special:
    cmp     dword [r12 + 28], 0
    jne     .bad
    jmp     .ok
.symlink:
    cmp     dword [r12 + 28], 0
    jne     .pointers
    cmp     dword [r12 + 4], 60
    ja      .bad
    jmp     .ok
.pointers:
    mov     dword [rel inode_owned_blocks], 0
    xor     r14d, r14d
.pointer:
    mov     edi, [r12 + r14 * 4 + 40]
    test    edi, edi
    jz      .next
    xor     esi, esi
    cmp     r14d, 12
    jb      .walk
    lea     esi, [r14 - 11]
.walk:
    call    verify_block_tree
    test    rax, rax
    jnz     .done
.next:
    inc     r14d
    cmp     r14d, 15
    jb      .pointer
    mov     eax, [rel inode_owned_blocks]
    cmp     eax, 0xFFFFFFFF / EXT_SECTORS
    ja      .bad
    imul    eax, EXT_SECTORS
    cmp     eax, [r12 + 28]
    jne     .bad
    cmp     r13d, EXT_DIR
    jne     .ok

    mov     edi, ebx
    call    directory_inode
    test    rax, rax
    jnz     .done
    xor     r14d, r14d
.dir_block:
    mov     rax, [rel dir_inode + ext_inode.size]
    shr     rax, 12
    cmp     r14, rax
    jae     .directory_ok
    mov     rdi, r14
    lea     rsi, [rel dir_inode]
    call    map_block
    test    rax, rax
    jnz     .done
    test    edx, edx
    jz      .bad
    mov     edi, edx
    lea     rsi, [rel dir_data]
    call    rw_read_block
    test    rax, rax
    jnz     .done
    lea     r15, [rel dir_data]
    lea     r13, [r15 + EXT_BLOCK]
.dir_entry:
    movzx   eax, word [r15 + 4]
    cmp     eax, 8
    jb      .bad
    test    eax, 3
    jnz     .bad
    lea     r12, [r15 + rax]
    cmp     r12, r13
    ja      .bad
    mov     edi, [r15]
    test    edi, edi
    jz      .dir_next
    movzx   ecx, byte [r15 + 6]
    test    ecx, ecx
    jz      .bad
    add     ecx, 8
    cmp     ecx, eax
    ja      .bad
    call    rw_test_inode
    test    rax, rax
    jnz     .done
    test    edx, edx
    jz      .bad
.dir_next:
    mov     r15, r12
    cmp     r15, r13
    jb      .dir_entry
    inc     r14
    jmp     .dir_block
.directory_ok:
    mov     edx, 1
    xor     eax, eax
    jmp     .done
.ok:
    xor     edx, edx
    xor     eax, eax
    jmp     .done
.bad:
    lea     rax, [rel rw_allocation_error]
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; Maximum depth is three. Use a distinct buffer for each indirect level.
verify_block_tree:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    call    verify_owned_block
    test    rax, rax
    jnz     .done
    inc     dword [rel inode_owned_blocks]
    test    r12d, r12d
    jz      .done
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
    mov     ebx, EXT_PTRS
.next:
    mov     edi, [r13]
    test    edi, edi
    jz      .advance
    mov     esi, r12d
    call    verify_block_tree
    test    rax, rax
    jnz     .done
.advance:
    add     r13, 4
    dec     ebx
    jnz     .next
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

verify_owned_block:
    push    rbx
    mov     ebx, edi
    call    rw_test_block
    test    rax, rax
    jnz     .done
    test    edx, edx
    jz      .bad
    mov     edi, ebx
    call    seen_mark
    jmp     .done
.bad:
    lea     rax, [rel rw_allocation_error]
.done:
    pop     rbx
    ret

; Split the ownership bitmap into allocated pages, each containing a link,
; an index, and the bits for one range. Cache the most recent range.
seen_mark:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     eax, edi
    xor     edx, edx
    mov     ecx, SEEN_BITS
    div     ecx
    mov     ebx, eax
    mov     r12d, edx
    mov     rdx, [rel seen_recent]
    test    rdx, rdx
    jz      .head
    cmp     ebx, [rdx + 8]
    je      .mark
.head:
    mov     rdx, [rel seen_head]
.search:
    test    rdx, rdx
    jz      .allocate
    cmp     ebx, [rdx + 8]
    je      .mark
    mov     rdx, [rdx]
    jmp     .search
.allocate:
    call    page_alloc
    test    rax, rax
    jz      .no_pages
    mov     rdx, rax
    mov     rdi, rax
    xor     eax, eax
    mov     ecx, PAGE_SIZE / 8
    rep     stosq
    mov     rax, [rel seen_head]
    mov     [rdx], rax
    mov     [rdx + 8], ebx
    mov     [rel seen_head], rdx
.mark:
    mov     [rel seen_recent], rdx
    bts     dword [rdx + 16], r12d
    jc      .duplicate
    xor     eax, eax
    jmp     .done
.duplicate:
    lea     rax, [rel rw_allocation_error]
    jmp     .done
.no_pages:
    lea     rax, [rel rw_memory_error]
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

section .rodata
rw_allocation_error: db "Ext2 allocation or ownership could not be verified.", 10, 0
rw_memory_error: db "Not enough memory to verify ext2 ownership.", 10, 0

section .bss
alignb 8
seen_head: resq 1
seen_recent: resq 1
inode_owned_blocks: resd 1
verify_sector: resb BLOCK_SIZE
tree_data: resb 3 * EXT_BLOCK
