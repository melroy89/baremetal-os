; Polled, single-interface Ethernet for QEMU's 82540EM (e1000).
bits 64
default rel

%include "os_constants.inc"

%define E1000_ID    0x100E8086
%define PCI_CMD     4
%define PCI_BAR0    16
%define REG_CTRL    0x0000
%define REG_STATUS  0x0008
%define REG_IMC     0x00D8
%define REG_ICR     0x00C0
%define REG_RCTL    0x0100
%define REG_TCTL    0x0400
%define REG_TIPG    0x0410
%define REG_RDBAL   0x2800
%define REG_RDBAH   0x2804
%define REG_RDLEN   0x2808
%define REG_RDH     0x2810
%define REG_RDT     0x2818
%define REG_TDBAL   0x3800
%define REG_TDBAH   0x3804
%define REG_TDLEN   0x3808
%define REG_TDH     0x3810
%define REG_TDT     0x3818
%define REG_RAL     0x5400
%define REG_RAH     0x5404
%define DESC_COUNT  8
%define DESC_BYTES  16
%define RING_BYTES  (DESC_COUNT * DESC_BYTES)
%define RX_BYTES    2048
%define PAGES       6
%define FRAME_HDR   14
%define FRAME_MIN   60
%define PAYLOAD_MAX 1500
%define NET_WAIT_NS 1000000000

extern pci_walk
extern pci_config_read32
extern pci_config_write16
extern page_alloc
extern page_free
extern timer_ns
extern ramfs_lookup
extern ramfs_not_found
extern str_eq
extern console_putc
extern console_write
extern console_write_cstr
extern format_hex_raw
extern write_u64
extern ip_command, ip_info, ip_mode, ip_usage
extern virtio_init, virtio_shutdown, virtio_link
extern virtio_rx_poll, virtio_rx_boundary, virtio_rx_recycle
extern virtio_tx_submit, virtio_tx_complete

section .text
global command_net
global net_frame_receive
global net_frame_send
global net_init, net_mac, net_rx_poll, net_tx_submit, net_tx_complete
global net_rx_boundary, net_rx_recycle, net_shutdown
global nic_bdf, tx_busy, invalid_frame, invalid_tx_size, link_down_error

command_net:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    lea     rsi, [rel info_arg]
    call    str_eq
    test    eax, eax
    jnz     .info
    mov     rdi, rbx
    lea     rsi, [rel recv_arg]
    call    str_eq
    test    eax, eax
    jnz     .receive
    cmp     dword [rbx], 'send'
    jne     .ip_command
    cmp     byte [rel ip_mode], 0
    jne     .raw_only
    cmp     byte [rbx + 4], ' '
    jne     .usage
    lea     rdi, [rbx + 5]
    call    parse_send
    jc      .usage
    call    ramfs_lookup
    test    rax, rax
    jz      .missing_file
    cmp     rdx, PAYLOAD_MAX
    ja      .large_payload
    mov     rsi, rax
    mov     r13, rdx
    lea     r12, [rel console_frame]
    mov     rax, [rel destination]
    mov     [r12], eax
    shr     rax, 32
    mov     [r12 + 4], ax
    mov     ax, [rel ether_type]
    rol     ax, 8
    mov     [r12 + 12], ax
    lea     rdi, [r12 + FRAME_HDR]
    mov     rcx, r13
    rep     movsb

    ; Initialize the device before taking its source MAC.
    call    net_init
    test    rax, rax
    jnz     .error
    mov     eax, [rel nic_mac]
    mov     [r12 + 6], eax
    mov     ax, [rel nic_mac + 4]
    mov     [r12 + 10], ax
    mov     rdi, r12
    lea     rsi, [r13 + FRAME_HDR]
    call    net_frame_send
    test    rax, rax
    jnz     .error
    mov     r12d, edx
    lea     rdi, [rel sent_label]
    call    console_write_cstr
    mov     edi, r12d
    call    write_u64
    lea     rdi, [rel bytes_label]
    jmp     .print

.ip_command:
    mov     rdi, rbx
    pop     r13
    pop     r12
    pop     rbx
    jmp     ip_command
.raw_only:
    lea     rdi, [rel raw_only]
    jmp     .print
