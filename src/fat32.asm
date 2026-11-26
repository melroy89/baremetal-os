; FAT32 operations for the volume selected in rbp.
bits 64
default rel

%include "os_constants.inc"
%include "fat32_mount.inc"

%define FAT_MIN_CLUSTERS 65525
%define FAT_LINK_MASK    0x0FFFFFFF
%define FAT_END          0x0FFFFFF8
%define FAT_END_MARKER   0x0FFFFFFF
%define FAT_ENTRY_SIZE   32
%define FAT_ATTR_READ_ONLY 0x01

extern block_read
extern vfs_mount_overlap
extern block_write
extern block_flush
extern gpt_load
extern gpt_partition
extern parse_lba
extern ramfs_lookup
extern ramfs_not_found
extern console_write
extern console_write_cstr
extern console_putc

section .text
global fat_mount
global fat_list
global fat_cat
global fat_put
global fat_unmount
global fat_write
global fat_touch
global fat_rm
global fat_find_dir
global fat_validate_root

fat_mount:
    push    rbx
    cmp     byte [rbp + fat_volume.mounted], 0
    jne     .busy
    call    parse_lba
    jc      .partition
    cmp     rax, 128
    ja      .partition
    mov     ebx, eax
    call    gpt_load
    test    rax, rax
    jnz     .error
    mov     edi, ebx
    call    gpt_partition
    test    rax, rax
    jz      .partition
    mov     [rbp + fat_volume.volume_base], rax
    mov     [rbp + fat_volume.partition_last], rdx
    mov     rdi, rax
    mov     rsi, rdx
    mov     edx, [rbp + fat_volume.device]
    call    vfs_mount_overlap
    test    eax, eax
    jnz     .overlap
    mov     rax, [rbp + fat_volume.volume_base]
    mov     rdx, [rbp + fat_volume.partition_last]
    sub     rdx, rax
    inc     rdx
    mov     rbx, rdx
    mov     rdi, rax
    lea     rsi, [rel sector_buffer]
    call    block_read
    test    rax, rax
    jnz     .error

    lea     rdi, [rel sector_buffer]
    cmp     word [rdi + 510], 0xAA55
    jne     .invalid
    cmp     word [rdi + 11], BLOCK_SIZE
    jne     .invalid
    cmp     word [rdi + 17], 0         ; FAT32 has no fixed root table.
    jne     .invalid
    cmp     word [rdi + 19], 0
    jne     .invalid
    cmp     word [rdi + 22], 0
    jne     .invalid
    cmp     word [rdi + 42], 0
    jne     .invalid
    test    word [rdi + 40], 0x80      ; Require mirrored FATs.
    jnz     .invalid
    movzx   ecx, byte [rdi + 13]
    test    ecx, ecx
    jz      .invalid
    lea     eax, [rcx - 1]
    test    eax, ecx
    jnz     .invalid
    mov     [rbp + fat_volume.sectors_per_cluster], ecx
    movzx   eax, word [rdi + 14]
    test    eax, eax
    jz      .invalid
    mov     [rbp + fat_volume.reserved_sectors], eax
    mov     eax, [rdi + 32]
    cmp     rax, rbx
    ja      .invalid
    mov     [rbp + fat_volume.total_sectors], rax
    movzx   ecx, byte [rdi + 16]
    dec     ecx
    cmp     ecx, 1
    ja      .invalid
    inc     ecx
    mov     [rbp + fat_volume.fat_copies], ecx
    mov     eax, [rdi + 36]
    test    eax, eax
    jz      .invalid
    mov     [rbp + fat_volume.sectors_per_fat], eax
    imul    rax, rcx
    mov     ecx, [rbp + fat_volume.reserved_sectors]
    add     rax, rcx
    cmp     rax, [rbp + fat_volume.total_sectors]
    jae     .invalid
    mov     [rbp + fat_volume.data_start], rax
    mov     rcx, rax
    mov     rax, [rbp + fat_volume.total_sectors]
    sub     rax, rcx
    xor     edx, edx
    div     dword [rbp + fat_volume.sectors_per_cluster]
    cmp     eax, FAT_MIN_CLUSTERS
    jb      .invalid
    inc     eax
    cmp     eax, 0x0FFFFFF0
    jae     .invalid
    mov     [rbp + fat_volume.last_cluster], eax
    shr     eax, 7
    cmp     eax, [rbp + fat_volume.sectors_per_fat]
    jae     .invalid
    mov     eax, [rdi + 44]
    cmp     eax, 2
    jb      .invalid
    cmp     eax, [rbp + fat_volume.last_cluster]
    ja      .invalid
    mov     [rbp + fat_volume.root_cluster], eax
    movzx   eax, word [rdi + 48]
    mov     [rbp + fat_volume.fsinfo_lba], eax
    movzx   ecx, word [rdi + 50]
    cmp     ecx, 0xFFFF
    je      .no_backup_info
    add     ecx, eax
    jmp     .store_backup
.no_backup_info:
    xor     ecx, ecx
