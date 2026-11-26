; Explicit FAT32 consistency check and orphan reclamation.
%define FAT_BITMAP_SHIFT (PAGE_SHIFT + 3)
%define FAT_BITMAP_BITS (1 << FAT_BITMAP_SHIFT)
%define FAT_BITMAP_PAGES (1 << (28 - FAT_BITMAP_SHIFT))

struc check_dir_frame
    .cluster: resd 1
    .head:    resd 1
    .sectors: resd 1
    .offset:  resd 1
    .parent:  resd 1
    alignb    8
    .lba:     resq 1
endstruc

extern page_alloc
extern page_free
extern pages_free
extern write_u64

section .text
global fat_check
global fat_repair

fat_repair:
    mov     edi, 1
    jmp     check_volume

fat_check:
    xor     edi, edi
check_volume:
    cmp     byte [rbp + mount_volume.mounted], 0
    je      print_unmounted
    test    edi, edi
    jz      .start
    cmp     byte [rbp + mount_volume.write_error], 0
    jne     print_write_blocked
.start:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    call    check_reachable_tree
    test    rax, rax
    jnz     .finish
    mov     dword [rel orphan_count], 0
    xor     edi, edi
    call    check_fat_table
    test    rax, rax
    jnz     .finish
    test    ebx, ebx
    jz      .report
    cmp     dword [rel orphan_count], 0
    je      .report

    ; Publish nothing until the entire directory tree and FATs have passed.
    call    prepare_mutation
    test    rax, rax
    jnz     .write_error
    mov     edi, 1
    call    check_fat_table
    test    rax, rax
    jnz     .write_error
    call    block_flush
    test    rax, rax
    jnz     .write_error
    mov     byte [rbp + mount_volume.pending_write], 0

.report:
    lea     rdi, [rel orphan_report]
    lea     rax, [rel reclaimed_report]
    test    ebx, ebx
    cmovnz  rdi, rax
    call    console_write_cstr
    mov     edi, [rel orphan_count]
    call    write_u64
    mov     edi, 10
    call    console_putc
    xor     eax, eax
    jmp     .finish
.write_error:
    mov     byte [rbp + mount_volume.write_error], 1
.finish:
    mov     r12, rax
    call    check_free_bitmap
    mov     rax, r12
    add     rsp, 8
    pop     r12
    pop     rbx
    test    rax, rax
    jnz     print_error
    ret

verify_mutation_tree:
    push    rbx
    call    check_reachable_tree
    mov     rbx, rax
    call    check_free_bitmap
    mov     rax, rbx
    pop     rbx
    ret

; The caller frees the bitmap on every exit, including allocation failures.
check_reachable_tree:
    sub     rsp, 8
    call    check_alloc_bitmap
    add     rsp, 8
    test    rax, rax
    jnz     .done
    mov     dword [rel cached_fat_lba], -1
    mov     edi, [rbp + mount_volume.root_cluster]
    xor     esi, esi
    jmp     check_directory
.done:
    ret

check_alloc_bitmap:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     eax, [rbp + mount_volume.last_cluster]
    shr     eax, FAT_BITMAP_SHIFT
    inc     eax
    cmp     rax, [rel pages_free]
    ja      .oom
    mov     ebx, eax
    lea     r12, [rel check_pages]
.page:
    call    page_alloc
    test    rax, rax
    jz      .oom
    mov     [r12], rax
    inc     dword [rel check_page_count]
    mov     rdi, rax
    mov     ecx, PAGE_SIZE / 8
    xor     eax, eax
    rep     stosq
    add     r12, 8
    dec     ebx
    jnz     .page
    jmp     .done
.oom:
    lea     rax, [rel check_no_memory]
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

check_free_bitmap:
    push    rbx
    lea     rbx, [rel check_pages]
.page:
    mov     eax, [rel check_page_count]
    test    eax, eax
    jz      .done
    dec     eax
    mov     [rel check_page_count], eax
    mov     rdi, [rbx + rax * 8]
    call    page_free
    jmp     .page
.done:
    pop     rbx
    ret

; edi = validated cluster. Return bitmap page in rax and bit index in ecx.
check_cluster_bit:
    mov     eax, edi
    shr     eax, FAT_BITMAP_SHIFT
    lea     rcx, [rel check_pages]
    mov     rax, [rcx + rax * 8]
    mov     ecx, edi
    and     ecx, FAT_BITMAP_BITS - 1
    ret

; edi = chain head, esi = minimum required clusters (zero for directories).
check_mark_chain:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, esi
.cluster:
    cmp     ebx, 2
    jb      .invalid
    cmp     ebx, [rbp + mount_volume.last_cluster]
    ja      .invalid
    mov     edi, ebx
    call    check_cluster_bit
    bts     qword [rax], rcx
    jc      .invalid                 ; A cycle or shared cluster.
    mov     edi, ebx
    call    cached_fat_link
    test    rax, rax
    jnz     .done
    test    r12d, r12d
    jz      .follow
    dec     r12d
