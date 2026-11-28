; Shell-side completion. The editor owns the draft and its viewport.
%define COMPLETE_COMMAND      0
%define COMPLETE_PATH         1
%define COMPLETE_DIRECTORY    2
%define COMPLETE_WORD_PATH    3
%define COMPLETE_RAM          4
%define COMPLETE_MOUNTS       5
%define COMPLETE_FAT_MOUNTS   6
%define COMPLETE_PARTITION    7
%define COMPLETE_REDIRECT     8

%define COMPLETION_ROWS       32
%define COMPLETION_NAME_MAX   255
%define COMPLETION_ROW_BYTES  (COMPLETION_NAME_MAX + 2)

extern block_selected, disk_visit_partitions
extern vfs_visit_path, vfs_visit_mounts, vfs_path_is_directory, ramfs_visit
extern console_cancel_begin, console_cancel_check, console_write_interruptible

section .text
global shell_complete

; rdi = line, esi = length, edx = cursor, ecx = maximum line length.
; Return length/cursor in eax/edx, or -1 interrupted, -2 listed, -3 unchanged.
shell_complete:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     eax, [rel block_selected]
    mov     [rsp], eax
    mov     r12, rdi
    mov     ebx, esi
    mov     r13d, edx
    mov     r14d, ecx
    call    console_cancel_begin
    test    rax, rax
    jnz     .unchanged

    call    completion_operand
    jc      .unchanged
    mov     [rel completion_mode], r15b
    mov     rax, rdi
    sub     rax, r12
    mov     [rel completion_start], eax
    mov     rax, rsi
    sub     rax, r12
    mov     [rel completion_end], eax
    lea     rsi, [r12 + r13]           ; Match only the text before the cursor.
    call    completion_decode
    cmp     r15d, COMPLETE_REDIRECT
    jne     .decoded
    push    rcx
    lea     rdi, [rel completion_token]
    mov     esi, ecx
    call    completion_name_safe
    pop     rcx
    jc      .unchanged
.decoded:
    mov     dword [rel completion_count], 0
    mov     byte [rel completion_add_slash], 0
    xor     eax, eax
    lea     rdi, [rel completion_token]
    cmp     r15d, COMPLETE_COMMAND
    je      .component
    cmp     r15d, COMPLETE_PARTITION
    je      .component
    cmp     r15d, COMPLETE_RAM
    je      .component
    cmp     r15d, COMPLETE_MOUNTS
    je      .mount_point
    cmp     r15d, COMPLETE_FAT_MOUNTS
    jne     .split_path
.mount_point:
    test    ecx, ecx
    jnz     .mount_prefix
    mov     byte [rdi], '/'
    mov     byte [rdi + 1], 0
    mov     byte [rel completion_add_slash], 1
    inc     ecx
.mount_prefix:
    cmp     byte [rdi], '/'
    jne     .unchanged
    mov     eax, 1
    mov     edx, eax
.mount_bytes:
    cmp     edx, ecx
    jae     .component
    cmp     byte [rdi + rdx], '/'
    je      .unchanged
    inc     edx
    jmp     .mount_bytes
.split_path:
    mov     edx, ecx
    test    edx, edx
    jz      .component
.last_slash:
    dec     edx
    cmp     byte [rdi + rdx], '/'
    je      .parent
    test    edx, edx
    jnz     .last_slash
    jmp     .component
.parent:
    lea     eax, [rdx + 1]
.component:
    mov     [rel completion_parent_length], eax
    sub     ecx, eax
    mov     [rel completion_prefix_length], ecx
    cmp     ecx, COMPLETION_NAME_MAX
    ja      .unchanged
    lea     rdx, [rel completion_candidate]
    cmp     r15d, COMPLETE_COMMAND
    je      .commands
    cmp     r15d, COMPLETE_RAM
    je      .ram
    cmp     r15d, COMPLETE_PARTITION
    je      .partitions
    cmp     r15d, COMPLETE_MOUNTS
    je      .mounts
    cmp     r15d, COMPLETE_FAT_MOUNTS
    je      .fat_mounts
    mov     ecx, eax
    mov     rsi, rdi
    lea     rdi, [rel completion_parent]
    rep     movsb
    mov     byte [rdi], 0
    lea     rdi, [rel completion_parent]
    movzx   ecx, byte [rel completion_ext_only]
    call    vfs_visit_path
    jmp     .collected
.commands:
    call    completion_commands
    jmp     .collected
.ram:
    call    ramfs_visit
    jmp     .collected
