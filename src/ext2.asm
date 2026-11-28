; Ext2 with 1, 2 or 4 KiB blocks and legacy block pointers.
bits 64
default rel

%include "os_constants.inc"
%include "volume.inc"

%define EXT_BLOCK 4096
%define EXT_ROOT 2
%define EXT_DIRECT 12
; Linux ext2 computes its 4 KiB limit from the dense tree, including metadata.
%define EXT_4K_SECTOR_LIMIT (0xFFFFFFFF >> 3)
%define EXT_4K_TRIPLE_DATA (EXT_4K_SECTOR_LIMIT - EXT_DIRECT - 1024 - 1024 * 1024)
%define EXT_4K_META (1027 + (EXT_4K_TRIPLE_DATA + 1023) / 1024 + (EXT_4K_TRIPLE_DATA + 1048575) / 1048576)
%define EXT_4K_MAX_SIZE ((EXT_4K_SECTOR_LIMIT - EXT_4K_META) * EXT_BLOCK)
%define EXT_INDEX_FL 0x1000
%define EXT_DIR 0x4000
%define EXT_REG 0x8000
%define EXT_SYMLINK 0xA000
%define EXT_FILETYPE 2
%define EXT_LARGE_FILE 2
%define EXT_COMPAT_XATTR 0x08
%define EXT_COMPAT_RESIZE 0x10
%define EXT_COMPAT_INDEX 0x20
%define EXT_RESIZE_INODE 7

; Convert a byte offset to a logical ext2 block, preserving rcx.
%macro ext_block_index 1
    push    rcx
    mov     ecx, [rbp + mount_volume.ext_block_shift]
    shr     %1, cl
    pop     rcx
%endmacro

struc ext_inode
    .size: resq 1
    .mode: resd 1
    .flags: resd 1
    .links: resd 1
    .data_sectors: resd 1
    .blocks: resd 15
    alignb 8
endstruc

extern block_read, block_read_range
extern block_write, block_flush, page_alloc, page_free, ip_checkpoint
extern console_write, console_write_cstr, console_putc
extern console_cancel_check, console_cancel_commit, interrupted_text

section .text
extern block_selected

global ext_geometry, ext_visit
global ext_mount, ext_root, ext_find_dir, ext_list, ext_open, ext_read_at

; Publish only after validating the root and mount-specific state.
ext_mount:
    call    ext_geometry
    test    rax, rax
    jnz     .done
    cmp     word [rel metadata + 58], 1 ; Clean, no error flag.
    jne     .bad
    call    ext_root
    test    rax, rax
    jnz     .done
    mov     byte [rbp + mount_volume.write_error], 0
    cmp     byte [rbp + mount_volume.read_only], 0
    jne     .publish
    call    ext_verify_allocations
    test    rax, rax
    jnz     .done
    xor     edi, edi
    call    ext_set_state
    test    rax, rax
    jnz     .done
.publish:
    mov     byte [rbp + mount_volume.mounted], 1
.done:
    ret
.bad:
    lea     rax, [rel bad_super]
    ret

