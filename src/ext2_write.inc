; Create only, with a single-sector directory publication after the inode
; and allocation records are durable.
%define EXT_DIRECT 12
%define EXT_WRITE_MAX (EXT_DIRECT * EXT_BLOCK)

section .text
global ext_write, ext_touch, ext_finish

rw_drop_cache:
    mov     dword [rel group_number], -1
    mov     dword [rel block_bitmap_group], -1
    mov     dword [rel inode_bitmap_group], -1
    ret

; edi = block group. Cache checked descriptor geometry.
rw_load_group:
    cmp     edi, [rel group_number]
    je      .cached
    cmp     edi, [rbp + mount_volume.ext_groups]
    jae     .bad
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     eax, edi
    shr     edi, 4
    add     edi, EXT_SECTORS
    mov     [rel group_desc_sector], edi
    and     eax, 15
    shl     eax, 5
    mov     [rel group_desc_offset], eax
    lea     rsi, [rel group_sector]
    call    read_sector
    test    rax, rax
    jnz     .done
    mov     eax, [rel group_desc_offset]
    lea     r12, [rel group_sector]
    add     r12, rax
    mov     ecx, [rbp + mount_volume.ext_blocks_group]
    mov     r13d, ebx
    imul    r13d, ecx
    mov     [rel group_start], r13d
    mov     eax, [rbp + mount_volume.ext_blocks]
    sub     eax, r13d
    cmp     eax, ecx
    cmova   eax, ecx
    mov     [rel group_blocks], eax
    lea     r8, [r13 + rax]            ; Exclusive end block.
    mov     edi, ebx
    call    group_has_super
    mov     [rel group_reserved], eax
    add     r13, rax                  ; First permissible bitmap/table block.
    mov     eax, [r12]
    mov     edx, [r12 + 4]
    mov     ecx, [r12 + 8]
    cmp     rax, r13
    jb      .invalid
    cmp     rdx, r13
    jb      .invalid
    cmp     rcx, r13
    jb      .invalid
    cmp     rax, r8
    jae     .invalid
    cmp     rdx, r8
    jae     .invalid
    cmp     eax, edx
    je      .invalid
    mov     esi, [rbp + mount_volume.ext_inode_blocks]
    add     rsi, rcx
    cmp     rsi, r8
    ja      .invalid
    cmp     eax, ecx
    jb      .second_bitmap
    cmp     rax, rsi
    jb      .invalid
.second_bitmap:
    cmp     edx, ecx
    jb      .counts
    cmp     rdx, rsi
    jb      .invalid
.counts:
    mov     [rel group_blockmap], eax
    mov     [rel group_inodemap], edx
    mov     [rel group_table], ecx
    movzx   eax, word [r12 + 12]
    mov     [rel group_free_blocks], eax
    movzx   eax, word [r12 + 14]
    mov     [rel group_free_inodes], eax
    mov     ecx, [rbp + mount_volume.ext_inodes_group]
    mov     eax, ebx
    imul    rax, rcx
    mov     edx, [rbp + mount_volume.ext_inodes]
    sub     rdx, rax
    jc      .no_inodes
    cmp     rdx, rcx
    cmova   edx, ecx
    jmp     .save
.no_inodes:
    xor     edx, edx
.save:
    mov     [rel group_inodes], edx
    mov     [rel group_number], ebx
    xor     eax, eax
    jmp     .done
.invalid:
    lea     rax, [rel rw_allocation_error]
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret
.bad:
    lea     rax, [rel rw_allocation_error]
    ret
.cached:
    xor     eax, eax
    ret

; eax = reserved superblock + GDT block count for group edi.
group_has_super:
    cmp     edi, 1
    jbe     .yes
    test    dword [rbp + mount_volume.ext_features], EXT_SPARSE_SUPER
    jz      .yes
    mov     r10d, 3
.power:
    mov     eax, edi
.divide:
    xor     edx, edx
    div     r10d
    test    edx, edx
    jnz     .next
    cmp     eax, 1
    jne     .divide
    jmp     .yes
.next:
    add     r10d, 2
    cmp     r10d, 7
    jbe     .power
    xor     eax, eax
    ret
