; Ordered ext2 mutations. Publish names and inode pointers only after
; their backing allocations are durable.
%define EXT_LINK_MAX 32000
%define EXT_PROTECTED_FLAGS 0x30     ; Immutable or append-only.

section .text
global ext_write, ext_copy_write, ext_copy_stream, ext_copy_sparse, ext_touch, ext_finish, ext_mkdir
extern rtc_unix_seconds

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
    add     edi, [rbp + mount_volume.ext_gdt_sector]
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
    add     r13d, [rbp + mount_volume.ext_first_data]
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
    movzx   eax, word [r12 + 16]
    mov     [rel group_used_dirs], eax
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
    cmp     [rel group_used_dirs], edx
    ja      .invalid
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
    add     eax, [rbp + mount_volume.ext_reserved_gdt]
    inc     eax
    ret

%macro block_transfer 2
%1:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    imul    rbx, [rbp + mount_volume.ext_sectors]
    mov     r12, rsi
    mov     r13d, [rbp + mount_volume.ext_sectors]
.next:
    mov     rdi, rbx
    mov     rsi, r12
    call    %2
    test    rax, rax
    jnz     .done
    inc     rbx
    add     r12, BLOCK_SIZE
    dec     r13d
    jnz     .next
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret
%endmacro
block_transfer rw_read_block, read_sector
block_transfer rw_write_block, rw_write_sector

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
    sub     eax, [rbp + mount_volume.ext_first_data]
    jc      rw_invalid
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
    imul    rdx, [rbp + mount_volume.ext_sectors]
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
    call    console_cancel_check
    test    rax, rax
    jnz     .done
    cmp     rdi, [rbp + mount_volume.total_sectors]
    jae     rw_invalid
    add     rdi, [rbp + mount_volume.volume_base]
    mov     eax, [rbp + mount_volume.device]
    mov     [rel block_selected], eax
    jmp     block_write
.done:
    ret

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
    call    ext_flush
.done:
    pop     rbx
    ret

; An I/O error prevents a clean state for the lifetime of the mount.
; Detach a failed mount after a successful flush, leaving it dirty.
ext_finish:
    push    rbx
    cmp     byte [rbp + mount_volume.read_only], 0
    jne     .detach
    call    ext_flush
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
    jmp     ext_create_plain

ext_mkdir:
    mov     ecx, esi
    xor     esi, esi
    mov     edx, [rbp + mount_volume.ext_block_size]
    mov     r8d, 2
    jmp     ext_create_plain

ext_symlink:
    mov     r8d, 4
    jmp     ext_create_plain

ext_copy_sparse:
    mov     r8d, 5
    jmp     ext_create
ext_copy_stream:
    mov     r8d, 3                    ; rsi is a sector reader, not a payload address.
    jmp     ext_create
ext_copy_write:
    xor     r8d, r8d
    jmp     ext_create
ext_write:
    xor     r8d, r8d
ext_create_plain:
    xor     r9d, r9d                  ; No same-volume source inode.
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
    mov     [rel copy_source_inode], r9d
    mov     qword [rel create_reader], 0
    mov     byte [rel create_sparse], 0
    mov     byte [rel create_resize], 0
    cmp     r15d, 5
    jb      .reader_mode
    mov     byte [rel create_sparse], 1
    cmp     r15d, 6
    sete    byte [rel create_resize]
.reader_mode:
    cmp     r15d, 3
    jne     .mode_ready
    mov     [rel create_reader], rsi
.mode_ready:
    cmp     byte [rbp + mount_volume.read_only], 0
    jne     .readonly
    cmp     byte [rbp + mount_volume.write_error], 0
    jne     .blocked
    mov     rax, [rbp + mount_volume.ext_max_blocks]
    imul    rax, [rbp + mount_volume.ext_block_size]
    mov     rdx, EXT_4K_MAX_SIZE
    cmp     rax, rdx
    cmova   rax, rdx
    cmp     r13, rax
    ja      .large
    cmp     r13, 0x7FFFFFFF
    jbe     .size_ok
    test    dword [rbp + mount_volume.ext_features], EXT_LARGE_FILE << 16
    jz      .large
.size_ok:
    mov     byte [rel create_type], 1
    cmp     r15d, 4
    jne     .directory_type
    cmp     r13, [rbp + mount_volume.ext_block_size]
    jae     .large
    mov     byte [rel create_type], 7
    jmp     .inspect
.directory_type:
    cmp     r15d, 2
    jne     .inspect
    mov     byte [rel create_type], 2
.inspect:
    mov     rdi, rbx
    mov     esi, r14d
    call    rw_prepare_target
    test    rax, rax
    jnz     .error
    mov     edx, [rel target_inode]
    test    edx, edx
    jnz     .existing
    test    dword [rel dir_inode + ext_inode.flags], EXT_PROTECTED_FLAGS
    jnz     .blocked
    cmp     r15d, 2
    jne     .plan
    cmp     dword [rel dir_inode + ext_inode.links], EXT_LINK_MAX
    jae     .link_limit
