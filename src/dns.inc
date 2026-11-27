; Minimal DNS stub resolver, one foreground A query at a time.
%define DNS_HEADER 12
%define DNS_NAME 255
%define DNS_HOPS 8
%define DNS_POINTERS 16
%define DNS_TIMEOUT 3000000000

%ifdef TEST_DNS_RNG
extern dns_fixture_draw
%endif

section .text
ip_extra_command:
    push    rbx
    mov     rbx, rdi
    lea     rsi, [rel dhcp_name]
    call    str_eq
    test    eax, eax
    jnz     .dhcp
    cmp     dword [rbx], 'dns '
    je      .dns
    cmp     dword [rbx], 'reso'
    jne     .usage
    cmp     dword [rbx + 4], 'lve '
    jne     .usage
    lea     rdi, [rbx + 8]
    call    dns_lookup
    jc      .done
    mov     edi, eax
    call    print_ip
    mov     edi, 10
    call    console_putc
    lea     rax, [rel empty_text]
    jmp     .done
.dhcp:
    call    dhcp_start
    jmp     .done
.dns:
    cmp     byte [rel ip_mode], MODE_STATIC
    jne     .static_required
    lea     rdi, [rbx + 4]
    call    parse_ip
    jc      .usage
    cmp     byte [rdi], 0
    jne     .usage
    mov     ebx, eax
    mov     edi, eax
    call    valid_unicast
    jc      .usage
    call    dns_cancel
    mov     [rel ip_dns], ebx
    lea     rax, [rel dns_configured]
    jmp     .done
.static_required:
    lea     rax, [rel dns_static]
    jmp     .done
.usage:
    lea     rax, [rel ip_usage]
.done:
    pop     rbx
    ret

; Return a usable random word in eax with CF clear, or CF set on failure.
random_word:
    push    rbx
    mov     eax, 1
    cpuid
    pop     rbx
    test    ecx, 1 << 30
    jz      .fail
    mov     ecx, 10
.draw:
%ifdef TEST_DNS_RNG
    sub     rsp, 8
    call    dns_fixture_draw
    lea     rsp, [rsp + 8]
%else
    rdrand  eax
%endif
    jc      .good
    dec     ecx
    jnz     .draw
.fail:
    stc
    ret
.good:
    clc
    ret

dns_cancel:
    cmp     word [rel dns_port], 0
    je      .done
    lea     rax, [rel config_changed]
    mov     [rel dns_result], rax
    mov     word [rel dns_port], 0
    mov     byte [rel dns_sent], 0
.done:
    ret

; rdi = NUL-terminated name. Return address in eax or error string, CF set.
dns_lookup:
    push    rbx
    cmp     dword [rel ip_address], 0
    je      .no_ip
    cmp     dword [rel ip_dns], 0
    je      .no_dns
    call    dns_encode
    jc      .bad_name
    mov     byte [rel dns_hops], 0
    call    timer_ns
    mov     rdx, DNS_TIMEOUT
    add     rax, rdx
    mov     [rel dns_deadline], rax
    call    dns_begin
    test    rax, rax
    jnz     .error
.wait:
    call    ip_service
    cmp     word [rel dns_port], 0
    je      .result
    call    ip_wait_rx
    jmp     .wait
.result:
    mov     rax, [rel dns_result]
    test    rax, rax
    jnz     .error
    mov     eax, [rel dns_answer]
    clc
    jmp     .done
.no_ip:
    lea     rax, [rel no_ip_text]
    jmp     .error
.no_dns:
    lea     rax, [rel dns_unconfigured]
    jmp     .error
.bad_name:
    lea     rax, [rel dns_bad_name]
.error:
    stc
.done:
    pop     rbx
    ret

; Allocate transaction parameters before any ARP or DNS send.
dns_begin:
    push    rbx
    call    random_word
    jc      .entropy
    mov     [rel dns_id], ax
    mov     ebx, 16
.port:
    call    random_word
    jc      .entropy
    mov     edi, eax
    and     edi, 0x3FFF
    or      edi, 0xC000
    call    udp_port_bound
    test    eax, eax
    jz      .build
    dec     ebx
    jnz     .port
    lea     rax, [rel dns_no_port]
    jmp     .done
