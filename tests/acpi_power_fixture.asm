; Synchronize power requests with a real write and inject a shutdown flush fault.
bits 64
default rel
extern __real_block_write, __real_block_flush, __real_vfs_shutdown
extern acpi_power_poll, timer_ns, console_write_cstr
global __wrap_block_write, __wrap_block_flush, __wrap_vfs_shutdown

section .text
__wrap_block_write:
    cmp     dword [rsi], 'GATE'
    jne     __real_block_write
    cmp     dword [rsi + 4], 'FAIL'      ; GATEFAIL also arms the flush fault.
    jne     .gate
    mov     byte [rel arm_failure], 1
.gate:
    push    rbx
    call    __real_block_write
    test    rax, rax
    jnz     .done
    lea     rdi, [rel gate]
    call    console_write_cstr
    call    timer_ns
    mov     ebx, 2500000000
    lea     rbx, [rax + rbx * 2]
.wait:
    call    acpi_power_poll
    test    eax, eax
    jnz     .received
    call    timer_ns
    cmp     rax, rbx
    jb      .wait
    lea     rax, [rel timeout]
    jmp     .done
.received:
    xor     eax, eax
.done:
    pop     rbx
    ret

__wrap_vfs_shutdown:
    xor     al, al
    xchg    al, [rel arm_failure]
    mov     [rel fail_flush], al
    jmp     __real_vfs_shutdown

__wrap_block_flush:
    cmp     byte [rel fail_flush], 0
    je      __real_block_flush
    mov     byte [rel fail_flush], 0
    lea     rax, [rel flush_error]
    ret

section .rodata
gate: db "Test write awaiting host power request.", 10, 0
timeout: db "Test power request timed out.", 10, 0
flush_error: db "Test shutdown flush failed.", 10, 0

section .bss
arm_failure: resb 1
fail_flush: resb 1