.store_backup:
    mov     [rbp + fat_volume.backup_fsinfo_lba], ecx
    mov     byte [rbp + fat_volume.mounted], 1
    mov     byte [rbp + fat_volume.pending_write], 0
    mov     byte [rbp + fat_volume.write_error], 0
    lea     rdi, [rel mounted_text]
    jmp     .print
.busy:
    lea     rax, [rel already_mounted]
    jmp     .error
.overlap:
    lea     rax, [rel overlapping_mount]
    jmp     .error
.partition:
    lea     rax, [rel missing_partition]
    jmp     .error
.invalid:
    lea     rax, [rel unsupported_volume]
.error:
    mov     rdi, rax
.print:
    pop     rbx
    jmp     console_write_cstr

fat_unmount:
    cmp     byte [rbp + fat_volume.mounted], 0
    je      print_unmounted
    cmp     byte [rbp + fat_volume.pending_write], 0
    je      .clear
    sub     rsp, 8
    call    block_flush
    add     rsp, 8
    test    rax, rax
    jnz     print_error
.clear:
    mov     byte [rbp + fat_volume.mounted], 0
    lea     rdi, [rel unmounted_text]
    jmp     console_write_cstr

fat_list:
    cmp     byte [rbp + fat_volume.mounted], 0
    je      print_unmounted
    mov     esi, edi
    mov     edi, 1
    sub     rsp, 8
    call    scan_directory
    add     rsp, 8
    test    rax, rax
    jnz     print_error
    ret

fat_cat:
    cmp     byte [rbp + fat_volume.mounted], 0
    je      print_unmounted
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, esi
    call    short_name
    jc      .bad_name
    mov     esi, ebx
    xor     edi, edi
    call    scan_directory
    test    rax, rax
    jnz     .error
    cmp     byte [rel slot_found], 0
    je      .missing
    test    byte [rel slot_attr], 0x10
    jnz     .is_directory
    mov     r12d, [rel slot_size]
    mov     r13d, [rel slot_cluster]
    mov     edi, r13d
    mov     esi, r12d
    call    check_chain
    test    rax, rax
    jnz     .error
    xor     r15d, r15d                 ; Last byte printed
    test    r12d, r12d
    jz      .done
.cluster:
    mov     edi, r13d
    call    cluster_lba
    test    rax, rax
    jz      .corrupt
    mov     r14, rax
    mov     ebx, [rbp + fat_volume.sectors_per_cluster]
.sector:
    mov     rdi, r14
    call    read_sector
    test    rax, rax
    jnz     .error
    mov     esi, BLOCK_SIZE
    cmp     r12d, esi
    cmovb   esi, r12d
    sub     r12d, esi
    lea     rdi, [rel sector_buffer]
    movzx   r15d, byte [rdi + rsi - 1]
    call    console_write
    test    r12d, r12d
    jz      .newline
    inc     r14
    dec     ebx
    jnz     .sector
    mov     edi, r13d
    call    get_link
    test    rax, rax
    jnz     .error
    mov     r13d, edx
    jmp     .cluster
.newline:
    cmp     r15b, 10
    je      .done
    mov     edi, 10
    call    console_putc
    jmp     .done
.is_directory:
    lea     rax, [rel name_is_directory]
    jmp     .error
.bad_name:
    lea     rax, [rel invalid_name]
    jmp     .error
.missing:
    lea     rax, [rel file_missing]
    jmp     .error
.corrupt:
    lea     rax, [rel invalid_chain]
.error:
    mov     rdi, rax
    call    console_write_cstr
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; esi = directory cluster (zero selects the root). edi != 0 lists entries.
; Otherwise find a unique name_buf match or the first free slot.
scan_directory:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r15d, edi
    mov     qword [rel slot_lba], 0
    mov     dword [rel slot_dir_cluster], 0
    mov     byte [rel slot_found], 0
    mov     byte [rel pending_lfn], 0
    mov     r12d, esi
    test    r12d, r12d
    cmovz   r12d, [rbp + fat_volume.root_cluster]
    mov     edi, r12d
    call    validate_directory_chain
    test    rax, rax
    jnz     .done
.cluster:
    mov     edi, r12d
    call    cluster_lba
    test    rax, rax
    jz      .corrupt
    mov     r13, rax
    mov     r14d, [rbp + fat_volume.sectors_per_cluster]
.sector:
    mov     rdi, r13
    call    read_sector
    test    rax, rax
    jnz     .done
    xor     ebx, ebx
.entry:
    lea     rsi, [rel sector_buffer]
    add     rsi, rbx
    cmp     byte [rsi], 0
    je      .end_marker
    cmp     byte [rsi], 0xE5
    je      .deleted
    cmp     byte [rsi + 11], 0x0F
    je      .long_name
    mov     dl, [rel pending_lfn]
    mov     byte [rel pending_lfn], 0
    test    byte [rsi + 11], 0x08      ; Skip volume labels.
    jnz     .advance
    test    r15d, r15d
    jnz     .list_entry
    lea     rdi, [rel name_buf]
    xor     ecx, ecx
