bits 64
default rel
%include "virtio_pci.inc"
%define RESET_NS 100000000
extern timer_ns
global virtio_reset
section .text
virtio_reset:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     byte [rbx + vpci.status], 0
    call    timer_ns
    lea     r12, [rax + RESET_NS]
.wait:
    cmp     byte [rbx + vpci.status], 0
    je      .ready
    call    timer_ns
    cmp     rax, r12
    jb      .wait
    mov     eax, 1
    jmp     .done
.ready:
    xor     eax, eax
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret
