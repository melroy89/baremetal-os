%strlen EDIT_PROMPT_COLS CONSOLE_PROMPT
%defstr EDIT_PROMPT_COLUMNS EDIT_PROMPT_COLS
%define EDIT_WIDTH (79 - EDIT_PROMPT_COLS)

console_readline:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi                    ; buf
    lea     r13, [rsi - 1]              ; max chars (leave room for NUL)
    xor     ebx, ebx                    ; len = 0

    mov     r14d, 3                   ; Allow three extra batches per HLT.
    mov     dword [rel history_age], 0
    mov     dword [rel edit_cursor], 0
    mov     dword [rel edit_view], 0
    mov     byte [rel edit_utf8_pending], 0
    mov     byte [r12], 0
    call    edit_prompt

.poll:
    call    acpi_power_poll
    test    eax, eax
    jnz     .host_power
    call    ip_service
    mov     r15d, eax
    call    console_next_key
    cmp     eax, -1
    jne     .got_char
    ; A discarded scancode may have left another byte queued.
    in      al, PS2_STATUS
    cmp     al, 0xFF
    je      .sleep
    test    al, 1
    jnz     .poll
.sleep:
    call    net_irq_rearm
    test    r14d, r14d
    jz      .halt
    test    eax, eax
    jnz     .more_rx
    test    r15d, r15d
    jz      .halt
    call    net_rx_boundary
    test    eax, eax
    jz      .halt
.more_rx:
    dec     r14d
    jmp     .poll
.halt:
    ; Interrupts stay masked across the input check. STI defers interrupt
    ; delivery until after HLT so input arriving during the check wakes us.
    sti
    hlt
    cli
    mov     r14d, 3
    jmp     .poll

.host_power:
    call    vga_resume
    mov     edi, 10
    call    console_putc
    mov     rax, -1
    jmp     .return

.got_char:
    cmp     eax, KEY_PAGE_UP
    je      .page_up
    cmp     eax, KEY_PAGE_DOWN
    je      .page_down
    cmp     eax, 10
    jne     .not_lf
    cmp     byte [rel last_was_cr], 0
    je      .enter
    mov     byte [rel last_was_cr], 0
    jmp     .poll
.not_lf:
    mov     byte [rel last_was_cr], 0
    cmp     eax, 13
    je      .got_cr
    cmp     eax, 3
    je      .cancel
    cmp     rbx, LINE_TOO_LONG
    je      .discard_overlong

    mov     edx, [rel edit_cursor]
    cmp     eax, KEY_HISTORY_UP
    je      .history_up
    cmp     eax, KEY_HISTORY_DOWN
    je      .history_down
    cmp     eax, KEY_LEFT
    je      .left
    cmp     eax, KEY_RIGHT
    je      .right
    cmp     eax, KEY_HOME
    je      .home
    cmp     eax, KEY_END
    je      .end
    cmp     eax, KEY_DELETE
    je      .delete
    cmp     eax, 0x7F
    je      .backspace
    cmp     eax, 0x20
    jae     .insert
    lea     rcx, [rel edit_controls]
    movsx   rcx, word [rcx + rax * 2]
    lea     rax, [rel .got_char]
    add     rax, rcx
    jmp     rax

.insert:
    cmp     rbx, r13
    jae     .overflow
    mov     r8d, eax
    cmp     edx, ebx
    je      .store_byte
    lea     rsi, [r12 + rbx]
    lea     rdi, [rsi + 1]
    mov     ecx, ebx
    sub     ecx, edx
    inc     ecx
    std
    rep     movsb
    cld
.store_byte:
    mov     [r12 + rdx], al
    inc     ebx
    mov     byte [r12 + rbx], 0
    lea     eax, [rdx + 1]
    mov     [rel edit_cursor], eax
    cmp     r8b, 0x80
    jae     .utf8
    cmp     byte [rel edit_utf8_pending], 0
    jne     .redraw
    cmp     eax, ebx
    jne     .redraw
    sub     eax, [rel edit_view]
    cmp     eax, EDIT_WIDTH
    ja      .redraw
    call    vga_resume
    movzx   edi, byte [r12 + rbx - 1]
    call    console_putc
    jmp     .poll
.utf8:
    cmp     r8b, 0xC0
    jae     .utf8_lead
    cmp     byte [rel edit_utf8_pending], 0
    je      .redraw
    dec     byte [rel edit_utf8_pending]
    jz      .redraw
    jmp     .poll
.utf8_lead:
    mov     al, 1
    cmp     r8b, 0xE0
    jb      .utf8_pending
    inc     al
    cmp     r8b, 0xF0
    jb      .utf8_pending
    inc     al
.utf8_pending:
    mov     [rel edit_utf8_pending], al
    jmp     .poll

.overflow:
    call    vga_resume
    mov     rbx, LINE_TOO_LONG
    mov     byte [r12], 0
    jmp     .poll
