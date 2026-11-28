; Synchronize Ctrl+C with a real write or flush in a disposable guest.
bits 64
default rel

extern __real_block_read, __real_block_write, __real_block_flush
extern console_write_cstr, console_cancel_pending, timer_ns
global __wrap_block_read, __wrap_block_write, __wrap_block_flush

section .text
__wrap_block_read:
    cmp     rdi, 118786               ; First superblock sector of GPT entry 5.
    je      .error
    push    rbx
    mov     rbx, rsi
    call    __real_block_read
    test    rax, rax
    jnz     .done
    ; The first non-dot entry of the completion fixture's /Slow directory.
    mov     rdx, 'CANCELTA'
    cmp     [rbx + 32], rdx
    jne     .done
    lea     rdi, [rel read_gate_text]
    call    wait_for_interrupt
.done:
    pop     rbx
    ret
.error:
    lea     rax, [rel read_error]
    ret

__wrap_block_write:
    cmp     dword [rsi], 'CANC'       ; Data in unallocated ext2 blocks or a new FAT chain.
    je      .stage
    cmp     dword [rsi], 'KEEP'
    je      .commit
    cmp     dword [rsi], 'FLUS'
    je      .before_publish
    jmp     __real_block_write
.commit:
    mov     byte [rel flush_countdown], 2
    jmp     __real_block_write
.before_publish:
    mov     byte [rel flush_countdown], 1
    jmp     __real_block_write
.stage:
    sub     rsp, 8
    call    __real_block_write
    test    rax, rax
    jnz     .done
    lea     rdi, [rel gate_text]
    call    wait_for_interrupt
.done:
    add     rsp, 8
    ret

__wrap_block_flush:
    cmp     byte [rel flush_countdown], 0
    je      .flush
    dec     byte [rel flush_countdown]
    jnz     .flush
    sub     rsp, 8
    call    __real_block_flush
    test    rax, rax
    jnz     .done
    lea     rdi, [rel gate_text]
    call    wait_for_interrupt
.done:
    add     rsp, 8
    ret
.flush:
    jmp     __real_block_flush

wait_for_interrupt:
    push    rbx
    call    console_write_cstr
    call    timer_ns
    mov     ebx, 3000000000
    add     rbx, rax
.poll:
    call    console_cancel_pending
    test    rax, rax
    jnz     .ok
    call    timer_ns
    cmp     rax, rbx
    jb      .poll
    lea     rax, [rel timeout_text]
    pop     rbx
    ret
.ok:
    xor     eax, eax
    pop     rbx
    ret

section .rodata
read_error: db "Test read error.", 10, 0
gate_text: db "Test write boundary.", 10, 0
read_gate_text: db "Test completion read boundary.", 10, 0
timeout_text: db "Timed out waiting for Ctrl+C.", 10, 0

section .bss
flush_countdown: resb 1
