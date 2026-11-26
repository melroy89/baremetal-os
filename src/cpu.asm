; CPUID diagnostics for the boot CPU.
bits 64
default rel

extern console_write_cstr
extern console_putc
extern print_cpu_counts
extern g_smp_online_cpus
extern g_smp_total_cpus

section .text
global command_cpu

command_cpu:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 80                    ; 49-byte string buffer and four feature registers

    xor     eax, eax
    cpuid
    mov     r12d, eax                  ; Highest basic leaf
    mov     [rsp], ebx
    mov     [rsp + 4], edx
    mov     [rsp + 8], ecx
    mov     byte [rsp + 12], 0

    lea     rdi, [rel vendor_label]
    call    console_write_cstr
    mov     rdi, rsp
    call    console_write_cstr

    mov     qword [rsp + 56], 0
    mov     qword [rsp + 64], 0
    cmp     r12d, 1
    jb      .extended
    mov     eax, 1
    cpuid
    mov     [rsp + 56], ecx
    mov     [rsp + 60], edx
    cmp     r12d, 7
    jb      .extended
    mov     eax, 7
    xor     ecx, ecx
    cpuid
    mov     [rsp + 64], ebx

.extended:
    mov     eax, 0x80000000
    cpuid
    mov     r12d, eax                  ; Highest extended leaf
    cmp     r12d, 0x80000001
    jb      .no_model
    mov     eax, 0x80000001
    cpuid
    mov     [rsp + 68], edx
    cmp     r12d, 0x80000004
    jb      .no_model

    xor     r13d, r13d
.model_leaf:
    mov     eax, r13d
    shr     eax, 4
    add     eax, 0x80000002
    cpuid
    mov     [rsp + r13], eax
    mov     [rsp + r13 + 4], ebx
    mov     [rsp + r13 + 8], ecx
    mov     [rsp + r13 + 12], edx
    add     r13d, 16
    cmp     r13d, 48
    jb      .model_leaf
    mov     byte [rsp + 48], 0

    lea     rdi, [rel model_label]
    call    console_write_cstr
    mov     rdi, rsp
.skip_padding:
    cmp     byte [rdi], ' '
    jne     .print_model
    inc     rdi
    jmp     .skip_padding
.print_model:
    call    console_write_cstr
    jmp     .features

.no_model:
    lea     rdi, [rel model_unavailable]
    call    console_write_cstr

.features:
    lea     rdi, [rel features_label]
    call    console_write_cstr
    lea     r12, [rel feature_table]
    xor     r13d, r13d
.next_feature:
    mov     rdi, [r12]
    test    rdi, rdi
    jz      .finish_features
    mov     rax, [r12 + 8]
    add     r12, 16
    bt      [rsp + 56], rax
    jnc     .next_feature
    call    console_write_cstr
    inc     r13d
    jmp     .next_feature
.finish_features:
    test    r13d, r13d
    jnz     .counts
    lea     rdi, [rel none_label]
    call    console_write_cstr
.counts:
    mov     edi, 10
    call    console_putc
    mov     edi, [rel g_smp_online_cpus]
    mov     esi, [rel g_smp_total_cpus]
    call    print_cpu_counts

    add     rsp, 80
    pop     r13
    pop     r12
    pop     rbx
    ret

section .rodata
vendor_label:      db "CPU vendor: ", 0
model_label:       db 10, "CPU model: ", 0
model_unavailable: db 10, "CPU model: unavailable", 0
features_label:    db 10, "CPU capabilities:", 0
none_label:        db " none", 0
feature_apic:      db " APIC", 0
feature_sse2:      db " SSE2", 0
feature_sse42:     db " SSE4.2", 0
feature_avx:       db " AVX", 0
feature_avx2:      db " AVX2", 0
feature_nx:        db " NX", 0

; Bit offsets into CPUID.1 ECX/EDX, CPUID.7 EBX, CPUID.80000001 EDX.
align 8
feature_table:
    dq feature_apic, 32 + 9
    dq feature_sse2, 32 + 26
    dq feature_sse42, 20
    dq feature_avx, 28
    dq feature_avx2, 64 + 5
    dq feature_nx, 96 + 20
    dq 0