; Read the first superblock sector. CF marks a failed read.
ext_geometry:
    push    rbx
    mov     rdi, [rbp + mount_volume.volume_base]
    add     rdi, 2
    jc      .bad
    cmp     rdi, [rbp + mount_volume.partition_last]
    ja      .bad
    lea     rbx, [rel metadata]
    mov     rsi, rbx
    call    block_read
    test    rax, rax
    jnz     .io

    cmp     word [rbx + 56], 0xEF53
    jne     .bad
    mov     ecx, [rbx + 24]
    cmp     ecx, 2
    ja      .bad
    cmp     ecx, [rbx + 28]            ; Fragment size equals block size.
    jne     .bad
    xor     eax, eax
    test    ecx, ecx
    setz    al
    cmp     eax, [rbx + 20]
    jne     .bad
    mov     [rbp + mount_volume.ext_first_data], eax
    mov     edx, 1024
    shl     edx, cl
    mov     [rbp + mount_volume.ext_block_size], rdx
    add     ecx, 10
    mov     [rbp + mount_volume.ext_block_shift], ecx
    lea     ecx, [rdx - 1]
    mov     [rbp + mount_volume.ext_block_mask], ecx
    mov     ecx, edx
    shr     ecx, 9
    mov     [rbp + mount_volume.ext_sectors], rcx
    inc     eax
    imul    eax, ecx
    mov     [rbp + mount_volume.ext_gdt_sector], eax
    mov     eax, edx
    shr     eax, 2
    mov     [rbp + mount_volume.ext_ptrs], eax
    mov     edx, eax
    imul    edx, eax
    lea     ecx, [rax + rdx + 12]
    imul    edx, eax
    add     edx, ecx
    mov     [rbp + mount_volume.ext_max_blocks], rdx
    cmp     dword [rbx + 76], 1
    ja      .bad
    mov     dword [rbp + mount_volume.ext_first_inode], 11
    mov     ecx, 128
    cmp     dword [rbx + 76], 0
    je      .inode_size
    movzx   ecx, word [rbx + 88]
    mov     edx, [rbx + 84]
    mov     [rbp + mount_volume.ext_first_inode], edx
    cmp     ecx, 128
    je      .inode_size
    cmp     ecx, 256
    jne     .bad
.inode_size:
    mov     [rbp + mount_volume.ext_inode_size], ecx
    mov     eax, [rbx + 92]
    test    eax, ~0x38                 ; xattr, resize_inode, dir_index
    jnz     .bad
    mov     [rbp + mount_volume.ext_compat], eax
    xor     edx, edx
    test    eax, EXT_COMPAT_RESIZE
    jz      .reserved_gdt
    movzx   edx, word [rbx + 206]
    cmp     edx, [rbp + mount_volume.ext_ptrs]
    ja      .bad
.reserved_gdt:
    mov     [rbp + mount_volume.ext_reserved_gdt], edx
    mov     eax, [rbx + 96]
    test    eax, ~EXT_FILETYPE
    jnz     .bad
    mov     edx, [rbx + 100]
    test    edx, ~3                    ; sparse_super, large_file
    jnz     .bad
    shl     edx, 16
    or      eax, edx
    mov     [rbp + mount_volume.ext_features], eax

    mov     eax, [rbx + 4]
    cmp     eax, 3
    jb      .bad
    mov     [rbp + mount_volume.ext_blocks], eax
    imul    rax, [rbp + mount_volume.ext_sectors]
    mov     rdx, [rbp + mount_volume.partition_last]
    sub     rdx, [rbp + mount_volume.volume_base]
    inc     rdx
    cmp     rax, rdx
    ja      .bad
    mov     [rbp + mount_volume.total_sectors], rax
    mov     eax, [rbx + 32]
    lea     edx, [rax - 1]
    mov     r8d, [rbp + mount_volume.ext_block_size]
    shl     r8d, 3
    cmp     edx, r8d
    jae     .bad
    cmp     eax, [rbx + 36]
    jne     .bad
    mov     [rbp + mount_volume.ext_blocks_group], eax
    mov     esi, [rbx + 40]
    lea     edx, [rsi - 1]
    mov     r8d, [rbp + mount_volume.ext_block_size]
    shl     r8d, 3
    cmp     edx, r8d
    jae     .bad
    mov     [rbp + mount_volume.ext_inodes_group], esi
    imul    ecx, esi
    test    ecx, [rbp + mount_volume.ext_block_mask]
    jnz     .bad
    mov     r8d, ecx
    ext_block_index r8d
    mov     [rbp + mount_volume.ext_inode_blocks], r8d
    mov     ecx, eax
    mov     eax, [rbp + mount_volume.ext_blocks]
    sub     eax, [rbp + mount_volume.ext_first_data]
    dec     eax
    xor     edx, edx
    div     ecx
    inc     eax                        ; Block groups, rounded up.
    mov     [rbp + mount_volume.ext_groups], eax
    imul    rsi, rax
    mov     ecx, [rbx]
    cmp     ecx, EXT_ROOT
    jb      .bad
    cmp     rcx, rsi
    ja      .bad
    mov     [rbp + mount_volume.ext_inodes], ecx
    shl     rax, 5
    add     rax, [rbp + mount_volume.ext_block_size]
    dec     rax
    ext_block_index rax
    mov     [rbp + mount_volume.ext_gdt_blocks], eax
    cmp     eax, [rbp + mount_volume.ext_blocks_group]
    jae     .bad
    xor     eax, eax
    jmp     .done
