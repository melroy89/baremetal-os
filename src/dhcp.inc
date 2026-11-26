; DHCPv4 client on the foreground service loop.
%define DHCP_SELECT 1
%define DHCP_REQUEST 2
%define DHCP_PROBE 3
%define DHCP_BOUND 4
%define DHCP_RENEW 5
%define DHCP_REBIND 6
%define DHCP_BACKOFF 7
%define DHCP_DECLINE 8
%define DHCP_COOKIE 0x63538263
%define DHCP_MIN 240
%define DHCP_RETRY_NS 1000000000
%define DHCP_DECLINE_NS 10000000000
%define DHCP_PROBE_COUNT 3
%define DHCP_PROBE_GAP 1000000000
%define DHCP_PROBE_SETTLE 2000000000
; Two probe gaps followed by the final settle interval, with time to use the lease.
%define DHCP_MIN_NEW_LEASE (((DHCP_PROBE_COUNT - 1) * DHCP_PROBE_GAP + DHCP_PROBE_SETTLE) / 1000000000 + 1)

struc dhcp_options
    .address: resd 1
    .server: resd 1
    .mask: resd 1
    .router: resd 1
    .dns: resd 1
    .lease: resd 1
    .t1: resd 1
    .t2: resd 1
    .type: resb 1
    alignb 4
endstruc

section .text
global dhcp_start

dhcp_start:
    sub     rsp, 8
    call    net_init
    test    rax, rax
    jnz     .done
    mov     edi, MODE_DHCP
    call    ip_handover
    call    dhcp_discover
    lea     rax, [rel dhcp_text]
.done:
    add     rsp, 8
    ret

dhcp_reset:
    mov     byte [rel dhcp_state], 0
    mov     qword [rel dhcp_expiry], 0
    ret

dhcp_discover:
    sub     rsp, 8
    call    dhcp_new_xid
    add     rsp, 8
    mov     byte [rel dhcp_state], DHCP_SELECT
    mov     qword [rel dhcp_next], 0
    mov     qword [rel dhcp_expiry], 0
    ret

dhcp_new_xid:
    sub     rsp, 8
    call    random_word
    jnc     .ready
    ; DHCP transaction identity also includes a unique station MAC.
    rdtsc
    xor     eax, edx
    xor     eax, [rel net_mac]
    xor     eax, [rel dhcp_xid]
    inc     eax
.ready:
    add     rsp, 8
    mov     [rel dhcp_xid], eax
    ret

dhcp_expire:
    cmp     byte [rel ip_mode], MODE_DHCP
    jne     .done
    mov     rax, [rel dhcp_expiry]
    test    rax, rax
    jz      .done
    cmp     [rel ip_now], rax
    jb      .done
    sub     rsp, 8
    call    ip_withdraw
    call    dhcp_discover
    add     rsp, 8
.done:
    ret

dhcp_tick:
    cmp     byte [rel ip_mode], MODE_DHCP
    jne     .idle
    push    rbx
    movzx   ebx, byte [rel dhcp_state]
    mov     rax, [rel ip_now]
    cmp     ebx, DHCP_PROBE
    je      .probe
    cmp     ebx, DHCP_BOUND
    je      .bound
    cmp     ebx, DHCP_RENEW
    je      .renew
    cmp     ebx, DHCP_BACKOFF
    je      .backoff
    jmp     .transmit
.bound:
    cmp     rax, [rel dhcp_t2]
    jae     .rebind_new
    cmp     rax, [rel dhcp_t1]
    jb      .done
    mov     ebx, DHCP_RENEW
    jmp     .new_exchange
.rebind_new:
    mov     ebx, DHCP_REBIND
.new_exchange:
    mov     [rel dhcp_state], bl
    call    dhcp_new_xid
    jmp     .immediate
.renew:
    cmp     rax, [rel dhcp_t2]
    jb      .transmit
    mov     ebx, DHCP_REBIND
    mov     [rel dhcp_state], bl
.immediate:
    mov     qword [rel dhcp_next], 0
.transmit:
    mov     rax, [rel ip_now]
    cmp     rax, [rel dhcp_next]
    jb      .done
    cmp     ebx, DHCP_REQUEST
    jne     .send
    cmp     rax, [rel dhcp_request_end]
    jb      .send
    call    dhcp_discover
    jmp     .done
.send:
    mov     edi, ebx
    call    dhcp_send
    test    rax, rax
    jnz     .done
    mov     rax, [rel ip_now]
    add     rax, DHCP_RETRY_NS
    mov     [rel dhcp_next], rax
    cmp     ebx, DHCP_DECLINE
    jne     .done
    mov     byte [rel dhcp_state], DHCP_BACKOFF
    mov     rdx, DHCP_DECLINE_NS
    add     rax, rdx
    mov     [rel dhcp_next], rax
    jmp     .done
.backoff:
    cmp     rax, [rel dhcp_next]
    jb      .done
    call    dhcp_discover
    jmp     .done
.probe:
    cmp     byte [rel arp_conflict], 0
    jne     .conflict
    cmp     rax, [rel dhcp_candidate_expiry]
    jae     .expired_candidate
    cmp     rax, [rel dhcp_next]
    jb      .done
    cmp     byte [rel dhcp_probes], DHCP_PROBE_COUNT
    je      .activate
    mov     edi, [rel arp_probe_ip]
    xor     esi, esi
    call    arp_request
    test    rax, rax
    jnz     .done
    inc     byte [rel dhcp_probes]
    mov     edx, DHCP_PROBE_GAP
    mov     ecx, DHCP_PROBE_SETTLE
    cmp     byte [rel dhcp_probes], DHCP_PROBE_COUNT
    cmove   edx, ecx
    mov     rax, [rel ip_now]
    add     rax, rdx
    mov     [rel dhcp_next], rax
    jmp     .done
.activate:
    call    dhcp_activate
    jmp     .done
.conflict:
    call    ip_withdraw
    mov     byte [rel dhcp_state], DHCP_DECLINE
    mov     qword [rel dhcp_next], 0
    jmp     .done
.expired_candidate:
    call    ip_withdraw
    call    dhcp_discover
.done:
    pop     rbx
.idle:
    ret

; edi = state. Build BOOTP and the DHCP options for this transmission.
dhcp_send:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    lea     rbx, [rel dhcp_packet]
    mov     rdi, rbx
    xor     eax, eax
    mov     ecx, 320 / 8
    rep     stosq
    mov     dword [rbx], 0x00060101   ; Request, Ethernet, six octets.
    mov     eax, [rel dhcp_xid]
    mov     [rbx + 4], eax
    mov     eax, [rel net_mac]
    mov     [rbx + 28], eax
    mov     ax, [rel net_mac + 4]
    mov     [rbx + 32], ax
    mov     dword [rbx + 236], DHCP_COOKIE
    mov     word [rbx + 240], 0x0135  ; Message type.
    mov     byte [rbx + 242], 3
    lea     r13, [rbx + 243]
    mov     edi, -1
    cmp     r12d, DHCP_SELECT
    je      .discover
    cmp     r12d, DHCP_RENEW
    je      .renew
    cmp     r12d, DHCP_REBIND
    je      .ciaddr
    cmp     r12d, DHCP_DECLINE
    je      .decline
    jmp     .offer
.renew:
    mov     edi, [rel dhcp_server]
.ciaddr:
    mov     eax, [rel ip_address]
    mov     [rbx + 12], eax
    jmp     .options
.discover:
    mov     byte [rbx + 242], 1
    jmp     .broadcast
.decline:
    mov     byte [rbx + 242], 4
.offer:
    mov     word [r13], 0x0432       ; Requested IP address.
    mov     eax, [rel dhcp_candidate + dhcp_options.address]
    mov     [r13 + 2], eax
    mov     word [r13 + 6], 0x0436   ; Server identifier.
    mov     eax, [rel dhcp_candidate + dhcp_options.server]
    mov     [r13 + 8], eax
    add     r13, 12
.broadcast:
    mov     word [rbx + 10], 0x0080
