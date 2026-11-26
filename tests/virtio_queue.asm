; Force TX completions to accumulate without releasing guest buffers.
bits 64
default rel
extern __real_console_readline, net_tx_submit, net_tx_complete, tx_busy
extern timer_ns, console_write_cstr
global __wrap_console_readline, fixture_hold_tx

section .text
__wrap_console_readline:
    push    rbx
    push    r12
    push    r13
    mov     r13, rdi
    call    __real_console_readline
    cmp     rax, 10
    jne     .done
    mov     rdx, 'queue-te'
    cmp     [r13], rdx
    jne     .done
    cmp     word [r13 + 8], 'st'
    jne     .done
    call    timer_ns
    lea     r12, [rax + 1000000000]
    call    drain_tx
    test    rax, rax
    jnz     .failed
    mov     byte [rel fixture_hold_tx], 1
    xor     ebx, ebx
.fill:
    lea     rdi, [rel frame]
    mov     [rdi + 14], bl
    mov     esi, 60
    call    net_tx_submit
    test    rax, rax
    jnz     .failed
    inc     ebx
    cmp     ebx, 8
    jb      .fill
    lea     rdi, [rel frame]
    mov     esi, 60
    call    net_tx_submit
    lea     rcx, [rel tx_busy]
    cmp     rax, rcx
    jne     .failed
    mov     byte [rel fixture_hold_tx], 0
    call    timer_ns
    lea     r12, [rax + 1000000000]
    call    drain_tx
    test    rax, rax
    jnz     .failed
    lea     rdi, [rel frame]
    mov     [rdi + 14], bl
    mov     esi, 60
    call    net_tx_submit
    test    rax, rax
    jnz     .failed
    lea     rdi, [rel passed]
    jmp     .print
.failed:
    mov     byte [rel fixture_hold_tx], 0
    lea     rdi, [rel failed]
.print:
    call    console_write_cstr
    xor     eax, eax
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

drain_tx:
    sub     rsp, 8
.next:
    call    net_tx_complete
    lea     rcx, [rel tx_busy]
    cmp     rax, rcx
    jne     .done
    call    timer_ns
    cmp     rax, r12
    jb      .next
    lea     rax, [rel failed]
.done:
    add     rsp, 8
    ret

section .rodata
passed: db "Test: Virtio TX backpressure recovered.", 10, 0
failed: db "Test: Virtio TX backpressure failed.", 10, 0

section .data
frame: db 0x52,0x54,0,0xAB,0xCD,0xEF, 0x52,0x54,0,0x12,0x34,0x56, 0x88,0xB5
       times 46 db 0

section .bss
fixture_hold_tx: resb 1