.yes:
    mov     eax, [rbp + mount_volume.ext_gdt_blocks]
    inc     eax
    ret

rw_read_block:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    shl     rbx, 3
    mov     r12, rsi
    mov     r13d, EXT_SECTORS
.read:
    mov     rdi, rbx
    mov     rsi, r12
    call    read_sector
    test    rax, rax
    jnz     .done
    inc     rbx
    add     r12, BLOCK_SIZE
    dec     r13d
    jnz     .read
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

%macro load_bitmap 1
rw_load_%1_bitmap:
    push    rbx
    mov     ebx, edi
    call    rw_load_group
    test    rax, rax
    jnz     .done
    cmp     ebx, [rel %1_bitmap_group]
    je      .done
    mov     dword [rel %1_bitmap_group], -1
    mov     edi, [rel group_%1map]
    lea     rsi, [rel %1_bitmap]
    call    rw_read_block
    test    rax, rax
    jnz     .done
    mov     [rel %1_bitmap_group], ebx
.done:
    pop     rbx
    ret
%endmacro
load_bitmap block
load_bitmap inode

rw_test_inode:
    cmp     edi, 1
    jb      rw_invalid
    cmp     edi, [rbp + mount_volume.ext_inodes]
    ja      rw_invalid
    lea     eax, [rdi - 1]
    xor     edx, edx
    div     dword [rbp + mount_volume.ext_inodes_group]
    push    rbx
    mov     ebx, edx
    mov     edi, eax
    call    rw_load_inode_bitmap
    test    rax, rax
    jnz     .done
    lea     rcx, [rel inode_bitmap]
    xor     edx, edx
    bt      dword [rcx], ebx
    setc    dl
.done:
    pop     rbx
    ret

rw_test_block:
    cmp     edi, [rbp + mount_volume.ext_blocks]
    jae     rw_invalid
    mov     eax, edi
    xor     edx, edx
    div     dword [rbp + mount_volume.ext_blocks_group]
    push    rbx
    mov     ebx, edx
    mov     edi, eax
    call    rw_load_block_bitmap
    test    rax, rax
    jnz     .done
    lea     rcx, [rel block_bitmap]
    xor     edx, edx
    bt      dword [rcx], ebx
    setc    dl
.done:
    pop     rbx
    ret

; edi = inode. Return inode sector in rdx, byte offset in ecx.
rw_inode_location:
    lea     eax, [rdi - 1]
    cmp     eax, [rbp + mount_volume.ext_inodes]
    jae     rw_invalid
    xor     edx, edx
    div     dword [rbp + mount_volume.ext_inodes_group]
    push    rbx
    mov     ebx, edx
    mov     edi, eax
    call    rw_load_group
    test    rax, rax
    jnz     .done
    imul    ebx, [rbp + mount_volume.ext_inode_size]
    mov     edx, [rel group_table]
    shl     rdx, 3
    mov     ecx, ebx
    shr     ebx, 9
    add     rdx, rbx
    and     ecx, BLOCK_SIZE - 1
.done:
    pop     rbx
    ret

rw_invalid:
    lea     rax, [rel rw_allocation_error]
    ret

rw_write_sector:
    cmp     rdi, [rbp + mount_volume.total_sectors]
    jae     rw_invalid
    add     rdi, [rbp + mount_volume.volume_base]
    jmp     block_write

; edi = clean bit. Update only the primary superblock.
ext_set_state:
    push    rbx
    mov     ebx, edi
    mov     edi, 2
    lea     rsi, [rel write_sector_buffer]
    call    read_sector
    test    rax, rax
    jnz     .done
    mov     word [rel write_sector_buffer + 58], bx
    mov     edi, 2
    lea     rsi, [rel write_sector_buffer]
    call    rw_write_sector
    test    rax, rax
    jnz     .done
    call    block_flush
.done:
    pop     rbx
    ret

; An I/O error prevents a clean state for the lifetime of the mount.
; Detach a failed mount after a successful flush, leaving it dirty.
ext_finish:
    push    rbx
    cmp     byte [rbp + mount_volume.ext_readonly], 0
    jne     .detach
    call    block_flush
    test    rax, rax
    jnz     .failed
    cmp     byte [rbp + mount_volume.write_error], 0
    jne     .dirty
    mov     edi, 1
    call    ext_set_state
    test    rax, rax
    jz      .detach
    mov     rbx, rax
    xor     edi, edi                  ; Restore dirty state if the device permits.
    call    ext_set_state
    mov     rax, rbx
    jmp     .failed