.compare:
    mov     al, [rsi + rcx]
    cmp     al, 'a'
    jb      .compare_byte
    cmp     al, 'z'
    ja      .compare_byte
    sub     al, 'a' - 'A'
.compare_byte:
    cmp     al, [rdi + rcx]
    jne     .advance
    inc     ecx
    cmp     ecx, 11
    jb      .compare
    cmp     byte [rel slot_found], 0
    jne     .duplicate
    mov     [rel slot_lfn], dl
    mov     byte [rel slot_found], 1
    mov     byte [rel slot_at_end], 0
    mov     [rel slot_lba], r13
    mov     [rel slot_offset], ebx
    lea     rsi, [rel sector_buffer]
    add     rsi, rbx
    call    entry_cluster
    mov     [rel slot_cluster], eax
    mov     eax, [rsi + 28]
    mov     [rel slot_size], eax
    mov     al, [rsi + 11]
    mov     [rel slot_attr], al
    jmp     .advance
.long_name:
    mov     byte [rel pending_lfn], 1
    jmp     .advance
.list_entry:
    cmp     byte [rsi], '.'
    je      .advance
    mov     rdi, rsi
    call    print_name
    jmp     .advance
.deleted:
    mov     al, [rel pending_lfn]
    mov     byte [rel pending_lfn], 0
    test    al, al
    jnz     .advance
    cmp     qword [rel slot_lba], 0
    jne     .advance
    mov     byte [rel slot_at_end], 0
    mov     [rel slot_lba], r13
    mov     [rel slot_offset], ebx
.advance:
    add     ebx, FAT_ENTRY_SIZE
    cmp     ebx, BLOCK_SIZE
    jb      .entry
    inc     r13
    dec     r14d
    jnz     .sector
    mov     edi, r12d
    call    get_link
    test    rax, rax
    jnz     .done
    cmp     edx, FAT_END
    jae     .chain_end
    mov     r12d, edx
    jmp     .cluster
.chain_end:
    cmp     qword [rel slot_lba], 0
    jne     .success
    cmp     byte [rel pending_lfn], 0
    jne     .success
    mov     [rel slot_dir_cluster], r12d
    jmp     .success
.end_marker:
    cmp     qword [rel slot_lba], 0
    jne     .success
    cmp     byte [rel pending_lfn], 0
    jne     .success                  ; Do not attach an orphaned LFN to a new file.
    mov     byte [rel slot_at_end], 1
    mov     [rel slot_lba], r13
    mov     [rel slot_offset], ebx
    mov     [rel slot_dir_cluster], r12d
    mov     [rel slot_dir_left], r14d
.success:
    xor     eax, eax
    jmp     .done
.corrupt:
    lea     rax, [rel invalid_chain]
    jmp     .done
.duplicate:
    lea     rax, [rel duplicate_name]
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; Fill the padded uppercase name. Require an ASCII 8.3 component.
short_name:
    lea     rdx, [rel name_buf]
    mov     rax, 0x2020202020202020
    mov     [rdx], rax
    mov     [rdx + 8], eax
    xor     ecx, ecx
    mov     r8d, 8
.next:
    mov     al, [rdi]
    test    al, al
    jz      .finish
    cmp     al, '.'
    je      .extension
    cmp     ecx, r8d
    jae     .bad
    cmp     al, 'a'
    jb      .validate
    cmp     al, 'z'
    ja      .validate
    and     al, 0xDF
.validate:
    cmp     al, 'A'
    jb      .digit
    cmp     al, 'Z'
    jbe     .store
.digit:
    cmp     al, '0'
    jb      .punct
    cmp     al, '9'
    jbe     .store
.punct:
    lea     r9, [rel short_punctuation]
.check_punct:
    cmp     byte [r9], 0
    je      .bad
    cmp     al, [r9]
    je      .store
    inc     r9
    jmp     .check_punct
.store:
    mov     [rdx + rcx], al
    inc     ecx
    inc     rdi
    jmp     .next
.extension:
    test    ecx, ecx
    jz      .bad
    cmp     r8d, 8
    jne     .bad
    mov     r8d, 11
    mov     ecx, 8
    inc     rdi
    jmp     .next
.finish:
    test    ecx, ecx
    jz      .bad
    cmp     r8d, 11
    jne     .valid
    cmp     ecx, 8
    je      .bad
.valid:
    clc
    ret
.bad:
    stc
    ret

print_name:
    mov     dl, [rdi + 11]
    sub     rsp, 24
    mov     rsi, rdi
    mov     rdi, rsp
    mov     ecx, 8
.base:
    lodsb
    cmp     al, ' '
    je      .trim
    stosb
.trim:
    loop    .base
    cmp     byte [rsi], ' '
    je      .newline
    mov     al, '.'
    stosb
    mov     ecx, 3
.ext:
    lodsb
    cmp     al, ' '
    je      .end_ext
    stosb
.end_ext:
    loop    .ext
.newline:
    test    dl, 0x10
    jz      .end_line
    mov     al, '/'
    stosb