.partitions:
    mov     rdi, rdx
    call    disk_visit_partitions
    jmp     .collected
.mounts:
    mov     edi, VISIT_MOUNTS
    jmp     .visit_mounts
.fat_mounts:
    mov     edi, VISIT_FAT_MOUNTS
.visit_mounts:
    call    vfs_visit_mounts
.collected:
    test    rax, rax
    jnz     .unchanged
    mov     eax, [rel completion_count]
    test    eax, eax
    jz      .unchanged
    cmp     eax, 1
    je      .apply
    mov     eax, [rel completion_common]
    cmp     eax, [rel completion_prefix_length]
    ja      .apply
    cmp     byte [rel completion_add_slash], 0
    jne     .apply
    call    completion_list
    mov     eax, -2
    jmp     .finish
.apply:
    call    completion_apply
    jmp     .finish
.unchanged:
    mov     eax, -3
.finish:
    mov     r15d, eax
    mov     r13d, edx
    mov     eax, [rsp]
    mov     [rel block_selected], eax
    call    console_cancel_end
    test    rax, rax
    mov     eax, -1
    cmovz   eax, r15d
    mov     edx, r13d
    cdqe
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

%include "completion_operand.inc"

completion_commands:
    push    rbx
    lea     rbx, [rel commands]
.next:
    mov     rdi, [rbx]
    test    rdi, rdi
    jz      .success
    xor     esi, esi
.length:
    cmp     byte [rdi + rsi], 0
    je      .visit
    inc     esi
    jmp     .length
.visit:
    xor     edx, edx
    call    completion_candidate
    test    rax, rax
    jnz     .done
    add     rbx, 24
    jmp     .next
.success:
    xor     eax, eax
.done:
    pop     rbx
    ret

; Visit a name as a byte span. Keep the full count and common prefix, and
; retain only the first screenful of names for display.
completion_candidate:
    call    console_cancel_check
    test    rax, rax
    jnz     .return
    test    esi, esi
    jz      .skip
    cmp     esi, COMPLETION_NAME_MAX
    ja      .skip
    cmp     byte [rel completion_mode], COMPLETE_DIRECTORY
    jne     .match
    test    edx, ENTRY_DIRECTORY | ENTRY_SYMLINK
    jz      .skip
.match:
    mov     ecx, [rel completion_prefix_length]
    cmp     ecx, esi
    ja      .skip
    lea     r8, [rel completion_token]
    mov     eax, [rel completion_parent_length]
    add     r8, rax
    xor     eax, eax
.prefix_byte:
    cmp     eax, ecx
    je      .representable
    mov     r9b, [r8 + rax]
    mov     r10b, [rdi + rax]
    cmp     r9b, r10b
    je      .prefix_next
    test    dl, ENTRY_FOLD_CASE
    jz      .skip
    or      r9b, 0x20
    or      r10b, 0x20
    cmp     r9b, 'a'
    jb      .skip
    cmp     r9b, 'z'
    ja      .skip
    cmp     r9b, r10b
    jne     .skip
.prefix_next:
    inc     eax
    jmp     .prefix_byte
.representable:
    cmp     byte [rel completion_mode], COMPLETE_DIRECTORY
    jne     .syntax
    test    dl, ENTRY_SYMLINK
    jz      .syntax
    call    completion_link_is_directory
    test    rax, rax
    jnz     .skip
    or      edx, ENTRY_DIRECTORY
.syntax:
    cmp     byte [rel completion_mode], COMPLETE_WORD_PATH
    je      .validate
    cmp     dword [rel completion_parent_length], 0
    jne     .trailing_space
    cmp     byte [rdi], ' '
    je      .skip
.trailing_space:
    test    dl, ENTRY_DIRECTORY
    jnz     .validate
    cmp     byte [rdi + rsi - 1], ' '
    je      .skip
.validate:
    call    completion_name_safe
    jc      .skip
    mov     r9d, edx
    mov     ecx, esi
    mov     rsi, rdi
    lea     rdi, [rel completion_candidate_name]
    rep     movsb
    test    r9b, ENTRY_DIRECTORY
    jz      .terminate
    mov     byte [rdi], '/'
    inc     rdi
.terminate:
    mov     byte [rdi], 0
    lea     rsi, [rel completion_candidate_name]
    mov     rdx, rdi
    sub     rdx, rsi
    mov     r8d, [rel completion_count]
    inc     dword [rel completion_count]
    lea     rdi, [rel completion_names]
    test    r8d, r8d
    jnz     .common
    mov     [rel completion_common], edx
    jmp     .save