.dirty:
    mov     byte [rbp + mount_volume.mounted], 0
    lea     rax, [rel ext_dirty_detached]
    jmp     .done
.detach:
    mov     byte [rbp + mount_volume.mounted], 0
    xor     eax, eax
    jmp     .done
.failed:
    mov     byte [rbp + mount_volume.write_error], 1
.done:
    pop     rbx
    ret

ext_touch:
    mov     ecx, esi
    xor     esi, esi
    xor     edx, edx
    mov     r8d, 1
    jmp     ext_create

ext_write:
    xor     r8d, r8d
ext_create:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     r14d, ecx
    mov     r15d, r8d
    cmp     byte [rbp + mount_volume.ext_readonly], 0
    jne     .readonly
    cmp     byte [rbp + mount_volume.write_error], 0
    jne     .blocked
    cmp     r13, EXT_WRITE_MAX
    ja      .large
    xor     ecx, ecx
.name:
    mov     al, [rbx + rcx]
    test    al, al
    jz      .name_end
    inc     ecx
    cmp     ecx, 255
    jbe     .name
    jmp     .bad_name
.name_end:
    test    ecx, ecx
    jz      .bad_name
    mov     [rel create_name_length], ecx
    mov     [rel create_name], rbx
    lea     eax, [rcx + 11]
    and     eax, -4
    mov     [rel create_rec_min], eax
    mov     esi, r14d
    call    scan_dir
    test    rax, rax
    jz      .existing
    lea     rcx, [rel missing_entry]
    cmp     rax, rcx
    jne     .error
    test    dword [rel dir_inode + ext_inode.flags], 0x30 ; Immutable or append-only.
    jnz     .blocked
    call    rw_find_slot
    test    rax, rax
    jnz     .error
    call    rw_drop_cache
    mov     eax, r13d
    add     eax, EXT_BLOCK - 1
    shr     eax, 12
    mov     [rel create_block_count], eax
    call    rw_select_free
    test    rax, rax
    jnz     .error

    mov     [rel create_size], r13d
    mov     [rel create_data], r12
    call    rw_write_data
    test    rax, rax
    jnz     .write_error
    call    rw_reserve_allocations
    test    rax, rax
    jnz     .write_error
    call    rw_write_inode
    test    rax, rax
    jnz     .write_error
    call    block_flush
    test    rax, rax
    jnz     .write_error
    call    rw_publish
    test    rax, rax
    jnz     .write_error
    call    block_flush
    test    rax, rax
    jnz     .write_error
    test    r15d, r15d
    jnz     .done
    lea     rdi, [rel ext_saved]
    jmp     .print
.existing:
    test    r15d, r15d
    jz      .occupied
    mov     edi, edx
    lea     rsi, [rel entry_inode]
    call    load_inode
    test    rax, rax
    jnz     .error
    cmp     dword [rel entry_inode + ext_inode.mode], EXT_REG
    je      .done
.occupied:
    lea     rax, [rel ext_exists]
    jmp     .error
.write_error:
    mov     byte [rbp + mount_volume.write_error], 1
.error:
    mov     rdi, rax
.print:
    call    console_write_cstr
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.readonly:
    lea     rax, [rel ext_readonly_error]
    jmp     .error
.blocked:
    lea     rax, [rel ext_write_blocked]
    jmp     .error
.large:
    lea     rax, [rel ext_write_large]
    jmp     .error
.bad_name:
    lea     rax, [rel ext_bad_name]
    jmp     .error

; scan_dir left the validated parent inode. Find a record that can be
; published by changing only one sector, without growing the directory.
rw_find_slot:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    xor     r12d, r12d
.block:
    mov     rax, [rel dir_inode + ext_inode.size]
    shr     rax, 12
    cmp     r12, rax
    jae     .full
    mov     rdi, r12
    lea     rsi, [rel dir_inode]
    call    map_block
    test    rax, rax
    jnz     .done
    test    edx, edx
    jz      .invalid
    mov     r13d, edx
    mov     edi, edx
    lea     rsi, [rel dir_data]
    call    rw_read_block
    test    rax, rax
    jnz     .done
    lea     r14, [rel dir_data]
    xor     ebx, ebx