.end_line:
    mov     al, 10
    stosb
    mov     rsi, rdi
    sub     rsi, rsp
    mov     rdi, rsp
    call    console_write
    add     rsp, 24
    ret

; Return zero for invalid clusters, otherwise the volume-relative LBA.
cluster_lba:
    cmp     edi, 2
    jb      .bad
    cmp     edi, [rbp + fat_volume.last_cluster]
    ja      .bad
    lea     eax, [rdi - 2]
    mov     ecx, [rbp + fat_volume.sectors_per_cluster]
    imul    rax, rcx
    add     rax, [rbp + fat_volume.data_start]
    ret
.bad:
    xor     eax, eax
    ret

; edi = cluster. Return link in edx, with zero/error in rax.
get_link:
    push    rbx
    mov     ebx, edi
    mov     edi, ebx
    call    cluster_lba
    test    rax, rax
    jz      .invalid
    mov     edi, ebx
    shr     edi, 7
    add     edi, [rbp + fat_volume.reserved_sectors]
    call    read_sector
    test    rax, rax
    jnz     .done
    and     ebx, 127
    lea     rcx, [rel sector_buffer]
    mov     edx, [rcx + rbx * 4]
    and     edx, FAT_LINK_MASK
    jmp     .done
.invalid:
    lea     rax, [rel invalid_chain]
.done:
    pop     rbx
    ret

; Update one FAT entry in every FAT, preserving its reserved high bits.
set_link:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    and     ebx, 127
    shr     edi, 7
    add     edi, [rbp + fat_volume.reserved_sectors]
    mov     r12d, edi
    mov     r13d, esi
    mov     r14d, [rbp + fat_volume.fat_copies]
    lea     r15, [rel sector_buffer]
.copy:
    mov     rdi, r12
    call    read_sector
    test    rax, rax
    jnz     .done
    mov     eax, [r15 + rbx * 4]
    and     eax, 0xF0000000
    or      eax, r13d
    mov     [r15 + rbx * 4], eax
    mov     rdi, r12
    call    write_sector
    test    rax, rax
    jnz     .done
    mov     eax, [rbp + fat_volume.sectors_per_fat]
    add     r12, rax
    dec     r14d
    jnz     .copy
    xor     eax, eax
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; edi = sector in the first FAT. Read the corresponding sector in each copy.
read_fat_pair:
    push    rbx
    mov     ebx, edi
    lea     rsi, [rel fat_sector_pair]
    call    read_sector_into
    test    rax, rax
    jnz     .done
    cmp     dword [rbp + fat_volume.fat_copies], 2
    jne     .done
    mov     edi, ebx
    add     edi, [rbp + fat_volume.sectors_per_fat]
    lea     rsi, [rel fat_sector_pair + BLOCK_SIZE]
    call    read_sector_into
.done:
    pop     rbx
    ret

; rdi = relative sector. Reject addresses outside the volume.
read_sector:
    lea     rsi, [rel sector_buffer]
read_sector_into:
    cmp     rdi, [rbp + fat_volume.total_sectors]
    jae     bad_volume_sector
    add     rdi, [rbp + fat_volume.volume_base]
    jmp     block_read
write_sector:
    lea     rsi, [rel sector_buffer]
write_sector_from:
    cmp     rdi, [rbp + fat_volume.total_sectors]
    jae     bad_volume_sector
    add     rdi, [rbp + fat_volume.volume_base]
    jmp     block_write
bad_volume_sector:
    lea     rax, [rel unsupported_volume]
    ret

fat_put:
    cmp     byte [rbp + fat_volume.mounted], 0
    je      print_unmounted
    cmp     byte [rbp + fat_volume.write_error], 0
    jne     print_write_blocked
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    xor     r12d, r12d
.find_separator:
    mov     al, [rdi]
    test    al, al
    jz      .separator
    cmp     al, ' '
    cmove   r12, rdi
    inc     rdi
    jmp     .find_separator
.separator:
    test    r12, r12
    jz      .usage
    lea     rdi, [r12 + 1]
    call    short_name
    jc      .name
    lea     r12, [r12 + 1]
    lea     rdi, [r12 - 1]
.trim_source:
    cmp     rdi, rbx
    je      .usage
    cmp     byte [rdi - 1], ' '
    jne     .source
    dec     rdi
    jmp     .trim_source
.source:
    mov     byte [rdi], 0
    mov     rdi, rbx
    call    ramfs_lookup
    test    rax, rax
    jz      .missing
    mov     rdi, r12
    mov     rsi, rax
    xor     ecx, ecx
    add     rsp, 8
    pop     r12
    pop     rbx
    jmp     fat_write
.usage:
    lea     rax, [rel put_usage]
    jmp     .error
.name:
    lea     rax, [rel invalid_name]
    jmp     .error
.missing:
    add     rsp, 8
    pop     r12
    pop     rbx
    jmp     ramfs_not_found
.error:
    add     rsp, 8
    pop     r12
    pop     rbx
    jmp     print_error

; rdi = name, esi = parent cluster. Create an empty file only on a miss.
fat_touch:
    mov     ecx, esi
    xor     esi, esi
    xor     edx, edx
    mov     r8d, 1
    jmp     fat_store

