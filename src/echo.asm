; Console echo with one optional output redirection.
bits 64
default rel

extern console_write
extern console_write_cstr
extern console_putc
%include "os_constants.inc"

extern vfs_write

section .text
global command_echo

command_echo:
    mov     rsi, rdi                    ; Start of text
    mov     rcx, rdi                    ; Scan cursor
    cmp     byte [rcx], '"'
    je      .quoted

.unquoted:
    mov     al, [rcx]
    test    al, al
    jz      .print_unquoted
    cmp     al, '>'
    je      .redirect_unquoted
    cmp     al, '"'
    je      .usage
    inc     rcx
    jmp     .unquoted

.quoted:
    inc     rsi
    mov     rcx, rsi
.quoted_byte:
    mov     al, [rcx]
    test    al, al
    jz      .usage
    cmp     al, '"'
    je      .quote_end
    inc     rcx
    jmp     .quoted_byte
.quote_end:
    mov     rdx, rcx
    sub     rdx, rsi
    inc     rcx
.after_quote:
    cmp     byte [rcx], ' '
    jne     .quote_suffix
    inc     rcx
    jmp     .after_quote
.quote_suffix:
    cmp     byte [rcx], 0
    je      .print
    cmp     byte [rcx], '>'
    je      .redirect
    jmp     .usage

.print_unquoted:
    mov     rdx, rcx
    sub     rdx, rsi
.print:
    sub     rsp, 8
    mov     rdi, rsi
    mov     rsi, rdx
    call    console_write
    mov     edi, 10
    add     rsp, 8
    jmp     console_putc

.redirect_unquoted:
    mov     rdx, rcx
.trim_text:
    cmp     rdx, rsi
    je      .length
    cmp     byte [rdx - 1], ' '
    jne     .length
    dec     rdx
    jmp     .trim_text
.length:
    sub     rdx, rsi
.redirect:
    lea     rdi, [rcx + 1]
.skip_space:
    cmp     byte [rdi], ' '
    jne     .target
    inc     rdi
    jmp     .skip_space
.target:
    cmp     byte [rdi], 0
    je      .usage
    mov     rcx, rdi
.check_target:
    mov     al, [rcx]
    test    al, al
    jz      .write
    cmp     al, '>'
    je      .usage
    cmp     al, '"'
    je      .usage
    inc     rcx
    jmp     .check_target

.write:
    cmp     rdx, LINE_BUF_SIZE
    jae     .usage
    mov     r8, rdi
    lea     rdi, [rel output_bytes]
    mov     rcx, rdx
    rep     movsb
    mov     byte [rdi], 10
    inc     rdx
    mov     rdi, r8
    lea     rsi, [rel output_bytes]
    jmp     vfs_write

.usage:
    lea     rdi, [rel echo_usage]
    jmp     console_write_cstr

section .rodata
echo_usage: db "Usage: echo [TEXT] [> FILE]", 10, 0

section .bss
output_bytes: resb LINE_BUF_SIZE