.common:
    mov     ecx, [rel completion_common]
    cmp     ecx, edx
    cmova   ecx, edx
    xor     eax, eax
.common_byte:
    cmp     eax, ecx
    jae     .boundary
    mov     r10b, [rsi + rax]
    cmp     r10b, [rdi + rax]
    jne     .boundary
    inc     eax
    jmp     .common_byte
.boundary:
    mov     cl, [rdi + rax]
    and     cl, 0xC0
    cmp     cl, 0x80
    jne     .common_length
    dec     eax
    jmp     .boundary
.common_length:
    mov     [rel completion_common], eax
.save:
    cmp     r8d, COMPLETION_ROWS
    jae     .skip
    imul    r8d, COMPLETION_ROW_BYTES
    add     rdi, r8
    lea     ecx, [rdx + 1]
    rep     movsb
.skip:
    xor     eax, eax
.return:
    ret

; Resolve a matched link in the user's original path context. The outer
; ext2 visit owns separate buffers while the resolver walks this path.
completion_link_is_directory:
    mov     eax, [rel completion_parent_length]
    lea     ecx, [rax + rsi]
    cmp     ecx, LINE_BUF_SIZE
    jae     .too_long
    push    rdi
    push    rsi
    push    rdx
    lea     rdi, [rel completion_encoded]
    lea     rsi, [rel completion_parent]
    mov     ecx, eax
    rep     movsb
    mov     rsi, [rsp + 16]
    mov     ecx, [rsp + 8]
    rep     movsb
    mov     byte [rdi], 0
    lea     rdi, [rel completion_encoded]
    call    vfs_path_is_directory
    pop     rdx
    pop     rsi
    pop     rdi
    ret
.too_long:
    mov     eax, 1
    ret

; Filter terminal controls and malformed UTF-8. Echo redirection cannot
; represent a literal quote or greater-than sign in its target.
completion_name_safe:
    xor     ecx, ecx
.next:
    cmp     ecx, esi
    jae     .valid
    movzx   eax, byte [rdi + rcx]
    inc     ecx
    cmp     al, 0x20
    jb      .bad
    cmp     al, 0x7F
    je      .bad
    ja      .utf8
    cmp     byte [rel completion_mode], COMPLETE_REDIRECT
    jne     .next
    cmp     al, '"'
    je      .bad
    cmp     al, '>'
    jne     .next
    jmp     .bad
.utf8:
    cmp     al, 0xC2
    jb      .bad
    mov     r8d, 1
    cmp     al, 0xE0
    jb      .extent
    inc     r8d
    cmp     al, 0xF0
    jb      .extent
    inc     r8d
    cmp     al, 0xF4
    ja      .bad
.extent:
    lea     r9d, [rcx + r8]
    cmp     r9d, esi
    ja      .bad
    mov     r9b, [rdi + rcx]
    cmp     al, 0xC2
    je      .control
    cmp     al, 0xE0
    je      .below_800
    cmp     al, 0xED
    je      .surrogate
    cmp     al, 0xF0
    je      .below_10000
    cmp     al, 0xF4
    jne     .continuation
    cmp     r9b, 0x90
    jae     .bad
    jmp     .continuation
.control:
    cmp     r9b, 0xA0
    jb      .bad
    jmp     .continuation
.below_800:
    cmp     r9b, 0xA0
    jb      .bad
    jmp     .continuation
.surrogate:
    cmp     r9b, 0xA0
    jae     .bad
    jmp     .continuation
.below_10000:
    cmp     r9b, 0x90
    jb      .bad
.continuation:
    mov     al, [rdi + rcx]
    and     al, 0xC0
    cmp     al, 0x80
    jne     .bad
    inc     ecx
    dec     r8d
    jnz     .continuation
    jmp     .next
.bad:
    stc
    ret
.valid:
    clc
    ret

; Build and size the replacement before changing the live input. r12 is
; the draft, ebx its length, and r14d its capacity.
completion_apply:
    mov     r8d, [rel completion_parent_length]
    mov     r9d, [rel completion_prefix_length]
    mov     ecx, [rel completion_common]
    lea     eax, [r8 + rcx]
    cmp     eax, r14d
    ja      .too_long
    lea     rdi, [rel completion_token]
    add     rdi, r8
    add     rdi, r9
    lea     rsi, [rel completion_names]
    add     rsi, r9
    sub     ecx, r9d
    ; A case-insensitive match can retain the user's existing prefix.
    jbe     .terminate
    rep     movsb