.bad:
    lea     rax, [rel bad_super]
    clc
    jmp     .done
.io:
    stc
.done:
    pop     rbx
    ret

; rdi = volume-relative sector, rsi = destination.
read_sector:
    call    console_cancel_check
    test    rax, rax
    jnz     .done
    cmp     rdi, [rbp + mount_volume.total_sectors]
    jae     corrupt
    add     rdi, [rbp + mount_volume.volume_base]
    mov     eax, [rbp + mount_volume.device]
    mov     [rel block_selected], eax
    jmp     block_read
.done:
    ret

; edi = inode number, rsi = decoded inode destination.
load_inode:
    push    rbx
    push    r12
    push    r13
    mov     r12, rsi
    lea     eax, [rdi - 1]
    cmp     eax, [rbp + mount_volume.ext_inodes]
    jae     .bad
    xor     edx, edx
    div     dword [rbp + mount_volume.ext_inodes_group]
    mov     ebx, eax
    mov     r13d, edx
    mov     edi, eax
    shr     edi, 4                     ; Sixteen group descriptors per sector.
    add     edi, [rbp + mount_volume.ext_gdt_sector]
    lea     rsi, [rel metadata]
    call    read_sector
    test    rax, rax
    jnz     .done
    mov     eax, ebx
    and     eax, 15
    shl     eax, 5
    lea     rsi, [rel metadata]
    add     rsi, rax
    imul    ebx, [rbp + mount_volume.ext_blocks_group]
    add     ebx, [rbp + mount_volume.ext_first_data]
    mov     eax, [rsi + 8]             ; Inode table block.
    test    eax, eax
    jz      .bad
    cmp     eax, ebx
    jb      .bad
    mov     edx, [rbp + mount_volume.ext_blocks_group]
    add     rdx, rbx
    mov     ecx, [rbp + mount_volume.ext_blocks]
    cmp     rdx, rcx
    cmova   rdx, rcx
    mov     ecx, [rbp + mount_volume.ext_inode_blocks]
    add     rcx, rax
    cmp     rcx, rdx
    ja      .bad
    mov     ecx, [rsi]
    cmp     ecx, ebx
    jb      .bad
    cmp     rcx, rdx
    jae     .bad
    mov     r8d, [rsi + 4]
    cmp     r8d, ebx
    jb      .bad
    cmp     r8, rdx
    jae     .bad
    cmp     ecx, r8d
    je      .bad
    ; Bitmap blocks must sit outside the inode table.
    cmp     ecx, eax
    jb      .inode_bitmap
    mov     edx, [rbp + mount_volume.ext_inode_blocks]
    add     rdx, rax
    cmp     rcx, rdx
    jb      .bad
.inode_bitmap:
    cmp     r8d, eax
    jb      .address
    mov     edx, [rbp + mount_volume.ext_inode_blocks]
    add     rdx, rax
    cmp     r8, rdx
    jb      .bad
.address:
    cmp     ebx, [rbp + mount_volume.ext_first_data]
    jne     .offset
    mov     ecx, [rbp + mount_volume.ext_gdt_blocks]
    add     ecx, ebx
    cmp     eax, ecx
    jbe     .bad
