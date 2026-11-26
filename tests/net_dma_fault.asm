; Fail the second e1000 allocation once. Leave a completion bit in the freed
; page so an attempted RX handover over that page is detectable.
bits 64
default rel
extern __real_page_alloc
%ifdef TEST_VIRTIO_DMA
extern virtio_init, virtio_shutdown, __real_pci_config_read32
global __wrap_pci_config_read32
%else
extern net_init, net_rx_boundary
%endif
global __wrap_page_alloc

section .text
%ifdef TEST_VIRTIO_DMA
; Move the reported one-byte ISR to an odd offset. The driver uses polling
; and does not access this register.
__wrap_pci_config_read32:
    sub     rsp, 8
    call    __real_pci_config_read32
    add     rsp, 8
    cmp     esi, [rel isr_offset_register]
    jne     .header
    or      eax, 1
    ret
.header:
    cmp     esi, 0x40
    jb      .done
    mov     edx, eax
    and     edx, 0xFFFF00FF
    cmp     edx, 0x03100009
    jne     .done
    lea     edx, [rsi + 8]
    mov     [rel isr_offset_register], edx
.done:
    ret

; Fail the second Virtio allocation once to force raw I/O to retry.
__wrap_page_alloc:
    mov     rax, [rsp]
    lea     rdx, [rel virtio_init]
    cmp     rax, rdx
    jb      __real_page_alloc
    lea     rdx, [rel virtio_shutdown]
    cmp     rax, rdx
    jae     __real_page_alloc
    cmp     byte [rel state], 2
    jae     __real_page_alloc
    inc     byte [rel state]
    cmp     byte [rel state], 2
    jne     __real_page_alloc
    xor     eax, eax
    ret

section .data
isr_offset_register: dd -1
%else
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
%endif

section .bss
state: resb 1
