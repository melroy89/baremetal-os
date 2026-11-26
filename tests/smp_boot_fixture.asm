; Linker wrappers for disposable Multiboot kernels. Release links omit this file.
bits 64
default rel
%include "os_constants.inc"

%ifdef TEST_delayed_ap
extern __real_pit_delay_us
extern __real_console_readline
extern __real_smp_ping_irq
extern __real_apic_send_ipi
global __wrap_pit_delay_us
global __wrap_console_readline
global __wrap_smp_ping_irq
global __wrap_apic_send_ipi

section .text
__wrap_pit_delay_us:
    ; SMP installs the trampoline before its first PIT delay and sends
    ; the first SIPI afterwards. Insert a stackless gate in that mailbox.
    cmp     qword [rel ap_resume], 0
    jne     .resume
    mov     rax, [abs TRAMP_ENTRY64]
    test    rax, rax
    jz      .resume
    mov     [rel ap_resume], rax
    lea     rax, [rel ap_wait]
    mov     [abs TRAMP_ENTRY64], rax
    mfence
.resume:
    jmp     __real_pit_delay_us

ap_wait:
    pause
    cmp     byte [rel ap_gate_open], 0
    je      ap_wait
    jmp     [rel ap_resume]

__wrap_console_readline:
    push    rdi
    call    __real_console_readline
    pop     rdi
    cmp     rax, 2
    jne     .check_ping_gate
    cmp     word [rdi], 'go'
    jne     .done
    mov     byte [rel ap_gate_open], 1
    jmp     .consumed
.check_ping_gate:
    cmp     rax, 7
    jne     .done
    cmp     dword [rdi], 'ping'
    jne     .done
    cmp     dword [rdi + 4], '-go'
    jne     .done
    mov     byte [rel ping_release_requested], 1
.consumed:
    xor     eax, eax                   ; Treat the test signal as an empty line.
.done:
    ret

__wrap_smp_ping_irq:
    ; Hold APIC ID 1's first interrupt so it replies after the timeout.
    push    rax
    mov     eax, APIC_DEFAULT_BASE
    cmp     dword [rax + APIC_REG_ID], 1 << 24
    jne     .resume
.wait:
    cmp     byte [rel ping_gate_open], 0
    jne     .resume
    pause
    jmp     .wait
.resume:
    pop     rax
    jmp     __real_smp_ping_irq

__wrap_apic_send_ipi:
    cmp     edi, 1
    jne     .send
    cmp     byte [rel ping_release_requested], 0
    je      .send
    cmp     esi, APIC_DRAIN_VECTOR
    jne     .check_ping
    ; Release the old reply only once the BSP is trying to drain it.
    mov     byte [rel ping_gate_open], 1
    jmp     .send
.check_ping:
    cmp     esi, APIC_PING_VECTOR
    jne     .send
    cmp     byte [rel dropped_fresh_ping], 0
    jne     .send
    ; The old reply must not make this unsent fresh request succeed.
    mov     byte [rel dropped_fresh_ping], 1
    xor     eax, eax
    ret
.send:
    jmp     __real_apic_send_ipi

section .bss
alignb 8
ap_resume:    resq 1
ap_gate_open: resb 1
ping_gate_open: resb 1
ping_release_requested: resb 1
dropped_fresh_ping: resb 1

%elifdef TEST_lost_ping
extern __real_apic_send_ipi
global __wrap_apic_send_ipi

section .text
__wrap_apic_send_ipi:
    cmp     edi, 1
    jne     .send
    cmp     esi, APIC_PING_VECTOR
    jne     .check_drain
    cmp     byte [rel ping_attempts], 0
    jne     .check_loss
    inc     byte [rel ping_attempts]
    ; Report a confirmed failure at the APIC driver's return boundary.
    mov     eax, APIC_IPI_NOT_SENT
    ret
.check_loss:
    cmp     byte [rel ping_attempts], 1
    jne     .send
    inc     byte [rel ping_attempts]
    jmp     .drop
.check_drain:
    cmp     esi, APIC_DRAIN_VECTOR
    jne     .send
    cmp     byte [rel dropped_drain], 0
    jne     .send
    mov     byte [rel dropped_drain], 1
.drop:
    xor     eax, eax
    ret
.send:
    jmp     __real_apic_send_ipi

section .bss
ping_attempts: resb 1
dropped_drain: resb 1

%elifdef TEST_crc32_work
extern __real_apic_send_ipi
extern __real_console_readline
extern __real_crc32_buffer
global __wrap_apic_send_ipi
global __wrap_console_readline
global __wrap_crc32_buffer

section .text
__wrap_apic_send_ipi:
    cmp     esi, APIC_CRC_VECTOR
    jne     .send
    inc     dword [rel crc_sends]
    cmp     dword [rel crc_sends], 2
    jne     .send
    ; Lose the second work interrupt without reporting a send failure.
    xor     eax, eax
    ret
.send:
    jmp     __real_apic_send_ipi

__wrap_console_readline:
    push    rdi
    call    __real_console_readline
    pop     rdi
    cmp     rax, 6
    jne     .done
    cmp     dword [rdi], 'crc-'
    jne     .done
    cmp     word [rdi + 4], 'go'
    jne     .done
    mov     byte [rel crc_gate_open], 1
    xor     eax, eax
.done:
    ret

__wrap_crc32_buffer:
    mov     eax, APIC_DEFAULT_BASE
    cmp     dword [rax + APIC_REG_ID], 1 << 24
    jne     __real_crc32_buffer
    inc     dword [rel crc_worker_calls]
    cmp     dword [rel crc_worker_calls], 2
    jne     .compute
    ; Keep the second claimed job alive past the boot CPU's timeout.
.wait:
    cmp     byte [rel crc_gate_open], 0
    jne     .compute
    pause
    jmp     .wait
.compute:
    sub     rsp, 8
    call    __real_crc32_buffer
    add     rsp, 8
    cmp     dword [rel crc_worker_calls], 1
    je      .tag_worker
    cmp     dword [rel crc_worker_calls], 2
    jne     .verify_snapshot
    mov     [rel crc_delayed_result], eax
.verify_snapshot:
    ; After the overwrite, the delayed worker must still see "123456789\n".
    cmp     dword [rel crc_delayed_result], 0xE0117757
    jne     .wrong_data
.tag_worker:
    ; Tag AP results so the serial test can distinguish a local fallback.
    xor     eax, 1
    ret
.wrong_data:
    mov     eax, 0xFFFFFFFF
    ret

section .bss
crc_sends:          resd 1
crc_worker_calls:   resd 1
crc_delayed_result: resd 1
crc_gate_open:      resb 1

%else
extern __real_smp_init
global __wrap_smp_init

section .text
__wrap_smp_init:
%ifdef TEST_missing_map
    and     dword [rdi + MBI_FLAGS], ~(1 << 6)
%elifdef TEST_one_page
    or      dword [rdi + MBI_FLAGS], 1 << 6
    lea     rax, [rel test_map]
    mov     [rdi + MBI_MMAP_ADDR], eax
    mov     dword [rdi + MBI_MMAP_LENGTH], test_map_end - test_map
%else
    %error Unknown SMP boot fixture
%endif
    jmp     __real_smp_init

%ifdef TEST_one_page
section .rodata
test_map:
    dd 20
    dq 0x400000, PAGE_SIZE
    dd 1
test_map_end:
%endif
%endif