.plan:
    call    rw_plan_file
    test    rax, rax
    jnz     .error
    mov     byte [rel create_inode_needed], 1
    call    rw_plan_growth
    test    rax, rax
    jnz     .error
    call    rw_select_free
    test    rax, rax
    jnz     .error
    cmp     r15d, 2
    jne     .grow
    mov     edi, [rel create_inode]
    xor     esi, esi
    call    rw_dir_count
    test    rax, rax
    jnz     .error
.grow:
    ; First stage the payload in free blocks, including its pointer blocks.
    ; Growth and bitmap changes begin only once cancellation is deferred.
    mov     [rel create_size], r13
    mov     [rel create_data], r12
    cmp     r15d, 2
    jne     .payload
    call    rw_make_directory
.payload:
    call    rw_write_data
    test    rax, rax
    jnz     .stage_error
    call    console_cancel_commit
    test    rax, rax
    jnz     .error
    call    rw_clear_parent_index
    test    rax, rax
    jnz     .write_error
    call    rw_grow_directory
    test    rax, rax
    jnz     .write_error
    call    rw_reserve_allocations
    test    rax, rax
    jnz     .write_error
    cmp     byte [rel create_has_pointers], 0
    je      .new_inode
    call    ext_flush
    test    rax, rax
    jnz     .write_error
.new_inode:
    mov     edi, [rel create_inode]
    call    rw_write_inode
    test    rax, rax
    jnz     .write_error
    cmp     r15d, 2
    jne     .flush_inode
    mov     edi, [rel create_inode]
    mov     esi, 1
    call    rw_dir_count
    test    rax, rax
    jnz     .write_error
.flush_inode:
    call    ext_flush
    test    rax, rax
    jnz     .write_error
    cmp     r15d, 2
    jne     .publish
    mov     edi, [rel parent_inode]
    mov     esi, 1
    call    rw_change_links
    test    rax, rax
    jnz     .write_error
.publish:
    call    rw_publish
    test    rax, rax
    jnz     .write_error
    call    ext_flush
    test    rax, rax
    jnz     .write_error
    cmp     r15d, 1
    je      .done
    lea     rdi, [rel ext_saved]
    lea     rax, [rel ext_dir_saved]
    cmp     r15d, 2
    cmove   rdi, rax
    jmp     .print
.existing:
    cmp     r15d, 4
    je      .occupied
    cmp     r15d, 2
    je      .occupied
    mov     edi, edx
    lea     rsi, [rel entry_inode]
    call    load_inode
    test    rax, rax
    jnz     .error
    cmp     dword [rel entry_inode + ext_inode.mode], EXT_REG
    jne     .occupied
    cmp     r15d, 1
    je      .done
    mov     eax, [rel target_inode]
    cmp     eax, [rel copy_source_inode]
    je      .same_file
    test    dword [rel entry_inode + ext_inode.flags], EXT_PROTECTED_FLAGS
    jnz     .blocked
    cmp     byte [rel create_resize], 0
    je      .plan_replacement
    cmp     r13, [rel entry_inode + ext_inode.size]
    jb      .shorten
    je      .saved
.plan_replacement:
    call    rw_plan_file
    test    rax, rax
    jnz     .error
    call    rw_collect_blocks
    test    rax, rax
    jnz     .error
    mov     dword [rel reclaim_inode], 0
    mov     byte [rel reclaim_is_dir], 0
    mov     eax, [rel create_owned_count]
    mov     [rel create_total], eax
    mov     byte [rel create_inode_needed], 0
    call    rw_select_free
    test    rax, rax
    jnz     .error
    call    rtc_unix_seconds
    jc      .clock_error
    mov     [rel replace_time], eax
    mov     [rel create_size], r13
    mov     [rel create_data], r12
    call    rw_write_data
    test    rax, rax
    jnz     .stage_error
    call    console_cancel_commit
    test    rax, rax
    jnz     .error
    call    rw_reserve_allocations
    test    rax, rax
    jnz     .write_error
    call    ext_flush
    test    rax, rax
    jnz     .write_error
    mov     edi, [rel target_inode]
    call    rw_write_inode
    test    rax, rax
    jnz     .write_error
    call    ext_flush
    test    rax, rax
    jnz     .write_error
    call    rw_reclaim
    test    rax, rax
    jnz     .write_error
.saved:
    lea     rdi, [rel ext_saved]
    jmp     .print
.shorten:
    mov     [rel create_size], r13
    call    rw_plan_shrink
    test    rax, rax
    jnz     .error
    call    rtc_unix_seconds
    jc      .clock_error
    mov     [rel replace_time], eax
    call    rw_publish_shrink
    test    rax, rax
    jnz     .write_error
    jmp     .saved
.clock_error:
    lea     rax, [rel ext_clock_error]
    jmp     .error
.same_file:
    lea     rax, [rel ext_same_file]
    jmp     .error
.occupied:
    lea     rax, [rel ext_exists]
    jmp     .error