.options:
    mov     word [r13], 0x0637
    mov     dword [r13 + 2], 0x33060301 ; Mask, router, DNS, lease.
    mov     word [r13 + 6], 0x3B3A     ; T1 and T2.
    mov     byte [r13 + 8], 255
    mov     rsi, rbx
    mov     edx, (DHCP_CLIENT_PORT << 16) | DHCP_SERVER_PORT
    mov     ecx, 300
    mov     r8d, 1
    call    udp_send
    pop     r13
    pop     r12
    pop     rbx
    ret

; rdi = BOOTP, esi = datagram size, edx = sender IP, ecx = recipient IP.
dhcp_receive:
    cmp     byte [rel ip_mode], MODE_DHCP
    jne     .idle
    cmp     esi, DHCP_MIN + 1
    jb      .idle
    cmp     word [rdi], 0x0102
    jne     .idle
    cmp     byte [rdi + 2], 6
    jne     .idle
    mov     eax, [rdi + 4]
    cmp     eax, [rel dhcp_xid]
    jne     .idle
    mov     eax, [rdi + 28]
    cmp     eax, [rel net_mac]
    jne     .idle
    mov     ax, [rdi + 32]
    cmp     ax, [rel net_mac + 4]
    jne     .idle
    cmp     dword [rdi + 236], DHCP_COOKIE
    jne     .idle
    cmp     ecx, -1
    je      .recipient
    test    ecx, ecx
    jz      .idle
    cmp     ecx, [rel ip_address]
    je      .recipient
    cmp     ecx, [rdi + 16]
    jne     .idle
.recipient:
    push    rbx
    movzx   ebx, byte [rel dhcp_state]
    call    dhcp_parse
    jc      .done
    mov     edi, [rel dhcp_reply + dhcp_options.server]
    call    valid_unicast
    jc      .done
    mov     al, [rel dhcp_reply + dhcp_options.type]
    cmp     ebx, DHCP_SELECT
    je      .offer
    cmp     ebx, DHCP_REQUEST
    je      .request
    cmp     ebx, DHCP_REBIND
    je      .acknak
    cmp     ebx, DHCP_RENEW
    jne     .done
    cmp     edi, [rel dhcp_server]
    jne     .done
    jmp     .acknak
.request:
    cmp     edi, [rel dhcp_candidate + dhcp_options.server]
    jne     .done
.acknak:
    cmp     al, 6
    je      .nak
    cmp     al, 5
    jne     .done
    call    dhcp_validate
    jc      .done
    mov     eax, [rel dhcp_reply + dhcp_options.address]
    cmp     eax, [rel ip_address]
    je      .accepted
    cmp     dword [rel dhcp_reply + dhcp_options.lease], DHCP_MIN_NEW_LEASE
    jb      .done
.accepted:
    mov     rax, [rel ip_now]
    mov     edx, [rel dhcp_reply + dhcp_options.lease]
    imul    rdx, 1000000000
    add     rdx, rax
    mov     [rel dhcp_candidate_expiry], rdx
    mov     edx, [rel dhcp_reply + dhcp_options.t1]
    imul    rdx, 1000000000
    add     rdx, rax
    mov     [rel dhcp_t1], rdx
    mov     edx, [rel dhcp_reply + dhcp_options.t2]
    imul    rdx, 1000000000
    add     rdx, rax
    mov     [rel dhcp_t2], rdx
    call    dhcp_save_reply
    mov     eax, [rel dhcp_candidate + dhcp_options.address]
    cmp     eax, [rel ip_address]
    je      .same_address
    call    ip_withdraw
    mov     eax, [rel dhcp_candidate + dhcp_options.address]
    mov     [rel arp_probe_ip], eax
    mov     byte [rel dhcp_probes], 0
    mov     byte [rel dhcp_state], DHCP_PROBE
    mov     qword [rel dhcp_expiry], 0
    mov     qword [rel dhcp_next], 0
    jmp     .done
.same_address:
    call    dhcp_activate
    jmp     .done