.entropy:
    lea     rax, [rel dns_entropy]
    jmp     .done
.build:
    mov     [rel dns_port], di
    mov     eax, [rel ip_dns]
    mov     [rel dns_peer], eax
    lea     rdi, [rel dns_query]
    xor     eax, eax
    mov     [rdi + 4], rax
    mov     ax, [rel dns_id]
    mov     [rdi], ax
    mov     word [rdi + 2], 1          ; RD
    mov     word [rdi + 4], 0x100      ; QDCOUNT = 1
    add     rdi, DNS_HEADER
    lea     rsi, [rel dns_question]
    mov     ecx, [rel dns_question_size]
    lea     eax, [rcx + DNS_HEADER + 4]
    mov     [rel dns_query_size], eax
    rep     movsb
    mov     dword [rdi], 0x01000100    ; A, IN
    mov     byte [rel dns_sent], 0
    mov     qword [rel dns_result], 0
    xor     eax, eax
.done:
    pop     rbx
    ret

dns_tick:
    movzx   edx, word [rel dns_port]
    test    edx, edx
    jz      .done
    mov     rax, [rel ip_now]
    cmp     rax, [rel dns_deadline]
    jae     .timeout
    cmp     byte [rel dns_sent], 0
    jne     .done
    sub     rsp, 8
    shl     edx, 16
    or      edx, DNS_SERVER_PORT
    mov     edi, [rel dns_peer]
    lea     rsi, [rel dns_query]
    mov     ecx, [rel dns_query_size]
    xor     r8d, r8d
    call    udp_send
    add     rsp, 8
    test    rax, rax
    jnz     .done
    mov     byte [rel dns_sent], 1
.done:
    ret
.timeout:
    lea     rax, [rel dns_timeout_text]
    jmp     dns_finish

dns_finish:
    mov     [rel dns_result], rax
    mov     word [rel dns_port], 0
    mov     byte [rel dns_sent], 0
    ret

; Encode an input name as length-prefixed labels. Preserve ASCII case.
dns_encode:
    lea     rsi, [rel dns_question]
    mov     r8, rsi
    lea     r9, [rsi + DNS_NAME - 1]
.label:
    mov     rdx, rsi
    inc     rsi
    xor     ecx, ecx
.byte:
    mov     al, [rdi]
    test    al, al
    jz      .end_label
    cmp     al, '.'
    je      .end_label
    cmp     al, '!'
    jb      .bad
    cmp     al, '~'
    ja      .bad
    cmp     al, 0x5C
    je      .bad
    cmp     ecx, 63
    jae     .bad
    cmp     rsi, r9
    jae     .bad
    mov     [rsi], al
    inc     rsi
    inc     rdi
    inc     ecx
    jmp     .byte
.end_label:
    test    ecx, ecx
    jz      .bad
    mov     [rdx], cl
    test    al, al
    jz      .end
    inc     rdi
    cmp     byte [rdi], 0
    jne     .label
.end:
    mov     byte [rsi], 0
    inc     rsi
    sub     rsi, r8
    mov     [rel dns_question_size], esi
    clc
    ret
.bad:
    stc
    ret

; Decode message name at rdi, output to rsi, with message base rdx and end rcx.
; Returns first byte after the original name in rdi. Pointers must go backward.
dns_decode:
    push    rbx
    push    r12
    xor     ebx, ebx
    mov     r12d, DNS_POINTERS
    lea     r8, [rsi + DNS_NAME]
.next:
    cmp     rdi, rcx
    jae     .bad
    movzx   eax, byte [rdi]
    inc     rdi
    cmp     eax, 63
    ja      .pointer
    lea     r10, [rsi + rax]
    cmp     r10, r8
    jae     .bad
    mov     [rsi], al
    inc     rsi
    test    eax, eax
    jz      .done
    lea     r10, [rdi + rax]
    cmp     r10, rcx
    ja      .bad