.stage_error:
    lea     rdx, [rel interrupted_text]
    cmp     rax, rdx
    je      .error
.write_error:
    mov     byte [rbp + mount_volume.write_error], 1
.error:
    mov     rdi, rax
.print:
    call    console_write_cstr
.done:
    call    rw_free_plans
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
.link_limit:
    lea     rax, [rel ext_dir_link_limit]
    jmp     .error

; Resolve the root sentinel, and find a unique matching entry and a slot.
; rdi = name, esi = parent.
rw_prepare_target:
    mov     [rel create_name], rdi
    xor     ecx, ecx
.name:
    mov     al, [rdi + rcx]
    test    al, al
    jz      .name_end
    cmp     al, '/'
    je      .bad_name
    inc     ecx
    cmp     ecx, 255
    jbe     .name
    jmp     .bad_name
.name_end:
    test    ecx, ecx
    jz      .bad_name
    mov     [rel create_name_length], ecx
    lea     eax, [rcx + 11]
    and     eax, -4
    mov     [rel create_rec_min], eax
    mov     edi, EXT_ROOT
    test    esi, esi
    cmovnz  edi, esi
    mov     [rel parent_inode], edi
    sub     rsp, 8
    call    rw_drop_cache
    mov     edi, [rel parent_inode]
    call    rw_find_slot
    add     rsp, 8
    ret
.bad_name:
    lea     rax, [rel ext_bad_name]
    ret

; Leave a separate free record in each sector so future publication can
; fit both the record length change and the new entry in one sector.
rw_init_directory_block:
    lea     rdi, [rel dir_data]
    xor     eax, eax
    mov     ecx, [rbp + mount_volume.ext_block_size]
    shr     ecx, 3
    rep     stosq
    lea     rdi, [rel dir_data]
    mov     ecx, [rbp + mount_volume.ext_sectors]
.record:
    mov     word [rdi + 4], BLOCK_SIZE
    add     rdi, BLOCK_SIZE
    dec     ecx
    jnz     .record
    ret

rw_make_directory:
    sub     rsp, 8
    call    rw_init_directory_block
    add     rsp, 8
    lea     rax, [rel dir_data]
    mov     [rel create_data], rax
    mov     eax, [rel create_inode]
    mov     [rel dir_data], eax
    mov     word [rel dir_data + 4], 12
    mov     byte [rel dir_data + 6], 1
    mov     byte [rel dir_data + 8], '.'
    mov     eax, [rel parent_inode]
    mov     [rel dir_data + 12], eax
    mov     word [rel dir_data + 16], BLOCK_SIZE - 12
    mov     byte [rel dir_data + 18], 2
    mov     word [rel dir_data + 20], '..'
    test    dword [rbp + mount_volume.ext_features], EXT_FILETYPE
    jz      .done
    mov     byte [rel dir_data + 7], 2
    mov     byte [rel dir_data + 19], 2
.done:
    ret

; edi = inode, esi = link count delta; edx optionally carries the new ctime.
rw_change_links:
    mov     edx, -1
rw_change_links_timestamp:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, esi
    mov     r12d, edx
    call    rw_read_inode_sector
    test    rax, rax
    jnz     .done
    add     word [rcx + 26], bx
    cmp     r12d, -1
    je      .save
    mov     eax, r12d
    call    rw_set_ctime
.save:
    call    rw_save_inode_sector
    test    rax, rax
    jnz     .done
    call    ext_flush
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; rcx = raw inode, eax = seconds. Keep the sector address in rdx.
rw_set_ctime:
    mov     [rcx + 12], eax
    cmp     dword [rbp + mount_volume.ext_inode_size], 128
    je      .done
    cmp     word [rcx + 128], 8
    jb      .done
    mov     dword [rcx + 132], 0
.done:
    ret

; edi = directory inode, esi = 0 check increment, 1 increment,
; -2 check decrement, -1 decrement.
rw_dir_count:
    push    rbx
    mov     ebx, esi
    lea     eax, [rdi - 1]
    xor     edx, edx
    div     dword [rbp + mount_volume.ext_inodes_group]
    mov     edi, eax
    call    rw_load_group
    test    rax, rax
    jnz     .done
    mov     edi, [rel group_desc_sector]
    lea     rsi, [rel write_sector_buffer]
    call    read_sector
    test    rax, rax
    jnz     .done
    mov     eax, [rel group_desc_offset]
    lea     rsi, [rel write_sector_buffer]
    lea     rcx, [rsi + rax + 16]
    movzx   eax, word [rcx]
    test    ebx, ebx
    js      .decrement
    cmp     eax, [rel group_inodes]
    jae     .bad
    test    ebx, ebx
    jz      .ok
    jmp     .apply
.decrement:
    test    eax, eax
    jz      .bad
    cmp     eax, [rel group_inodes]
    ja      .bad
    cmp     ebx, -2
    je      .ok
.apply:
    add     [rcx], bx
    mov     edi, [rel group_desc_sector]
    call    rw_write_sector
    jmp     .done
