; Stop a disposable guest after flushing replacement data, before publishing it.
bits 64
default rel

extern __real_block_flush
extern console_write_cstr
global __wrap_block_flush

section .text
__wrap_block_flush:
    sub     rsp, 8
    call    __real_block_flush
    test    rax, rax
    jnz     .done
    inc     dword [rel flushes]
    cmp     dword [rel flushes], 2
    jne     .done
    lea     rdi, [rel cut_point]
    call    console_write_cstr
    cli
.paused:
    hlt
    jmp     .paused
.done:
    add     rsp, 8
    ret

section .rodata
cut_point: db "Test: replacement data flushed before directory update.", 10, 0

section .bss
flushes: resd 1
