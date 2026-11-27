; One polled IPv4 interface. The boot CPU owns protocol and frame state.
bits 64
default rel

%define ETH 14
%define IP_HEADER 20
%define IP_MTU 1500
%define UDP_HEADER 8
%define UDP_MAX (IP_MTU - IP_HEADER - UDP_HEADER)
%define ARP_CACHE_SIZE 8
%define ARP_TTL 60000000000
%define ARP_RETRY 250000000
%define PING_TIMEOUT 2000000000
%define IP_SERVICE_INTERVAL_NS 20000000
%define IP_PRESSURE_INTERVAL_NS 5000000
%define IP_PRESSURE_HOLD_NS 40000000
%define IP_RX_BUDGET 8
%define IP_RX_PRESSURE_MIN 2

%define MODE_RAW 0
%define MODE_STATIC 1
%define MODE_DHCP 2

extern net_init, net_mac, net_rx_poll, net_tx_submit, net_tx_complete
extern net_rx_boundary, net_rx_recycle, net_timer, net_irq_enable, net_irq_disable
extern net_irq_rearm
extern timer_ns, console_write_cstr, console_putc, write_u64, str_eq

global ip_mode, ip_command, ip_service, ip_info, command_ping, ip_usage
global ip_checkpoint, ip_checkpoint_at

section .text
ip_command:
    push    rbx
    mov     rbx, rdi
    lea     rsi, [rel off_name]
    call    str_eq
    test    eax, eax
    jnz     .off
    cmp     dword [rbx], 'stat'
    jne     .extra
    cmp     dword [rbx + 3], 'tic '
    jne     .usage
    lea     rdi, [rbx + 7]
    call    ip_static
    jmp     .print
.extra:
    mov     rdi, rbx
    call    ip_extra_command
    jmp     .print
.off:
    xor     edi, edi
    call    ip_handover
    lea     rax, [rel raw_text]
    jmp     .print
.usage:
    lea     rax, [rel ip_usage]
.print:
    mov     rdi, rax
    pop     rbx
    jmp     console_write_cstr

ip_static:
    push    rbx
    push    r12
    push    r13
    call    parse_ip
    jc      .bad
    mov     ebx, eax
    cmp     byte [rdi], '/'
    jne     .bad
    inc     rdi
    call    decimal_byte
    jc      .bad
    cmp     eax, 32
    ja      .bad
    mov     r12d, eax
    xor     r13d, r13d
    cmp     byte [rdi], 0
    je      .validate
    cmp     byte [rdi], ' '
    jne     .bad
    call    skip_space
    call    parse_ip
    jc      .bad
    cmp     byte [rdi], 0
    jne     .bad
    mov     r13d, eax
    mov     edi, eax
    call    valid_unicast
    jc      .bad
.validate:
    mov     edi, ebx
    call    valid_unicast
    jc      .bad
    mov     edi, r12d
    call    prefix_mask
    mov     r12d, eax
    mov     edi, ebx
    mov     esi, r12d
    call    valid_host
    jc      .bad
    test    r13d, r13d
    jz      .ready
    cmp     r13d, ebx
    je      .bad
    mov     eax, r13d
    xor     eax, ebx
    test    eax, r12d
    jnz     .bad
    mov     edi, r13d
    mov     esi, r12d
    call    valid_host
    jc      .bad
.ready:
    call    net_init
    test    rax, rax
    jnz     .done
    mov     edi, MODE_STATIC
    call    ip_handover
    mov     [rel ip_address], ebx
    mov     [rel ip_mask], r12d
    mov     [rel ip_gateway], r13d
    lea     rax, [rel static_text]
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret
.bad:
    lea     rax, [rel static_usage]
    jmp     .done

; Switch after validation. IRQs never dispatch RX.
ip_handover:
    push    rbx
    mov     ebx, edi
    call    net_irq_disable
    call    net_rx_boundary
    push    rax
    sub     rsp, 8
    call    ip_withdraw
    call    dhcp_reset
    add     rsp, 8
    pop     rdi
    call    net_rx_recycle
    mov     [rel ip_mode], bl
    mov     qword [rel ip_pressure_until], 0
    test    ebx, ebx
    jz      .timer
    call    net_irq_enable
