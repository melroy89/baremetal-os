; Boot archive and page-backed writable RAM files.
bits 64
default rel

%include "os_constants.inc"

%define TAR_BLOCK         512
%define TAR_NAME_SIZE     100
%define TAR_SIZE          124
%define TAR_CHECKSUM      148
%define TAR_CHECKSUM_SIZE 8
%define TAR_TYPE          156
%define TAR_MAGIC         257
%define TAR_PREFIX        345

%define FILE_NEXT 0
%define FILE_SIZE 8
%define FILE_NAME 16
%define FILE_DATA (FILE_NAME + TAR_NAME_SIZE)

%define INDEX_BUCKETS     2048
; Archive addresses, file sizes, and allocator pages fit below 4 GiB.
%define INDEX_HASH_NEXT   0
%define INDEX_HEADER      4
%define INDEX_FILE_SIZE   8
%define INDEX_ORDER_NEXT  12
%define INDEX_ORDER_LINK  16
%define INDEX_SHADOWED    20
%define INDEX_RECORD_SIZE 24
%define INDEX_PAGE_DATA   4
%define INDEX_PAGE_RECORDS ((PAGE_SIZE - INDEX_PAGE_DATA) / INDEX_RECORD_SIZE)

extern console_write
extern console_write_cstr
extern console_putc
extern str_eq
extern page_alloc
extern page_free

section .text
global ramfs_mount
global ramfs_ls
global ramfs_cat
global ramfs_write
global ramfs_rm

; rdi = Multiboot info. Publish the archive only after validating every entry.
ramfs_mount:
    push    rbx
    push    r12
    push    r13
    lea     rax, [rel no_archive]
    mov     [rel archive_error], rax
    mov     rax, PHYS_MAP_END - MBI_SIZE
    test    rdi, rdi
    jz      .done
    cmp     rdi, rax
    ja      .invalid
    test    dword [rdi + MBI_FLAGS], 1 << 3
    jz      .done

    cmp     dword [rdi + MBI_MODS_COUNT], 0
    je      .done
    mov     edi, [rdi + MBI_MODS_ADDR]
    mov     eax, HIGH_MMIO_BASE - MB_MODULE_SIZE
    test    edi, edi
    jz      .invalid
    cmp     edi, eax
    ja      .invalid
    mov     ebx, [rdi]
    mov     r12d, [rdi + 4]
    mov     eax, HIGH_MMIO_BASE
    test    ebx, ebx
    jz      .invalid
    cmp     r12, rax
    ja      .invalid
    cmp     rbx, r12
    jae     .invalid

    lea     rax, [rel archive_index_seed]
    mov     [rel archive_index_page], eax
    lea     rax, [rel archive_index_head]
    mov     [rel archive_index_tail_link], eax
    mov     r13, rbx
.scan:
    mov     rdi, r13
    mov     rsi, r12
    call    tar_entry
    test    rax, rax
    js      .discard_invalid
    jz      .mounted
    mov     rbx, rax
    mov     rdi, r13
    mov     rsi, rdx
    call    index_archive_entry
    test    rax, rax
    jz      .out_of_memory
    mov     r13, rbx
    jmp     .scan

.mounted:
    mov     byte [rel archive_mounted], 1
    jmp     .done
.discard_invalid:
    call    discard_archive_index
.invalid:
    lea     rax, [rel bad_archive]
    jmp     .unavailable
.out_of_memory:
    call    discard_archive_index
    lea     rax, [rel no_index_memory]
.unavailable:
    mov     [rel archive_error], rax
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; Index the validated header in rdi and its payload size in rsi.
; Return the record, or zero if its storage could not be allocated.
index_archive_entry:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    call    find_archived
    test    rax, rax
    jnz     .replace

    mov     r13, rdx
    call    allocate_index_record
    test    rax, rax
    jz      .done
    mov     ecx, [r13]
    mov     [rax + INDEX_HASH_NEXT], ecx
    mov     [r13], eax
    mov     byte [rax + INDEX_SHADOWED], 0
    jmp     .append

.replace:
    ; Move the existing name to the position of its final occurrence.
    mov     ecx, [rax + INDEX_ORDER_NEXT]
    test    ecx, ecx
    jz      .store
    mov     edx, [rax + INDEX_ORDER_LINK]
    mov     [rdx], ecx
    mov     [rcx + INDEX_ORDER_LINK], edx