.discard_overlong:
    cmp     eax, 8
    je      .resume_discard
    cmp     eax, 0x20
    jb      .poll
.resume_discard:
    call    vga_resume
    jmp     .poll

.left:
    mov     eax, edx
    call    edit_previous
    jmp     .move_cursor
.right:
    mov     eax, edx
    call    edit_next
    jmp     .move_cursor
.home:
    xor     eax, eax
    jmp     .move_cursor
.end:
    mov     eax, ebx
.move_cursor:
    mov     [rel edit_cursor], eax
    jmp     .redraw

.eof:
    test    ebx, ebx
    jnz     .delete
    call    vga_resume
    mov     rax, -1
    jmp     .return
.backspace:
    mov     eax, edx
    call    edit_previous
    jmp     .erase
.delete:
    mov     eax, edx
    call    edit_next
    xchg    eax, edx
    cmp     eax, edx
    je      .poll
    jmp     .erase
.kill_start:
    xor     eax, eax
    jmp     .erase
.kill_end:
    mov     eax, edx
    mov     edx, ebx
    jmp     .erase
.word:
    mov     eax, edx
.word_space:
    test    eax, eax
    jz      .erase
    cmp     byte [r12 + rax - 1], ' '
    jne     .word_text
    dec     eax
    jmp     .word_space
.word_text:
    test    eax, eax
    jz      .erase
    cmp     byte [r12 + rax - 1], ' '
    je      .erase
    call    edit_previous
    jmp     .word_text

; Erase bytes [eax, edx) and leave the cursor at eax.
.erase:
    lea     rdi, [r12 + rax]
    lea     rsi, [r12 + rdx]
    mov     ecx, ebx
    sub     ecx, edx
    lea     ebx, [rax + rcx]
    inc     ecx
    rep     movsb
    jmp     .move_cursor

.got_cr:
    mov     byte [rel last_was_cr], 1
.enter:
    call    vga_resume
    cmp     rbx, LINE_TOO_LONG
    je      .newline
    mov     rdi, r12
    mov     esi, ebx
    call    history_save
.newline:
    mov     al, 13
    call    serial_putc
    mov     edi, 10
    call    console_putc
    mov     rax, rbx
.return:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.cancel:
    call    vga_resume
    lea     rdi, [rel edit_cancel_text]
    call    console_write_cstr
    xor     eax, eax
    jmp     .return

.history_up:
    mov     edx, 1
    jmp     .history
.history_down:
    mov     edx, -1
.history:
    mov     rdi, r12
    mov     esi, ebx
    mov     ecx, [rel edit_cursor]
    call    history_recall
    test    rax, rax
    js      .poll
    mov     ebx, eax
    cmp     dword [rel history_age], 0
    cmove   eax, [rel history_draft_cursor]
    mov     [rel edit_cursor], eax
    mov     dword [rel edit_view], 0
    jmp     .redraw_prompt

.complete:
    cmp     byte [rel edit_utf8_pending], 0
    jne     .poll
    call    vga_resume
    mov     rdi, r12
    mov     esi, ebx
    mov     edx, [rel edit_cursor]
    mov     ecx, r13d
    call    shell_complete
    cmp     eax, -1
    je      .cancel
    cmp     eax, -2
    je      .redraw_prompt
    test    eax, eax
    js      .poll
    mov     ebx, eax
    mov     eax, edx
    jmp     .move_cursor

.clear:
    call    edit_clear
.redraw_prompt:
    mov     edi, 1
    jmp     .draw
.redraw:
    xor     edi, edi
.draw:
    mov     byte [rel edit_utf8_pending], 0
    call    edit_redraw
    jmp     .poll
.page_up:
    mov     edi, VGA_ROWS
    jmp     .page
.page_down:
    mov     edi, -VGA_ROWS
.page:
    call    vga_page
    jmp     .poll

; r12 = line, ebx = length, eax = byte offset. Return a character boundary.
edit_previous:
    test    eax, eax
    jz      .done
    dec     eax
    mov     cl, [r12 + rax]
    and     cl, 0xC0
    cmp     cl, 0x80
    je      edit_previous
.done:
    ret

edit_next:
    cmp     eax, ebx
    jae     .done
    inc     eax
    mov     cl, [r12 + rax]
    and     cl, 0xC0
    cmp     cl, 0x80
    je      edit_next
.done:
    ret

edit_prompt:
    mov     edi, VGA_ATTR_GREEN
    call    vga_set_color
    lea     rdi, [rel prompt]
    call    console_write_cstr
    mov     edi, VGA_ATTR_WHITE
    jmp     vga_set_color

; Advance the VGA screen past the visible rows so Page Up can recover them.
edit_clear:
    push    rbx
    call    vga_resume
    mov     ebx, VGA_ROWS