.timer:
    xor     esi, esi
    mov     edi, ebx
    call    net_timer
    pop     rbx
    ret

ip_withdraw:
    sub     rsp, 8
    xor     eax, eax
    mov     [rel ip_address], eax
    mov     [rel ip_mask], eax
    mov     [rel ip_gateway], eax
    mov     [rel ip_dns], eax
    mov     [rel arp_probe_ip], eax
    mov     [rel arp_conflict], al
    mov     [rel ping_state], al
    lea     rdi, [rel arp_cache]
    mov     ecx, ARP_CACHE_SIZE * 3
    rep     stosq
    mov     [rel arp_cursor], eax
    mov     [rel arp_requested], eax
    mov     [rel arp_request_time], rax
    call    dns_cancel
    add     rsp, 8
    ret

ip_info:
    push    rbx
    movzx   ebx, byte [rel ip_mode]
    lea     rdi, [rel raw_text]
    test    ebx, ebx
    jz      .mode
    lea     rdi, [rel static_text]
    cmp     ebx, MODE_STATIC
    je      .mode
    lea     rdi, [rel dhcp_text]
.mode:
    call    console_write_cstr
    cmp     dword [rel ip_address], 0
    je      .pending
    lea     rdi, [rel address_text]
    call    console_write_cstr
    mov     edi, [rel ip_address]
    call    print_ip
    mov     edi, '/'
    call    console_putc
    mov     eax, [rel ip_mask]
    xor     edi, edi
.mask:
    test    eax, eax
    jz      .prefix
    lea     edx, [rax - 1]
    and     eax, edx
    inc     edi
    jmp     .mask
.prefix:
    call    write_u64
    lea     rdi, [rel gateway_text]
    call    console_write_cstr
    mov     edi, [rel ip_gateway]
    call    print_ip
    lea     rdi, [rel dns_text]
    call    console_write_cstr
    mov     edi, [rel ip_dns]
    call    print_ip
    mov     edi, 10
    call    console_putc
    jmp     .done
.pending:
    cmp     ebx, MODE_DHCP
    jne     .done
    lea     rdi, [rel acquiring_text]
    call    console_write_cstr
.done:
    pop     rbx
    ret

; Parse four decimal octets. Return wire-order eax and first suffix byte rdi.
parse_ip:
    push    rbx
    push    r12
    sub     rsp, 8
    xor     ebx, ebx
    mov     r12d, 4
.octet:
    call    decimal_byte
    jc      .bad
    ror     ebx, 8
    shl     eax, 24
    or      ebx, eax
    dec     r12d
    jz      .done
    cmp     byte [rdi], '.'
    jne     .bad
    inc     rdi
    jmp     .octet
.done:
    mov     eax, ebx
    clc
    jmp     .return
.bad:
    stc
.return:
    lea     rsp, [rsp + 8]
    pop     r12
    pop     rbx
    ret

decimal_byte:
    xor     eax, eax
    xor     ecx, ecx
.next:
    movzx   edx, byte [rdi]
    sub     edx, '0'
    cmp     edx, 9
    ja      .end
    imul    eax, eax, 10
    add     eax, edx
    cmp     eax, 255
    ja      .bad
    inc     rdi
    inc     ecx
    cmp     ecx, 3
    jbe     .next
.bad:
    stc
    ret
.end:
    test    ecx, ecx
    jz      .bad
    clc
    ret

skip_space:
    inc     rdi
    cmp     byte [rdi], ' '
    je      skip_space
    ret

print_ip:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     ebx, edi
    mov     r12d, 4
.next:
    movzx   edi, bl
    call    write_u64
    shr     ebx, 8
    dec     r12d
    jz      .done
    mov     edi, '.'
    call    console_putc
    jmp     .next
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