.copy:
    mov     r9b, [rdi]
    mov     [rsi], r9b
    inc     rdi
    inc     rsi
    dec     eax
    jnz     .copy
    jmp     .next
.pointer:
    cmp     eax, 192
    jb      .bad
    dec     r12d
    js      .bad
    cmp     rdi, rcx
    jae     .bad
    and     eax, 63
    shl     eax, 8
    mov     al, [rdi]
    lea     r10, [rdx + rax]
    lea     r9, [rdi - 1]
    cmp     r10, r9
    jae     .bad
    test    rbx, rbx
    jnz     .jump
    lea     rbx, [rdi + 1]
.jump:
    mov     rdi, r10
    jmp     .next
.done:
    test    rbx, rbx
    cmovnz  rdi, rbx
    clc
    jmp     .return
.bad:
    stc
.return:
    pop     r12
    pop     rbx
    ret

; Compare decoded names label by label. Lengths must match before any folding.
dns_name_equal:
.label:
    movzx   ecx, byte [rdi]
    cmp     cl, [rsi]
    jne     .different
    test    ecx, ecx
    jz      .equal
    inc     rdi
    inc     rsi
.byte:
    mov     al, [rdi]
    mov     dl, [rsi]
    cmp     al, 'A'
    jb      .right
    cmp     al, 'Z'
    ja      .right
    or      al, 0x20
.right:
    cmp     dl, 'A'
    jb      .compare
    cmp     dl, 'Z'
    ja      .compare
    or      dl, 0x20
.compare:
    cmp     al, dl
    jne     .different
    inc     rdi
    inc     rsi
    dec     ecx
    jnz     .byte
    jmp     .label
.equal:
    mov     eax, 1
    ret
.different:
    xor     eax, eax
    ret

; rdi = DNS payload, esi = length, edx = source IP, r8d = source port.
dns_receive:
    cmp     word [rel dns_port], 0
    je      .idle
    cmp     byte [rel dns_sent], 1
    jne     .idle
    cmp     r8d, DNS_SERVER_PORT
    jne     .idle
    cmp     edx, [rel dns_peer]
    jne     .idle
    mov     rax, [rel ip_now]
    cmp     rax, [rel dns_deadline]
    jae     .idle
    cmp     esi, DNS_HEADER
    jb      .idle
    mov     ax, [rel dns_id]
    cmp     ax, [rdi]
    jne     .idle
    mov     al, [rdi + 2]
    and     al, 0xF8
    cmp     al, 0x80                  ; Response, standard query opcode.
    jne     .idle
    cmp     word [rdi + 4], 0x100
    jne     .idle
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16
    mov     r12, rdi
    lea     r13, [rdi + rsi]
    add     rdi, DNS_HEADER
    lea     rsi, [rel dns_owner]
    mov     rdx, r12
    mov     rcx, r13
    call    dns_decode
    jc      .done
    lea     rax, [rdi + 4]
    cmp     rax, r13
    ja      .done
    cmp     dword [rdi], 0x01000100
    jne     .done
    mov     r14, rax
    lea     rdi, [rel dns_owner]
    lea     rsi, [rel dns_question]
    call    dns_name_equal
    test    eax, eax
    jz      .done
    test    byte [r12 + 2], 2
    jnz     .truncated
    mov     al, [r12 + 3]
    and     al, 15
    cmp     al, 3
    je      .nxdomain
    test    al, al
    jnz     .server_error
    mov     byte [rsp], 0
    mov     al, [rel dns_hops]
    mov     [rsp + 1], al
    lea     rsi, [rel dns_question]
    lea     rdi, [rel dns_target]
    mov     ecx, [rel dns_question_size]
    mov     [rsp + 4], ecx
    rep     movsb
.scan:
    mov     rbx, r14
    movzx   r15d, word [r12 + 6]
    rol     r15w, 8
