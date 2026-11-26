; Explicit FAT32 consistency check and orphan reclamation.
%define FAT_CHECK_DEPTH 16
%define FAT_BITMAP_SHIFT (PAGE_SHIFT + 3)
%define FAT_BITMAP_BITS (1 << FAT_BITMAP_SHIFT)
%define FAT_BITMAP_PAGES (1 << (28 - FAT_BITMAP_SHIFT))

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
    cmp     byte [rel mounted], 0
    je      print_unmounted
    test    edi, edi
    jz      .start
    cmp     byte [rel write_blocked], 0
    jne     print_write_blocked
.start:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    call    check_alloc_bitmap
    test    rax, rax
    jnz     .finish
    mov     dword [rel cached_fat_lba], -1
    mov     edi, [rel root_cluster]
    xor     esi, esi
    mov     edx, FAT_CHECK_DEPTH
    call    check_directory
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
    call    block_flush
    test    rax, rax
    jnz     .finish
    mov     byte [rel modified], 1
    mov     edi, [rel fsinfo_lba]
    call    invalidate_fsinfo
    test    rax, rax
    jnz     .write_error
    mov     edi, [rel backup_fsinfo_lba]
    call    invalidate_fsinfo
    test    rax, rax
    jnz     .write_error
    mov     edi, 1
    call    check_fat_table
    test    rax, rax
    jnz     .write_error
    call    block_flush
    test    rax, rax
    jnz     .write_error

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
    mov     byte [rel write_blocked], 1
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

check_alloc_bitmap:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     eax, [rel last_cluster]
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
    cmp     ebx, [rel last_cluster]
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

; edi = directory head, esi = parent head (zero for root), edx = depth left.
check_directory:
    test    edx, edx
    jz      check_too_deep
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, BLOCK_SIZE + 8
    mov     r12d, edi
    mov     r13d, edi
    mov     ebp, esi
    mov     r15d, edx
    xor     esi, esi
    call    check_mark_chain
    test    rax, rax
    jnz     .done
.cluster:
    mov     edi, r12d
    call    cluster_lba
    mov     r14, rax
    mov     eax, [rel sectors_per_cluster]
    mov     [rsp + BLOCK_SIZE], eax
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
    mov     ecx, [rel sectors_per_cluster]
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
    lea     edx, [r15 - 1]
    mov     esi, r13d
    call    check_directory
.check_error:
    test    rax, rax
    jnz     .done
    jmp     .advance
.dot:
    test    ebp, ebp                  ; Only subdirectories contain dot entries.
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
    cmp     edi, ebp
    je      .advance
    test    edi, edi                  ; A parent of zero denotes the root.
    jnz     .invalid
    cmp     ebp, [rel root_cluster]
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
    dec     dword [rsp + BLOCK_SIZE]
    jnz     .sector
    mov     edi, r12d
    call    cached_fat_link
    test    rax, rax
    jnz     .done
    mov     r12d, edx
    cmp     edx, FAT_END
    jb      .cluster
.success:
    xor     eax, eax
    jmp     .done
.invalid:
    lea     rax, [rel check_bad_tree]
.done:
    add     rsp, BLOCK_SIZE + 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

check_too_deep:
    lea     rax, [rel check_depth_error]
    ret

; edi = 0 for validation and counting, 1 to clear proven orphans after validation.
check_fat_table:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     ebp, edi
    xor     ebx, ebx                  ; Cluster number (including FAT padding).
    mov     r12d, [rel reserved_sectors]
    mov     r14d, [rel sectors_per_fat]
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
    cmp     dword [rel fat_copies], 2
    jne     .classify
    mov     eax, [r13 + r15 + BLOCK_SIZE]
    and     eax, FAT_LINK_MASK
    cmp     edx, eax
    jne     .mismatch
.classify:
    cmp     rbx, 2
    jb      .next
    mov     eax, [rel last_cluster]
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
    test    ebp, ebp
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
    cmp     dword [rel fat_copies], 2
    jne     .advance
    mov     edi, r12d
    add     edi, [rel sectors_per_fat]
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
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

section .rodata
fat_mismatch:       db "FAT32 check failed: FAT copies disagree.", 10, 0
check_bad_tree:     db "FAT32 check failed: cluster ownership could not be verified.", 10, 0
check_depth_error:  db "FAT32 check failed: directory nesting exceeds the scan limit.", 10, 0
check_no_memory:    db "FAT32 check failed: insufficient memory for the cluster map.", 10, 0
orphan_report:      db "Orphaned FAT32 clusters: ", 0
reclaimed_report:   db "Reclaimed FAT32 clusters: ", 0

section .bss
alignb 8
check_pages:        resq FAT_BITMAP_PAGES
check_page_count:   resd 1
orphan_count:       resd 1