.info:
    call    net_init
    test    rax, rax
    jnz     .error
    lea     rdi, [rel pci_label]
    call    console_write_cstr
    call    print_bdf
    lea     rdi, [rel mac_label]
    call    console_write_cstr
    lea     rdi, [rel nic_mac]
    call    print_mac
    call    net_link
    lea     rdi, [rel link_up]
    test    eax, eax
    jnz     .print_info
    lea     rdi, [rel link_down]
.print_info:
    call    console_write_cstr
    lea     rdi, [rel e1000_driver]
    cmp     byte [rel backend], 2
    jne     .driver
    lea     rdi, [rel virtio_driver]
.driver:
    call    console_write_cstr
    call    net_tx_complete
    call    ip_info
    jmp     .done
.receive:
    cmp     byte [rel ip_mode], 0
    jne     .raw_only
    lea     rdi, [rel console_frame]
    mov     esi, FRAME_HDR + PAYLOAD_MAX
    call    net_frame_receive
    test    rax, rax
    jnz     .error
    mov     r12d, edx
    lea     r13, [rel console_frame]
    lea     rdi, [rel frame_label]
    call    console_write_cstr
    mov     edi, r12d
    call    write_u64
    lea     rdi, [rel dst_label]
    call    console_write_cstr
    mov     rdi, r13
    call    print_mac
    lea     rdi, [rel src_label]
    call    console_write_cstr
    lea     rdi, [r13 + 6]
    call    print_mac
    lea     rdi, [rel type_label]
    call    console_write_cstr
    movzx   edi, word [r13 + 12]
    rol     di, 8
    call    print_type
    jmp     .done
.error:
    mov     rdi, rax
.print:
    call    console_write_cstr
    jmp     .done
.usage:
    lea     rdi, [rel ip_usage]
    jmp     .print
.large_payload:
    lea     rdi, [rel too_large]
    jmp     .print
.missing_file:
    pop     r13
    pop     r12
    pop     rbx
    jmp     ramfs_not_found
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

require_link:
    sub     rsp, 8
    call    net_init
    add     rsp, 8
    test    rax, rax
    jnz     .done
    call    net_link
    test    eax, eax
    jz      .down
    xor     eax, eax
    ret
.down:
    lea     rax, [rel link_down_error]
.done:
    ret

find_nic:
    xor     eax, eax
    cmp     esi, E1000_ID
    jne     .done
    mov     [rel nic_bdf], edi
    inc     eax
.done:
    ret

net_init:
    cmp     byte [rel backend], 0
    jne     .ready
    push    rbx
    call    virtio_init
    test    rax, rax
    jz      .virtio
    mov     rbx, rax
    call    e1000_init
    test    rax, rax
    jnz     .fallback_error
    mov     byte [rel backend], 1
    jmp     .done
.fallback_error:
    cmp     rbx, 1
    cmovne  rax, rbx
    jmp     .done
.virtio:
    mov     byte [rel backend], 2
.done:
    pop     rbx
    ret
.ready:
    xor     eax, eax
    ret

net_link:
    cmp     byte [rel backend], 2
    je      virtio_link
    mov     rax, [rel nic_mmio]
    mov     eax, [rax + REG_STATUS]
    shr     eax, 1
    and     eax, 1
    ret

net_shutdown:
    cmp     byte [rel backend], 2
    je      virtio_shutdown
    mov     rax, [rel nic_mmio]
    test    rax, rax
    jz      .done
    mov     dword [rax + REG_RCTL], 0
    mov     dword [rax + REG_TCTL], 0
    mov     edi, [rel nic_bdf]
    mov     esi, PCI_CMD
    sub     rsp, 8
    call    pci_config_read32
    add     rsp, 8
    movzx   edx, ax
    and     edx, ~4
    jmp     set_command
.done:
    ret

