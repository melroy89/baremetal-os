; Benchmark only ext2 reader calls. The console and CRC run outside the clock.
bits 64
default rel
extern __real_ext_read_at, timer_ns, console_write_cstr, console_putc, write_u64
global __wrap_ext_read_at

section .text
__wrap_ext_read_at:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13d, edx
    call    timer_ns
    mov     r14, rax
    mov     rdi, rbx
    mov     rsi, r12
    mov     edx, r13d
    call    __real_ext_read_at
    mov     r15, rax
    call    timer_ns
    sub     rax, r14
    add     [rel elapsed_ns], rax
    add     [rel read_bytes], r13
    cmp     qword [rel read_bytes], 16 * 1024 * 1024
    jne     .done
    lea     rdi, [rel elapsed_text]
    call    console_write_cstr
    mov     rdi, [rel elapsed_ns]
    call    write_u64
    mov     edi, 10
    call    console_putc
.done:
    mov     rax, r15
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

section .rodata
elapsed_text: db "Read ns: ", 0

section .bss
alignb 8
elapsed_ns: resq 1
read_bytes: resq 1