.follow:
    mov     ebx, edx
    cmp     edx, FAT_END
    jb      .cluster
    test    r12d, r12d
    jz      .done
.invalid:
    lea     rax, [rel check_bad_tree]
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; edi = directory head, esi = parent head (zero for root).
; Suspend parent cursors on a page-backed stack. Reload the parent sector
; on return so only one sector buffer is needed for the traversal.
check_directory:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, BLOCK_SIZE + 16
.open:
    mov     r12d, edi
    mov     r13d, edi
    mov     [rsp + BLOCK_SIZE], esi
    xor     esi, esi
    call    check_mark_chain
    test    rax, rax
    jnz     .done
.cluster:
    mov     edi, r12d
    call    cluster_lba
    mov     r14, rax
    mov     r15d, [rbp + mount_volume.sectors_per_cluster]
.sector:
    mov     rdi, r14
    mov     rsi, rsp
    call    read_sector_into
    test    rax, rax
    jnz     .done
    xor     ebx, ebx
.entry:
    lea     rsi, [rsp + rbx]
    cmp     byte [rsi], 0
    je      .success
    cmp     byte [rsi], 0xE5
    je      .advance
    mov     cl, [rsi + 11]
    cmp     cl, 0x0F                  ; An LFN slot has no data chain.
    je      .long_name
    call    entry_cluster
    mov     edi, eax
    test    cl, 0x08
    jnz     .label
    test    cl, 0x10
    jnz     .directory
    mov     eax, [rsi + 28]
    test    eax, eax
    jnz     .sized_file
    test    edi, edi
    jz      .advance
    xor     esi, esi
    jmp     .file
.sized_file:
    mov     ecx, [rbp + mount_volume.sectors_per_cluster]
    shl     ecx, 9
    dec     eax
    xor     edx, edx
    div     ecx
    lea     esi, [rax + 1]
.file:
    call    check_mark_chain
    jmp     .check_error
.long_name:
    cmp     word [rsi + 26], 0
    jne     .invalid
    jmp     .advance
.label:
    cmp     cl, 0x08
    jne     .invalid
    test    edi, edi
    jnz     .invalid
    jmp     .advance
.directory:
    cmp     byte [rsi], '.'
    je      .dot
    mov     esi, [rsp + BLOCK_SIZE]
    call    check_push_directory
    test    rax, rax
    jnz     .done
    mov     esi, r13d
    jmp     .open
.check_error:
    test    rax, rax
    jnz     .done
    jmp     .advance
.dot:
    cmp     dword [rsp + BLOCK_SIZE], 0 ; Only subdirectories contain dot entries.
    jz      .invalid
    mov     rcx, 0x2020202020202020
    cmp     [rsi + 2], rcx
    jne     .invalid
    cmp     byte [rsi + 10], ' '
    jne     .invalid
    cmp     word [rsi], '. '
    je      .self
    cmp     word [rsi], '..'
    jne     .invalid
    cmp     edi, [rsp + BLOCK_SIZE]
    je      .advance
    test    edi, edi                  ; A parent of zero denotes the root.
    jnz     .invalid
    mov     eax, [rsp + BLOCK_SIZE]
    cmp     eax, [rbp + mount_volume.root_cluster]
    je      .advance
    jmp     .invalid
.self:
    cmp     edi, r13d
    jne     .invalid
.advance:
    add     ebx, FAT_ENTRY_SIZE
    cmp     ebx, BLOCK_SIZE
    jb      .entry
    inc     r14
    dec     r15d
    jnz     .sector
    mov     edi, r12d
    call    cached_fat_link
    test    rax, rax
    jnz     .done
    mov     r12d, edx
    cmp     edx, FAT_END
    jb      .cluster
.success:
    mov     rax, [rel check_dir_stack]
    test    rax, rax
    jz      .done
    sub     rax, check_dir_frame_size
    mov     [rel check_dir_stack], rax
    mov     r12d, [rax + check_dir_frame.cluster]
    mov     r13d, [rax + check_dir_frame.head]
    mov     r15d, [rax + check_dir_frame.sectors]
    mov     ebx, [rax + check_dir_frame.offset]
    mov     edx, [rax + check_dir_frame.parent]
    mov     [rsp + BLOCK_SIZE], edx
    mov     r14, [rax + check_dir_frame.lba]
    and     eax, PAGE_SIZE - 1
    cmp     eax, check_dir_frame_size
    jne     .resume
    call    check_free_dir_page
.resume:
    mov     rdi, r14
    mov     rsi, rsp
    call    read_sector_into
    test    rax, rax
    jnz     .done
    jmp     .advance
.invalid:
    lea     rax, [rel check_bad_tree]
.done:
    mov     r12, rax
.free_stack:
    cmp     qword [rel check_dir_stack], 0
    je      .return
    call    check_free_dir_page
    jmp     .free_stack