.ok:
    xor     eax, eax
    jmp     .done
.bad:
    call    rw_invalid
.done:
    pop     rbx
    ret

; edi = directory inode, rsi = callback(record, physical block, offset).
; Validate the whole directory, including unused records' lengths.
rw_walk_dir:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rsi
    call    directory_inode
    test    rax, rax
    jnz     .done
    xor     r13d, r13d
.block:
    mov     rax, [rel dir_inode + ext_inode.size]
    ext_block_index rax
    cmp     r13, rax
    jae     .ok
    mov     rdi, r13
    lea     rsi, [rel dir_inode]
    call    map_block
    test    rax, rax
    jnz     .done
    test    edx, edx
    jz      .invalid
    mov     r14d, edx
    mov     edi, edx
    lea     rsi, [rel dir_data]
    call    rw_read_block
    test    rax, rax
    jnz     .done
    xor     ebx, ebx
.record:
    mov     eax, [rbp + mount_volume.ext_block_size]
    sub     eax, 12
    cmp     ebx, eax
    ja      .invalid
    lea     rdi, [rel dir_data]
    add     rdi, rbx
    movzx   r15d, word [rdi + 4]
    cmp     r15d, 12
    jb      .invalid
    test    r15b, 3
    jnz     .invalid
    lea     eax, [rbx + r15]
    cmp     eax, [rbp + mount_volume.ext_block_size]
    ja      .invalid
    mov     eax, [rdi]
    test    eax, eax
    jz      .visit
    cmp     eax, [rbp + mount_volume.ext_inodes]
    ja      .invalid
    movzx   ecx, byte [rdi + 6]
    test    ecx, ecx
    jz      .invalid
    lea     eax, [rcx + 11]
    and     eax, -4
    cmp     eax, r15d
    ja      .invalid
    test    dword [rbp + mount_volume.ext_features], EXT_FILETYPE
    jnz     .typed
    cmp     byte [rdi + 7], 0
    jne     .invalid
.typed:
    cmp     byte [rdi + 7], 7
    ja      .invalid
.name:
    mov     al, [rdi + rcx + 7]
    test    al, al
    jz      .invalid
    cmp     al, '/'
    je      .invalid
    dec     ecx
    jnz     .name
.visit:
    mov     esi, r14d
    mov     edx, ebx
    call    r12
    test    rax, rax
    jnz     .done
    add     ebx, r15d
    cmp     ebx, [rbp + mount_volume.ext_block_size]
    jb      .record
    call    ip_checkpoint
    inc     r13
    jmp     .block
.ok:
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

rw_find_slot:
    mov     qword [rel create_slot_sector], -1
    mov     dword [rel target_inode], 0
    mov     dword [rel slot_unused_start], -1
    lea     rsi, [rel rw_name_record]
    jmp     rw_walk_dir

; Record the first publishable slot and locate a unique existing name.
rw_name_record:
    mov     r8, rdi
    mov     r9d, esi
    mov     r10d, edx
    test    r10d, r10d
    jnz     .record
    mov     dword [rel slot_unused_start], -1
.record:
    mov     eax, [r8]
    test    eax, eax
    jz      .unused
    movzx   ecx, byte [r8 + 6]
    cmp     ecx, [rel create_name_length]
    jne     .occupied
    lea     rdi, [r8 + 8]
    mov     rsi, [rel create_name]
    repe    cmpsb
    jne     .occupied
    cmp     dword [rel target_inode], 0
    jne     .duplicate
    mov     [rel target_inode], eax
    mov     [rel target_block], r9d
    mov     [rel target_offset], r10d
.occupied:
    mov     dword [rel slot_unused_start], -1
    movzx   ecx, byte [r8 + 6]
    add     ecx, 11
    and     ecx, -4
    cmp     qword [rel create_slot_sector], -1
    jne     .done
    movzx   edx, word [r8 + 4]
    sub     edx, ecx
    cmp     edx, [rel create_rec_min]
    jb      .done
    lea     eax, [r10 + rcx]
    mov     esi, eax
    and     esi, -BLOCK_SIZE
    mov     edi, [rel create_rec_min]
    add     edi, eax
    sub     edi, esi
    cmp     edi, BLOCK_SIZE
    ja      .done
    lea     edi, [r10 + 4]
    sub     edi, esi
    cmp     edi, BLOCK_SIZE - 2
    ja      .done
    jmp     .slot
.unused:
    cmp     qword [rel create_slot_sector], -1
    jne     .done
    ; A new header can cover consecutive unused records. Only its own
    ; header and name need to fit in the sector written at publication.
    mov     eax, [rel slot_unused_start]
    cmp     eax, -1
    jne     .span
    mov     eax, r10d
    and     eax, BLOCK_SIZE - 1
    add     eax, [rel create_rec_min]
    cmp     eax, BLOCK_SIZE
    ja      .done
    mov     eax, r10d
    mov     [rel slot_unused_start], eax