prefix_mask:
    xor     eax, eax
    test    edi, edi
    jz      .done
    mov     ecx, 32
    sub     ecx, edi
    mov     eax, -1
    shl     eax, cl
    bswap   eax
.done:
    ret

valid_unicast:
    test    dil, dil
    jz      .bad
    cmp     dil, 127
    je      .bad
    cmp     dil, 224
    jae     .bad
    clc
    ret
.bad:
    stc
    ret

; Accept both endpoints of /31, and /32.
valid_host:
    mov     eax, esi
    not     eax
    test    eax, eax
    jz      .good
    lea     edx, [rax - 1]
    test    eax, edx
    jz      .good
    and     edi, eax
    jz      .bad
    cmp     edi, eax
    je      .bad
.good:
    clc
    ret
.bad:
    stc
    ret

; Add little-endian 16-bit words. Final bytes can be written directly to wire.
; rdi = bytes, ecx = count, eax = initial sum.
checksum_sum:
    xor     edx, edx
.word:
    cmp     ecx, 2
    jb      .tail
    movzx   edx, word [rdi]
    add     eax, edx
    add     rdi, 2
    sub     ecx, 2
    jmp     .word
.tail:
    test    ecx, ecx
    jz      .done
    movzx   edx, byte [rdi]
    add     eax, edx
.done:
    ret

checksum:
    xor     eax, eax
    call    checksum_sum
checksum_finish:
    mov     edx, eax
    shr     eax, 16
    movzx   edx, dx
    add     eax, edx
    cmp     eax, 0xFFFF
    jbe     .done
    inc     ax
.done:
    not     ax
    ret

; Foreground I/O runs at most one batch per current service interval.
ip_checkpoint:
    cmp     byte [rel ip_mode], MODE_RAW
    je      ip_service.idle
    sub     rsp, 8
    call    timer_ns
    add     rsp, 8
ip_checkpoint_at:
    cmp     byte [rel ip_mode], MODE_RAW
    je      ip_service.idle
    mov     edx, IP_SERVICE_INTERVAL_NS
    cmp     qword [rel ip_pressure_until], 0
    je      .interval
    mov     edx, IP_PRESSURE_INTERVAL_NS
.interval:
    cmp     rax, rdx
    jb      ip_service.idle
    neg     rdx
    add     rdx, rax
    cmp     rdx, [rel ip_now]
    jb      ip_service.idle
    jmp     ip_service.run

; Return one when the RX budget was used. The console can check for more work.
ip_service:
    cmp     byte [rel ip_mode], MODE_RAW
    je      .idle
    sub     rsp, 8
    call    timer_ns
    add     rsp, 8
.run:
    cmp     byte [rel ip_mode], MODE_RAW
    je      .idle
    cmp     byte [rel ip_servicing], 0
    jne     .idle
    mov     byte [rel ip_servicing], 1
    push    rbx
    mov     [rel ip_now], rax
    call    dhcp_expire
    call    net_tx_complete
    mov     ebx, IP_RX_BUDGET
.receive:
    lea     rdi, [rel rx_frame]
    mov     esi, ETH + IP_MTU
    call    net_rx_poll
    test    rax, rax
    jnz     .tick
    test    edx, edx
    jz      .tick
    mov     esi, edx
    lea     rdi, [rel rx_frame]
    call    ip_frame
    dec     ebx
    jnz     .receive
.tick:
    ; Ramp up after a full batch. Small batches let the fast rate expire.
    mov     rax, [rel ip_now]
    test    ebx, ebx
    jz      .full
    cmp     qword [rel ip_pressure_until], 0
    je      .timers
    cmp     ebx, IP_RX_BUDGET - IP_RX_PRESSURE_MIN
    jbe     .extend_pressure
    cmp     rax, [rel ip_pressure_until]
    jb      .timers
    mov     qword [rel ip_pressure_until], 0
    xor     esi, esi
    jmp     .set_timer
.full:
    cmp     qword [rel ip_pressure_until], 0
    jne     .extend_pressure
    add     rax, IP_PRESSURE_HOLD_NS
    mov     [rel ip_pressure_until], rax
    mov     esi, 1
    jmp     .set_timer
