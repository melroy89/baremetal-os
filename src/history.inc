; Bounded command history and serial cursor-key decoding.
%define HISTORY_SLOTS 16
%define HISTORY_MASK (HISTORY_SLOTS - 1)
%define SERIAL_ESCAPE_NS 250000000

section .text
global command_history

command_history:
    push    rbx
    push    r12
    mov     r12d, [rel history_count]
    mov     ebx, [rel history_next]
    sub     ebx, r12d
.next:
    test    r12d, r12d
    jz      .done
    and     ebx, HISTORY_MASK
    imul    eax, ebx, LINE_BUF_SIZE
    lea     rdi, [rel history_lines]
    add     rdi, rax
    call    console_write_cstr
    mov     edi, 10
    call    console_putc
    inc     ebx
    dec     r12d
    jmp     .next
.done:
    pop     r12
    pop     rbx
    ret

; rdi = completed line, esi = length excluding its NUL.
history_save:
    test    esi, esi
    jz      .done
    xor     ecx, ecx
.nonblank:
    cmp     byte [rdi + rcx], ' '
    jne     .compare
    inc     ecx
    cmp     ecx, esi
    jb      .nonblank
    ret
.compare:
    mov     r8, rdi
    lea     r9, [rel history_lines]
    mov     r10d, esi
    mov     eax, [rel history_next]
    cmp     dword [rel history_count], 0
    je      .store
    lea     edx, [rax - 1]
    and     edx, HISTORY_MASK
    imul    edx, LINE_BUF_SIZE
    mov     ecx, r10d
    inc     ecx
    lea     rsi, [r9 + rdx]
    repe    cmpsb
    je      .done
.store:
    imul    edx, eax, LINE_BUF_SIZE
    lea     rdi, [r9 + rdx]
    mov     rsi, r8
    lea     ecx, [r10 + 1]
    rep     movsb
    inc     eax
    and     eax, HISTORY_MASK
    mov     [rel history_next], eax
    cmp     dword [rel history_count], HISTORY_SLOTS
    jae     .done
    inc     dword [rel history_count]
.done:
    ret

; rdi = line, esi = length, edx = +1 for up or -1 for down, ecx = cursor.
; Return the recalled length or -1 when the line should stay as is.
history_recall:
    mov     eax, [rel history_age]
    add     edx, eax
    cmp     edx, [rel history_count]
    ja      .unchanged
    test    eax, eax
    jnz     .select
    mov     [rel history_draft_cursor], ecx
    mov     r8, rdi
    lea     rdi, [rel history_draft]
    mov     ecx, esi
    mov     rsi, r8
    rep     movsb
    mov     byte [rdi], 0
    mov     rdi, r8
.select:
    mov     [rel history_age], edx
    lea     rsi, [rel history_draft]
    test    edx, edx
    jz      .copy
    mov     eax, [rel history_next]
    sub     eax, edx
    and     eax, HISTORY_MASK
    imul    eax, LINE_BUF_SIZE
    lea     rsi, [rel history_lines]
    add     rsi, rax
.copy:
    mov     rdx, rdi
.next:
    lodsb
    stosb
    test    al, al
    jnz     .next
    lea     rax, [rdi - 1]
    sub     rax, rdx
    ret
.unchanged:
    mov     rax, -1
    ret

; eax = raw serial byte, returns byte/key event or -1 for a partial sequence.
serial_key:
    cmp     byte [rel serial_escape], 0
    jne     .partial
    cmp     al, 27
    jne     .done
.partial:
    push    rbx
    mov     ebx, eax
    call    timer_ns
    cmp     bl, 27
    je      .start
    cmp     rax, [rel serial_escape_deadline]
    jae     .expired
    cmp     byte [rel serial_escape], 1
    jne     .arrow
    cmp     bl, '['
    je      .prefix
    cmp     bl, 'O'
    jne     .expired
.prefix:
    mov     byte [rel serial_escape], 2
    jmp     .consume
.start:
    add     rax, SERIAL_ESCAPE_NS
    mov     [rel serial_escape_deadline], rax
    mov     byte [rel serial_escape], 1
    jmp     .consume
.arrow:
    cmp     byte [rel serial_escape], 4
    je      .discard_csi
    cmp     byte [rel serial_escape], 3
    je      .numeric
    cmp     bl, '1'
    jb      .letter
    cmp     bl, '8'
    ja      .letter
    mov     [rel serial_escape_digit], bl
    mov     byte [rel serial_escape], 3
    jmp     .consume
.letter:
    mov     byte [rel serial_escape], 0
    movzx   eax, bl
    sub     eax, 'A'
    cmp     eax, 'H' - 'A'
    ja      .other
    lea     rdx, [rel serial_letter_keys]
    movsx   eax, word [rdx + rax * 2]
    jmp     .pop
.numeric:
    cmp     bl, '~'
    jne     .discard_csi
    mov     byte [rel serial_escape], 0
    movzx   eax, byte [rel serial_escape_digit]
    sub     eax, '1'
    lea     rdx, [rel serial_numeric_keys]
    movsx   eax, word [rdx + rax * 2]
    jmp     .pop
.discard_csi:
    cmp     bl, 0x20
    jb      .expired
    cmp     bl, 0x40
    jae     .end_csi
    mov     byte [rel serial_escape], 4
    jmp     .consume
.end_csi:
    mov     byte [rel serial_escape], 0
.other:
    ; Preserve control input such as Enter when an escape was incomplete.
    cmp     bl, 0x20
    jb      .return_byte
.consume:
    mov     eax, -1
    jmp     .pop
.expired:
    mov     byte [rel serial_escape], 0
.return_byte:
    mov     eax, ebx
.pop:
    pop     rbx
.done:
    ret

section .rodata
serial_letter_keys:
    dw KEY_HISTORY_UP, KEY_HISTORY_DOWN, KEY_RIGHT, KEY_LEFT
    dw -1, KEY_END, -1, KEY_HOME
serial_numeric_keys:
    dw KEY_HOME, -1, KEY_DELETE, KEY_END, KEY_PAGE_UP, KEY_PAGE_DOWN, KEY_HOME, KEY_END

section .bss
alignb 8
serial_escape_deadline: resq 1
history_next: resd 1
history_count: resd 1
history_age: resd 1
history_draft_cursor: resd 1
serial_escape: resb 1
serial_escape_digit: resb 1
history_lines: resb HISTORY_SLOTS * LINE_BUF_SIZE
history_draft: resb LINE_BUF_SIZE
