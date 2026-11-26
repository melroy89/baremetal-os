; Present a GPT interval that shares one sector with the preceding partition.
; The original GPT is valid so the test exercises the mount table guard.
bits 64
default rel

extern __real_gpt_partition
global __wrap_gpt_partition

section .text
__wrap_gpt_partition:
    sub     rsp, 8
    mov     [rsp], edi
    call    __real_gpt_partition
    cmp     dword [rsp], 2
    jne     .done
    test    rax, rax
    jz      .done
    dec     rax
.done:
    add     rsp, 8
    ret
