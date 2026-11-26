; Bounded read-only GPT parser for the block device.
bits 64
default rel

%include "os_constants.inc"

%define GPT_HEADER_MIN 92
%define GPT_ENTRY_BYTES 128
%define GPT_MAX_ENTRIES 128
%define RANGE_SIZE 16

extern block_init
extern block_read
extern block_count
extern crc32_buffer
extern crc32_update
extern console_putc
extern console_write_cstr
extern write_u64

section .text
global command_gpt
global gpt_load
global gpt_partition

command_gpt:
    push    rbx
    push    r12
    push    r13
    call    gpt_load
    test    rax, rax
    jnz     .error
    lea     rdi, [rel primary_text]
    cmp     byte [rel gpt_backup], 0
    je      .heading
    lea     rdi, [rel backup_text]
.heading:
    call    console_write_cstr
    lea     r12, [rel ranges]
    xor     ebx, ebx
.next:
    cmp     ebx, [rel entry_count]
    jae     .done
    cmp     qword [r12], 0
    je      .advance
    lea     rdi, [rel partition_text]
    call    console_write_cstr
    lea     edi, [rbx + 1]
    call    write_u64
    lea     rdi, [rel lba_text]
    call    console_write_cstr
    mov     rdi, [r12]
    call    write_u64
    mov     edi, '-'
    call    console_putc
    mov     rdi, [r12 + 8]
    call    write_u64
    mov     edi, 10
    call    console_putc
.advance:
    inc     ebx
    add     r12, RANGE_SIZE
    jmp     .next
.error:
    mov     rdi, rax
    call    console_write_cstr
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; Read and validate at least one GPT copy. Return zero or an error string.
gpt_load:
    push    rbx
    call    block_init
    test    rax, rax
    jnz     .done
    mov     rbx, [rel block_count]
    dec     rbx
    cmp     rbx, 3
    jb      .invalid
    mov     byte [rel gpt_backup], 0
    mov     edi, 1
    call    load_copy
    test    eax, eax
    jz      .done
    mov     byte [rel gpt_backup], 1
    mov     rdi, rbx
    call    load_copy
    test    eax, eax
    jz      .done
.invalid:
    lea     rax, [rel invalid_text]
.done:
    pop     rbx
    ret

; Return first and last LBA in rax and rdx for one-based partition edi.
; Must follow a successful gpt_load. Return zero for an absent partition.
gpt_partition:
    dec     edi
    xor     eax, eax
    cmp     edi, [rel entry_count]
    jae     .none
    shl     edi, 4
    lea     rcx, [rel ranges]
    mov     rax, [rcx + rdi]
    mov     rdx, [rcx + rdi + 8]
.none:
    ret

; rdi = actual header LBA. Return zero for a valid copy, one otherwise.
load_copy:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    lea     rbx, [rel sector]
    mov     rsi, rbx
    call    block_read
    test    rax, rax
    jnz     .bad
    mov     rax, 'EFI PART'
    cmp     [rbx], rax
    jne     .bad
    cmp     dword [rbx + 8], 0x10000
    jne     .bad
    mov     esi, [rbx + 12]
    cmp     esi, GPT_HEADER_MIN
    jb      .bad
    cmp     esi, BLOCK_SIZE
    ja      .bad
    cmp     dword [rbx + 20], 0
    jne     .bad
    cmp     [rbx + 24], r12
    jne     .bad

    mov     r13, [rel block_count]
    dec     r13
    mov     eax, 1
    cmp     r12, 1
    cmove   rax, r13
    cmp     [rbx + 32], rax
    jne     .bad
    mov     rax, [rbx + 40]
    cmp     rax, 2
    jb      .bad
    mov     [rel first_usable], rax
    mov     rcx, [rbx + 48]
    cmp     rcx, rax
    jb      .bad
    cmp     rcx, r13
    jae     .bad
    mov     [rel last_usable], rcx

    cmp     dword [rbx + 84], GPT_ENTRY_BYTES
    jne     .bad
    mov     r14d, [rbx + 80]
    test    r14d, r14d
    jz      .bad
    cmp     r14d, GPT_MAX_ENTRIES
    ja      .bad
    mov     [rel entry_count], r14d
    mov     r15, [rbx + 72]
    lea     eax, [r14 + 3]
    shr     eax, 2
    lea     rcx, [rax + 2]
    cmp     [rel first_usable], rcx
    jb      .bad
    mov     rcx, r13
    sub     rcx, rax
    jc      .bad
    cmp     [rel last_usable], rcx
    jae     .bad
    add     rax, r15
    jc      .bad
    cmp     r12, 1
    jne     .backup_range
    cmp     r15, 2
    jb      .bad
    cmp     rax, [rel first_usable]
    ja      .bad
    jmp     .header_crc
