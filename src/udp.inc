; Internal UDP endpoint table. Ports are in host byte order.
%define DHCP_CLIENT_PORT 68
%define DHCP_SERVER_PORT 67
%define DNS_SERVER_PORT 53

section .text
; edi = candidate port. Return nonzero if a handler already owns it.
udp_port_bound:
    cmp     edi, DHCP_CLIENT_PORT
    je      .bound
    cmp     di, [rel dns_port]
    je      .bound
%ifdef TEST_UDP_ECHO
    cmp     edi, TEST_UDP_ECHO
    je      .bound
%endif
    xor     eax, eax
    ret
.bound:
    mov     eax, 1
    ret

; rdi = datagram, esi = IP payload length, edx = source IP, ecx = destination IP.
udp_receive:
    cmp     esi, UDP_HEADER
    jb      .idle
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12d, edx
    mov     r13d, ecx
    movzx   r14d, word [rbx + 4]
    rol     r14w, 8
    cmp     r14d, UDP_HEADER
    jb      .done
    cmp     r14d, esi
    jne     .done
    movzx   r15d, word [rbx + 2]
    rol     r15w, 8
    cmp     word [rbx + 6], 0
    je      .dispatch
    mov     esi, r14d
    call    udp_checksum
    test    ax, ax
    jnz     .done
.dispatch:
    lea     rdi, [rbx + UDP_HEADER]
    lea     esi, [r14 - UDP_HEADER]
    mov     edx, r12d
    mov     ecx, r13d
    movzx   r8d, word [rbx]
    rol     r8w, 8
    cmp     r15d, DHCP_CLIENT_PORT
    je      .dhcp
    cmp     dword [rel ip_address], 0
    je      .done
    cmp     r13d, [rel ip_address]
    jne     .done
%ifdef TEST_UDP_ECHO
    cmp     r15d, TEST_UDP_ECHO
    je      .echo
%endif
    cmp     r15w, [rel dns_port]
    jne     .done
    call    dns_receive
    jmp     .done
.dhcp:
    cmp     r8d, DHCP_SERVER_PORT
    jne     .done
    call    dhcp_receive
    jmp     .done
%ifdef TEST_UDP_ECHO
.echo:
    shl     r15d, 16
    or      r8d, r15d
    mov     ecx, esi
    mov     rsi, rdi
    mov     edi, edx
    mov     edx, r8d
    xor     r8d, r8d
    call    udp_send
%endif
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.idle:
    ret

; rdi = UDP data including header, esi = length, edx/ecx = IP endpoints.
udp_checksum:
    movzx   eax, dx
    shr     edx, 16
    add     eax, edx
    movzx   edx, cx
    shr     ecx, 16
    add     eax, edx
    add     eax, ecx
    add     eax, 0x1100
    mov     ecx, esi
    rol     si, 8
    add     eax, esi
    sub     rsp, 8
    call    checksum_sum
    add     rsp, 8
    jmp     checksum_finish

; edi = destination IP, rsi = data, edx = source port << 16 | destination,
; ecx = length, r8d = 1 to allow broadcast. Return nonzero if not submitted.
udp_send:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, edi
    mov     r12, rsi
    mov     r13d, edx
    mov     r14d, ecx
    cmp     ecx, UDP_MAX
    ja      .blocked
    mov     esi, r8d
    call    route_mac
    jc      .blocked
    mov     r15, rax
    lea     rdi, [rel udp_frame]
    mov     eax, r13d
    shr     eax, 16
    rol     ax, 8
    mov     [rdi], ax
    rol     r13w, 8
    mov     [rdi + 2], r13w
    lea     eax, [r14 + UDP_HEADER]
    rol     ax, 8
    mov     [rdi + 4], ax
    mov     word [rdi + 6], 0
    add     rdi, UDP_HEADER
    mov     rsi, r12
    mov     ecx, r14d
    rep     movsb
    lea     rdi, [rel udp_frame]
    lea     esi, [r14 + UDP_HEADER]
    mov     edx, [rel ip_address]
    mov     ecx, ebx
    call    udp_checksum
    test    ax, ax
    jnz     .send
    mov     ax, -1
.send:
    mov     [rel udp_frame + 6], ax
    mov     edi, ebx
    mov     esi, 17
    lea     rdx, [rel udp_frame]
    lea     ecx, [r14 + UDP_HEADER]
    mov     r8, r15
    call    ipv4_send
    jmp     .done
.blocked:
    mov     eax, 1
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

section .bss
udp_frame: resb UDP_MAX + UDP_HEADER