e1000_init:
    cmp     qword [rel nic_mmio], 0
    jne     .ready
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    lea     rdi, [rel find_nic]
    xor     esi, esi
    mov     edx, 1
    call    pci_walk
    cmp     eax, 1
    jne     .missing
    mov     edi, [rel nic_bdf]
    mov     esi, PCI_BAR0
    call    pci_config_read32
    test    eax, 7
    jnz     .bad_bar
    and     eax, -16
    cmp     eax, HIGH_MMIO_BASE
    jb      .bad_bar
    cmp     eax, 0xFFFE0000            ; Entire 128 KiB BAR fits below 4 GiB.
    ja      .bad_bar
    test    eax, 0x1FFFF
    jnz     .bad_bar
    mov     ebx, eax
    mov     edi, [rel nic_bdf]
    mov     esi, PCI_CMD
    call    pci_config_read32
    movzx   r15d, ax
    mov     edx, r15d
    or      edx, 2                     ; Memory decoding; defer DMA enable.
    and     edx, ~4
    call    set_command
    mov     dword [rbx + REG_IMC], -1
    mov     r12d, [rbx + REG_RAL]
    mov     r13d, [rbx + REG_RAH]
    mov     eax, r12d
    or      ax, r13w
    test    eax, eax
    jz      .bad_mac
    test    r12b, 1
    jnz     .bad_mac
    mov     [rel nic_mac], r12d
    mov     [rel nic_mac + 4], r13w
    mov     eax, [rbx + REG_CTRL]
    or      eax, 1 << 26               ; Controller reset
    mov     [rbx + REG_CTRL], eax
    call    timer_ns
    lea     r14, [rax + NET_WAIT_NS]
.reset_wait:
    test    dword [rbx + REG_CTRL], 1 << 26
    jz      .allocate
    call    timer_ns
    cmp     rax, r14
    jb      .reset_wait
    lea     r13, [rel reset_timeout]
    jmp     .restore

.allocate:
    xor     r14d, r14d
    lea     r12, [rel dma_pages]
.page:
    call    page_alloc
    test    rax, rax
    jz      .no_pages
    mov     [r12 + r14 * 8], rax
    inc     r14d
    cmp     r14d, PAGES
    jb      .page

    mov     rdi, [r12]
    xor     eax, eax
    mov     ecx, 2 * RING_BYTES / 8
    rep     stosq
    mov     rdi, [r12]
    xor     ecx, ecx
.rx_buffer:
    mov     eax, ecx
    shr     eax, 1
    mov     rdx, [r12 + rax * 8 + 8]
    test    ecx, 1
    jz      .rx_store
    add     rdx, RX_BYTES
.rx_store:
    mov     [rdi], rdx
    add     rdi, DESC_BYTES
    inc     ecx
    cmp     ecx, DESC_COUNT
    jb      .rx_buffer

    mov     eax, [rel nic_mac]
    mov     [rbx + REG_RAL], eax
    movzx   eax, word [rel nic_mac + 4]
    or      eax, 1 << 31
    mov     [rbx + REG_RAH], eax
    mov     dword [rbx + REG_IMC], -1
    mov     eax, [rbx + REG_ICR]
    mov     dword [rbx + REG_RCTL], 0
    mov     dword [rbx + REG_TCTL], 0
    mov     eax, [r12]
    mov     [rbx + REG_RDBAL], eax
    mov     dword [rbx + REG_RDBAH], 0
    mov     dword [rbx + REG_RDLEN], RING_BYTES
    mov     dword [rbx + REG_RDH], 0
    mov     dword [rbx + REG_RDT], DESC_COUNT - 1
    add     eax, RING_BYTES
    mov     [rbx + REG_TDBAL], eax
    mov     dword [rbx + REG_TDBAH], 0
    mov     dword [rbx + REG_TDLEN], RING_BYTES
    mov     dword [rbx + REG_TDH], 0
    mov     dword [rbx + REG_TDT], 0
    mov     dword [rbx + REG_TIPG], 0x0060200A
    mov     eax, [rbx + REG_CTRL]
    or      eax, 1 << 6                ; Set link up
    mov     [rbx + REG_CTRL], eax
    mfence
    mov     edx, r15d
    or      edx, 6
    call    set_command
    mov     dword [rbx + REG_RCTL], (1 << 26) | (1 << 15) | 2
    mov     dword [rbx + REG_TCTL], 0x0004010A
    mov     [rel nic_mmio], rbx
    xor     eax, eax
    jmp     .done

.no_pages:
    test    r14d, r14d
    jz      .allocation_error
    dec     r14d
    mov     rdi, [r12 + r14 * 8]
    mov     qword [r12 + r14 * 8], 0
    call    page_free
    jmp     .no_pages
.allocation_error:
    lea     r13, [rel no_dma_pages]
    jmp     .restore
.bad_mac:
    lea     r13, [rel bad_mac]
.restore:
    mov     edx, r15d
    and     edx, ~4                   ; A partial init must leave DMA disabled.
    call    set_command
    mov     rax, r13
    jmp     .done
.missing:
    lea     rax, [rel no_nic]
    jmp     .done
