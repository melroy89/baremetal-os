; Stop a disposable guest at the second FAT32 flush.
bits 64
default rel
%ifndef CUT_FLUSH
%define CUT_FLUSH 2
%endif

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
    cmp     dword [rel flushes], CUT_FLUSH
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
%if CUT_FLUSH = 2
cut_point: db "Test: second FAT32 flush complete.", 10, 0
%else
cut_point: db "Test: third FAT32 flush complete.", 10, 0
%endif

section .bss
flushes: resd 1