; rdi = name, rsi = bytes, rdx = count, ecx = parent cluster (zero for root).
fat_write:
    xor     r8d, r8d
fat_store:
    cmp     byte [rbp + fat_volume.write_error], 0
    jne     print_write_blocked
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     [rsp], r8d                ; Create only, with no success message.
    cmp     rdx, 0x7FFFFFFF
    ja      .large
    mov     r12, rsi
    mov     r13d, edx
    mov     ebx, ecx
    call    short_name
    jc      .name
    mov     [rel new_size], r13d
    xor     edi, edi
    mov     esi, ebx
    call    scan_directory
    test    rax, rax
    jnz     .error
    cmp     qword [rel slot_lba], 0
    jne     .slot_ready
    cmp     dword [rel slot_dir_cluster], 0
    je      .directory_full
.slot_ready:
    mov     dword [rel old_head], 0
    cmp     byte [rel slot_found], 0
    je      .verify
    cmp     dword [rsp], 0
    jne     .touch_existing
    call    verify_file_slot
    test    rax, rax
    jnz     .error
    mov     eax, [rel slot_cluster]
    mov     [rel old_head], eax
.verify:
    call    verify_mutation_tree
    test    rax, rax
    jnz     .error

.prepare:
    call    prepare_mutation
    test    rax, rax
    jnz     .write_error
    xor     r14d, r14d                 ; Last allocated cluster
    mov     dword [rel new_head], 0
    mov     dword [rel alloc_cursor], 2
    test    r13d, r13d
    jz      .persist
.cluster:
    call    find_free
    test    rax, rax
    jnz     .write_error
    test    edx, edx
    jz      .no_space
    mov     r15d, edx                  ; Newly reserved cluster
    mov     edi, r15d
    mov     esi, FAT_END_MARKER
    call    set_link
    test    rax, rax
    jnz     .write_error
    test    r14d, r14d
    jnz     .append
    mov     [rel new_head], r15d
    jmp     .write_cluster
.append:
    mov     edi, r14d
    mov     esi, r15d
    call    set_link
    test    rax, rax
    jnz     .write_error
.write_cluster:
    mov     r14d, r15d
    mov     edi, r15d
    call    cluster_lba
    mov     r15, rax
    mov     ebx, [rbp + fat_volume.sectors_per_cluster]
.sector:
    lea     rdi, [rel sector_buffer]
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
    mov     rdi, r15
    call    write_sector
    test    rax, rax
    jnz     .write_error
    inc     r15
    dec     ebx
    jnz     .sector
    test    r13d, r13d
    jnz     .cluster

.persist:
    cmp     qword [rel slot_lba], 0
    jne     .end_marker
    call    extend_directory
    test    rax, rax
    jnz     .write_error
    cmp     qword [rel slot_lba], 0
    je      .no_space
.end_marker:
    call    preserve_end_marker
    test    rax, rax
    jnz     .write_error
    call    block_flush
    test    rax, rax
    jnz     .write_error
    mov     rdi, [rel slot_lba]
    call    read_sector
    test    rax, rax
    jnz     .write_error
    lea     rbx, [rel sector_buffer]
    mov     eax, [rel slot_offset]
    add     rbx, rax
    cmp     byte [rel slot_at_end], 0
    je      .build_entry
    cmp     eax, BLOCK_SIZE - FAT_ENTRY_SIZE
    jae     .build_entry
    mov     byte [rbx + FAT_ENTRY_SIZE], 0
.build_entry:
    cmp     byte [rel slot_found], 0
    jne     .replace_entry
    mov     rdi, rbx
    mov     ecx, FAT_ENTRY_SIZE / 8
    xor     eax, eax
    rep     stosq
    mov     rdi, rbx
    lea     rsi, [rel name_buf]
    mov     ecx, 11
    rep     movsb
    mov     word [rbx + 16], 0x21      ; 1980-01-01, since there is no RTC API.
    jmp     .set_attributes
.replace_entry:
    ; Keep the stored name, case flags, and creation timestamp.
    mov     al, [rel slot_attr]
    and     al, 0x06                 ; Keep hidden and system on replacement.
.set_attributes:
    or      al, 0x20                 ; Mark new or modified files for archiving.
    mov     [rbx + 11], al
    mov     word [rbx + 22], 0
    mov     word [rbx + 18], 0x21
    mov     word [rbx + 24], 0x21
    mov     eax, [rel new_head]
    mov     [rbx + 26], ax
    shr     eax, 16
    mov     [rbx + 20], ax
    mov     eax, [rel new_size]
    mov     [rbx + 28], eax
    mov     rdi, [rel slot_lba]
    call    write_sector
    test    rax, rax
    jnz     .write_error
    call    block_flush               ; Publish before reclaiming the old chain.
    test    rax, rax
    jnz     .write_error
    mov     edi, [rel old_head]
    call    free_chain
    test    rax, rax
    jnz     .write_error
    call    block_flush
    test    rax, rax
    jnz     .write_error
    mov     byte [rbp + fat_volume.pending_write], 0
    cmp     dword [rsp], 0
    jne     .done
    lea     rdi, [rel saved_text]
    jmp     .print

