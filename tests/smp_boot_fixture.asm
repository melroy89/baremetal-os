; Linker wrappers for disposable Multiboot kernels. Release links omit this file.
bits 64
default rel
%include "os_constants.inc"

%ifdef TEST_delayed_ap
extern __real_pit_delay_us
extern __real_console_readline
global __wrap_pit_delay_us
global __wrap_console_readline

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
    jne     .done
    cmp     word [rdi], 'go'
    jne     .done
    mov     byte [rel ap_gate_open], 1
    xor     eax, eax                   ; Treat the test signal as an empty line.
.done:
    ret

section .bss
alignb 8
ap_resume:    resq 1
ap_gate_open: resb 1

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
