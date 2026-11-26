; Source cursor for a single synchronous copy. The destination uses the
; regular FAT32 writer and publishes its replacement only after all reads.
section .text

; rbp = volume, rdi = name, esi = parent. Return size in edx or error in rax.
fat_copy_open:
    push    rbx
    mov     ebx, esi
    call    short_name
    jc      .bad_name
    mov     esi, ebx
    xor     edi, edi
    call    scan_directory
    test    rax, rax
    jnz     .done
    cmp     byte [rel slot_found], 0
    je      .missing
    test    byte [rel slot_attr], 0x10
    jnz     .directory
    mov     edi, [rel slot_cluster]
    mov     esi, [rel slot_size]
    call    check_chain
    test    rax, rax
    jnz     .done
    mov     [rel copy_volume], rbp
    mov     rax, [rel slot_lba]
    mov     [rel copy_entry_lba], rax
    mov     eax, [rel slot_offset]
    mov     [rel copy_entry_offset], eax
    mov     edx, [rel slot_size]
    xor     eax, eax
    test    edx, edx
    jz      .done
    mov     edi, [rel slot_cluster]
    call    validate_directory_chain
    test    rax, rax
    jnz     .done
    mov     edi, [rel slot_cluster]
    call    copy_start_cluster
    mov     edx, [rel slot_size]
    xor     eax, eax
.done:
    pop     rbx
    ret
.bad_name:
    lea     rax, [rel invalid_name]
    jmp     .done
.missing:
    lea     rax, [rel file_missing]
    jmp     .done
.directory:
    lea     rax, [rel name_is_directory]
    jmp     .done

; rdi = sector-sized destination. The caller supplies the byte count.
fat_copy_chunk:
    push    rbx
    push    rbp
    sub     rsp, 8
    mov     rbx, rdi
    mov     rbp, [rel copy_volume]
    cmp     dword [rel copy_sectors_left], 0
    jne     .read
    mov     edi, [rel copy_cluster]
    call    get_link
    test    rax, rax
    jnz     .done
    cmp     edx, 2
    jb      .invalid
    cmp     edx, [rbp + fat_volume.last_cluster]
    ja      .invalid
    mov     edi, edx
    call    copy_start_cluster
.read:
    mov     rdi, [rel copy_next_sector]
    mov     rsi, rbx
    call    read_sector_into
    test    rax, rax
    jnz     .done
    inc     qword [rel copy_next_sector]
    dec     dword [rel copy_sectors_left]
.done:
    add     rsp, 8
    pop     rbp
    pop     rbx
    ret
.invalid:
    lea     rax, [rel invalid_chain]
    jmp     .done

copy_start_cluster:
    sub     rsp, 8
    mov     [rel copy_cluster], edi
    call    cluster_lba
    mov     [rel copy_next_sector], rax
    mov     eax, [rbp + fat_volume.sectors_per_cluster]
    mov     [rel copy_sectors_left], eax
    add     rsp, 8
    ret