.offset:
    imul    r13d, [rbp + mount_volume.ext_inode_size]
    imul    rax, [rbp + mount_volume.ext_sectors]
    mov     edi, r13d
    shr     edi, 9
    add     rdi, rax
    and     r13d, BLOCK_SIZE - 1
    lea     rsi, [rel metadata]
    call    read_sector
    test    rax, rax
    jnz     .done
    lea     rsi, [rel metadata]
    add     rsi, r13
    cmp     word [rsi + 26], 0          ; No live links.
    je      .bad
    cmp     dword [rsi + 20], 0         ; Deleted inode.
    jne     .bad
    movzx   eax, word [rsi]
    and     eax, 0xF000
    mov     [r12 + ext_inode.mode], eax
    mov     ecx, [rsi + 32]
    mov     [r12 + ext_inode.flags], ecx
    mov     edx, [rsi + 28]
    cmp     dword [rsi + 104], 0
    je      .data_sectors
    sub     edx, [rbp + mount_volume.ext_sectors]
    jc      .bad
.data_sectors:
    mov     [r12 + ext_inode.data_sectors], edx
    test    ecx, 0x10080C04            ; Inline data, extents, compression.
    jnz     .bad
    mov     edx, [rsi + 4]
    cmp     eax, EXT_REG
    jne     .size
    mov     ecx, [rsi + 108]
    test    ecx, ecx
    jz      .size
    test    dword [rbp + mount_volume.ext_features], EXT_LARGE_FILE << 16
    jz      .bad
    shl     rcx, 32
    or      rdx, rcx
.size:
    mov     rax, [rbp + mount_volume.ext_max_blocks]
    imul    rax, [rbp + mount_volume.ext_block_size]
    cmp     rdx, rax
    ja      .bad
    mov     [r12 + ext_inode.size], rdx
    movzx   eax, word [rsi + 26]
    mov     [r12 + ext_inode.links], eax
    lea     rdi, [r12 + ext_inode.blocks]
    add     rsi, 40
    mov     ecx, 15
    rep     movsd
    xor     eax, eax
    jmp     .done
.bad:
    lea     rax, [rel corrupt_text]
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; rdi = logical block, rsi = decoded inode. Return block in edx.
map_block:
    push    rbx
    push    r12
    push    r13
    cmp     rdi, [rbp + mount_volume.ext_max_blocks]
    jae     .bad
    cmp     edi, 12
    jb      .direct
    mov     ebx, edi
    sub     ebx, 12
    mov     r12d, 1
    mov     eax, [rbp + mount_volume.ext_ptrs]
    cmp     ebx, eax
    jb      .indirect
    sub     ebx, eax
    inc     r12d
    imul    eax, eax
    cmp     ebx, eax
    jb      .indirect
    sub     ebx, eax
    inc     r12d
.indirect:
    mov     edx, [rsi + ext_inode.blocks + 11 * 4 + r12 * 4]
.next:
    test    edx, edx
    jz      .mapped
    cmp     edx, [rbp + mount_volume.ext_blocks]
    jae     .bad
    dec     r12d
    mov     ecx, [rbp + mount_volume.ext_block_shift]
    sub     ecx, 2
    imul    ecx, r12d
    mov     r13d, ebx
    shr     r13d, cl
    mov     eax, [rbp + mount_volume.ext_ptrs]
    dec     eax
    and     r13d, eax
    mov     edi, edx
    imul    rdi, [rbp + mount_volume.ext_sectors]
    mov     eax, r13d
    shr     eax, 7
    add     rdi, rax
    lea     rsi, [rel metadata]
    call    read_sector
    test    rax, rax
    jnz     .done
    and     r13d, 127
    lea     rsi, [rel metadata]
    mov     edx, [rsi + r13 * 4]
    test    r12d, r12d
    jnz     .next
    jmp     .mapped
.direct:
    mov     edx, [rsi + ext_inode.blocks + rdi * 4]
.mapped:
    cmp     edx, [rbp + mount_volume.ext_blocks]
    jae     .bad
    xor     eax, eax
    jmp     .done
.bad:
    lea     rax, [rel corrupt_text]
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; edi = directory inode (zero means root).
directory_inode:
    sub     rsp, 8
    test    edi, edi
    jnz     .load
    mov     edi, EXT_ROOT
