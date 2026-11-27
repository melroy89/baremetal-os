; Disable the polling watchdog only when a NIC IRQ was actually claimed.
bits 64
default rel
extern __real_net_timer, net_irq_line
global __wrap_net_timer

section .text
__wrap_net_timer:
    cmp     byte [rel net_irq_line], 0
    je      .timer
    xor     edi, edi
.timer:
    jmp     __real_net_timer

%ifdef FALLBACK
extern __real_pci_config_read32
global __wrap_pci_config_read32
__wrap_pci_config_read32:
    cmp     esi, 0x3c
    jne     __real_pci_config_read32
    xor     eax, eax
    ret
%endif