.no_space:
    mov     edi, [rel new_head]
    call    free_chain
    test    rax, rax
    jnz     .write_error
    call    block_flush
    test    rax, rax
    jnz     .write_error
    mov     byte [rbp + fat_volume.pending_write], 0
    lea     rax, [rel volume_full]
    jmp     .error
.write_error:
    mov     byte [rbp + fat_volume.write_error], 1
.error:
    mov     rdi, rax
.print:
    call    console_write_cstr
    jmp     .done
.name:
    lea     rax, [rel invalid_name]
    jmp     .error
.large:
    lea     rax, [rel file_large]
    jmp     .error
.directory_full:
    lea     rax, [rel root_full]
    jmp     .error
.touch_existing:
    test    byte [rel slot_attr], 0x10
    jz      .done
    lea     rax, [rel name_is_directory]
    jmp     .error
.done:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; rdi = name, esi = parent cluster. Return the child in edx or an error in rax.
fat_find_dir:
    push    rbx
    mov     ebx, esi
    call    short_name
    jc      .name
    mov     esi, ebx
    xor     edi, edi
    call    scan_directory
    test    rax, rax
    jnz     .done
    cmp     byte [rel slot_found], 1
    jne     .missing
    test    byte [rel slot_attr], 0x10
    jz      .missing
    mov     ebx, [rel slot_cluster]
    mov     edi, ebx
    call    validate_directory_chain
    mov     edx, ebx
    jmp     .done
.name:
    lea     rax, [rel invalid_name]
    jmp     .done
.missing:
    lea     rax, [rel directory_missing]
    jmp     .done
.done:
    pop     rbx
    ret

fat_validate_root:
    mov     edi, [rbp + fat_volume.root_cluster]

; Validate each mirrored link and detect cycles with Brent's algorithm.
validate_directory_chain:
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, edi                 ; Cycle detection checkpoint
    mov     r13d, 1                   ; Steps until the next checkpoint
    mov     r14d, 1                   ; Checkpoint interval
    mov     dword [rel cached_fat_lba], -1
.chain:
    cmp     ebx, 2
    jb      .bad
    cmp     ebx, [rbp + fat_volume.last_cluster]
    ja      .bad
    mov     edi, ebx
    call    cached_fat_link
    test    rax, rax
    jnz     .done
    cmp     edx, FAT_END
    jae     .done
    cmp     edx, r12d
    je      .bad
    mov     ebx, edx
    dec     r13d
    jnz     .chain
    mov     r12d, edx
    shl     r14d, 1
    mov     r13d, r14d
    jmp     .chain
.bad:
    lea     rax, [rel invalid_chain]
.done:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; rdi = name, esi = parent cluster.
fat_rm:
    cmp     byte [rbp + fat_volume.write_error], 0
    jne     print_write_blocked
    push    rbx
    mov     ebx, esi
    call    short_name
    jc      .name
    mov     esi, ebx
    xor     edi, edi
    call    scan_directory
    test    rax, rax
    jnz     .error
    cmp     byte [rel slot_found], 1
    jne     .missing
    call    verify_file_slot
    test    rax, rax
    jnz     .error
    cmp     byte [rel slot_lfn], 0
    jne     .long_name
    call    verify_mutation_tree
    test    rax, rax
    jnz     .error
    call    prepare_mutation
    test    rax, rax
    jnz     .write_error
    mov     rdi, [rel slot_lba]
    call    read_sector
    test    rax, rax
    jnz     .write_error
    lea     rbx, [rel sector_buffer]
    mov     eax, [rel slot_offset]
    mov     byte [rbx + rax], 0xE5
    mov     rdi, [rel slot_lba]
    call    write_sector
    test    rax, rax
    jnz     .write_error
    call    block_flush
    test    rax, rax
    jnz     .write_error
    mov     edi, [rel slot_cluster]
    test    edi, edi
    jz      .done
    call    free_chain
    test    rax, rax
    jnz     .write_error
    call    block_flush
    test    rax, rax
    jnz     .write_error
.done:
    mov     byte [rbp + fat_volume.pending_write], 0
    pop     rbx
    ret
.name:
    lea     rax, [rel invalid_name]
    jmp     .error
.missing:
    lea     rax, [rel file_missing]
    jmp     .error
.long_name:
    lea     rax, [rel lfn_remove]
    jmp     .error
.write_error:
    mov     byte [rbp + fat_volume.write_error], 1
.error:
    pop     rbx
    jmp     print_error

verify_file_slot:
    test    byte [rel slot_attr], 0x10
    jnz     .directory
    test    byte [rel slot_attr], FAT_ATTR_READ_ONLY
    jnz     .read_only
    mov     edi, [rel slot_cluster]
    mov     esi, [rel slot_size]
    jmp     check_chain
.directory:
    lea     rax, [rel name_is_directory]
    ret
