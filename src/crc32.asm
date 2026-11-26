; Standard CRC-32 (IEEE polynomial, reflected), plus the console command.
bits 64
default rel

extern ramfs_lookup
extern ramfs_not_found
extern smp_crc32
extern console_write_cstr
extern console_putc
extern write_hex32_raw

section .text
global crc32_buffer
global crc32_update
global command_crc32

; rdi = data, rsi = length in bytes. Return the checksum in eax.
crc32_buffer:
    xor     edx, edx
; rdi = data, rsi = length, edx = checksum of preceding bytes.
crc32_update:
    mov     eax, edx
    not     eax
    lea     rdx, [rel crc32_table]
    test    rsi, rsi
    jz      .done
.next:
    movzx   ecx, byte [rdi]
    xor     cl, al
    shr     eax, 8
    xor     eax, [rdx + rcx * 4]
    inc     rdi
    dec     rsi
    jnz     .next
.done:
    not     eax
    ret

command_crc32:
    cmp     byte [rdi], 0
    je      .usage
    sub     rsp, 8
    call    ramfs_lookup
    test    rax, rax
    jz      .missing
    mov     rdi, rax
    mov     rsi, rdx
    mov     edx, ecx
    call    smp_crc32
    mov     edi, eax
    call    write_hex32_raw
    mov     edi, 10
    add     rsp, 8
    jmp     console_putc
.missing:
    add     rsp, 8
    jmp     ramfs_not_found
.usage:
    lea     rdi, [rel crc32_usage]
    jmp     console_write_cstr

section .rodata
crc32_usage: db "Usage: crc32 FILE", 10, 0

align 4
crc32_table:
%assign byte_value 0
%rep 256
    %assign remainder byte_value
    %rep 8
        %if remainder & 1
            %assign remainder (remainder >> 1) ^ 0xEDB88320
        %else
            %assign remainder remainder >> 1
        %endif
    %endrep
    dd remainder
    %assign byte_value byte_value + 1
%endrep