.entry:
    movzx   r15d, word [r14 + rbx + 4]
    cmp     r15d, 8
    jb      .invalid
    test    r15d, 3
    jnz     .invalid
    lea     eax, [rbx + r15]
    cmp     eax, EXT_BLOCK
    ja      .invalid
    xor     ecx, ecx                  ; Space kept by the original entry.
    cmp     dword [r14 + rbx], 0
    je      .candidate
    movzx   ecx, byte [r14 + rbx + 6]
    add     ecx, 11
    and     ecx, -4
.candidate:
    mov     edx, r15d
    sub     edx, ecx
    jc      .invalid
    cmp     edx, [rel create_rec_min]
    jb      .next
    lea     eax, [rbx + rcx]
    mov     esi, eax
    and     esi, -BLOCK_SIZE
    mov     edi, [rel create_rec_min]
    add     edi, eax
    sub     edi, esi
    cmp     edi, BLOCK_SIZE
    ja      .next
    test    ecx, ecx
    jz      .slot
    lea     edi, [rbx + 4]
    sub     edi, esi
    cmp     edi, BLOCK_SIZE - 2
    ja      .next
.slot:
    mov     [rel slot_new_offset], eax
    and     dword [rel slot_new_offset], BLOCK_SIZE - 1
    mov     [rel slot_new_length], edx
    mov     [rel slot_before_length], ecx
    mov     [rel slot_before_offset], ebx
    and     dword [rel slot_before_offset], BLOCK_SIZE - 1
    shr     esi, 9
    shl     r13, 3
    add     r13, rsi
    mov     [rel create_slot_sector], r13
    xor     eax, eax
    jmp     .done
.next:
    add     ebx, r15d
    cmp     ebx, EXT_BLOCK
    jb      .entry
    inc     r12
    jmp     .block
.full:
    lea     rax, [rel ext_slot_full]
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

rw_select_free:
    push    rbx
    push    r12
    push    r13
    xor     ebx, ebx
    mov     dword [rel create_inode], 0
    xor     r12d, r12d
.group:
    mov     edi, ebx
    call    rw_load_group
    test    rax, rax
    jnz     .done
    cmp     dword [rel create_inode], 0
    jne     .blocks
    cmp     dword [rel group_free_inodes], 0
    je      .blocks
    mov     edi, ebx
    call    rw_load_inode_bitmap
    test    rax, rax
    jnz     .done
    lea     r13, [rel inode_bitmap]
    xor     ecx, ecx
.inode_bit:
    bt      dword [r13], ecx
    jnc     .inode_found
    inc     ecx
    cmp     ecx, [rel group_inodes]
    jb      .inode_bit
    jmp     .bad
.inode_found:
    mov     eax, ebx
    imul    eax, [rbp + mount_volume.ext_inodes_group]
    lea     eax, [rax + rcx + 1]
    mov     [rel create_inode], eax
.blocks:
    cmp     r12d, [rel create_block_count]
    je      .group_done
    cmp     dword [rel group_free_blocks], 0
    je      .group_done
    mov     edi, ebx
    call    rw_load_block_bitmap
    test    rax, rax
    jnz     .done
    lea     r13, [rel block_bitmap]
    xor     ecx, ecx
.block_bit:
    bt      dword [r13], ecx
    jc      .next_bit
    mov     eax, [rel group_start]
    add     eax, ecx
    lea     rdx, [rel create_blocks]
    mov     [rdx + r12 * 4], eax
    inc     r12d
    cmp     r12d, [rel create_block_count]
    je      .group_done
.next_bit:
    inc     ecx
    cmp     ecx, [rel group_blocks]
    jb      .block_bit
.group_done:
    cmp     dword [rel create_inode], 0
    je      .advance
    cmp     r12d, [rel create_block_count]
    je      .ok