.extend_pressure:
    add     rax, IP_PRESSURE_HOLD_NS
    mov     [rel ip_pressure_until], rax
    jmp     .timers
.set_timer:
    mov     edi, 1
    call    net_timer
.timers:
    call    dhcp_tick
    call    dns_tick
    call    ping_tick
    xor     eax, eax
    test    ebx, ebx
    setz    al                       ; The receive budget was exhausted.
    pop     rbx
    mov     byte [rel ip_servicing], 0
    ret
.idle:
    xor     eax, eax
    ret

; Called with interrupts disabled and eax holding the ip_service batch result.
; Poll again after a full batch or if arming RX finds queued completions.
ip_wait_rx:
    test    eax, eax
    jnz     .done
    sub     rsp, 8
    call    net_irq_rearm
    add     rsp, 8
    test    eax, eax
    jnz     .done
    sti                              ; Deliver pending interrupts after HLT.
    hlt
    cli
.done:
    ret

; rdi = Ethernet frame, esi = size. Only NIC unicast or Ethernet broadcast.
ip_frame:
    mov     eax, [rdi]
    cmp     eax, [rel net_mac]
    jne     .broadcast
    mov     ax, [rdi + 4]
    cmp     ax, [rel net_mac + 4]
    je      .type
.broadcast:
    cmp     dword [rdi], -1
    jne     .ignore
    cmp     word [rdi + 4], -1
    jne     .ignore
.type:
    test    byte [rdi + 6], 1
    jnz     .ignore
    cmp     word [rdi + 12], 0x0608
    je      arp_receive
    cmp     word [rdi + 12], 0x0008
    je      ipv4_receive
.ignore:
    ret

; Construct the Ethernet address and resolve the IPv4 next hop.
; edi = destination, esi = optional flags (1 permits limited broadcast).
route_mac:
    cmp     edi, -1
    jne     .normal
    test    esi, esi
    jz      .failed
    mov     rax, 0xFFFFFFFFFFFF
    clc
    ret
.normal:
    cmp     dword [rel ip_address], 0
    je      .failed
    mov     eax, edi
    xor     eax, [rel ip_address]
    test    eax, [rel ip_mask]
    jz      .lookup
    mov     edi, [rel ip_gateway]
    test    edi, edi
    jz      .failed
.lookup:
    lea     rsi, [rel arp_cache]
    mov     ecx, ARP_CACHE_SIZE
    mov     rax, [rel ip_now]
.next:
    cmp     edi, [rsi]
    jne     .advance
    cmp     rax, [rsi + 16]
    jb      .hit
.advance:
    add     rsi, 24
    loop    .next
    cmp     edi, [rel arp_requested]
    jne     .request
    cmp     rax, [rel arp_request_time]
    jb      .failed
.request:
    sub     rsp, 8
    mov     [rel arp_requested], edi
    add     rax, ARP_RETRY
    mov     [rel arp_request_time], rax
    mov     esi, [rel ip_address]
    call    arp_request
    add     rsp, 8
.failed:
    stc
    ret
.hit:
    mov     rax, [rsi + 8]
    clc
    ret

; edi = target IP, esi = source IP (zero for DHCP probes).
arp_request:
    mov     r8, 0xFFFFFFFFFFFF
    xor     r9d, r9d
    mov     edx, 1
    jmp     arp_send

; edi = target IP, esi = sender IP, edx = operation, r8 = destination MAC,
; r9 = ARP target MAC.
arp_send:
    lea     rcx, [rel arp_frame]
    mov     [rcx], r8
    mov     eax, [rel net_mac]
    mov     [rcx + 6], eax
    mov     ax, [rel net_mac + 4]
    mov     [rcx + 10], ax
    mov     word [rcx + 12], 0x0608
    mov     dword [rcx + 14], 0x00080100
    mov     word [rcx + 18], 0x0406
    rol     dx, 8
    mov     [rcx + 20], dx
    mov     eax, [rel net_mac]
    mov     [rcx + 22], eax
    mov     ax, [rel net_mac + 4]
    mov     [rcx + 26], ax
    mov     [rcx + 28], esi
    mov     [rcx + 32], r9
    mov     [rcx + 38], edi
    mov     rdi, rcx
    mov     esi, 42
    jmp     net_tx_submit