.bad_bar:
    lea     rax, [rel unsupported_bar]
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.ready:
    xor     eax, eax
    ret

set_command:
    mov     edi, [rel nic_bdf]
    mov     esi, PCI_CMD
    jmp     pci_config_write16

; rdi = completion byte. Return CF set on timeout.
wait_descriptor:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    call    timer_ns
    lea     r12, [rax + NET_WAIT_NS]
.next:
    test    byte [rbx], 1
    jnz     .ready
    call    timer_ns
    cmp     rax, r12
    jae     .timeout
    pause
    jmp     .next
.ready:
    mfence
    xor     eax, eax
    jmp     .done
.timeout:
    stc
.done:
    lea     rsp, [rsp + 8]
    pop     r12
    pop     rbx
    ret

; rdi = caller buffer, rsi = capacity. Return error string in rax or
; zero with frame length in edx. DMA buffers stay private to the driver.
net_rx_poll:
    xor     edx, edx
    jmp     receive_frame
net_frame_receive:
    mov     edx, 1
receive_frame:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r13, rdi
    mov     r14, rsi
    mov     r15d, edx
    call    require_link
    test    rax, rax
    jnz     .done
    cmp     byte [rel backend], 2
    je      .virtio
    mov     r12d, [rel rx_next]
    mov     ebx, r12d
    shl     ebx, 4
    add     rbx, [rel dma_pages]
    lea     rdi, [rbx + 12]
    test    r15d, r15d
    jz      .poll
    call    wait_descriptor
    jc      .timeout
    jmp     .ready
.poll:
    test    byte [rdi], 1
    jz      .empty
.ready:
    xor     r15d, r15d
    test    byte [rbx + 12], 2         ; EOP
    jz      .invalid
    cmp     byte [rbx + 13], 0         ; Errors
    jne     .invalid
    movzx   r15d, word [rbx + 8]
    cmp     r15d, FRAME_HDR
    jb      .invalid
    cmp     r15d, FRAME_HDR + PAYLOAD_MAX
    ja      .invalid
    cmp     r15, r14
    ja      .too_small
    mov     rdi, r13
    mov     rsi, [rbx]
    mov     rcx, r15
    rep     movsb
    xor     eax, eax
    jmp     .recycle
.invalid:
    lea     rax, [rel invalid_frame]
    jmp     .recycle
.too_small:
    lea     rax, [rel rx_capacity]
.recycle:
    mov     qword [rbx + 8], 0
    mfence
    mov     rdx, [rel nic_mmio]
    mov     [rdx + REG_RDT], r12d
    inc     r12d
    and     r12d, DESC_COUNT - 1
    mov     [rel rx_next], r12d
    mov     edx, r15d
    jmp     .done
.empty:
    xor     edx, edx
    xor     eax, eax
    jmp     .done
.timeout:
    lea     rax, [rel rx_timeout]
    jmp     .done
.virtio:
    mov     rdi, r13
    mov     rsi, r14
    test    r15d, r15d
    jz      .virtio_poll
    call    wait_virtio_rx
    jmp     .done
.virtio_poll:
    call    virtio_rx_poll
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

wait_virtio_rx:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    call    timer_ns
    lea     r13, [rax + NET_WAIT_NS]
.next:
    mov     rdi, rbx
    mov     rsi, r12
    call    virtio_rx_poll
    test    rax, rax
    jnz     .done
    test    edx, edx
    jnz     .done
    call    timer_ns
    cmp     rax, r13
    jb      .next
    lea     rax, [rel rx_timeout]
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; rdi = complete Ethernet header and payload, rsi = length without FCS.
; Return error string or zero with the padded byte count in edx.
net_frame_send:
    push    rbx
    push    r12
    sub     rsp, 8
    call    net_tx_submit
    test    rax, rax
    jnz     .done
    mov     ebx, edx
    call    timer_ns
    lea     r12, [rax + NET_WAIT_NS]
.next:
    call    net_tx_complete
    lea     rcx, [rel tx_busy]
    cmp     rax, rcx
    jne     .complete
    call    timer_ns
    cmp     rax, r12
    jb      .next
    lea     rax, [rel tx_timeout]
    jmp     .done
.complete:
    mov     edx, ebx
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