.span:
    movzx   edx, word [r8 + 4]
    add     edx, r10d
    sub     edx, eax
    cmp     edx, [rel create_rec_min]
    jb      .done
    mov     r10d, eax
    mov     esi, eax
    and     esi, -BLOCK_SIZE
    xor     ecx, ecx
.slot:
    and     eax, BLOCK_SIZE - 1
    mov     [rel slot_new_offset], eax
    mov     [rel slot_new_length], edx
    mov     [rel slot_before_length], ecx
    and     r10d, BLOCK_SIZE - 1
    mov     [rel slot_before_offset], r10d
    shr     esi, 9
    imul    r9, [rbp + mount_volume.ext_sectors]
    add     r9, rsi
    mov     [rel create_slot_sector], r9
.done:
    xor     eax, eax
    ret
.duplicate:
    lea     rax, [rel ext_duplicate]
    ret

; Data blocks come first, then the indirect table and any parent extension.
; Return the number of blocks owned by the file itself.
rw_plan_file:
    mov     [rel create_size], r13
    cmp     byte [rel create_sparse], 0
    jne     rw_plan_sparse
    sub     rsp, 8
    call    rw_plan_payload
    lea     rsp, [rsp + 8]
    jc      .too_large
    xor     eax, eax
    ret
.too_large:
    lea     rax, [rel ext_write_large]
    ret

rw_plan_payload:
    mov     eax, [rbp + mount_volume.ext_block_mask]
    add     rax, r13
    ext_block_index rax
    cmp     byte [rel create_type], 7
    jne     .count
    cmp     r13d, 60
    jae     .count
    xor     eax, eax
.count:
    mov     [rel create_block_count], eax
    cmp     eax, EXT_DIRECT
    seta    byte [rel create_has_pointers]
    mov     r8d, eax
    cmp     eax, EXT_DIRECT
    jbe     .total
    sub     eax, EXT_DIRECT
    mov     r9d, eax
    mov     ecx, [rbp + mount_volume.ext_ptrs]
    mov     r10d, ecx
    mov     r11d, 1
.region:
    mov     eax, r9d
    cmp     eax, r10d
    cmova   eax, r10d
    sub     r9d, eax
    mov     esi, r11d
.nodes:
    lea     eax, [rax + rcx - 1]
    xor     edx, edx
    div     ecx
    add     r8d, eax
    dec     esi
    jnz     .nodes
    test    r9d, r9d
    jz      .total
    inc     r11d
    imul    r10d, ecx
    jmp     .region
.total:
    mov     eax, r8d
    imul    rax, [rbp + mount_volume.ext_sectors]
    shr     rax, 32
    jnz     .overflow
    mov     [rel create_owned_count], r8d
    mov     eax, r8d
    clc
    ret
.overflow:
    stc
    ret

; Allocate a distinct block for the parent only if there was no safe slot.
rw_plan_growth:
    mov     dword [rel growth_index], -1
    mov     dword [rel growth_depth], 0
    mov     dword [rel growth_old_count], 0
    mov     eax, [rel create_owned_count]
    mov     [rel create_total], eax
    cmp     qword [rel create_slot_sector], -1
    jne     .done
    mov     rax, [rel dir_inode + ext_inode.size]
    add     rax, [rbp + mount_volume.ext_block_size]
    shr     rax, 32
    jnz     .full
    mov     rax, [rel dir_inode + ext_inode.size]
    ext_block_index rax
    cmp     rax, [rbp + mount_volume.ext_max_blocks]
    jae     .full
    cmp     eax, EXT_DIRECT
    jae     .indirect
    lea     rcx, [rel dir_inode + ext_inode.blocks]
    cmp     dword [rcx + rax * 4], 0
    jne     rw_invalid
    mov     [rel growth_index], eax
    inc     dword [rel create_total]
.done:
    xor     eax, eax
    ret
.indirect:
    mov     edi, eax
    jmp     rw_plan_directory_path
.full:
    lea     rax, [rel ext_slot_full]
    ret

rw_grow_directory:
    cmp     dword [rel growth_index], -1
    jne     .grow
    xor     eax, eax
    ret
.grow:
    push    rbx
    lea     rdi, [rel create_plan]
    mov     esi, [rel create_owned_count]
    call    ext_list_cursor
    mov     ebx, [rax]
    mov     [rel growth_root], ebx
    call    rw_init_directory_block
    mov     edi, ebx
    lea     rsi, [rel dir_data]
    call    rw_write_block
    test    rax, rax
    jnz     .done
    mov     eax, ebx
    xor     esi, esi
    xor     edx, edx
    call    rw_change_bit
    test    rax, rax
    jnz     .done
    cmp     dword [rel growth_depth], 0
    je      .allocate_count
    call    rw_write_directory_path
    test    rax, rax
    jnz     .done