.load:
    lea     rsi, [rel dir_inode]
    call    load_inode
    add     rsp, 8
    test    rax, rax
    jnz     .done
    cmp     dword [rel dir_inode + ext_inode.mode], EXT_DIR
    jne     not_directory
    mov     rax, [rel dir_inode + ext_inode.size]
    test    rax, rax
    jz      corrupt
    test    eax, [rbp + mount_volume.ext_block_mask]
    jnz     corrupt
    test    dword [rel dir_inode + ext_inode.flags], EXT_INDEX_FL
    jnz     verify_directory_index
    xor     eax, eax
.done:
    ret

ext_root:
    xor     edi, edi
    jmp     directory_inode

; rdi = name, esi = parent inode. Return child inode in edx.
ext_find_dir:
    push    rbx
    call    scan_dir
    test    rax, rax
    jnz     .done
    mov     ebx, edx
    mov     edi, edx
    call    directory_inode
    mov     edx, ebx
.done:
    pop     rbx
    ret

; edi = directory inode. Return an error in rax.
ext_list:
    xor     edx, edx
    mov     esi, edi
    xor     edi, edi
    jmp     scan_dir

; edi = directory, rdx = callback(name, length, flags). A visitor may
; resolve another path, so retain this scan's inode and block privately.
ext_visit:
    sub     rsp, EXT_BLOCK + ext_inode_size + 8
    mov     rcx, rsp
    mov     esi, edi
    xor     edi, edi
    call    scan_dir
    add     rsp, EXT_BLOCK + ext_inode_size + 8
    ret

; rdi = optional child name (null lists names), esi = directory inode.
scan_dir:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 32
    mov     [rsp + 8], rdx
    mov     r12, rdi
    lea     rax, [rel dir_inode]
    mov     [rsp + 16], rax
    lea     rax, [rel dir_data]
    mov     [rsp + 24], rax
    test    r12, r12
    jnz     .load_directory
    test    rdx, rdx
    jz      .load_directory
    mov     [rsp + 16], rcx
    lea     rax, [rcx + ext_inode_size]
    mov     [rsp + 24], rax
.load_directory:
    mov     edi, esi
    call    directory_inode
    test    rax, rax
    jnz     .done
    lea     rsi, [rel dir_inode]
    mov     rdi, [rsp + 16]
    cmp     rdi, rsi
    je      .start
    mov     ecx, ext_inode_size / 8
    rep     movsq
.start:
    xor     r13d, r13d
.block:
    mov     rsi, [rsp + 16]
    mov     rax, [rsi + ext_inode.size]
    ext_block_index rax
    cmp     r13, rax
    jae     .end
    mov     rdi, r13
    call    map_block
    test    rax, rax
    jnz     .done
    test    edx, edx
    jz      .bad
    mov     ebx, edx
    imul    rbx, [rbp + mount_volume.ext_sectors]
    mov     r14, [rsp + 24]
    mov     r15d, [rbp + mount_volume.ext_sectors]
.read:
    mov     rdi, rbx
    mov     rsi, r14
    call    read_sector
    test    rax, rax
    jnz     .done
    inc     rbx
    add     r14, BLOCK_SIZE
    dec     r15d
    jnz     .read
    mov     rbx, [rsp + 24]
    mov     r15, r14
.entry:
    mov     rax, r15
    sub     rax, rbx
    cmp     eax, 8
    jb      .bad
    movzx   ecx, word [rbx + 4]
    cmp     ecx, 8
    jb      .bad
    test    ecx, 3
    jnz     .bad
    cmp     ecx, eax
    ja      .bad
    lea     r14, [rbx + rcx]
    mov     edx, [rbx]
    test    edx, edx
    jz      .advance
    cmp     edx, [rbp + mount_volume.ext_inodes]
    ja      .bad
    movzx   eax, byte [rbx + 6]
    test    dword [rbp + mount_volume.ext_features], EXT_FILETYPE
    jnz     .name
    cmp     byte [rbx + 7], 0
    jne     .bad