.nak:
    call    ip_withdraw
    call    dhcp_discover
    jmp     .done
.offer:
    cmp     al, 2
    jne     .done
    cmp     dword [rel dhcp_reply + dhcp_options.lease], DHCP_MIN_NEW_LEASE
    jb      .done
    mov     edi, [rel dhcp_reply + dhcp_options.address]
    call    valid_unicast
    jc      .done
    call    dhcp_save_reply
    mov     byte [rel dhcp_state], DHCP_REQUEST
    mov     qword [rel dhcp_next], 0
    mov     rax, [rel ip_now]
    mov     rdx, 4000000000
    add     rax, rdx
    mov     [rel dhcp_request_end], rax
.done:
    pop     rbx
.idle:
    ret

dhcp_save_reply:
    lea     rsi, [rel dhcp_reply]
    lea     rdi, [rel dhcp_candidate]
    mov     ecx, dhcp_options_size / 4
    rep     movsd
    ret

; Validate the config and supply RFC defaults for absent lease timers.
dhcp_validate:
    push    rbx
    lea     rbx, [rel dhcp_reply]
    mov     edi, [rbx + dhcp_options.address]
    call    valid_unicast
    jc      .bad
    mov     esi, [rbx + dhcp_options.mask]
    test    esi, esi
    jz      .bad
    mov     eax, esi
    bswap   eax
    not     eax
    lea     edx, [rax + 1]
    test    eax, edx
    jnz     .bad
    call    valid_host
    jc      .bad
    mov     r8, [rel dhcp_router_start]
.router:
    cmp     r8, [rel dhcp_router_end]
    jae     .dns
    mov     edi, [r8]
    add     r8, 4
    call    valid_unicast
    jc      .router
    mov     eax, edi
    xor     eax, [rbx + dhcp_options.address]
    jz      .router
    test    eax, esi
    jnz     .router
    mov     ecx, edi
    call    valid_host
    jc      .router
    mov     [rbx + dhcp_options.router], ecx
.dns:
    mov     edi, [rbx + dhcp_options.dns]
    call    valid_unicast
    jnc     .lease
    mov     dword [rbx + dhcp_options.dns], 0
.lease:
    mov     eax, [rbx + dhcp_options.lease]
    cmp     eax, 3
    jb      .bad
    cmp     eax, -1
    jne     .timers
    ; Saturate an infinite lease in the monotonic deadline representation.
    mov     eax, 0x7FFFFFFF
    mov     [rbx + dhcp_options.lease], eax
.timers:
    mov     edx, [rbx + dhcp_options.t1]
    mov     ecx, [rbx + dhcp_options.t2]
    test    edx, edx
    jz      .defaults
    cmp     edx, ecx
    jae     .defaults
    cmp     ecx, eax
    jb      .good
.defaults:
    mov     edx, eax
    shr     edx, 1
    mov     [rbx + dhcp_options.t1], edx
    mov     edx, eax
    shr     edx, 3
    sub     eax, edx
    test    edx, edx
    jnz     .t2
    dec     eax
.t2:
    mov     [rbx + dhcp_options.t2], eax
.good:
    pop     rbx
    clc
    ret
.bad:
    pop     rbx
    stc
    ret

dhcp_activate:
    push    rbx
    lea     rbx, [rel dhcp_candidate]
    mov     eax, [rbx + dhcp_options.address]
    cmp     eax, [rel ip_address]
    jne     .clear
    mov     eax, [rbx + dhcp_options.mask]
    cmp     eax, [rel ip_mask]
    jne     .clear
    mov     eax, [rbx + dhcp_options.router]
    cmp     eax, [rel ip_gateway]
    jne     .clear
    mov     eax, [rbx + dhcp_options.dns]
    cmp     eax, [rel ip_dns]
    je      .commit
.clear:
    call    ip_withdraw