.backup_range:
    cmp     r15, [rel last_usable]
    jbe     .bad
    cmp     rax, r13
    ja      .bad

.header_crc:
    mov     r13d, [rbx + 16]
    mov     dword [rbx + 16], 0
    mov     rdi, rbx
    call    crc32_buffer
    cmp     eax, r13d
    jne     .bad
    mov     eax, [rbx + 88]
    mov     [rel expected_crc], eax

    lea     rdi, [rel ranges]
    xor     eax, eax
    mov     ecx, GPT_MAX_ENTRIES * RANGE_SIZE / 8
    rep     stosq
    xor     r13d, r13d                 ; Incremental array CRC
    lea     r12, [rel ranges]
.array_sector:
    mov     rdi, r15
    mov     rsi, rbx
    call    block_read
    test    rax, rax
    jnz     .bad
    mov     eax, 4
    cmp     r14d, eax
    cmovb   eax, r14d
    mov     esi, eax
    shl     esi, 7
    mov     rdi, rbx
    mov     edx, r13d
    call    crc32_update
    mov     r13d, eax

    mov     r8, rbx
.entry:
    mov     rax, [r8]
    or      rax, [r8 + 8]
    jz      .advance
    mov     rax, [r8 + 32]
    mov     rdx, [r8 + 40]
    cmp     rax, [rel first_usable]
    jb      .bad
    cmp     rdx, rax
    jb      .bad
    cmp     rdx, [rel last_usable]
    ja      .bad
    lea     rcx, [rel ranges]
.overlap:
    cmp     rcx, r12
    je      .store
    cmp     qword [rcx], 0
    je      .previous
    cmp     rdx, [rcx]
    jb      .previous
    cmp     rax, [rcx + 8]
    jbe     .bad
.previous:
    add     rcx, RANGE_SIZE
    jmp     .overlap
.store:
    mov     [r12], rax
    mov     [r12 + 8], rdx
.advance:
    add     r12, RANGE_SIZE
    dec     r14d
    jz      .array_crc
    add     r8, GPT_ENTRY_BYTES
    lea     rax, [rbx + BLOCK_SIZE]
    cmp     r8, rax
    jb      .entry
    inc     r15
    jmp     .array_sector
.array_crc:
    xor     eax, eax
    cmp     r13d, [rel expected_crc]
    sete    al
    xor     eax, 1
    jmp     .done
.bad:
    mov     eax, 1
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

section .rodata
primary_text:   db "GPT: primary", 10, 0
backup_text:    db "GPT: backup", 10, 0
invalid_text:   db "No valid supported GPT.", 10, 0
partition_text: db "Partition ", 0
lba_text:       db "  LBA ", 0

section .bss
alignb 8
first_usable: resq 1
last_usable:  resq 1
entry_count:  resd 1
expected_crc: resd 1
gpt_backup:   resb 1
alignb 8
ranges:       resb GPT_MAX_ENTRIES * RANGE_SIZE
sector:       resb BLOCK_SIZE