.terminate:
    mov     byte [rdi], 0
    lea     rsi, [rel completion_token]
    lea     rdi, [rel completion_encoded]
    xor     r9d, r9d                   ; Whether to encode a quoted word.
    cmp     byte [rel completion_mode], COMPLETE_WORD_PATH
    jne     .encode
    cmp     byte [rel completion_quote], 0
    jne     .open
    cmp     byte [rsi], '"'
    je      .open
    mov     rax, rsi
.quote_needed:
    cmp     byte [rax], 0
    je      .encode
    cmp     byte [rax], ' '
    je      .open
    inc     rax
    jmp     .quote_needed
.open:
    mov     al, '"'
    stosb
    mov     r9d, 1
.encode:
    lodsb
    test    al, al
    jz      .end_quote
    test    r9d, r9d
    jz      .store
    cmp     al, '"'
    je      .escaped
    cmp     al, 0x5C
    jne     .store
.escaped:
    mov     byte [rdi], 0x5C
    inc     rdi
.store:
    stosb
    jmp     .encode
.end_quote:
    mov     r10d, [rel completion_end]
    test    r9d, r9d
    jz      .measure
    cmp     r10d, ebx
    jb      .close_query
    cmp     dword [rel completion_count], 1
    jne     .ambiguous
    cmp     byte [rsi - 2], '/'
    jne     .close_query
    jmp     .measure
.ambiguous:
    cmp     byte [rel completion_quote], 2
    jne     .measure
.close_query:
    mov     al, '"'
    stosb
.measure:
    lea     rsi, [rel completion_encoded]
    sub     rdi, rsi
    mov     r8d, [rel completion_start]
    lea     edx, [rdi + r8]            ; Cursor after the replacement.
    mov     eax, ebx
    sub     eax, r10d
    add     eax, edx
    cmp     eax, r14d
    ja      .too_long
    mov     r11d, edi                  ; Length of encoded token.
    mov     ecx, ebx
    sub     ecx, r10d
    inc     ecx                        ; Move the suffix together with its NUL.
    cmp     edx, r10d
    je      .copy_token
    jb      .shift_left
    lea     rsi, [r12 + rbx]
    lea     rdi, [r12 + rax]
    std
    rep     movsb
    cld
    jmp     .copy_token
.shift_left:
    lea     rsi, [r12 + r10]
    lea     rdi, [r12 + rdx]
    rep     movsb
.copy_token:
    lea     rsi, [rel completion_encoded]
    lea     rdi, [r12 + r8]
    mov     ecx, r11d
    rep     movsb
    ret
.too_long:
    mov     eax, -3
    ret

completion_list:
    push    rbx
    push    r12
    mov     ebx, [rel completion_count]
    mov     eax, COMPLETION_ROWS
    cmp     ebx, eax
    cmova   ebx, eax
    lea     r12, [rel completion_names]
    call    completion_newline
.next:
    mov     rdi, r12
    xor     esi, esi
.length:
    cmp     byte [rdi + rsi], 0
    je      .write
    inc     esi
    jmp     .length
.write:
    call    console_write_interruptible
    test    rax, rax
    jnz     .done
    call    completion_newline
    add     r12, COMPLETION_ROW_BYTES
    dec     ebx
    jnz     .next
    cmp     dword [rel completion_count], COMPLETION_ROWS
    jbe     .done
    lea     rdi, [rel completion_more]
    call    console_write_cstr
.done:
    pop     r12
    pop     rbx
    ret

completion_newline:
    lea     rdi, [rel completion_crlf]
    mov     esi, 2
    jmp     console_write_interruptible

section .rodata
completion_crlf: db 13, 10
completion_more: db "... (more matches)", 13, 10, 0

section .bss
alignb 4
completion_start: resd 1
completion_end: resd 1
completion_parent_length: resd 1
completion_prefix_length: resd 1
completion_count: resd 1
completion_common: resd 1
completion_mode: resb 1
completion_ext_only: resb 1
completion_quote: resb 1
completion_add_slash: resb 1
completion_token: resb LINE_BUF_SIZE
completion_parent: resb LINE_BUF_SIZE
completion_encoded: resb 2 * LINE_BUF_SIZE + 2
completion_candidate_name: resb COMPLETION_ROW_BYTES
completion_names: resb COMPLETION_ROWS * COMPLETION_ROW_BYTES