.read_only:
    lea     rax, [rel file_read_only]
    ret

prepare_mutation:
    sub     rsp, 8
    call    block_flush
    test    rax, rax
    jnz     .done
    mov     byte [rbp + fat_volume.pending_write], 1
    mov     edi, [rbp + fat_volume.fsinfo_lba]
    call    invalidate_fsinfo
    test    rax, rax
    jnz     .done
    mov     edi, [rbp + fat_volume.backup_fsinfo_lba]
    call    invalidate_fsinfo
.done:
    add     rsp, 8
    ret

; rsi = directory entry. Return its first cluster in eax.
entry_cluster:
    movzx   eax, word [rsi + 20]
    shl     eax, 16
    mov     ax, [rsi + 26]
    and     eax, FAT_LINK_MASK
    ret

; edi = validated cluster. Return the mirrored link in edx, or error in rax.
cached_fat_link:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, edi
    shr     r12d, 7
    add     r12d, [rbp + fat_volume.reserved_sectors]
    cmp     r12d, [rel cached_fat_lba]
    je      .cached
    mov     edi, r12d
    call    read_fat_pair
    test    rax, rax
    jnz     .done
    mov     [rel cached_fat_lba], r12d
.cached:
    xor     eax, eax
    and     ebx, 127
    lea     rcx, [rel fat_sector_pair]
    mov     edx, [rcx + rbx * 4]
    and     edx, FAT_LINK_MASK
    cmp     dword [rbp + fat_volume.fat_copies], 2
    jne     .done
    mov     esi, [rcx + rbx * 4 + BLOCK_SIZE]
    and     esi, FAT_LINK_MASK
    cmp     edx, esi
    je      .done
    lea     rax, [rel fat_mismatch]
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; Validate exactly as many clusters as the recorded file uses. This also
; prevents a cyclic or out-of-range old chain from being reclaimed.
check_chain:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, [rbp + fat_volume.sectors_per_cluster]
    shl     r13d, 9
    test    r12d, r12d
    jnz     .next
    test    ebx, ebx
    jz      .ok
    jmp     .bad
.next:
    mov     edi, ebx
    call    get_link
    test    rax, rax
    jnz     .done
    cmp     r12d, r13d
    jbe     .last
    cmp     edx, FAT_END
    jae     .bad
    sub     r12d, r13d
    mov     ebx, edx
    jmp     .next
.last:
    cmp     edx, FAT_END
    jb      .bad
.ok:
    xor     eax, eax
    jmp     .done
.bad:
    lea     rax, [rel invalid_chain]
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

free_chain:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    test    ebx, ebx
    jz      .done
.next:
    mov     edi, ebx
    call    get_link
    test    rax, rax
    jnz     .return
    mov     r12d, edx
    mov     edi, ebx
    xor     esi, esi
    call    set_link
    test    rax, rax
    jnz     .return
    mov     ebx, r12d
    cmp     ebx, FAT_END
    jb      .next
.done:
    xor     eax, eax
.return:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; A cluster is free only when every FAT marks it free.
find_free:
    push    rbx
    mov     ebx, [rel alloc_cursor]
.sector:
    cmp     ebx, [rbp + fat_volume.last_cluster]
    ja      .full
    mov     edi, ebx
    shr     edi, 7
    add     edi, [rbp + fat_volume.reserved_sectors]
    call    read_fat_pair
    test    rax, rax
    jnz     .done
    lea     rcx, [rel fat_sector_pair]
    mov     r8, rcx
    cmp     dword [rbp + fat_volume.fat_copies], 2
    jne     .next
    lea     r8, [rcx + BLOCK_SIZE]
.next:
    mov     edx, ebx
    and     edx, 127
    mov     esi, [rcx + rdx * 4]
    or      esi, [r8 + rdx * 4]
    test    esi, FAT_LINK_MASK
    jz      .found
    inc     ebx
    cmp     ebx, [rbp + fat_volume.last_cluster]
    ja      .full
    test    ebx, 127
    jnz     .next
    jmp     .sector
.found:
    mov     edx, ebx
    inc     ebx
    mov     [rel alloc_cursor], ebx
    jmp     .done
.full:
    xor     eax, eax
    xor     edx, edx
.done:
    pop     rbx
    ret

; Mark optional free-count/allocation hints unknown without relying on them.
invalidate_fsinfo:
    test    edi, edi
    jz      .skip
    cmp     edi, [rbp + fat_volume.reserved_sectors]
    jae     .skip
    push    rbx
    mov     ebx, edi
    call    read_sector
    test    rax, rax
    jnz     .done
    lea     rcx, [rel sector_buffer]
    cmp     dword [rcx], 0x41615252
    jne     .done
    cmp     dword [rcx + 484], 0x61417272
    jne     .done
    cmp     dword [rcx + 508], 0xAA550000
    jne     .done
    mov     qword [rcx + 488], -1
    mov     edi, ebx
    call    write_sector
.done:
    pop     rbx
    ret
.skip:
    xor     eax, eax
    ret

