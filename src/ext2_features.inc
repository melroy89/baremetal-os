; Optional Linux ext2 metadata supported by writable mounts.
section .text

; Inode 7 has a double-indirect root. Its descendants must be exactly the
; reserved GDT blocks already protected by verify_group.
verify_resize_inode:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    movzx   eax, word [r12]
    and     eax, 0xF000
    cmp     eax, EXT_REG
    jne     .invalid
    cmp     word [r12 + 26], 1
    jne     .invalid
    cmp     dword [r12 + 20], 0
    jne     .invalid
    cmp     dword [r12 + 32], 0
    jne     .invalid
    lea     rdi, [r12 + 40]
    xor     eax, eax
    mov     ecx, 13
    repe    scasd
    jne     .invalid
    cmp     dword [r12 + 96], 0
    jne     .invalid
    mov     eax, [r12 + 28]
    mov     [rel resize_sectors], rax
    mov     ebx, [r12 + 92]
    test    ebx, ebx
    jz      .invalid
    mov     edi, ebx
    call    verify_owned_block
    test    rax, rax
    jnz     .done
    mov     edi, ebx
    lea     rsi, [rel tree_data]
    call    rw_read_block
    test    rax, rax
    jnz     .done
    mov     r15d, 1
    xor     r13d, r13d
.primary:
    cmp     r13d, [rbp + mount_volume.ext_reserved_gdt]
    jae     .root_tail
    mov     ecx, [rbp + mount_volume.ext_gdt_blocks]
    add     ecx, r13d
    mov     r14d, [rbp + mount_volume.ext_first_data]
    lea     r14d, [r14 + rcx + 1]
    mov     eax, [rbp + mount_volume.ext_ptrs]
    dec     eax
    and     ecx, eax
    lea     rdi, [rel tree_data]
    cmp     [rdi + rcx * 4], r14d
    jne     .invalid
    mov     dword [rdi + rcx * 4], 0
    inc     r15d
    mov     edi, r14d
    lea     rsi, [rel tree_data + EXT_BLOCK]
    call    rw_read_block
    test    rax, rax
    jnz     .done
    mov     ebx, 1
    lea     r12, [rel tree_data + EXT_BLOCK]
.backups:
    cmp     ebx, [rbp + mount_volume.ext_groups]
    jae     .backup_tail
    mov     edi, ebx
    call    group_has_super
    test    eax, eax
    jz      .next_group
    lea     rax, [rel tree_data + EXT_BLOCK]
    add     rax, [rbp + mount_volume.ext_block_size]
    cmp     r12, rax
    jae     .invalid
    mov     eax, ebx
    imul    eax, [rbp + mount_volume.ext_blocks_group]
    add     eax, r14d
    cmp     [r12], eax
    jne     .invalid
    add     r12, 4
    inc     r15d
.next_group:
    inc     ebx
    jmp     .backups
.backup_tail:
    lea     rax, [rel tree_data + EXT_BLOCK]
    add     rax, [rbp + mount_volume.ext_block_size]
    sub     rax, r12
    shr     eax, 2
    mov     ecx, eax
    mov     rdi, r12
    xor     eax, eax
    repe    scasd
    jne     .invalid
    inc     r13d
    call    ip_checkpoint
    jmp     .primary
.root_tail:
    lea     rdi, [rel tree_data]
    mov     ecx, [rbp + mount_volume.ext_ptrs]
    xor     eax, eax
    repe    scasd
    jne     .invalid
    imul    r15, [rbp + mount_volume.ext_sectors]
    cmp     r15, [rel resize_sectors]
    jne     .invalid
    jmp     .done
.invalid:
    lea     rax, [rel rw_allocation_error]
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

section .bss
alignb 8
resize_sectors: resq 1

; Shared xattr blocks count as one owned block with multiple inode references.
%define XATTR_RECORD_BYTES 12
%define XATTR_PAGE_ENTRIES ((PAGE_SIZE - 16) / XATTR_RECORD_BYTES)
%define XATTR_REFCOUNT_MAX 1024

section .text
verify_xattr_reference:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12, [rel xattr_records]
.page:
    test    r12, r12
    jz      .first
    mov     ecx, [r12 + 8]
    lea     rdi, [r12 + 16]
.record:
    test    ecx, ecx
    jz      .next
    cmp     ebx, [rdi]
    je      .found
    add     rdi, XATTR_RECORD_BYTES
    dec     ecx
    jmp     .record
.next:
    mov     r12, [r12]
    jmp     .page
.found:
    mov     eax, [rdi + 4]
    cmp     eax, [rdi + 8]
    jae     .invalid
    inc     dword [rdi + 4]
    xor     eax, eax
    jmp     .done