net_tx_complete:
    cmp     byte [rel backend], 2
    je      virtio_tx_complete
    mov     rcx, [rel tx_pending]
    xor     eax, eax
    test    rcx, rcx
    jz      .done
    mov     dl, [rcx + 12]
    test    dl, 1
    jz      .busy
    mov     qword [rel tx_pending], 0
    mfence
    test    dl, 0x0E
    jz      .done
    lea     rax, [rel tx_error]
.done:
    ret
.busy:
    lea     rax, [rel tx_busy]
    ret

net_tx_submit:
    push    rbx
    push    r12
    push    r13
    cmp     rsi, FRAME_HDR
    jb      .invalid
    cmp     rsi, FRAME_HDR + PAYLOAD_MAX
    ja      .invalid
    mov     r12, rdi
    mov     r13, rsi
    call    require_link
    test    rax, rax
    jnz     .done
    cmp     byte [rel backend], 2
    je      .virtio
    call    net_tx_complete
    cmp     qword [rel tx_pending], 0
    jne     .done
    mov     rsi, r12
    mov     r12, [rel dma_pages + 5 * 8]
    mov     rdi, r12
    mov     rcx, r13
    rep     movsb
    cmp     r13d, FRAME_MIN
    jae     .descriptor
    mov     ecx, FRAME_MIN
    sub     ecx, r13d
    xor     eax, eax
    rep     stosb
    mov     r13d, FRAME_MIN
.descriptor:
    mov     eax, [rel tx_next]
    mov     ebx, eax
    shl     ebx, 4
    add     rbx, [rel dma_pages]
    add     rbx, RING_BYTES
    mov     [rbx], r12
    mov     qword [rbx + 8], 0
    mov     [rbx + 8], r13w
    mov     byte [rbx + 11], 0x0B     ; EOP, IFCS, RS
    mov     [rel tx_pending], rbx
    inc     eax
    and     eax, DESC_COUNT - 1
    mov     [rel tx_next], eax
    mfence
    mov     rdx, [rel nic_mmio]
    mov     [rdx + REG_TDT], eax
    mov     edx, r13d
    xor     eax, eax
    jmp     .done
.virtio:
    mov     rdi, r12
    mov     rsi, r13
    call    virtio_tx_submit
    jmp     .done
.invalid:
    lea     rax, [rel invalid_tx_size]
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; Parse MAC, EtherType, then RAM filename tail. CF marks malformed syntax.
parse_send:
    sub     rsp, 8
    call    skip_spaces
    lea     r8, [rel destination]
    mov     r9d, 6
.octet:
    mov     ecx, 2
    call    parse_hex
    jc      .bad
    mov     [r8], al
    inc     r8
    dec     r9d
    jz      .type
    cmp     byte [rdi], ':'
    jne     .bad
    inc     rdi
    jmp     .octet
.type:
    cmp     byte [rdi], ' '
    jne     .bad
    call    skip_spaces
    mov     ecx, 4
    call    parse_hex
    jc      .bad
    cmp     eax, 0x600
    jb      .bad
    mov     [rel ether_type], ax
    cmp     byte [rdi], ' '
    jne     .bad
    call    skip_spaces
    cmp     byte [rdi], 0
    je      .bad
    clc
    jmp     .done
.bad:
    stc
.done:
    lea     rsp, [rsp + 8]
    ret

skip_spaces:
    cmp     byte [rdi], ' '
    jne     .done
    inc     rdi
    jmp     skip_spaces
.done:
    ret

parse_hex:
    xor     eax, eax
.next:
    movzx   edx, byte [rdi]
    sub     edx, '0'
    cmp     edx, 9
    jbe     .digit
    or      edx, 0x20
    sub     edx, 'a' - '0'
    cmp     edx, 5
    ja      .bad
    add     edx, 10
.digit:
    shl     eax, 4
    or      eax, edx
    inc     rdi
    loop    .next
    clc
    ret
.bad:
    stc
    ret

print_type:
    sub     rsp, 24
    mov     esi, 4
    mov     rdx, rsp
    call    format_hex_raw
    mov     byte [rsp + 4], 10
    mov     rdi, rsp
    mov     esi, 5
    call    console_write
    add     rsp, 24
    ret

print_mac:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     rbx, rdi
    mov     r12, rsp
    mov     r13d, 6
.octet:
    movzx   edi, byte [rbx]
    mov     esi, 2
    mov     rdx, r12
    call    format_hex_raw
    mov     byte [r12 + 2], ':'
    inc     rbx
    add     r12, 3
    dec     r13d
    jnz     .octet
    mov     rdi, rsp
    mov     esi, 17
    call    console_write
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