; Append a zeroed cluster to the verified directory tail. Keep it
; unreachable until its end-of-directory marker is durable.
; Return success with slot_lba still zero when the disk is full.
extend_directory:
    push    rbx
    push    r12
    push    r13
    call    find_free
    test    rax, rax
    jnz     .done
    test    edx, edx
    jz      .done
    mov     ebx, edx
    mov     edi, ebx
    mov     esi, FAT_END_MARKER
    call    set_link
    test    rax, rax
    jnz     .done
    mov     edi, ebx
    call    cluster_lba
    mov     r12, rax
    mov     r13d, [rbp + fat_volume.sectors_per_cluster]
    lea     rdi, [rel sector_buffer]
    xor     eax, eax
    mov     ecx, BLOCK_SIZE / 8
    rep     stosq
.zero_sector:
    mov     rdi, r12
    call    write_sector
    test    rax, rax
    jnz     .done
    inc     r12
    dec     r13d
    jnz     .zero_sector
    call    block_flush
    test    rax, rax
    jnz     .done
    mov     edi, [rel slot_dir_cluster]
    mov     esi, ebx
    call    set_link
    test    rax, rax
    jnz     .done
    mov     edi, ebx
    call    cluster_lba
    mov     [rel slot_lba], rax
    mov     dword [rel slot_offset], 0
    mov     byte [rel slot_at_end], 1
    xor     eax, eax
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; When reusing an end marker in the last slot of a sector, preserve the
; marker in the following sector if there is one.
preserve_end_marker:
    cmp     byte [rel slot_at_end], 0
    je      .skip
    cmp     dword [rel slot_offset], BLOCK_SIZE - FAT_ENTRY_SIZE
    jne     .skip
    push    rbx
    mov     rbx, [rel slot_lba]
    inc     rbx
    cmp     dword [rel slot_dir_left], 1
    jne     .read
    mov     edi, [rel slot_dir_cluster]
    call    get_link
    test    rax, rax
    jnz     .done
    cmp     edx, FAT_END
    jae     .done
    mov     edi, edx
    call    cluster_lba
    test    rax, rax
    jz      .bad
    mov     rbx, rax
.read:
    mov     rdi, rbx
    call    read_sector
    test    rax, rax
    jnz     .done
    mov     byte [rel sector_buffer], 0
    mov     rdi, rbx
    call    write_sector
    jmp     .done
.bad:
    lea     rax, [rel invalid_chain]
.done:
    pop     rbx
    ret
.skip:
    xor     eax, eax
    ret

print_unmounted:
    lea     rdi, [rel no_mount]
    jmp     console_write_cstr
print_write_blocked:
    lea     rdi, [rel blocked_text]
    jmp     console_write_cstr
print_error:
    mov     rdi, rax
    jmp     console_write_cstr

section .rodata
short_punctuation:  db "!#$%&'()-@^_`{}~", 0
mounted_text:       db "FAT32 mounted.", 10, 0
unmounted_text:     db "FAT32 unmounted.", 10, 0
already_mounted:    db "Unmount the current FAT32 volume first.", 10, 0
overlapping_mount:   db "Partition overlaps an active mount.", 10, 0
no_mount:           db "No FAT32 volume mounted.", 10, 0
missing_partition:  db "Invalid or missing GPT partition.", 10, 0
unsupported_volume: db "Unsupported or invalid FAT32 volume.", 10, 0
invalid_name:       db "Use a short FAT name (8.3).", 10, 0
file_missing:       db "Disk file not found.", 10, 0
invalid_chain:      db "Invalid or unsupported FAT32 cluster chain.", 10, 0
file_read_only:     db "Disk file is read-only.", 10, 0
name_is_directory:  db "Disk name refers to a directory.", 10, 0
directory_missing:   db "FAT32 directory not found.", 10, 0
duplicate_name:     db "Duplicate FAT32 short name.", 10, 0
lfn_remove:         db "Cannot remove a FAT32 file with long-name entries.", 10, 0
root_full:          db "FAT32 directory is full.", 10, 0
volume_full:        db "FAT32 volume is full.", 10, 0
file_large:         db "RAM file is too large for this FAT32 writer.", 10, 0
put_usage:          db "Usage: disk put RAMFILE NAME", 10, 0
saved_text:         db "Disk file saved.", 10, 0
blocked_text:       db "FAT32 writes stopped after an I/O error.", 10, 0

section .bss
alignb 8
slot_lba:             resq 1
slot_offset:         resd 1
slot_dir_cluster:    resd 1
slot_dir_left:       resd 1
slot_size:           resd 1
slot_cluster:        resd 1
new_size:            resd 1
new_head:            resd 1
old_head:            resd 1
cached_fat_lba:      resd 1
alloc_cursor:        resd 1
slot_found:          resb 1
slot_at_end:         resb 1
slot_attr:           resb 1
slot_lfn:            resb 1
pending_lfn:         resb 1
name_buf:            resb 11
alignb 16
fat_sector_pair:      resb 2 * BLOCK_SIZE
sector_buffer:       resb BLOCK_SIZE

%include "fat32_check.inc"