arp_receive:
    cmp     esi, 42
    jb      .done
    cmp     dword [rdi + 14], 0x00080100
    jne     .done
    cmp     word [rdi + 18], 0x0406
    jne     .done
    mov     eax, [rdi + 6]
    cmp     eax, [rdi + 22]
    jne     .done
    mov     ax, [rdi + 10]
    cmp     ax, [rdi + 26]
    jne     .done
    mov     ecx, [rdi + 28]
    mov     edx, [rdi + 38]
    movzx   esi, word [rdi + 20]
    cmp     esi, 0x100
    je      .op
    cmp     esi, 0x200
    jne     .done
.op:
    mov     eax, [rel arp_probe_ip]
    test    eax, eax
    jz      .active
    cmp     ecx, eax
    je      .conflict
    test    ecx, ecx
    jnz     .active
    cmp     esi, 0x100
    jne     .active
    cmp     edx, eax
    jne     .active
.conflict:
    mov     byte [rel arp_conflict], 1
.active:
    mov     eax, [rel ip_address]
    test    eax, eax
    jz      .done
    cmp     edx, eax
    jne     .done
    cmp     ecx, eax
    je      .done
    mov     r8, [rdi + 22]
    shl     r8, 16
    shr     r8, 16
    jz      .done
    test    ecx, ecx
    jz      .reply
    xor     eax, ecx
    test    eax, [rel ip_mask]
    jnz     .done
    lea     r9, [rel arp_cache]
    mov     eax, ARP_CACHE_SIZE
.find:
    cmp     ecx, [r9]
    je      .store
    add     r9, 24
    dec     eax
    jnz     .find
    mov     eax, [rel arp_cursor]
    lea     r9, [rel arp_cache]
    lea     rax, [rax + rax * 2]
    lea     r9, [r9 + rax * 8]
    inc     dword [rel arp_cursor]
    and     dword [rel arp_cursor], ARP_CACHE_SIZE - 1
.store:
    mov     [r9], ecx
    mov     [r9 + 8], r8
    mov     rax, [rel ip_now]
    mov     r10, ARP_TTL
    add     rax, r10
    mov     [r9 + 16], rax
.reply:
    cmp     esi, 0x100
    jne     .done
    mov     edi, ecx
    mov     esi, edx
    mov     edx, 2
    mov     r9, r8
    jmp     arp_send
.done:
    ret

; edi = destination IP, esi = protocol, rdx = payload, ecx = length,
; r8 = Ethernet destination. Return driver status.
ipv4_send:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdx
    mov     r13d, ecx
    lea     rbx, [rel tx_frame]
    mov     [rbx], r8
    mov     eax, [rel net_mac]
    mov     [rbx + 6], eax
    mov     ax, [rel net_mac + 4]
    mov     [rbx + 10], ax
    mov     word [rbx + 12], 0x0008
    mov     word [rbx + ETH], 0x45
    lea     eax, [rcx + IP_HEADER]
    rol     ax, 8
    mov     [rbx + ETH + 2], ax
    mov     eax, [rel ip_ident]
    inc     dword [rel ip_ident]
    rol     ax, 8
    mov     [rbx + ETH + 4], ax
    mov     word [rbx + ETH + 6], 0x40 ; DF
    mov     byte [rbx + ETH + 8], 64
    mov     [rbx + ETH + 9], sil
    mov     word [rbx + ETH + 10], 0
    mov     eax, [rel ip_address]
    mov     [rbx + ETH + 12], eax
    mov     [rbx + ETH + 16], edi
    lea     rdi, [rbx + ETH]
    mov     ecx, IP_HEADER
    call    checksum
    mov     [rbx + ETH + 10], ax
    lea     rdi, [rbx + ETH + IP_HEADER]
    mov     rsi, r12
    mov     ecx, r13d
    rep     movsb
    mov     rdi, rbx
    lea     esi, [r13 + ETH + IP_HEADER]
    call    net_tx_submit
    pop     r13
    pop     r12
    pop     rbx
    ret

