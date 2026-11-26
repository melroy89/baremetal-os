; Fail one write and the first subsequent flush for the affected volume.
bits 64
default rel

extern __real_block_write
extern __real_block_flush
global __wrap_block_write
global __wrap_block_flush

section .text
__wrap_block_write:
    cmp     qword [rel failed_volume], 0
    jne     __real_block_write
    mov     [rel failed_volume], rbp
    lea     rax, [rel write_error]
    ret

__wrap_block_flush:
    cmp     [rel failed_volume], rbp
    jne     __real_block_flush
    cmp     byte [rel failed_flush], 0
    jne     __real_block_flush
    mov     byte [rel failed_flush], 1
    lea     rax, [rel flush_error]
    ret

section .rodata
write_error: db "Test: ATA write failed.", 10, 0
flush_error: db "Test: ATA flush failed.", 10, 0

section .bss
alignb 8
failed_volume: resq 1
failed_flush:  resb 1