.first:
    mov     edi, ebx
    call    verify_owned_block
    test    rax, rax
    jnz     .done
    mov     edi, ebx
    call    read_xattr_header
    test    rax, rax
    jnz     .done
    mov     r13d, [rel xattr_sector + 4]
    mov     r12, [rel xattr_records]
    test    r12, r12
    jz      .allocate
    cmp     dword [r12 + 8], XATTR_PAGE_ENTRIES
    jb      .add
.allocate:
    call    page_alloc
    test    rax, rax
    jz      .memory
    mov     [rax], r12
    mov     dword [rax + 8], 0
    mov     [rel xattr_records], rax
    mov     r12, rax
.add:
    mov     eax, [r12 + 8]
    imul    eax, XATTR_RECORD_BYTES
    lea     rdi, [r12 + rax + 16]
    mov     [rdi], ebx
    mov     dword [rdi + 4], 1
    mov     [rdi + 8], r13d
    inc     dword [r12 + 8]
    xor     eax, eax
    jmp     .done
.invalid:
    lea     rax, [rel rw_allocation_error]
    jmp     .done
.memory:
    lea     rax, [rel rw_memory_error]
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

verify_xattr_counts:
    mov     rdx, [rel xattr_records]
.page:
    test    rdx, rdx
    jz      .ok
    mov     ecx, [rdx + 8]
    lea     rdi, [rdx + 16]
.record:
    test    ecx, ecx
    jz      .next
    mov     eax, [rdi + 4]
    cmp     eax, [rdi + 8]
    jne     rw_invalid
    add     rdi, XATTR_RECORD_BYTES
    dec     ecx
    jmp     .record
.next:
    mov     rdx, [rdx]
    jmp     .page
.ok:
    xor     eax, eax
    ret

free_xattr_records:
    sub     rsp, 8
.next:
    mov     rdi, [rel xattr_records]
    test    rdi, rdi
    jz      .done
    mov     rax, [rdi]
    mov     [rel xattr_records], rax
    call    page_free
    jmp     .next
.done:
    add     rsp, 8
    ret

; edi = xattr block. Read only its header sector. Entry bytes are opaque.
read_xattr_header:
    sub     rsp, 8
    imul    rdi, [rbp + mount_volume.ext_sectors]
    lea     rsi, [rel xattr_sector]
    call    read_sector
    add     rsp, 8
    test    rax, rax
    jnz     .done
    cmp     dword [rel xattr_sector], 0xEA020000
    jne     rw_invalid
    cmp     dword [rel xattr_sector + 8], 1
    jne     rw_invalid
    mov     edx, [rel xattr_sector + 4]
    dec     edx
    cmp     edx, XATTR_REFCOUNT_MAX
    jae     rw_invalid
.done:
    ret

; edi = inode whose last directory reference is about to be removed.
rw_plan_xattr_release:
    push    rbx
    call    rw_read_inode_sector
    test    rax, rax
    jnz     .done
    mov     ebx, [rcx + 104]
    test    ebx, ebx
    jz      .done
    mov     edi, ebx
    call    read_xattr_header
    test    rax, rax
    jnz     .done
    test    edx, edx
    jnz     .shared
    mov     esi, ebx
    call    rw_append_reclaim
    jmp     .done
.shared:
    mov     [rel reclaim_xattr], ebx
.done:
    pop     rbx
    ret

; After publishing the inode removal, drop its external attribute reference.
rw_release_xattr:
    push    rbx
    xor     eax, eax
    mov     ebx, [rel reclaim_xattr]
    test    ebx, ebx
    jz      .done
    mov     edi, ebx
    call    read_xattr_header
    test    rax, rax
    jnz     .done
    test    edx, edx
    jz      .invalid
    mov     [rel xattr_sector + 4], edx
    mov     edi, ebx
    imul    rdi, [rbp + mount_volume.ext_sectors]
    lea     rsi, [rel xattr_sector]
    call    rw_write_sector
    test    rax, rax
    jnz     .done
    call    ext_flush
.done:
    pop     rbx
    ret
.invalid:
    call    rw_invalid
    jmp     .done

section .bss
alignb 8
xattr_records: resq 1
xattr_sector: resb BLOCK_SIZE
reclaim_xattr: resd 1