.append:
    mov     ecx, [rel archive_index_tail_link]
    mov     [rax + INDEX_ORDER_LINK], ecx
    mov     [rcx], eax
    mov     dword [rax + INDEX_ORDER_NEXT], 0
    lea     rcx, [rax + INDEX_ORDER_NEXT]
    mov     [rel archive_index_tail_link], ecx
.store:
    mov     [rax + INDEX_HEADER], ebx
    mov     [rax + INDEX_FILE_SIZE], r12d
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

allocate_index_record:
    mov     ecx, [rel archive_index_used]
    mov     eax, [rel archive_index_page]
    cmp     ecx, INDEX_PAGE_RECORDS
    jb      .slot
    sub     rsp, 8
    call    page_alloc
    add     rsp, 8
    test    rax, rax
    jz      .done
    mov     ecx, [rel archive_index_page]
    mov     [rax], ecx
    mov     [rel archive_index_page], eax
    xor     ecx, ecx
.slot:
    lea     edx, [rcx + 1]
    mov     [rel archive_index_used], edx
    imul    ecx, INDEX_RECORD_SIZE
    lea     rax, [rax + rcx + INDEX_PAGE_DATA]
.done:
    ret

discard_archive_index:
    push    rbx
    lea     rbx, [rel archive_index_seed]
.free_page:
    mov     edi, [rel archive_index_page]
    cmp     rdi, rbx
    je      .clear
    mov     eax, [rdi]
    mov     [rel archive_index_page], eax
    call    page_free
    jmp     .free_page
.clear:
    mov     dword [rel archive_index_head], 0
    mov     dword [rel archive_index_used], 0
    lea     rdi, [rel archive_index_buckets]
    mov     ecx, INDEX_BUCKETS
    xor     eax, eax
    rep     stosd
    pop     rbx
    ret

; rdi = header, rsi = archive end. Return the next header in rax and file
; size in rdx, or rax = 0 at the end of the archive, -1 on invalid input.
tar_entry:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    lea     rax, [rbx + TAR_BLOCK]
    cmp     rax, r12
    ja      .bad
    cmp     byte [rbx], 0
    je      .end_marker

    cmp     dword [rbx + TAR_MAGIC], 'usta'
    jne     .bad
    cmp     word [rbx + TAR_MAGIC + 4], 'r'
    jne     .bad
    cmp     word [rbx + TAR_MAGIC + 6], '00'
    jne     .bad
    cmp     byte [rbx + TAR_PREFIX], 0
    jne     .bad
    mov     al, [rbx + TAR_TYPE]
    test    al, al
    jz      .name
    cmp     al, '0'
    jne     .bad

.name:
    mov     rdi, rbx
    call    filename_length
    test    eax, eax
    jz      .bad

    lea     rdi, [rbx + TAR_CHECKSUM]
    mov     ecx, TAR_CHECKSUM_SIZE
    call    tar_octal
    mov     r13, rax
    xor     ecx, ecx
    mov     edx, TAR_CHECKSUM_SIZE * ' '
.sum:
    movzx   eax, byte [rbx + rcx]
    add     edx, eax
    inc     ecx
    cmp     ecx, TAR_CHECKSUM
    jne     .sum_tail
    add     ecx, TAR_CHECKSUM_SIZE
.sum_tail:
    cmp     ecx, TAR_BLOCK
    jb      .sum
    cmp     rdx, r13
    jne     .bad

    lea     rdi, [rbx + TAR_SIZE]
    mov     ecx, 12
    call    tar_octal
    test    rax, rax
    js      .bad
    mov     rdx, rax
    add     rax, TAR_BLOCK - 1
    and     rax, -TAR_BLOCK
    lea     rax, [rbx + rax + TAR_BLOCK]
    cmp     rax, r12
    ja      .bad
    jmp     .return

.end_marker:
    lea     rax, [rbx + 2 * TAR_BLOCK]
    cmp     rax, r12
    ja      .bad
    xor     eax, eax
    mov     rdi, rbx
    mov     ecx, 2 * TAR_BLOCK / 8
    repe    scasq
    je      .return

.bad:
    mov     rax, -1
.return:
    pop     r13
    pop     r12
    pop     rbx
    ret

; Parse a fixed-width, ASCII octal tar field. Widths are at most 12 bytes.
tar_octal:
    xor     eax, eax
.leading_space:
    cmp     byte [rdi], ' '
    jne     .first_digit
    inc     rdi
    dec     ecx
    jnz     .leading_space
    jmp     .bad
