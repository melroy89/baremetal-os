; Disposable-kernel fault at specific ext2 persistence boundaries.
bits 64
default rel
extern __real_block_write, __real_block_flush, console_write_cstr
global __wrap_block_write, __wrap_block_flush

section .text
__wrap_block_write:
%ifdef ALLOC
    inc     dword [rel writes]
    cmp     dword [rel writes], 11     ; Descriptor update after inode allocation.
    je      fault
%elifdef PUBLISH
    cmp     dword [rel flushes], 2    ; Data and allocation are durable.
    je      fault
%endif
    jmp     __real_block_write

__wrap_block_flush:
    inc     dword [rel flushes]
%ifdef FINAL
    cmp     dword [rel flushes], 5    ; Clean-state flush.
    je      fault
%endif
%ifdef CUT
    sub     rsp, 8
    call    __real_block_flush
    test    rax, rax
    jnz     .done
    cmp     dword [rel flushes], CUT  ; Before or after publication.
    jne     .done
    lea     rdi, [rel cut_msg]
    call    console_write_cstr
    cli
.wait:
    hlt
    jmp     .wait
.done:
    add     rsp, 8
    ret
%else
    jmp     __real_block_flush
%endif

fault:
    lea     rax, [rel fault_msg]
    ret

section .rodata
fault_msg: db "Test: ext2 I/O error.", 10, 0
cut_msg: db "Test: ext2 flush complete.", 10, 0

section .bss
writes: resd 1
flushes: resd 1
