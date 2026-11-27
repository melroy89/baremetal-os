; Bounded command history and serial cursor-key decoding.
%define HISTORY_SLOTS 16
%define HISTORY_MASK (HISTORY_SLOTS - 1)
%define HISTORY_ESCAPE_NS 250000000

section .text
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

; rdi = editable line, esi = length, edx = +1 for up or -1 for down.
; Return the recalled length or -1 when the line should stay as is.
history_recall:
    mov     eax, [rel history_age]
    add     edx, eax
    cmp     edx, [rel history_count]
    ja      .unchanged
    test    eax, eax
    jnz     .select
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
history_serial_key:
    cmp     byte [rel history_escape], 0
    jne     .partial
    cmp     al, 27
    jne     .done
.partial:
    push    rbx
    mov     ebx, eax
    call    timer_ns
    cmp     bl, 27
    je      .start
    cmp     rax, [rel history_escape_deadline]
    jae     .expired
    cmp     byte [rel history_escape], 1
    jne     .arrow
    cmp     bl, '['
    je      .prefix
    cmp     bl, 'O'
    jne     .expired
.prefix:
    mov     byte [rel history_escape], 2
    jmp     .consume
.start:
    add     rax, HISTORY_ESCAPE_NS
    mov     [rel history_escape_deadline], rax
    mov     byte [rel history_escape], 1
    jmp     .consume
.arrow:
    mov     byte [rel history_escape], 0
    cmp     bl, 'A'
    je      .up
    cmp     bl, 'B'
    je      .down
    ; Preserve control input such as Enter when an escape was incomplete.
    cmp     bl, 0x20
    jb      .return_byte
.consume:
    mov     eax, -1
    jmp     .pop
.up:
    mov     eax, KEY_HISTORY_UP
    jmp     .pop
.down:
    mov     eax, KEY_HISTORY_DOWN
    jmp     .pop
.expired:
    mov     byte [rel history_escape], 0
.return_byte:
    mov     eax, ebx
.pop:
    pop     rbx
.done:
    ret

section .bss
alignb 8
history_escape_deadline: resq 1
history_next: resd 1
history_count: resd 1
history_age: resd 1
history_escape: resb 1
history_lines: resb HISTORY_SLOTS * LINE_BUF_SIZE
history_draft: resb LINE_BUF_SIZE