.allocate_count:
    mov     edi, [rel growth_depth]
    not     edi
    xor     esi, esi
    call    rw_adjust_super
    test    rax, rax
    jnz     .done
    call    ext_flush
    test    rax, rax
    jnz     .done
    mov     edi, [rel parent_inode]
    call    rw_read_inode_sector
    test    rax, rax
    jnz     .done
    mov     eax, [rel growth_index]
    mov     esi, [rel growth_root]
    mov     [rcx + 40 + rax * 4], esi
    mov     eax, [rbp + mount_volume.ext_block_size]
    add     [rcx + 4], eax
    mov     eax, [rel growth_depth]
    inc     eax
    sub     eax, [rel growth_old_count]
    imul    eax, [rbp + mount_volume.ext_sectors]
    add     [rcx + 28], eax
    call    rw_save_inode_sector
    test    rax, rax
    jnz     .done
    call    ext_flush
    test    rax, rax
    jnz     .done
    cmp     dword [rel growth_old_count], 0
    je      .slot
    call    rw_release_directory_path
    test    rax, rax
    jnz     .done
.slot:
    imul    rbx, [rbp + mount_volume.ext_sectors]
    mov     [rel create_slot_sector], rbx
    mov     dword [rel slot_new_offset], 0
    mov     dword [rel slot_new_length], BLOCK_SIZE
    mov     dword [rel slot_before_length], 0
.done:
    pop     rbx
    ret

rw_select_free:
    push    rbx
    push    r12
    push    r13
    xor     ebx, ebx
    mov     dword [rel create_inode], 0
    xor     r12d, r12d
    cmp     byte [rel create_inode_needed], 0
    jne     .group
    cmp     dword [rel create_total], 0
    je      .ok
.group:
    call    console_cancel_check
    test    rax, rax
    jnz     .done
    mov     edi, ebx
    call    rw_load_group
    test    rax, rax
    jnz     .done
    cmp     byte [rel create_inode_needed], 0
    je      .blocks
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
    cmp     r12d, [rel create_total]
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
    test    ecx, 255
    jnz     .test_bit
    call    console_cancel_check
    test    rax, rax
    jnz     .done
.test_bit:
    bt      dword [r13], ecx
    jc      .next_bit
    mov     eax, [rel group_start]
    add     eax, ecx
    push    rcx
    mov     esi, eax
    lea     rdi, [rel create_plan]
    call    ext_list_append
    pop     rcx
    test    rax, rax
    jnz     .done
    inc     r12d
    cmp     r12d, [rel create_total]
    je      .group_done
.next_bit:
    inc     ecx
    cmp     ecx, [rel group_blocks]
    jb      .block_bit
.group_done:
    cmp     byte [rel create_inode_needed], 0
    je      .check_blocks
    cmp     dword [rel create_inode], 0
    je      .advance
.check_blocks:
    cmp     r12d, [rel create_total]
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
    mov     r13, [rel create_size]
    mov     rax, [rel create_plan + ext_list_state.head]
    lea     r14, [rax + 8]
    mov     r15d, [rel create_block_count]
    mov     rax, [rel sparse_plan + ext_list_state.head]
    add     rax, 8
    mov     [rel sparse_payload_cursor], rax
.block:
    xor     eax, eax
    test    r15d, r15d
    jz      .mapping
    mov     eax, [r14]
    add     r14, 4
    test    r14d, PAGE_SIZE - 1
    jnz     .block_number
    mov     r14, [r14 - PAGE_SIZE]
    add     r14, 8
.block_number:
    mov     ebx, eax
    imul    rbx, [rbp + mount_volume.ext_sectors]
    cmp     byte [rel create_sparse], 0
    je      .block_ready
    cmp     byte [rel create_resize], 0
    je      .sparse_list
    mov     eax, [rel resize_tail]
    jmp     .sparse_offset
.sparse_list:
    lea     rdi, [rel sparse_payload_cursor]
    call    ext_list_next
.sparse_offset:
    imul    rax, [rbp + mount_volume.ext_block_size]
    mov     [rel sparse_payload_offset], rax
    mov     r13, [rel create_size]
    sub     r13, rax
.block_ready:
    dec     r15d
    mov     eax, [rbp + mount_volume.ext_sectors]
    push    rax
    sub     rsp, 8
.sector:
    lea     rdi, [rel write_sector_buffer]
    cmp     byte [rel create_sparse], 0
    jne     .sparse_sector
    cmp     qword [rel create_reader], 0
    je      .memory
    test    r13, r13
    jz      .padding
    call    [rel create_reader]
    jmp     .stream_read
.sparse_sector:
    xor     eax, eax
    mov     ecx, BLOCK_SIZE / 8
    rep     stosq
    mov     rsi, [rel sparse_payload_offset]
    add     qword [rel sparse_payload_offset], BLOCK_SIZE
    mov     rdx, [rel sparse_source_size]
    sub     rdx, rsi
    jbe     .write_sector
    mov     eax, BLOCK_SIZE
    cmp     rdx, rax
    cmova   rdx, rax
    lea     rdi, [rel write_sector_buffer]
    call    ext_read_at
    test    rax, rax
    jnz     .block_done
    jmp     .write_sector