.return:
    mov     rax, r12
    add     rsp, BLOCK_SIZE + 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; Preserve the child cluster in edi. The 32-byte slots divide the page
; evenly. The first slot links to the previous page's stack pointer.
check_push_directory:
    mov     rax, [rel check_dir_stack]
    test    eax, PAGE_SIZE - 1
    jnz     .save
    push    rdi
    push    rsi
    sub     rsp, 8
    call    page_alloc
    add     rsp, 8
    pop     rsi
    pop     rdi
    test    rax, rax
    jz      .oom
    mov     rdx, [rel check_dir_stack]
    mov     [rax], rdx
    add     rax, check_dir_frame_size
.save:
    mov     [rax + check_dir_frame.cluster], r12d
    mov     [rax + check_dir_frame.head], r13d
    mov     [rax + check_dir_frame.sectors], r15d
    mov     [rax + check_dir_frame.offset], ebx
    mov     [rax + check_dir_frame.parent], esi
    mov     [rax + check_dir_frame.lba], r14
    add     rax, check_dir_frame_size
    mov     [rel check_dir_stack], rax
    xor     eax, eax
    ret
.oom:
    lea     rax, [rel check_stack_no_memory]
    ret

check_free_dir_page:
    mov     rdi, [rel check_dir_stack]
    dec     rdi
    and     rdi, -PAGE_SIZE
    mov     rax, [rdi]
    mov     [rel check_dir_stack], rax
    jmp     page_free

; edi = 0 for validation and counting, 1 to clear proven orphans after validation.
check_fat_table:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     [rsp + 4], edi
    xor     ebx, ebx                  ; Cluster number (including FAT padding).
    mov     r12d, [rbp + mount_volume.reserved_sectors]
    mov     r14d, [rbp + mount_volume.sectors_per_fat]
.sector:
    mov     edi, r12d
    call    read_fat_pair
    test    rax, rax
    jnz     .done
    lea     r13, [rel fat_sector_pair]
    xor     r15d, r15d                 ; Byte offset within the FAT sector.
    mov     byte [rsp], 0             ; Modified sector.
.entry:
    mov     edx, [r13 + r15]
    and     edx, FAT_LINK_MASK
    cmp     dword [rbp + mount_volume.fat_copies], 2
    jne     .classify
    mov     eax, [r13 + r15 + BLOCK_SIZE]
    and     eax, FAT_LINK_MASK
    cmp     edx, eax
    jne     .mismatch
.classify:
    cmp     rbx, 2
    jb      .next
    mov     eax, [rbp + mount_volume.last_cluster]
    cmp     rbx, rax
    ja      .next
    test    edx, edx
    jz      .next
    cmp     edx, FAT_END
    jae     .in_use
    cmp     edx, 0x0FFFFFF0            ; Preserve reserved values and bad markers.
    jae     .next
    cmp     edx, 2
    jb      .invalid
    cmp     edx, eax
    ja      .invalid
.in_use:
    mov     edi, ebx
    call    check_cluster_bit
    bt      qword [rax], rcx
    jc      .next
    cmp     dword [rsp + 4], 0
    jnz     .clear
    inc     dword [rel orphan_count]
    jmp     .next
.clear:
    and     dword [r13 + r15], 0xF0000000
    and     dword [r13 + r15 + BLOCK_SIZE], 0xF0000000
    mov     byte [rsp], 1
.next:
    inc     rbx
    add     r15d, 4
    cmp     r15d, BLOCK_SIZE
    jb      .entry
    cmp     byte [rsp], 0
    je      .advance
    mov     edi, r12d
    mov     rsi, r13
    call    write_sector_from
    test    rax, rax
    jnz     .done
    cmp     dword [rbp + mount_volume.fat_copies], 2
    jne     .advance
    mov     edi, r12d
    add     edi, [rbp + mount_volume.sectors_per_fat]
    lea     rsi, [r13 + BLOCK_SIZE]
    call    write_sector_from
    test    rax, rax
    jnz     .done
.advance:
    inc     r12d
    dec     r14d
    jnz     .sector
    xor     eax, eax
    jmp     .done
.mismatch:
    lea     rax, [rel fat_mismatch]
    jmp     .done
.invalid:
    lea     rax, [rel check_bad_tree]
.done:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

section .rodata
fat_mismatch:       db "FAT32 check failed: FAT copies disagree.", 10, 0
check_bad_tree:     db "FAT32 check failed: cluster ownership could not be verified.", 10, 0
check_stack_no_memory: db "FAT32 check failed: insufficient memory for directory traversal.", 10, 0
check_no_memory:    db "FAT32 check failed: insufficient memory for the cluster map.", 10, 0
orphan_report:      db "Orphaned FAT32 clusters: ", 0
reclaimed_report:   db "Reclaimed FAT32 clusters: ", 0

section .bss
alignb 8
check_dir_stack:     resq 1
check_pages:        resq FAT_BITMAP_PAGES
check_page_count:   resd 1
orphan_count:       resd 1