; The legacy HTree has a root and at most one level of interior nodes.
; A bounded bitmap requires every nonroot directory block to appear once.
%define DX_MAX_BLOCKS ((EXT_BLOCK / 8) * (EXT_BLOCK / 8) + 1)
section .text
verify_directory_index:
    test    dword [rbp + mount_volume.ext_compat], EXT_COMPAT_INDEX
    jz      .unsupported
    push    rbx
    push    r12
    mov     rax, [rel dir_inode + ext_inode.size]
    ext_block_index rax
    cmp     rax, 2
    jb      .invalid
    cmp     rax, DX_MAX_BLOCKS
    ja      .invalid
    mov     [rel dx_blocks], eax
    lea     ecx, [rax + 63]
    shr     ecx, 6
    lea     rdi, [rel dx_seen]
    xor     eax, eax
    rep     stosq
    mov     dword [rel dx_count], 1
    xor     edi, edi
    lea     r12, [rel dx_root]
    mov     rdx, r12
    call    read_index_block
    test    rax, rax
    jnz     .done
    cmp     word [r12 + 4], 12
    jne     .invalid
    cmp     byte [r12 + 6], 1
    jne     .invalid
    cmp     byte [r12 + 8], '.'
    jne     .invalid
    mov     eax, [rbp + mount_volume.ext_block_size]
    sub     eax, 12
    cmp     [r12 + 16], ax
    jne     .invalid
    cmp     byte [r12 + 18], 2
    jne     .invalid
    cmp     word [r12 + 20], '..'
    jne     .invalid
    cmp     dword [r12 + 24], 0
    jne     .invalid
    cmp     byte [r12 + 28], 5
    ja      .invalid
    cmp     byte [r12 + 29], 8
    jne     .invalid
    movzx   edx, byte [r12 + 30]
    cmp     edx, 1
    ja      .invalid
    cmp     byte [r12 + 31], 0
    jne     .invalid
    lea     rdi, [r12 + 32]
    mov     esi, [rbp + mount_volume.ext_block_size]
    sub     esi, 32
    call    verify_dx_entries
    test    rax, rax
    jnz     .done
    mov     eax, [rel dx_count]
    cmp     eax, [rel dx_blocks]
    jne     .invalid
    xor     eax, eax
    jmp     .done
.invalid:
    lea     rax, [rel indexed_directory]
.done:
    pop     r12
    pop     rbx
    ret
.unsupported:
    lea     rax, [rel indexed_directory]
    ret

; edi = directory logical block, rdx = block buffer.
read_index_block:
    push    rdx
    lea     rsi, [rel dir_inode]
    call    map_block
    pop     rsi
    test    rax, rax
    jnz     .done
    mov     edi, edx
    test    edi, edi
    jz      .invalid
    jmp     rw_read_block
.invalid:
    lea     rax, [rel indexed_directory]
.done:
    ret

; rdi = index entries, esi = available bytes, edx = interior depth.
verify_dx_entries:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13d, edx
    movzx   ebx, word [r12 + 2]
    shr     esi, 3
    cmp     [r12], si
    jne     .invalid
    test    ebx, ebx
    jz      .invalid
    cmp     ebx, esi
    ja      .invalid
    xor     r14d, r14d
.next:
    mov     edi, [r12 + 4]
    test    edi, edi
    jz      .invalid
    cmp     edi, [rel dx_blocks]
    jae     .invalid
    lea     rax, [rel dx_seen]
    bts     dword [rax], edi
    jc      .invalid
    inc     dword [rel dx_count]
    test    r13d, r13d
    jz      .advance
    lea     r15, [rel dx_node]
    mov     rdx, r15
    call    read_index_block
    test    rax, rax
    jnz     .done
    cmp     dword [r15], 0
    jne     .invalid
    mov     esi, [rbp + mount_volume.ext_block_size]
    cmp     [r15 + 4], si
    jne     .invalid
    cmp     word [r15 + 6], 0
    jne     .invalid
    lea     rdi, [r15 + 8]
    sub     esi, 8
    xor     edx, edx
    call    verify_dx_entries
    test    rax, rax
    jnz     .done
.advance:
    dec     ebx
    jz      .ok
    add     r12, 8
    mov     eax, [r12]
    cmp     eax, r14d
    jb      .invalid
    mov     r14d, eax
    jmp     .next
.ok:
    xor     eax, eax
    jmp     .done
.invalid:
    lea     rax, [rel indexed_directory]
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; The directory was validated during preflight. Clear its index before
; any linear dirent edits or growth become visible on disk.
rw_clear_parent_index:
    test    dword [rbp + mount_volume.ext_compat], EXT_COMPAT_INDEX
    jz      .ok
    sub     rsp, 8
    mov     edi, [rel parent_inode]
    call    rw_read_inode_sector
    test    rax, rax
    jnz     .done
    test    dword [rcx + 32], EXT_INDEX_FL
    jz      .done
    and     dword [rcx + 32], ~EXT_INDEX_FL
    call    rw_save_inode_sector
    test    rax, rax
    jnz     .done
    call    ext_flush
.done:
    add     rsp, 8
    ret
.ok:
    xor     eax, eax
    ret

section .bss
alignb 8
dx_root: resb EXT_BLOCK
dx_node: resb EXT_BLOCK
dx_seen: resq (DX_MAX_BLOCKS + 63) / 64
dx_blocks: resd 1
dx_count: resd 1