.stream_read:
    test    rax, rax
    jnz     .block_done
    lea     rdi, [rel write_sector_buffer]
    mov     ecx, BLOCK_SIZE
    cmp     r13, rcx
    cmovb   rcx, r13
    sub     r13, rcx
    add     rdi, rcx
    jmp     .pad_sector
.padding:
    xor     ecx, ecx
    jmp     .pad_sector
.memory:
    mov     rsi, r12
    mov     ecx, BLOCK_SIZE
    cmp     r13, rcx
    cmovb   rcx, r13
    mov     edx, ecx
    rep     movsb
    add     r12, rdx
    sub     r13, rdx
    mov     ecx, edx
.pad_sector:
    neg     ecx
    add     ecx, BLOCK_SIZE
    xor     eax, eax
    rep     stosb
.write_sector:
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
    jmp     .done
.mapping:
    call    rw_write_mapping
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
    mov     r13d, [rel create_inode]
    test    r13d, r13d
    jz      .init_blocks
    lea     eax, [r13 - 1]
    mov     esi, 1
    xor     edx, edx
    call    rw_change_bit
    test    rax, rax
    jnz     .done
.init_blocks:
    mov     rax, [rel create_plan + ext_list_state.head]
    lea     rbx, [rax + 8]
    mov     r12d, [rel create_owned_count]
    cmp     r12d, EXT_DIRECT + 1
    jbe     .block
    lea     rdi, [rel create_plan]
    mov     esi, r12d
    xor     edx, edx
    call    rw_apply_block_runs
    test    rax, rax
    jnz     .done
    jmp     .super
.block:
    test    r12d, r12d
    jz      .super
    mov     eax, [rbx]
    add     rbx, 4
    test    ebx, PAGE_SIZE - 1
    jnz     .sector
    mov     rbx, [rbx - PAGE_SIZE]
    add     rbx, 8
.sector:
    xor     esi, esi
    xor     edx, edx
    call    rw_change_bit
    test    rax, rax
    jnz     .done
    dec     r12d
    jmp     .block
.super:
    mov     edi, [rel create_owned_count]
    neg     edi
    xor     esi, esi
    test    r13d, r13d
    setnz   sil
    neg     esi
    call    rw_adjust_super
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; edi/esi = signed block/inode deltas.
rw_adjust_super:
    mov     eax, edi
    or      eax, esi
    jz      .unchanged
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
    mov     edi, 2
    lea     rsi, [rel write_sector_buffer]
    call    read_sector
    test    rax, rax
    jnz     .done
    add     [rel write_sector_buffer + 12], ebx
    add     [rel write_sector_buffer + 16], r12d
    mov     edi, 2
    lea     rsi, [rel write_sector_buffer]
    call    rw_write_sector
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
.unchanged:
    xor     eax, eax
    ret

; eax = zero-based block/inode number, esi = inode selector.
; edx = 0 allocate both records, 1 release bitmap, 2 release group count.
rw_change_bit:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     r13d, esi
    mov     r14d, edx
    mov     ecx, [rbp + mount_volume.ext_blocks_group]
    test    esi, esi
    cmovnz  ecx, [rbp + mount_volume.ext_inodes_group]
    jnz     .divide
    sub     eax, [rbp + mount_volume.ext_first_data]
    jc      .bad
.divide:
    xor     edx, edx
    div     ecx
    mov     ebx, edx
    mov     edi, eax
    call    rw_load_group
    test    rax, rax
    jnz     .done
    cmp     r14d, 2
    je      .count
    mov     eax, [rel group_blockmap]
    test    r13d, r13d
    cmovnz  eax, [rel group_inodemap]
    imul    rax, [rbp + mount_volume.ext_sectors]
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
    test    r14d, r14d
    jnz     .release
    bts     dword [rsi], ebx
    jc      .bad
    jmp     .save_bit
.release:
    btr     dword [rsi], ebx
    jnc     .bad
.save_bit:
    mov     rdi, r12
    call    rw_write_sector
    test    rax, rax
    jnz     .done
    test    r14d, r14d
    jnz     .done
.count:
    mov     edi, [rel group_desc_sector]
    lea     rsi, [rel write_sector_buffer]
    call    read_sector
    test    rax, rax
    jnz     .done
    mov     eax, [rel group_desc_offset]
    lea     rsi, [rel write_sector_buffer]
    lea     rdx, [rsi + rax + 12]
    test    r14d, r14d
    jnz     .credit
    cmp     word [rdx + r13 * 2], 0
    je      .bad
    dec     word [rdx + r13 * 2]
    jmp     .save_count
.credit:
    inc     word [rdx + r13 * 2]
.save_count:
    mov     edi, [rel group_desc_sector]
    call    rw_write_sector
.done:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.bad:
    call    rw_invalid
    jmp     .done

; Read the latest sector. Return its LBA in rdx and the inode address in rcx.
rw_read_inode_sector:
    push    rbx
    push    r12
    sub     rsp, 8
    call    rw_inode_location
    test    rax, rax
    jnz     .done
    mov     r12, rdx
    mov     ebx, ecx
    mov     rdi, r12
    lea     rsi, [rel write_sector_buffer]
    call    read_sector
    mov     rdx, r12
    lea     rcx, [rel write_sector_buffer]
    add     rcx, rbx
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