.name:
    test    eax, eax
    jz      .bad
    sub     ecx, 8
    cmp     eax, ecx
    ja      .bad
    xor     ecx, ecx
.name_byte:
    mov     dil, [rbx + rcx + 8]
    test    dil, dil
    jz      .bad
    cmp     dil, '/'
    je      .bad
    test    r12, r12
    jz      .next_byte
    cmp     dil, [r12 + rcx]
    jne     .advance
.next_byte:
    inc     ecx
    cmp     ecx, eax
    jb      .name_byte
    test    r12, r12
    jz      .list
    cmp     byte [r12 + rcx], 0
    jne     .advance
    xor     eax, eax
    jmp     .done
.list:
    cmp     byte [rbx + 8], '.'
    jne     .type
    cmp     eax, 1
    je      .advance
    cmp     eax, 2
    jne     .type
    cmp     byte [rbx + 9], '.'
    je      .advance
.type:
    mov     [rsp], eax
    mov     edi, edx
    lea     rsi, [rel entry_inode]
    call    load_inode
    test    rax, rax
    jnz     .done
    lea     rdi, [rbx + 8]
    mov     esi, [rsp]
    cmp     qword [rsp + 8], 0
    jne     .visit
    call    console_write
    cmp     dword [rel entry_inode + ext_inode.mode], EXT_DIR
    jne     .newline
    mov     edi, '/'
    call    console_putc
.newline:
    mov     edi, 10
    call    console_putc
    jmp     .advance
.visit:
    xor     edx, edx
    mov     eax, [rel entry_inode + ext_inode.mode]
    cmp     eax, EXT_DIR
    sete    dl
    cmp     eax, EXT_SYMLINK
    jne     .emit
    or      edx, ENTRY_SYMLINK
.emit:
    call    [rsp + 8]
    test    rax, rax
    jnz     .done
.advance:
    mov     rbx, r14
    cmp     rbx, r15
    jb      .entry
    inc     r13
    jmp     .block
.end:
    xor     eax, eax
    test    r12, r12
    jz      .done
    lea     rax, [rel missing_entry]
    jmp     .done
.bad:
    lea     rax, [rel corrupt_text]
.done:
    add     rsp, 32
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; rdi = name, esi = parent. On success return size in rdx and inode in ecx.
ext_open:
    sub     rsp, 8
    call    scan_dir
    test    rax, rax
    jnz     .done
    mov     [rsp], edx
    mov     edi, edx
    lea     rsi, [rel file_inode]
    call    load_inode
    test    rax, rax
    jnz     .done
    cmp     dword [rel file_inode + ext_inode.mode], EXT_REG
    jne     .type
    mov     [rel file_volume], rbp
    mov     qword [rel cached_logical], -1
    mov     byte [rel file_block_valid], 0
    mov     rdx, [rel file_inode + ext_inode.size]
    mov     ecx, [rsp]
    jmp     .done
.type:
    lea     rax, [rel not_regular]
.done:
    add     rsp, 8
    ret

; rdi = destination, rsi = byte offset, edx = count (up to 64 KiB).
ext_read_at:
    push    rbp
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbp, [rel file_volume]
    mov     r12, rdi
    mov     r13, rsi
    mov     r14d, edx
    cmp     r14d, 64 * 1024
    ja      .bad
    mov     rax, [rel file_inode + ext_inode.size]
    sub     rax, rsi
    jc      .bad
    cmp     r14, rax
    ja      .bad
.copy:
    test    r14d, r14d
    jz      .success
    call    console_cancel_check
    test    rax, rax
    jnz     .done
    mov     rbx, r13
    ext_block_index rbx
    cmp     rbx, [rel cached_logical]
    je      .cached
    mov     rdi, rbx
    lea     rsi, [rel file_inode]
    call    map_block
    test    rax, rax
    jnz     .done
    mov     byte [rel file_block_valid], 0
    mov     [rel cached_physical], edx
    mov     [rel cached_logical], rbx