.advance:
    inc     ebx
    cmp     ebx, [rbp + mount_volume.ext_groups]
    jb      .group
    lea     rax, [rel ext_no_space]
    jmp     .done
.bad:
    lea     rax, [rel rw_allocation_error]
    jmp     .done
.ok:
    xor     eax, eax
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

rw_write_data:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, [rel create_data]
    mov     r13d, [rel create_size]
    lea     r14, [rel create_blocks]
    mov     r15d, [rel create_block_count]
.block:
    xor     eax, eax
    test    r15d, r15d
    jz      .done
    mov     ebx, [r14]
    shl     rbx, 3
    add     r14, 4
    dec     r15d
    mov     eax, EXT_SECTORS
    push    rax
    sub     rsp, 8
.sector:
    lea     rdi, [rel write_sector_buffer]
    mov     rsi, r12
    mov     ecx, BLOCK_SIZE
    cmp     r13d, ecx
    cmovb   ecx, r13d
    mov     edx, ecx
    rep     movsb
    add     r12, rdx
    sub     r13d, edx
    mov     ecx, BLOCK_SIZE
    sub     ecx, edx
    xor     eax, eax
    rep     stosb
    mov     rdi, rbx
    lea     rsi, [rel write_sector_buffer]
    call    rw_write_sector
    test    rax, rax
    jnz     .block_done
    inc     rbx
    dec     dword [rsp + 8]
    jnz     .sector
.block_done:
    add     rsp, 16
    test    rax, rax
    jz      .block
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

rw_reserve_allocations:
    push    rbx
    push    r12
    push    r13
    mov     eax, [rel create_inode]
    dec     eax
    mov     esi, 1
    call    rw_reserve_bit
    test    rax, rax
    jnz     .done
    lea     rbx, [rel create_blocks]
    mov     r12d, [rel create_block_count]
    mov     r13d, r12d
.block:
    test    r12d, r12d
    jz      .super
    mov     eax, [rbx]
    xor     esi, esi
    call    rw_reserve_bit
    test    rax, rax
    jnz     .done
    add     rbx, 4
    dec     r12d
    jmp     .block
.super:
    mov     edi, 2
    lea     rsi, [rel write_sector_buffer]
    call    read_sector
    test    rax, rax
    jnz     .done
    sub     [rel write_sector_buffer + 12], r13d
    dec     dword [rel write_sector_buffer + 16]
    mov     edi, 2
    lea     rsi, [rel write_sector_buffer]
    call    rw_write_sector
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; eax = zero-based block or inode number, esi = inode selector.
rw_reserve_bit:
    push    rbx
    push    r12
    push    r13
    mov     r13d, esi
    mov     ecx, [rbp + mount_volume.ext_blocks_group]
    test    esi, esi
    cmovnz  ecx, [rbp + mount_volume.ext_inodes_group]
    xor     edx, edx
    div     ecx
    mov     ebx, edx
    mov     edi, eax
    call    rw_load_group
    test    rax, rax
    jnz     .done
    mov     eax, [rel group_blockmap]
    test    r13d, r13d
    cmovnz  eax, [rel group_inodemap]
    shl     rax, 3
    mov     ecx, ebx
    shr     ecx, 12
    lea     r12, [rax + rcx]
    and     ebx, 4095
    mov     rdi, r12
    lea     rsi, [rel write_sector_buffer]
    call    read_sector
    test    rax, rax
    jnz     .done
    lea     rsi, [rel write_sector_buffer]
    bts     dword [rsi], ebx
    jc      .bad
    mov     rdi, r12
    call    rw_write_sector
    test    rax, rax
    jnz     .done
    mov     edi, [rel group_desc_sector]
    lea     rsi, [rel write_sector_buffer]
    call    read_sector
    test    rax, rax
    jnz     .done
    mov     eax, [rel group_desc_offset]
    lea     rsi, [rel write_sector_buffer]
    lea     rdx, [rsi + rax + 12]
    cmp     word [rdx + r13 * 2], 0
    je      .bad
    dec     word [rdx + r13 * 2]
    mov     edi, [rel group_desc_sector]
    call    rw_write_sector
    jmp     .done
.bad:
    lea     rax, [rel rw_allocation_error]
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