.record:
    test    r15d, r15d
    jz      .no_record
    dec     r15d
    mov     rdi, rbx
    lea     rsi, [rel dns_owner]
    mov     rdx, r12
    mov     rcx, r13
    call    dns_decode
    jc      .done
    lea     rbx, [rdi + 10]
    cmp     rbx, r13
    ja      .done
    movzx   eax, word [rdi + 8]
    rol     ax, 8
    add     rbx, rax
    cmp     rbx, r13
    ja      .done
    cmp     word [rdi + 2], 0x100
    jne     .record
    mov     [rsp + 8], rdi
    lea     rdi, [rel dns_owner]
    lea     rsi, [rel dns_target]
    call    dns_name_equal
    test    eax, eax
    jz      .record
    mov     rdi, [rsp + 8]
    cmp     word [rdi], 0x100
    je      .address
    cmp     word [rdi], 0x500
    jne     .record
    cmp     byte [rsp + 1], DNS_HOPS
    jae     .alias_limit
    add     rdi, 10
    lea     rsi, [rel dns_alias]
    mov     rdx, r12
    mov     rcx, r13
    call    dns_decode
    jc      .done
    cmp     rdi, rbx
    jne     .done
    mov     byte [rsp], 1
    inc     byte [rsp + 1]
    lea     rsi, [rel dns_alias]
    lea     rdi, [rel dns_target]
    mov     rcx, rdi
.alias:
    lodsb
    stosb
    test    al, al
    jz      .alias_end
    movzx   edx, al
.alias_label:
    movsb
    dec     edx
    jnz     .alias_label
    jmp     .alias
.alias_end:
    sub     rdi, rcx
    mov     [rsp + 4], edi
    jmp     .scan
.address:
    cmp     word [rdi + 8], 0x400
    jne     .done
    mov     eax, [rdi + 10]
    mov     [rel dns_answer], eax
    xor     eax, eax
    jmp     .finish
.no_record:
    cmp     byte [rsp], 0
    je      .no_a
    mov     al, [rsp + 1]
    mov     [rel dns_hops], al
    lea     rsi, [rel dns_target]
    lea     rdi, [rel dns_question]
    mov     ecx, [rsp + 4]
    mov     [rel dns_question_size], ecx
    rep     movsb
    ; Keep the old binding reserved while picking a distinct source port.
    call    dns_begin
    test    rax, rax
    jz      .done
    jmp     .finish
.no_a:
    lea     rax, [rel dns_no_a]
    jmp     .finish
.nxdomain:
    lea     rax, [rel dns_nxdomain_text]
    jmp     .finish
.truncated:
    lea     rax, [rel dns_truncated]
    jmp     .finish
.server_error:
    lea     rax, [rel dns_server_error]
    jmp     .finish
.alias_limit:
    lea     rax, [rel dns_alias_error]
.finish:
    call    dns_finish
.done:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.idle:
    ret

section .rodata
dhcp_name: db "dhcp", 0
empty_text: db 0
dns_configured: db "DNS configured.", 10, 0
dns_static: db "Configure static IPv4 before setting DNS.", 10, 0
dns_unconfigured: db "DNS server unavailable.", 10, 0
dns_bad_name: db "Invalid DNS name.", 10, 0
dns_entropy: db "DNS entropy unavailable.", 10, 0
dns_no_port: db "Unable to reserve a DNS source port.", 10, 0
dns_timeout_text: db "DNS query timed out.", 10, 0
dns_no_a: db "DNS reply has no A record.", 10, 0
dns_nxdomain_text: db "DNS name does not exist (NXDOMAIN).", 10, 0
dns_truncated: db "DNS reply truncated.", 10, 0
dns_server_error: db "DNS server returned an error.", 10, 0
dns_alias_error: db "DNS CNAME limit exceeded.", 10, 0

section .bss
alignb 8
dns_result: resq 1
dns_deadline: resq 1
dns_answer: resd 1
dns_peer: resd 1
dns_query_size: resd 1
dns_question_size: resd 1
dns_port: resw 1
dns_id: resw 1
dns_sent: resb 1
dns_hops: resb 1
dns_question: resb DNS_NAME
dns_alias: resb DNS_NAME
dns_target: resb DNS_NAME
dns_owner: resb DNS_NAME
dns_query: resb DNS_HEADER + DNS_NAME + 4