.first_digit:
    cmp     byte [rdi], '0'
    jb      .bad
    cmp     byte [rdi], '7'
    ja      .bad
.digits:
    movzx   edx, byte [rdi]
    sub     edx, '0'
    cmp     edx, 7
    ja      .padding
    lea     rax, [rax * 8 + rdx]
    inc     rdi
    dec     ecx
    jnz     .digits
    ret
.padding:
    cmp     byte [rdi], 0
    je      .advance
    cmp     byte [rdi], ' '
    jne     .bad
.advance:
    inc     rdi
    dec     ecx
    jnz     .padding
    ret
.bad:
    mov     rax, -1
    ret

; Return the name length, or zero for an invalid flat filename.
filename_length:
    xor     eax, eax
    cmp     byte [rdi], 0
    je      .bad
    cmp     byte [rdi], ' '
    je      .bad
.next:
    cmp     eax, TAR_NAME_SIZE
    jae     .bad
    mov     dl, [rdi + rax]
    test    dl, dl
    jz      .end
    cmp     dl, ' '
    jb      .bad
    cmp     dl, '~'
    ja      .bad
    cmp     dl, '/'
    je      .bad
    inc     eax
    jmp     .next
.end:
    cmp     byte [rdi + rax - 1], ' '
    jne     .done
.bad:
    xor     eax, eax
.done:
    ret

; Return the writable record in rax. rdx points to its incoming link,
; or to the last link in the list when the name does not exist.
find_writable:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    lea     rbx, [rel writable_head]
.next:
    mov     r13, [rbx]
    test    r13, r13
    jz      .done
    mov     rdi, r12
    lea     rsi, [r13 + FILE_NAME]
    call    str_eq
    test    eax, eax
    jnz     .done
    lea     rbx, [r13 + FILE_NEXT]
    jmp     .next
.done:
    mov     rax, r13
    mov     rdx, rbx
    pop     r13
    pop     r12
    pop     rbx
    ret

; Return the indexed record in rax and the bucket address in rdx.
find_archived:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     eax, 2166136261              ; FNV-1a offset basis
.hash:
    movzx   ecx, byte [rdi]
    test    ecx, ecx
    jz      .bucket
    xor     eax, ecx
    imul    eax, 16777619
    inc     rdi
    jmp     .hash
.bucket:
    and     eax, INDEX_BUCKETS - 1
    lea     rbx, [rel archive_index_buckets]
    lea     rbx, [rbx + rax * 4]
    mov     r13d, [rbx]
.next:
    test    r13, r13
    jz      .done
    mov     rdi, r12
    mov     esi, [r13 + INDEX_HEADER]
    call    str_eq
    test    eax, eax
    jnz     .done
    mov     r13d, [r13 + INDEX_HASH_NEXT]
    jmp     .next
.done:
    mov     rax, r13
    mov     rdx, rbx
    pop     r13
    pop     r12
    pop     rbx
    ret

ramfs_ls:
    cmp     byte [rel archive_mounted], 0
    jne     .list
    cmp     qword [rel writable_head], 0
    je      ramfs_unavailable
.list:
    push    rbx
    mov     ebx, [rel archive_index_head]
.archive_entry:
    test    rbx, rbx
    jz      .writable
    cmp     byte [rbx + INDEX_SHADOWED], 0
    jne     .next_archive
    mov     edi, [rbx + INDEX_HEADER]
    call    print_filename
.next_archive:
    mov     ebx, [rbx + INDEX_ORDER_NEXT]
    jmp     .archive_entry
.writable:
    mov     rbx, [rel writable_head]
.writable_entry:
    test    rbx, rbx
    jz      .done
    lea     rdi, [rbx + FILE_NAME]
    call    print_filename
    mov     rbx, [rbx + FILE_NEXT]
    jmp     .writable_entry
.done:
    pop     rbx
    ret

print_filename:
    sub     rsp, 8
    call    console_write_cstr
    mov     edi, 10
    add     rsp, 8
    jmp     console_putc

ramfs_cat:
    cmp     byte [rdi], 0
    je      .usage
    push    r12
    mov     r12, rdi
    call    find_writable
    test    rax, rax
    jz      .archive
    mov     rdx, [rax + FILE_SIZE]
    add     rax, FILE_DATA
    jmp     .print
.archive:
    mov     rdi, r12
    call    find_archived
    test    rax, rax
    jz      .missing
    mov     edx, [rax + INDEX_FILE_SIZE]
    mov     eax, [rax + INDEX_HEADER]
    add     rax, TAR_BLOCK