; Validate and strip Ethernet padding, then dispatch the IP payload.
ipv4_receive:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    cmp     esi, ETH + IP_HEADER
    jb      .done
    movzx   r12d, byte [rbx + ETH]
    mov     eax, r12d
    and     eax, 0xF0
    cmp     eax, 0x40
    jne     .done
    and     r12d, 15
    shl     r12d, 2
    cmp     r12d, IP_HEADER
    jb      .done
    movzx   r13d, word [rbx + ETH + 2]
    rol     r13w, 8
    cmp     r13d, r12d
    jb      .done
    sub     esi, ETH
    cmp     r13d, esi
    ja      .done
    cmp     r13d, IP_MTU
    ja      .done
    test    word [rbx + ETH + 6], 0xFFBF ; Reserved, MF and fragment offset.
    jnz     .done
    cmp     byte [rbx + ETH + 8], 0
    je      .done
    lea     rdi, [rbx + ETH]
    mov     ecx, r12d
    call    checksum
    test    ax, ax
    jnz     .done
    lea     rdi, [rbx + r12 + ETH]
    mov     esi, r13d
    sub     esi, r12d
    mov     edx, [rbx + ETH + 12]
    mov     ecx, [rbx + ETH + 16]
    cmp     byte [rbx + ETH + 9], 17
    je      .udp
    cmp     byte [rbx + ETH + 9], 1
    jne     .done
    cmp     dword [rel ip_address], 0
    je      .done
    cmp     ecx, [rel ip_address]
    jne     .done
    mov     r8, [rbx + 6]
    shl     r8, 16
    shr     r8, 16
    call    icmp_receive
    jmp     .done
.udp:
    call    udp_receive
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

command_ping:
    push    rbx
    mov     rbx, rdi
    cmp     dword [rel ip_address], 0
    je      .disabled
    call    parse_ip
    jc      .name
    cmp     byte [rdi], 0
    jne     .name
    jmp     .address
.name:
    mov     rdi, rbx
    call    dns_lookup
    jc      .print
.address:
    mov     ebx, eax
    mov     edi, eax
    call    valid_unicast
    jc      .invalid
    mov     [rel ping_target], ebx
    cmp     ebx, [rel ip_address]
    je      .reply
    inc     word [rel ping_seq]
    call    timer_ns
    add     rax, PING_TIMEOUT
    mov     [rel ping_deadline], rax
    mov     byte [rel ping_state], 1
.wait:
    call    ip_service
    mov     cl, [rel ping_state]
    cmp     cl, 3
    je      .reply
    test    cl, cl
    jz      .cancelled
    mov     rcx, [rel ip_now]
    cmp     rcx, [rel ping_deadline]
    jae     .timeout
    call    ip_wait_rx
    jmp     .wait
.reply:
    mov     byte [rel ping_state], 0
    lea     rdi, [rel reply_text]
    call    console_write_cstr
    mov     edi, ebx
    call    print_ip
    pop     rbx
    mov     edi, 10
    jmp     console_putc
.timeout:
    mov     byte [rel ping_state], 0
    lea     rax, [rel ping_timeout_text]
    jmp     .print
.cancelled:
    lea     rax, [rel config_changed]
    jmp     .print
.invalid:
    lea     rax, [rel ping_usage]
    jmp     .print
.disabled:
    lea     rax, [rel no_ip_text]
.print:
    pop     rbx
    mov     rdi, rax
    jmp     console_write_cstr