rw_write_inode:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     edi, [rel create_inode]
    call    rw_inode_location
    test    rax, rax
    jnz     .done
    mov     r12, rdx
    lea     rbx, [rel write_sector_buffer]
    add     rbx, rcx
    mov     rdi, r12
    lea     rsi, [rel write_sector_buffer]
    call    read_sector
    test    rax, rax
    jnz     .done
    mov     rdi, rbx
    mov     ecx, [rbp + mount_volume.ext_inode_size]
    xor     eax, eax
    rep     stosb
    mov     word [rbx], EXT_REG | 0o644
    mov     eax, [rel create_size]
    mov     [rbx + 4], eax
    mov     word [rbx + 26], 1
    mov     ecx, [rel create_block_count]
    lea     eax, [rcx * EXT_SECTORS]
    mov     [rbx + 28], eax
    lea     rdi, [rbx + 40]
    lea     rsi, [rel create_blocks]
    rep     movsd
    mov     rdi, r12
    lea     rsi, [rel write_sector_buffer]
    call    rw_write_sector
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

rw_publish:
    push    rbx
    mov     rdi, [rel create_slot_sector]
    lea     rsi, [rel write_sector_buffer]
    call    read_sector
    test    rax, rax
    jnz     .done
    lea     rbx, [rel write_sector_buffer]
    mov     eax, [rel slot_before_length]
    test    eax, eax
    jz      .entry
    mov     ecx, [rel slot_before_offset]
    mov     [rbx + rcx + 4], ax
.entry:
    mov     eax, [rel slot_new_offset]
    add     rbx, rax
    mov     rdi, rbx
    mov     ecx, [rel create_rec_min]
    xor     eax, eax
    rep     stosb
    mov     eax, [rel create_inode]
    mov     [rbx], eax
    mov     eax, [rel slot_new_length]
    mov     [rbx + 4], ax
    mov     ecx, [rel create_name_length]
    mov     [rbx + 6], cl
    test    dword [rbp + mount_volume.ext_features], EXT_FILETYPE
    jz      .name
    mov     byte [rbx + 7], 1
.name:
    lea     rdi, [rbx + 8]
    mov     rsi, [rel create_name]
    rep     movsb
    mov     rdi, [rel create_slot_sector]
    lea     rsi, [rel write_sector_buffer]
    call    rw_write_sector
.done:
    pop     rbx
    ret

section .rodata
rw_features_error: db "Ext2 features require a read-only mount (-o ro).", 10, 0
ext_readonly_error: db "Ext2 is read-only.", 10, 0
ext_write_blocked: db "Ext2 writes are blocked.", 10, 0
ext_dirty_detached: db "Ext2 unmounted dirty. Run offline e2fsck.", 10, 0
ext_write_large: db "Ext2 create limit is 48 KiB.", 10, 0
ext_bad_name: db "Invalid ext2 file name.", 10, 0
ext_slot_full: db "Ext2 directory has no writable slot in one sector.", 10, 0
ext_exists: db "Ext2 entry already exists.", 10, 0
ext_no_space: db "Ext2 has no free inode or data blocks.", 10, 0
ext_saved: db "Ext2 file saved.", 10, 0

section .bss
alignb 8
create_data: resq 1
create_name: resq 1
create_slot_sector: resq 1
create_size: resd 1
create_name_length: resd 1
create_rec_min: resd 1
create_block_count: resd 1
create_blocks: resd EXT_DIRECT
create_inode: resd 1
slot_new_offset: resd 1
slot_new_length: resd 1
slot_before_offset: resd 1
slot_before_length: resd 1
group_number: resd 1
group_start: resd 1
group_reserved: resd 1
group_blocks: resd 1
group_inodes: resd 1
group_table: resd 1
group_blockmap: resd 1
group_inodemap: resd 1
group_desc_sector: resd 1
group_desc_offset: resd 1
group_free_blocks: resd 1
group_free_inodes: resd 1
block_bitmap_group: resd 1
inode_bitmap_group: resd 1
group_sector: resb BLOCK_SIZE
write_sector_buffer: resb BLOCK_SIZE
block_bitmap: resb EXT_BLOCK
inode_bitmap: resb EXT_BLOCK