.print:
    pop     r12
    mov     rdi, rax
    mov     rsi, rdx
    jmp     print_file
.missing:
    pop     r12
    jmp     ramfs_not_found
.usage:
    lea     rdi, [rel cat_usage]
    jmp     console_write_cstr

; One page holds metadata and the complete output line. Replacing a file
; reuses its page. The boot archive stays available underneath the copy.
; rdi = flat file name, rsi = text, rdx = text length.
ramfs_write:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    cmp     r14, PAGE_SIZE - FILE_DATA - 1
    ja      .too_long
    call    filename_length
    test    eax, eax
    jz      .bad_name
    mov     ebx, eax

    mov     rdi, r12
    call    find_writable
    xor     r15d, r15d
    test    rax, rax
    jnz     .store
    mov     r15, rdx
    call    page_alloc
    test    rax, rax
    jz      .out_of_memory
    mov     qword [rax + FILE_NEXT], 0
    lea     rdi, [rax + FILE_NAME]
    mov     rsi, r12
    lea     ecx, [rbx + 1]
    rep     movsb
.store:
    lea     rdi, [rax + FILE_DATA]
    mov     rsi, r13
    mov     rcx, r14
    rep     movsb
    mov     byte [rdi], 10
    lea     rcx, [r14 + 1]
    mov     [rax + FILE_SIZE], rcx
    test    r15, r15
    jz      .done
    mov     [r15], rax
    mov     rdi, r12
    call    find_archived
    test    rax, rax
    jz      .done
    mov     byte [rax + INDEX_SHADOWED], 1
    jmp     .done
.bad_name:
    lea     rdi, [rel invalid_name]
    jmp     .error
.too_long:
    lea     rdi, [rel file_too_long]
    jmp     .error
.out_of_memory:
    lea     rdi, [rel no_free_pages]
.error:
    call    console_write_cstr
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

ramfs_rm:
    cmp     byte [rdi], 0
    je      .usage
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    call    find_writable
    test    rax, rax
    jz      .archive
    mov     rbx, rdx
    mov     r13, [rax + FILE_NEXT]
    mov     rdi, rax
    call    page_free
    mov     [rbx], r13
    mov     rdi, r12
    call    find_archived
    test    rax, rax
    jz      .done
    mov     byte [rax + INDEX_SHADOWED], 0
    jmp     .done
.archive:
    mov     rdi, r12
    call    find_archived
    test    rax, rax
    jz      .missing
    lea     rdi, [rel read_only]
    call    console_write_cstr
    jmp     .done
.missing:
    call    ramfs_not_found
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret
.usage:
    lea     rdi, [rel rm_usage]
    jmp     console_write_cstr

print_file:
    test    rsi, rsi
    jz      .done
    push    rbx
    xor     ebx, ebx
    cmp     byte [rdi + rsi - 1], 10
    setne   bl
    call    console_write
    test    ebx, ebx
    pop     rbx
    jz      .done
    mov     edi, 10
    jmp     console_putc
.done:
    ret

ramfs_not_found:
    cmp     byte [rel archive_mounted], 0
    jne     .missing
    cmp     qword [rel writable_head], 0
    je      ramfs_unavailable
.missing:
    lea     rdi, [rel missing_file]
    jmp     console_write_cstr

ramfs_unavailable:
    mov     rdi, [rel archive_error]
    jmp     console_write_cstr

section .rodata
no_archive:   db "No RAM filesystem loaded.", 10, 0
bad_archive:  db "Invalid RAM filesystem archive.", 10, 0
no_index_memory: db "No free pages for the RAM filesystem index.", 10, 0
missing_file: db "File not found.", 10, 0
cat_usage:    db "Usage: cat FILE", 10, 0
rm_usage:     db "Usage: rm FILE", 10, 0
read_only:    db "Archive file is read-only.", 10, 0
invalid_name: db "Invalid RAM filename.", 10, 0
file_too_long: db "Text is too long for a RAM file.", 10, 0
no_free_pages: db "No free pages for a RAM file.", 10, 0

section .bss
alignb 8
archive_error: resq 1
writable_head: resq 1
archive_index_head: resd 1
archive_index_tail_link: resd 1
archive_index_page: resd 1
archive_index_buckets: resd INDEX_BUCKETS
; Keep small archives usable even when the bootloader supplies no memory map.
archive_index_seed: resb PAGE_SIZE
archive_index_used: resd 1
archive_mounted: resb 1
