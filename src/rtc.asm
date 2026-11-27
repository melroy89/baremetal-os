; Read the boot CPU's PC-compatible CMOS clock. The clock is assumed UTC.
bits 64
default rel

%define RTC_INDEX 0x70
%define RTC_DATA 0x71
%define RTC_STATUS_A 0x0A
%define RTC_STATUS_B 0x0B
%define RTC_STATUS_D 0x0D
%define RTC_CENTURY 0x32             ; PC-compatible CMOS century byte.
%define RTC_UIP 0x80
%define RTC_VALID 0x80
%define RTC_FROZEN 0x80
%define RTC_BINARY 4
%define RTC_24_HOUR 2
%define RTC_TIMEOUT_NS 5000000

extern timer_ns
global rtc_unix_seconds
section .text

; Return seconds since 1970 in eax, or CF for invalid/unavailable time or
; a date outside ext2's signed 32-bit seconds range.
rtc_unix_seconds:
    push    rbx
    sub     rsp, 16
    call    timer_ns
    mov     rbx, rax
.retry:
    mov     rdi, rsp
    call    rtc_snapshot
    jc      .wait
    lea     rdi, [rsp + 8]
    call    rtc_snapshot
    jc      .wait
    mov     rax, [rsp]
    cmp     rax, [rsp + 8]
    je      .decode
.wait:
    pause
    call    timer_ns
    sub     rax, rbx
    cmp     rax, RTC_TIMEOUT_NS
    jb      .retry
    jmp     .invalid
.decode:
    ; The hour's top bit is PM in 12-hour mode, including BCD mode.
    movzx   r9d, byte [rsp + 2]
    and     r9d, 0x80
    and     byte [rsp + 2], 0x7F
    cmp     byte [rsp + 6], 0xFF      ; An absent century byte.
    jne     .format
    mov     byte [rsp + 6], 0
.format:
    test    byte [rsp + 7], RTC_BINARY
    jnz     .hour
    xor     ecx, ecx
.bcd:
    movzx   eax, byte [rsp + rcx]
    mov     edx, eax
    and     eax, 0xF
    shr     edx, 4
    cmp     eax, 9
    ja      .invalid
    cmp     edx, 9
    ja      .invalid
    imul    edx, 10
    add     eax, edx
    mov     [rsp + rcx], al
    inc     ecx
    cmp     ecx, 7
    jb      .bcd
.hour:
    movzx   edx, byte [rsp + 2]
    test    byte [rsp + 7], RTC_24_HOUR
    jnz     .hour24
    lea     eax, [rdx - 1]
    cmp     eax, 11
    ja      .invalid
    cmp     edx, 12
    jne     .period
    xor     edx, edx
.period:
    test    r9d, r9d
    jz      .time
    add     edx, 12
    jmp     .time
.hour24:
    test    r9d, r9d
    jnz     .invalid
    cmp     edx, 23
    ja      .invalid
.time:
    movzx   eax, byte [rsp + 1]
    movzx   ecx, byte [rsp]
    cmp     eax, 59
    ja      .invalid
    cmp     ecx, 59
    ja      .invalid
    imul    edx, 60
    add     edx, eax
    imul    r10d, edx, 60
    add     r10d, ecx

    movzx   r8d, byte [rsp + 5]
    cmp     r8d, 99
    ja      .invalid
    movzx   eax, byte [rsp + 6]
    test    eax, eax
    jz      .year_without_century
    imul    eax, 100
    add     r8d, eax
    jmp     .date
.year_without_century:
    ; Legacy two-digit window only if CMOS has no century value.
    add     r8d, 2000
    cmp     r8d, 2070
    jb      .date
    sub     r8d, 100
.date:
    cmp     r8d, 1970
    jb      .invalid
    cmp     r8d, 2038
    ja      .invalid
    movzx   ecx, byte [rsp + 4]
    dec     ecx
    cmp     ecx, 11
    ja      .invalid
    movzx   r9d, byte [rsp + 3]
    dec     r9d
    lea     rsi, [rel days_before_month]
    movzx   edx, word [rsi + rcx * 2]
    movzx   eax, word [rsi + rcx * 2 + 2]
    sub     eax, edx
    ; The decoded year range crosses only the leap century year 2000.
    test    r8b, 3
    jnz     .check_day
    cmp     ecx, 1
    jne     .after_feb
    inc     eax
.after_feb:
    cmp     ecx, 1
    jbe     .check_day
    inc     edx
.check_day:
    cmp     r9d, eax
    jae     .invalid
    add     edx, r9d
    lea     eax, [r8 - 1970]
    imul    eax, 365
    add     eax, edx
    dec     r8d
    shr     r8d, 2
    lea     eax, [rax + r8 - (1969 / 4)]
    imul    rax, 86400
    add     rax, r10
    cmp     rax, 0x7FFFFFFF
    ja      .invalid
    clc
    jmp     .done
.invalid:
    stc
.done:
    lea     rsp, [rsp + 16]
    pop     rbx
    ret

; Capture calendar registers outside the hardware update window.
rtc_snapshot:
    mov     al, RTC_STATUS_D
    out     RTC_INDEX, al
    in      al, RTC_DATA
    test    al, RTC_VALID
    jz      .retry
    xor     eax, eax                   ; Seconds, before checking UIP.
    out     RTC_INDEX, al
    in      al, RTC_DATA
    mov     [rdi], al
    mov     al, RTC_STATUS_A
    out     RTC_INDEX, al
    in      al, RTC_DATA
    test    al, RTC_UIP
    jnz     .retry
    lea     rsi, [rel rtc_registers]
    mov     ecx, 1
.next:
    mov     al, [rsi + rcx - 1]
    out     RTC_INDEX, al
    in      al, RTC_DATA
    mov     [rdi + rcx], al
    inc     ecx
    cmp     ecx, 8
    jb      .next
    test    byte [rdi + 7], RTC_FROZEN
    jnz     .retry
    mov     al, RTC_STATUS_A
    out     RTC_INDEX, al
    in      al, RTC_DATA
    test    al, RTC_UIP
    jnz     .retry
    xor     eax, eax
    out     RTC_INDEX, al
    in      al, RTC_DATA
    cmp     al, [rdi]
    jne     .retry
    clc
    ret
.retry:
    stc
    ret

section .rodata
rtc_registers: db 2, 4, 7, 8, 9, RTC_CENTURY, RTC_STATUS_B
days_before_month: dw 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365