.scroll:
    mov     al, 10
    call    vga_emit_ascii
    dec     ebx
    jnz     .scroll
    mov     rax, [rel vga_ram_row]
    sub     rax, (VGA_ROWS - 1) * VGA_ROW_BYTES
    lea     rdx, [rel vga_ring]
    cmp     rax, rdx
    jae     .new_top
    add     rax, VGA_RING_BYTES
.new_top:
    mov     [rel vga_ram_row], rax
    mov     dword [rel vga_row], 0
    mov     eax, [rel vga_start_cell]
    mov     [rel vga_write_cell], eax
    lea     rdi, [rel serial_clear]
    call    serial_write_cstr
    pop     rbx
    ret

; edi = whether to redraw the prompt. Use a byte budget so even double-width
; UTF-8 characters fit. Serial saves its actual column before writing the tail.
edit_redraw:
    push    r13
    push    r14
    push    r15
    mov     r15d, edi
    call    vga_resume
    mov     eax, [rel edit_view]
    mov     edx, [rel edit_cursor]
    cmp     eax, edx
    ja      .shift_view
    lea     ecx, [rax + EDIT_WIDTH]
    cmp     edx, ecx
    jbe     .view
.shift_view:
    mov     eax, edx
    sub     eax, EDIT_WIDTH / 2
    jnc     .align_view
    xor     eax, eax
.align_view:
    cmp     eax, edx
    je      .view
    mov     cl, [r12 + rax]
    and     cl, 0xC0
    cmp     cl, 0x80
    jne     .view
    inc     eax
    jmp     .align_view
.view:
    mov     r13d, eax
    mov     [rel edit_view], eax
    lea     r14d, [rax + EDIT_WIDTH]
    cmp     r14d, ebx
    cmova   r14d, ebx
    cmp     r14d, [rel edit_cursor]
    je      .position
.tail_boundary:
    mov     al, [r12 + r14]
    and     al, 0xC0
    cmp     al, 0x80
    jne     .position
    dec     r14d
    jmp     .tail_boundary
.position:
    mov     dword [rel vga_col], EDIT_PROMPT_COLS
    lea     rdi, [rel edit_serial_row]
    test    r15d, r15d
    jz      .erase_row
    mov     dword [rel vga_col], 0
    lea     rdi, [rel edit_serial_prompt_row]
.erase_row:
    call    serial_write_cstr
    mov     edi, [rel vga_col]
    mov     edx, [rel vga_write_cell]
    add     edx, edi
    mov     r8, [rel vga_ram_row]
    lea     r8, [r8 + rdi * 2]
    mov     ecx, VGA_COLS
    sub     ecx, edi
    mov     ah, [rel vga_attr]
    mov     al, ' '
    lea     rdi, [VGA_MEM + rdx * 2]
    mov     edx, ecx
    rep     stosw
    mov     rdi, r8
    mov     ecx, edx
    rep     stosw
    test    r15d, r15d
    jz      .prefix
    call    edit_prompt
.prefix:
    lea     rdi, [r12 + r13]
    mov     esi, [rel edit_cursor]
    sub     esi, r13d
    call    console_write
    mov     r13d, [rel edit_cursor]
    sub     r14d, r13d
    jz      .done
    mov     r15d, [rel vga_col]
    lea     rdi, [rel edit_save_cursor]
    call    serial_write_cstr
    lea     rdi, [r12 + r13]
    mov     esi, r14d
    call    console_write
    lea     rdi, [rel edit_restore_cursor]
    call    serial_write_cstr
    mov     [rel vga_col], r15d
    call    vga_update_cursor
.done:
    pop     r15
    pop     r14
    pop     r13
    ret

serial_write_cstr:
    push    rbx
    mov     rbx, rdi
.next:
    mov     al, [rbx]
    test    al, al
    jz      .done
    inc     rbx
    call    serial_putc
    jmp     .next
.done:
    pop     rbx
    ret

section .rodata
edit_serial_row: db 13, 27, "[", EDIT_PROMPT_COLUMNS, "C", 27, "[K", 0
edit_serial_prompt_row: db 13, 27, "[K", 0
edit_save_cursor: db 27, "[s", 0
edit_restore_cursor: db 27, "[u", 0
edit_cancel_text: db "^C", 13, 10, 0

%macro edit_control 1-2 1
    times %2 dw console_readline.%1 - console_readline.got_char
%endmacro
edit_controls:
    edit_control poll
    edit_control home
    edit_control poll
    edit_control cancel
    edit_control eof
    edit_control end
    edit_control poll, 2
    edit_control backspace
    edit_control complete
    edit_control poll
    edit_control kill_end
    edit_control clear
    edit_control poll, 8
    edit_control kill_start
    edit_control poll
    edit_control word
    edit_control poll, 8

section .bss
alignb 4
edit_cursor: resd 1
edit_view: resd 1
edit_utf8_pending: resb 1

section .text