print_bdf:
    sub     rsp, 24
    mov     edi, [rel nic_bdf]
    shr     edi, 8
    mov     esi, 2
    mov     rdx, rsp
    call    format_hex_raw
    mov     byte [rsp + 2], ':'
    mov     edi, [rel nic_bdf]
    shr     edi, 3
    and     edi, 31
    lea     rdx, [rsp + 3]
    call    format_hex_raw
    mov     byte [rsp + 5], '.'
    mov     edi, [rel nic_bdf]
    and     edi, 7
    mov     esi, 1
    lea     rdx, [rsp + 6]
    call    format_hex_raw
    mov     rdi, rsp
    mov     esi, 7
    call    console_write
    add     rsp, 24
    ret

; Snapshot completed descriptors without returning ownership to the NIC.
net_rx_boundary:
    cmp     byte [rel backend], 2
    je      virtio_rx_boundary
    xor     eax, eax
    cmp     qword [rel nic_mmio], 0
    je      .done
    mov     rdx, [rel dma_pages]
    mov     ecx, [rel rx_next]
.next:
    mov     esi, ecx
    shl     esi, 4
    test    byte [rdx + rsi + 12], 1
    jz      .done
    inc     eax
    inc     ecx
    and     ecx, DESC_COUNT - 1
    cmp     eax, DESC_COUNT
    jb      .next
.done:
    ret

; edi = count from net_rx_boundary. No dispatch during this operation.
net_rx_recycle:
    cmp     byte [rel backend], 2
    je      virtio_rx_recycle
    test    edi, edi
    jz      .done
    mov     r8, [rel nic_mmio]
    test    r8, r8
    jz      .done
    mov     rdx, [rel dma_pages]
    mov     ecx, [rel rx_next]
.next:
    mov     eax, ecx
    shl     eax, 4
    mov     qword [rdx + rax + 8], 0
    mov     esi, ecx
    inc     ecx
    and     ecx, DESC_COUNT - 1
    dec     edi
    jnz     .next
    mov     [rel rx_next], ecx
    mfence
    mov     [r8 + REG_RDT], esi
.done:
    ret

section .rodata
raw_only:        db "Raw Ethernet commands require net off.", 10, 0
e1000_driver:    db "Driver: e1000", 10, 0
virtio_driver:   db "Driver: virtio-net", 10, 0
info_arg:        db "info", 0
recv_arg:        db "recv", 0
no_nic:          db "QEMU e1000 NIC unavailable.", 10, 0
unsupported_bar: db "e1000 BAR0 is outside supported uncached MMIO.", 10, 0
bad_mac:         db "e1000 has no valid station address.", 10, 0
no_dma_pages:    db "No free DMA pages for e1000.", 10, 0
reset_timeout:   db "e1000 reset timed out.", 10, 0
link_down_error: db "Ethernet link is down.", 10, 0
too_large:       db "Ethernet payload exceeds 1500 bytes.", 10, 0
pci_label:       db "PCI: ", 0
mac_label:       db 10, "MAC: ", 0
link_up:         db 10, "Link: up", 10, 0
link_down:       db 10, "Link: down", 10, 0
frame_label:     db "Frame: ", 0
dst_label:       db " bytes", 10, "Destination: ", 0
src_label:       db 10, "Source: ", 0
type_label:      db 10, "EtherType: ", 0
sent_label:      db "Sent ", 0
bytes_label:     db " bytes.", 10, 0
rx_timeout:      db "Ethernet receive timed out.", 10, 0
invalid_frame:   db "Invalid Ethernet receive descriptor.", 10, 0
tx_busy:         db "Previous transmit is still pending.", 10, 0
tx_timeout:      db "Ethernet transmit timed out.", 10, 0
rx_capacity:     db "Ethernet receive buffer is too small.", 10, 0
invalid_tx_size: db "Invalid Ethernet transmit length.", 10, 0
tx_error:        db "Ethernet transmit failed.", 10, 0

section .bss
alignb 8
nic_mmio:    resq 1
dma_pages:   resq PAGES
tx_pending:  resq 1
destination: resq 1
net_mac:
nic_mac:     resb 6
ether_type:  resw 1
nic_bdf:     resd 1
rx_next:     resd 1
tx_next:     resd 1
backend:     resb 1

console_frame: resb FRAME_HDR + PAYLOAD_MAX