.cached:
    cmp     dword [rbp + mount_volume.device], 1
    je      .read_block
    mov     rsi, r13
    and     esi, BLOCK_SIZE - 1
    mov     ebx, BLOCK_SIZE
    sub     ebx, esi
    cmp     ebx, r14d
    cmova   ebx, r14d
    mov     eax, [rel cached_physical]
    test    eax, eax
    jz      .hole
    mov     rdi, rax
    imul    rdi, [rbp + mount_volume.ext_sectors]
    mov     eax, r13d
    shr     eax, 9
    mov     ecx, [rbp + mount_volume.ext_sectors]
    dec     ecx
    and     eax, ecx
    add     rdi, rax
    lea     rsi, [rel file_sector]
    call    read_sector
    test    rax, rax
    jnz     .done
    mov     esi, r13d
    and     esi, BLOCK_SIZE - 1
    lea     rax, [rel file_sector]
    add     rsi, rax
.copy_bytes:
    mov     rdi, r12
    mov     ecx, ebx
    rep     movsb
    jmp     .advance
.read_block:
    mov     esi, r13d
    and     esi, [rbp + mount_volume.ext_block_mask]
    mov     ebx, [rbp + mount_volume.ext_block_size]
    sub     ebx, esi
    cmp     ebx, r14d
    cmova   ebx, r14d
    mov     edi, [rel cached_physical]
    test    edi, edi
    jz      .hole
    cmp     byte [rel file_block_valid], 0
    jne     .block_bytes
    imul    rdi, [rbp + mount_volume.ext_sectors]
    mov     rax, [rbp + mount_volume.total_sectors]
    sub     rax, rdi
    jc      .bad
    cmp     rax, [rbp + mount_volume.ext_sectors]
    jb      .bad
    add     rdi, [rbp + mount_volume.volume_base]
    mov     dword [rel block_selected], 1
    lea     rsi, [rel file_block]
    mov     ecx, [rbp + mount_volume.ext_sectors]
    call    block_read_range
    test    rax, rax
    jnz     .done
    mov     byte [rel file_block_valid], 1
.block_bytes:
    mov     esi, r13d
    and     esi, [rbp + mount_volume.ext_block_mask]
    lea     rax, [rel file_block]
    add     rsi, rax
    jmp     .copy_bytes
.hole:
    mov     rdi, r12
    mov     ecx, ebx
    xor     eax, eax
    rep     stosb
.advance:
    add     r12, rbx
    add     r13, rbx
    sub     r14d, ebx
    jmp     .copy
.success:
    xor     eax, eax
    jmp     .done
.bad:
    lea     rax, [rel corrupt_text]
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret

not_directory:
    lea     rax, [rel not_dir]
    ret
corrupt:
    lea     rax, [rel corrupt_text]
    ret

section .rodata
bad_super: db "Unsupported or invalid ext2 volume.", 10, 0
corrupt_text: db "Invalid ext2 metadata or block pointer.", 10, 0
indexed_directory: db "Invalid or unsupported ext2 directory index.", 10, 0
not_dir: db "Expected an ext2 directory.", 10, 0
not_regular: db "Expected a regular ext2 file.", 10, 0
missing_entry: db "Ext2 entry not found.", 10, 0

section .bss
alignb 8
file_volume: resq 1
cached_logical: resq 1
cached_physical: resd 1
file_block_valid: resb 1
dir_inode: resb ext_inode_size
entry_inode: resb ext_inode_size
file_inode: resb ext_inode_size
metadata: resb BLOCK_SIZE
dir_data: resb EXT_BLOCK
file_sector: resb BLOCK_SIZE
file_block: resb EXT_BLOCK

%include "ext2_verify.inc"
%include "ext2_features.inc"
%include "ext2_tree.inc"
%include "ext2_sparse.inc"
%include "ext2_write.inc"
%include "ext2_remove.inc"
%include "ext2_move.inc"
%include "ext2_namespace.inc"

section .text
ext_flush:
    mov     eax, [rbp + mount_volume.device]
    mov     [rel block_selected], eax
    jmp     block_flush