rw_save_inode_sector:
    mov     rdi, rdx
    lea     rsi, [rel write_sector_buffer]
    jmp     rw_write_sector

rw_write_inode:
    push    rbx
    call    rw_read_inode_sector
    test    rax, rax
    jnz     .done
    mov     rbx, rcx
    cmp     dword [rel create_inode], 0
    je      .replace
    mov     rdi, rbx
    mov     ecx, [rbp + mount_volume.ext_inode_size]
    xor     eax, eax
    rep     stosb
    mov     word [rbx], EXT_REG | 0o644
    mov     word [rbx + 26], 1
    cmp     byte [rel create_type], 7
    jne     .directory_mode
    mov     word [rbx], EXT_SYMLINK | 0o777
    jmp     .payload
.directory_mode:
    cmp     byte [rel create_type], 2
    jne     .payload
    mov     word [rbx], EXT_DIR | 0o755
    mov     word [rbx + 26], 2
    jmp     .payload
.replace:
    lea     rdi, [rbx + 40]
    xor     eax, eax
    mov     ecx, 15                    ; Clear stale indirect roots as well.
    rep     stosd
    mov     dword [rbx + 108], 0       ; High size of a regular file.
    mov     eax, [rel replace_time]
    mov     [rbx + 16], eax            ; mtime
    mov     rcx, rbx
    call    rw_set_ctime
    cmp     dword [rbp + mount_volume.ext_inode_size], 128
    je      .payload
    cmp     word [rbx + 128], 12
    jb      .payload
    mov     dword [rbx + 136], 0
.payload:
    mov     rax, [rel create_size]
    mov     [rbx + 4], eax
    cmp     byte [rel create_type], 1
    jne     .allocated
    shr     rax, 32
    mov     [rbx + 108], eax
.allocated:
    mov     eax, [rel create_owned_count]
    cmp     byte [rel create_resize], 0
    je      .attributes
    mov     eax, [rel sparse_count]
    add     eax, [rel sparse_metadata]
.attributes:
    cmp     dword [rbx + 104], 0
    je      .block_count
    inc     eax
.block_count:
    imul    eax, [rbp + mount_volume.ext_sectors]
    mov     [rbx + 28], eax
    lea     rdi, [rbx + 40]
    cmp     byte [rel create_type], 7
    jne     .mapped
    cmp     dword [rel create_block_count], 0
    jne     .mapped
    mov     rsi, [rel create_data]
    mov     ecx, [rel create_size]
    rep     movsb
    jmp     .save
.mapped:
    lea     rsi, [rel create_roots]
    mov     ecx, 15
    rep     movsd
.save:
    call    rw_save_inode_sector
.done:
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
    mov     al, [rel create_type]
    mov     [rbx + 7], al
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
ext_readonly_error: db "Ext2 is read-only.", 10, 0
ext_write_blocked: db "Ext2 writes are blocked.", 10, 0
ext_dirty_detached: db "Ext2 unmounted dirty. Run offline e2fsck.", 10, 0
ext_write_large: db "File exceeds the supported ext2 size limit.", 10, 0
ext_bad_name: db "Invalid ext2 file name.", 10, 0
ext_slot_full: db "Ext2 directory has no writable slot and cannot grow further.", 10, 0
ext_duplicate: db "Duplicate ext2 directory entries.", 10, 0
ext_exists: db "Ext2 entry already exists.", 10, 0
ext_no_space: db "Ext2 has no free inode or data blocks.", 10, 0
ext_dir_link_limit: db "Ext2 parent directory link limit reached.", 10, 0
ext_dir_saved: db "Ext2 directory created.", 10, 0
ext_clock_error: db "Ext2 replacement requires a valid UTC hardware clock.", 10, 0
ext_same_file: db "Source and destination are the same file.", 10, 0
ext_saved: db "Ext2 file saved.", 10, 0

section .bss
alignb 8
create_data: resq 1
create_reader: resq 1
create_sparse: resb 1
create_resize: resb 1
create_has_pointers: resb 1
create_name: resq 1
create_slot_sector: resq 1
create_size: resq 1
create_name_length: resd 1
create_rec_min: resd 1
create_block_count: resd 1
create_owned_count: resd 1
create_total: resd 1
growth_index: resd 1
parent_inode: resd 1
target_inode: resd 1
copy_source_inode: resd 1
target_block: resd 1
target_offset: resd 1
create_inode: resd 1
replace_time: resd 1
slot_unused_start: resd 1
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
group_used_dirs: resd 1
block_bitmap_group: resd 1
inode_bitmap_group: resd 1
group_sector: resb BLOCK_SIZE
write_sector_buffer: resb BLOCK_SIZE
block_bitmap: resb EXT_BLOCK
inode_bitmap: resb EXT_BLOCK
create_inode_needed: resb 1
create_type: resb 1
