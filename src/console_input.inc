; The foreground reader owns the devices and the decoded input queue.
%define INPUT_QUEUE_SIZE 4096
%define CANCEL_OPEN 1
%define CANCEL_DEFERRED 2

section .text
global console_cancel_begin, console_cancel_check, console_cancel_commit
global console_cancel_pending, console_cancel_end
global interrupted_text

console_device_key:
    call    serial_try_getc
    cmp     eax, -1
    je      ps2_try_getc
    call    serial_key
    cmp     eax, -1
    je      ps2_try_getc
    ret

console_next_key:
    mov     ecx, [rel input_read]
    cmp     ecx, [rel input_write]
    je      console_device_key
    lea     rdx, [rel input_events]
    movzx   eax, word [rdx + rcx * 2]
    inc     ecx
    and     ecx, INPUT_QUEUE_SIZE - 1
    mov     [rel input_read], ecx
    ret

console_cancel_begin:
    mov     byte [rel cancel_state], CANCEL_OPEN
    jmp     console_cancel_check

; Check and then defer cancellation for an update that must finish.
console_cancel_commit:
    call    console_cancel_check
    test    rax, rax
    jnz     .done
    cmp     byte [rel cancel_state], 0
    je      .done
    mov     byte [rel cancel_state], CANCEL_DEFERRED
.done:
    ret

; Safe to call while registers hold a read or write's arguments.
; Only rax and flags change. Return an error string or zero.
console_cancel_check:
    call    console_cancel_pending
    cmp     byte [rel cancel_state], CANCEL_DEFERRED
    jne     .done
    xor     eax, eax
.done:
    ret

; Also expose the pending interrupt to a writer at its own rollback point.
console_cancel_pending:
    xor     eax, eax
    cmp     byte [rel cancel_state], 0
    je      .inactive
    push    rbx
    push    rcx
    push    rdx
    mov     ebx, 32
.next:
    ; Give a keyboard interrupt a chance even during serial typeahead.
    call    ps2_try_getc
    cmp     eax, -1
    jne     .key
    call    serial_try_getc
    cmp     eax, -1
    je      .check_devices
    call    serial_key
    cmp     eax, -1
    je      .check_devices
.key:
    cmp     eax, 3
    je      .interrupt
    mov     ecx, [rel input_write]
    lea     edx, [rcx + 1]
    and     edx, INPUT_QUEUE_SIZE - 1
    ; Preserve queued keys. Discard excess ordinary input so either device
    ; can still deliver an interrupt behind it.
    cmp     edx, [rel input_read]
    je      .advance
    lea     rdx, [rel input_events]
    mov     [rdx + rcx * 2], ax
    inc     ecx
    and     ecx, INPUT_QUEUE_SIZE - 1
    mov     [rel input_write], ecx
    jmp     .advance
.interrupt:
    mov     byte [rel cancel_pending], 1
    jmp     .advance
.check_devices:
    mov     dx, COM1_LSR
    in      al, dx
    cmp     al, 0xFF
    je      .ps2
    test    al, 1
    jnz     .advance
.ps2:
    in      al, PS2_STATUS
    cmp     al, 0xFF
    je      .result
    test    al, 1
    jz      .result
.advance:
    dec     ebx
    jnz     .next
.result:
    xor     eax, eax
    cmp     byte [rel cancel_pending], 0
    lea     rdx, [rel interrupted_text]
    cmovne  rax, rdx
    pop     rdx
    pop     rcx
    pop     rbx
.inactive:
    ret

console_cancel_end:
    call    console_cancel_pending
    mov     byte [rel cancel_pending], 0
    mov     byte [rel cancel_state], 0
    ret

section .rodata
interrupted_text: db 10, "Interrupted.", 10, 0

section .bss
alignb 4
input_read: resd 1
input_write: resd 1
input_events: resw INPUT_QUEUE_SIZE
cancel_state: resb 1
cancel_pending: resb 1
