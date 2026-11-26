; Deterministic draw outcomes for one DNS-only guest.
bits 64
default rel
global dns_fixture_draw

section .text
dns_fixture_draw:
    mov     eax, [rel draws]
    inc     dword [rel draws]
    test    eax, eax                 ; Give boot DHCP its transaction ID.
    jz      .id
    dec     eax
    cmp     eax, 10                  ; First lookup, ten CF-clear results.
    jb      .failed
    je      .id
    cmp     eax, 26                  ; Second lookup, sixteen occupied ports.
    jbe     .collision
    cmp     eax, 27                  ; Third lookup, transient failure.
    je      .failed
    cmp     eax, 28
    je      .id
    mov     eax, 1                    ; Free port 49153.
    stc
    ret
.collision:
    xor     eax, eax                  ; Port 49152 is the fixture's UDP echo port.
    stc
    ret
.id:
    mov     eax, 0x1234
    stc
    ret
.failed:
    clc
    ret

section .bss
draws: resd 1