.commit:
    mov     eax, [rbx + dhcp_options.address]
    mov     [rel ip_address], eax
    mov     eax, [rbx + dhcp_options.mask]
    mov     [rel ip_mask], eax
    mov     eax, [rbx + dhcp_options.router]
    mov     [rel ip_gateway], eax
    mov     eax, [rbx + dhcp_options.dns]
    mov     [rel ip_dns], eax
    mov     eax, [rbx + dhcp_options.server]
    mov     [rel dhcp_server], eax
    mov     rax, [rel dhcp_candidate_expiry]
    mov     [rel dhcp_expiry], rax
    mov     byte [rel dhcp_state], DHCP_BOUND
    pop     rbx
    ret

; Decode bounded TLVs. IPv4 addresses remain in wire order; timers are host order.
dhcp_parse:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    lea     r12, [rdi + rsi]
    lea     rdi, [rel dhcp_reply]
    xor     eax, eax
    mov     ecx, dhcp_options_size / 4
    rep     stosd
    lea     r13, [rel dhcp_reply]
    mov     [rel dhcp_router_start], rax
    mov     [rel dhcp_router_end], rax
    mov     eax, [rbx + 16]
    mov     [r13 + dhcp_options.address], eax
    lea     rbx, [rbx + DHCP_MIN]
.next:
    cmp     rbx, r12
    jae     .bad
    movzx   eax, byte [rbx]
    inc     rbx
    test    eax, eax
    jz      .next
    cmp     eax, 255
    je      .done
    cmp     rbx, r12
    jae     .bad
    movzx   ecx, byte [rbx]
    inc     rbx
    lea     r14, [rbx + rcx]
    cmp     r14, r12
    ja      .bad
    cmp     eax, 53
    je      .type
    cmp     eax, 54
    je      .server
    cmp     eax, 1
    je      .mask
    cmp     eax, 3
    je      .router
    cmp     eax, 6
    je      .dns
    cmp     eax, 51
    je      .lease
    cmp     eax, 58
    je      .t1
    cmp     eax, 59
    je      .t2
.advance:
    mov     rbx, r14
    jmp     .next
.type:
    cmp     ecx, 1
    jne     .bad
    mov     al, [rbx]
    mov     [r13 + dhcp_options.type], al
    jmp     .advance
.server:
    lea     r15, [r13 + dhcp_options.server]
    jmp     .ipv4
.mask:
    lea     r15, [r13 + dhcp_options.mask]
.ipv4:
    cmp     ecx, 4
    jne     .bad
    mov     eax, [rbx]
    mov     [r15], eax
    jmp     .advance
.router:
    test    ecx, ecx
    jz      .bad
    test    ecx, 3
    jnz     .bad
    mov     [rel dhcp_router_start], rbx
    mov     [rel dhcp_router_end], r14
    jmp     .advance
.dns:
    lea     r15, [r13 + dhcp_options.dns]
.list:
    test    ecx, ecx
    jz      .bad
    test    ecx, 3
    jnz     .bad
.address:
    mov     edi, [rbx]
    call    valid_unicast
    jnc     .usable
    add     rbx, 4
    cmp     rbx, r14
    jb      .address
    jmp     .advance
.usable:
    mov     [r15], edi
    jmp     .advance
.lease:
    lea     r15, [r13 + dhcp_options.lease]
    jmp     .timer
.t1:
    lea     r15, [r13 + dhcp_options.t1]
    jmp     .timer
.t2:
    lea     r15, [r13 + dhcp_options.t2]
.timer:
    cmp     ecx, 4
    jne     .bad
    mov     eax, [rbx]
    bswap   eax
    mov     [r15], eax
    jmp     .advance
.done:
    clc
    jmp     .return
.bad:
    stc
.return:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

section .bss
alignb 8
dhcp_router_start: resq 1
dhcp_router_end: resq 1
dhcp_next: resq 1
dhcp_expiry: resq 1
dhcp_candidate_expiry: resq 1
dhcp_request_end: resq 1
dhcp_t1: resq 1
dhcp_t2: resq 1
dhcp_xid: resd 1
dhcp_server: resd 1
dhcp_state: resb 1
dhcp_probes: resb 1
dhcp_candidate: resb dhcp_options_size
dhcp_reply: resb dhcp_options_size
dhcp_packet: resb 320