ping_tick:
    cmp     byte [rel ping_state], 1
    jne     .idle
    mov     rax, [rel ip_now]
    cmp     rax, [rel ping_deadline]
    jae     .idle
    push    rbx
    mov     edi, [rel ping_target]
    xor     esi, esi
    call    route_mac
    jc      .done
    mov     rbx, rax
    lea     rdi, [rel ping_payload]
    mov     dword [rdi], 8
    mov     word [rdi + 4], 0x4D42
    mov     ax, [rel ping_seq]
    mov     [rdi + 6], ax
    mov     ecx, 8
    call    checksum
    mov     [rel ping_payload + 2], ax
    mov     edi, [rel ping_target]
    mov     esi, 1
    lea     rdx, [rel ping_payload]
    mov     ecx, 8
    mov     r8, rbx
    call    ipv4_send
    test    rax, rax
    jnz     .done
    mov     byte [rel ping_state], 2
.done:
    pop     rbx
.idle:
    ret

; rdi = ICMP, esi = length, edx = sender IP, r8 = incoming source MAC.
icmp_receive:
    cmp     esi, 8
    jb      .idle
    cmp     byte [rdi + 1], 0
    jne     .idle
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14, r8
    mov     edi, edx
    call    valid_unicast
    jc      .done
    mov     rdi, rbx
    mov     ecx, r12d
    call    checksum
    test    ax, ax
    jnz     .done
    cmp     byte [rbx], 8
    je      .echo
    cmp     byte [rbx], 0
    jne     .done
    cmp     byte [rel ping_state], 2
    jne     .done
    cmp     r13d, [rel ping_target]
    jne     .done
    cmp     word [rbx + 4], 0x4D42
    jne     .done
    mov     ax, [rel ping_seq]
    cmp     [rbx + 6], ax
    jne     .done
    mov     byte [rel ping_state], 3
    jmp     .done
.echo:
    lea     rdi, [rel echo_payload]
    mov     rsi, rbx
    mov     ecx, r12d
    rep     movsb
    lea     rdi, [rel echo_payload]
    mov     dword [rdi], 0
    mov     ecx, r12d
    call    checksum
    mov     [rel echo_payload + 2], ax
    mov     edi, r13d
    mov     esi, 1
    lea     rdx, [rel echo_payload]
    mov     ecx, r12d
    mov     r8, r14
    call    ipv4_send
.done:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.idle:
    ret

section .rodata
off_name: db "off", 0
ip_usage: db "Usage: net info | net static ADDRESS/PREFIX [GATEWAY] | net dhcp | net dns ADDRESS | net resolve NAME | net off | net recv | net send DEST TYPE FILE", 10, 0
static_usage: db "Usage: net static ADDRESS/PREFIX [GATEWAY] (valid on-link gateway)", 10, 0
ping_usage: db "Usage: ping ADDRESS or NAME", 10, 0
raw_text: db "IPv4: off", 10, 0
static_text: db "IPv4: static", 10, 0
dhcp_text: db "IPv4: DHCP", 10, 0
acquiring_text: db "Acquiring address", 10, 0
address_text: db "Address: ", 0
gateway_text: db 10, "Gateway: ", 0
dns_text: db 10, "DNS: ", 0
reply_text: db "Reply from ", 0
no_ip_text: db "IPv4 address unavailable.", 10, 0
ping_timeout_text: db "Ping timed out.", 10, 0
config_changed: db "IPv4 configuration changed.", 10, 0

section .bss
alignb 8
ip_now: resq 1
ip_pressure_until: resq 1
ping_deadline: resq 1
arp_request_time: resq 1
arp_cache: resb ARP_CACHE_SIZE * 24
arp_cursor: resd 1
arp_requested: resd 1
ip_address: resd 1
ip_mask: resd 1
ip_gateway: resd 1
ip_dns: resd 1
ip_ident: resd 1
arp_probe_ip: resd 1
ping_target: resd 1
ping_seq: resw 1
ip_mode: resb 1
ip_servicing: resb 1
ping_state: resb 1
arp_conflict: resb 1
arp_frame: resb 42
rx_frame: resb ETH + IP_MTU
tx_frame: resb ETH + IP_MTU
echo_payload: resb IP_MTU - IP_HEADER
ping_payload: resb 8

%include "udp.inc"
%include "dhcp.inc"
%include "dns.inc"
