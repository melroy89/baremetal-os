; Fail the second e1000 allocation once. Leave a completion bit in the freed
; page so an attempted RX handover over that page is detectable.
bits 64
default rel
extern __real_page_alloc, net_init, net_rx_boundary
global __wrap_page_alloc

section .text
__wrap_page_alloc:
    mov     rax, [rsp]
    lea     rdx, [rel net_init]
    cmp     rax, rdx
    jb      __real_page_alloc
    lea     rdx, [rel net_rx_boundary]
    cmp     rax, rdx
    jae     __real_page_alloc
    cmp     byte [rel state], 0
    je      .first
    cmp     byte [rel state], 1
    je      .fail
    cmp     byte [rel state], 2
    jne     __real_page_alloc
    mov     rax, [rel ring_page]
    cmp     byte [rax + 12], 1
    jne     .corrupted
    inc     byte [rel state]
    jmp     __real_page_alloc
.first:
    sub     rsp, 8
    call    __real_page_alloc
    add     rsp, 8
    test    rax, rax
    jz      .done
    mov     [rel ring_page], rax
    mov     byte [rax + 12], 1
    inc     byte [rel state]
.done:
    ret
.fail:
    inc     byte [rel state]
    xor     eax, eax
    ret
.corrupted:
    ud2

section .bss
alignb 8
ring_page: resq 1
state: resb 1
