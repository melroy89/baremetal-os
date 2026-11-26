; Modern virtio-net PCI, one polled split queue pair.
bits 64
default rel
%include "os_constants.inc"

%define VIRTIO_VENDOR 0x1AF4
%define VIRTIO_NET_ID 0x1041
%define VIRTIO_NET_TRANSITIONAL 0x1000
%define PCI_CMD 4
%define PCI_BAR0 16
%define PCI_INTX_DISABLE (1 << 10)
%define PCI_MEM_MASTER 6

%define VQ_COUNT 8
%define VQ_MASK (VQ_COUNT - 1)
%define VQ_AVAIL (16 * VQ_COUNT)
%define VQ_USED  (VQ_AVAIL + 4 + 2 * VQ_COUNT + 4)
%define VQ_BUF 2048
%define VNET_HDR 12
%define ETH_MIN 14
%define ETH_PAD 60
%define ETH_MAX 1514
%define DMA_PAGES (2 + VQ_COUNT)
%define RESET_NS 100000000
%define VNET_MAC (1 << 5)
%define VNET_STATUS (1 << 16)

struc vpci
    .feature_select: resd 1
    .features: resd 1
    .driver_select: resd 1
    .driver_features: resd 1
    .msix: resw 1
    .num_queues: resw 1
    .status: resb 1
    .generation: resb 1
    .queue_select: resw 1
    .queue_size: resw 1
    .queue_msix: resw 1
    .queue_enable: resw 1
    .queue_notify: resw 1
    .desc: resq 1
    .avail: resq 1
    .used: resq 1
endstruc

extern pci_walk, pci_config_read32, pci_config_write16, pci_config_write32
extern page_alloc, page_free, timer_ns
extern net_mac, nic_bdf, tx_busy, invalid_frame, invalid_tx_size, link_down_error
%ifdef TEST_VIRTIO_TX
extern fixture_hold_tx
%endif

global virtio_init, virtio_shutdown, virtio_link
global virtio_rx_poll, virtio_rx_boundary, virtio_rx_recycle
global virtio_tx_submit, virtio_tx_complete

section .text
find_device:
    xor     eax, eax
    cmp     si, VIRTIO_VENDOR
    jne     .done
    shr     esi, 16
    cmp     si, VIRTIO_NET_ID
    je      .found
    cmp     si, VIRTIO_NET_TRANSITIONAL
    jne     .done
.found:
    mov     [rel nic_bdf], edi
    push    rdx
    call    init_device
    pop     rdx
    test    rax, rax
    jz      .ready
    mov     [rdx], rax
    xor     eax, eax
    ret
.ready:
    mov     eax, 1
.done:
    ret

; Return zero on success, one when absent, or the last candidate's error.
virtio_init:
    push    1
    lea     rdi, [rel find_device]
    mov     rsi, rsp
    mov     edx, 1
    call    pci_walk
    cmp     eax, 1
    pop     rax
    jne     .done
    xor     eax, eax
.done:
    ret

init_device:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     esi, PCI_CMD
    call    read_cfg
    test    eax, 1 << 20              ; PCI Status capabilities list.
    jz      .bad
    mov     [rel saved_command], ax
    and     eax, ~PCI_MEM_MASTER
    or      eax, PCI_INTX_DISABLE
    mov     edx, eax
    call    set_command
    lea     rdi, [rel regions]
    xor     eax, eax
    mov     ecx, 4
    rep     stosq
    mov     esi, 0x34
    call    read_cfg
    movzx   ebx, al
    mov     r12d, 48
.cap:
    test    ebx, ebx
    jz      .configure
    cmp     ebx, 0x40
    jb      .rollback
    test    ebx, 3
    jnz     .rollback
    dec     r12d
    js      .rollback
    mov     esi, ebx
    call    read_cfg
    mov     r13d, eax
    shr     r13d, 8
    and     r13d, 255
    cmp     al, 9
    jne     .next_cap
    mov     r14d, eax
    shr     r14d, 24
    cmp     r14d, 1
    jb      .next_cap
    cmp     r14d, 4
    ja      .next_cap
    mov     r15d, 16
    cmp     r14d, 2
    jne     .cap_size
    mov     r15d, 20
.cap_size:
    shr     eax, 16
    movzx   eax, al
    cmp     eax, r15d
    jb      .rollback
    add     eax, ebx
    cmp     eax, 256
    ja      .rollback
    lea     rax, [rel regions]
    cmp     qword [rax + r14 * 8 - 8], 0
    jne     .next_cap
    lea     esi, [rbx + 4]
    call    read_cfg
    movzx   edi, al
    call    read_bar
    test    rax, rax
    jz      .rollback
    ; The BAR base and exclusive window size must contain the whole region.
    mov     [rel bar_address], rax
    mov     [rel bar_length], rdx
    lea     esi, [rbx + 8]
    call    read_cfg
    mov     r15d, eax
    lea     esi, [rbx + 12]
    call    read_cfg
    test    eax, eax
    jz      .rollback
    lea     rdx, [rax + r15]
    cmp     rdx, [rel bar_length]
    ja      .rollback
    add     r15, [rel bar_address]
    cmp     r14d, 2
    je      .notify_alignment
    cmp     r14d, 1
    jne     .not_common
    cmp     eax, vpci_size
    jb      .rollback
    test    r15b, 3
    jnz     .rollback
    jmp     .not_common
.notify_alignment:
    test    r15b, 1
    jnz     .rollback
.not_common:
    cmp     r14d, 4
    jne     .not_device
    test    r15b, 3
    jnz     .rollback
    cmp     eax, 6
    jb      .rollback
    mov     [rel device_length], eax
.not_device:
    lea     rdx, [rel regions]
    mov     [rdx + r14 * 8 - 8], r15
    cmp     r14d, 2
    jne     .next_cap
    mov     [rel notify_length], eax
    lea     esi, [rbx + 16]
    call    read_cfg
    mov     [rel notify_multiplier], eax
.next_cap:
    mov     ebx, r13d
    jmp     .cap

.configure:
    mov     r12, [rel config]
    test    r12, r12
    jz      .rollback
    cmp     qword [rel notify_base], 0
    je      .rollback
    cmp     qword [rel isr_base], 0
    je      .rollback
    mov     r13, [rel device_config]
    test    r13, r13
    jz      .rollback
    movzx   edx, word [rel saved_command]
    and     edx, ~4
    or      edx, 2 | PCI_INTX_DISABLE
    call    set_command
    mov     rdi, r12
    call    reset_device
    test    eax, eax
    jnz     .rollback
    mov     byte [r12 + vpci.status], 3
    mov     dword [r12 + vpci.feature_select], 1
    test    dword [r12 + vpci.features], 1 ; VERSION_1
    jz      .failed
    mov     dword [r12 + vpci.feature_select], 0
    mov     eax, [r12 + vpci.features]
    test    eax, VNET_MAC
    jz      .failed
    and     eax, VNET_MAC | VNET_STATUS
    cmp     dword [rel device_length], 8
    jae     .status_feature
    and     eax, ~VNET_STATUS
.status_feature:
    mov     [rel features], eax
    mov     dword [r12 + vpci.driver_select], 0
    mov     [r12 + vpci.driver_features], eax
    mov     dword [r12 + vpci.driver_select], 1
    mov     dword [r12 + vpci.driver_features], 1
    mov     byte [r12 + vpci.status], 11
    test    byte [r12 + vpci.status], 8
    jz      .failed
    mov     ecx, 8
.mac:
    mov     dl, [r12 + vpci.generation]
    lea     rdi, [rel net_mac]
    xor     esi, esi
.mac_octet:
    mov     al, [r13 + rsi]
    mov     [rdi + rsi], al
    inc     esi
    cmp     esi, 6
    jb      .mac_octet
    cmp     dl, [r12 + vpci.generation]
    je      .mac_read
    loop    .mac
    jmp     .failed
.mac_read:
    mov     eax, [rel net_mac]
    test    al, 1
    jnz     .failed
    movzx   edx, word [rel net_mac + 4]
    or      eax, edx
    jz      .failed
    xor     ebx, ebx
    lea     r14, [rel dma_pages]
.allocate:
    call    page_alloc
    test    rax, rax
    jz      .failed
    mov     [r14 + rbx * 8], rax
    mov     rdi, rax
    xor     eax, eax
    mov     ecx, PAGE_SIZE / 8
    rep     stosq
    inc     ebx
    cmp     ebx, DMA_PAGES
    jb      .allocate

    xor     edi, edi
    call    configure_queue
    test    eax, eax
    jnz     .failed
    mov     edi, 1
    call    configure_queue
    test    eax, eax
    jnz     .failed
    ; All RX descriptors start device-owned, and all TX descriptors free.
    mov     rcx, [rel dma_pages]
    xor     edx, edx
.post:
    mov     [rcx + VQ_AVAIL + 4 + rdx * 2], dx
    inc     edx
    cmp     edx, VQ_COUNT
    jb      .post
    mov     byte [rel rx_owned], 0xFF
    mov     byte [rel tx_owned], 0
    mov     word [rel rx_used], 0
    mov     word [rel tx_used], 0
    mfence
    mov     word [rcx + VQ_AVAIL + 2], VQ_COUNT
    movzx   edx, word [rel saved_command]
    or      edx, PCI_MEM_MASTER | PCI_INTX_DISABLE
    call    set_command
    mfence
    mov     byte [r12 + vpci.status], 15 ; DRIVER_OK.
    mov     rdx, [rel rx_notify]
    mov     word [rdx], 0
    mov     byte [rel active], 1
    xor     eax, eax
    jmp     .done
.failed:
    mov     byte [r12 + vpci.status], 0x80
    mov     rdi, r12
    call    reset_device
.rollback:
    movzx   edx, word [rel saved_command]
    and     edx, ~4
    call    set_command
    call    free_pages
.bad:
    lea     rax, [rel init_error]
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; edi = queue number, r12 = vpci configuration. Zero on success.
configure_queue:
    mov     [r12 + vpci.queue_select], di
    cmp     word [r12 + vpci.queue_size], VQ_COUNT
    jb      .bad
    mov     word [r12 + vpci.queue_size], VQ_COUNT
    mov     word [r12 + vpci.queue_msix], -1
    movzx   eax, word [r12 + vpci.queue_notify]
    mov     edx, [rel notify_multiplier]
    imul    rax, rdx
    lea     rdx, [rax + 2]
    mov     ecx, [rel notify_length]
    cmp     rdx, rcx
    ja      .bad
    add     rax, [rel notify_base]
    test    al, 1
    jnz     .bad
    lea     rdx, [rel rx_notify]
    mov     [rdx + rdi * 8], rax
    lea     rdx, [rel dma_pages]
    mov     r8, [rdx + rdi * 8]
    mov     [r12 + vpci.desc], r8d
    mov     dword [r12 + vpci.desc + 4], 0
    lea     eax, [r8 + VQ_AVAIL]
    mov     [r12 + vpci.avail], eax
    mov     dword [r12 + vpci.avail + 4], 0
    lea     eax, [r8 + VQ_USED]
    mov     [r12 + vpci.used], eax
    mov     dword [r12 + vpci.used + 4], 0
    mov     word [r8 + VQ_AVAIL], 1 ; Polling. Suppress used notifications.
    shl     edi, 2
    lea     rdx, [rdx + rdi * 8 + 16]
    xor     ecx, ecx
.descriptor:
    mov     eax, ecx
    shr     eax, 1
    mov     rax, [rdx + rax * 8]
    test    cl, 1
    jz      .address
    add     rax, VQ_BUF
.address:
    mov     [r8], rax
    test    edi, edi
    jnz     .advance
    mov     dword [r8 + 8], VQ_BUF
    mov     word [r8 + 12], 2          ; Device writes RX.
    mov     word [rax + 10], 1         ; Older QEMU leaves this field untouched.
.advance:
    add     r8, 16
    inc     ecx
    cmp     ecx, VQ_COUNT
    jb      .descriptor
    mov     word [r12 + vpci.queue_enable], 1
    xor     eax, eax
    ret
.bad:
    mov     eax, 1
    ret

; Size a memory BAR with PCI decoding off. Return address and size.
read_bar:
    cmp     edi, 5
    ja      .invalid
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    lea     ebx, [PCI_BAR0 + rdi * 4]
    mov     esi, ebx
    call    read_cfg
    mov     r12d, eax
    test    al, 1
    jnz     .bad
    and     eax, 6
    xor     r13d, r13d
    test    eax, eax
    jz      .probe
    cmp     eax, 4
    jne     .bad
    cmp     ebx, PCI_BAR0 + 20
    je      .bad
    lea     esi, [rbx + 4]
    call    read_cfg
    test    eax, eax                  ; Current kernel maps only below 4 GiB.
    jnz     .bad
    mov     r13d, 1
.probe:
    mov     esi, ebx
    mov     edx, -1
    call    write_cfg
    test    r13d, r13d
    jz      .read_mask
    lea     esi, [rbx + 4]
    mov     edx, -1
    call    write_cfg
.read_mask:
    mov     esi, ebx
    call    read_cfg
    mov     r14d, eax
    mov     r15d, -1
    test    r13d, r13d
    jz      .restore
    lea     esi, [rbx + 4]
    call    read_cfg
    mov     r15d, eax
    lea     esi, [rbx + 4]
    xor     edx, edx
    call    write_cfg
.restore:
    mov     esi, ebx
    mov     edx, r12d
    call    write_cfg
    and     r14d, -16
    and     r12d, -16
    mov     eax, HIGH_MMIO_BASE
    cmp     r12, rax
    jb      .bad
    shl     r15, 32
    or      r14, r15
    neg     r14
    jz      .bad
    lea     rax, [r14 - 1]
    test    rax, r14
    jnz     .bad
    test    rax, r12
    jnz     .bad
    lea     rax, [r12 + r14 - 1]
    shr     rax, 32
    jnz     .bad
    mov     rax, r12
    mov     rdx, r14
    jmp     .done
.bad:
    xor     eax, eax
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.invalid:
    xor     eax, eax
    ret

read_cfg:
    mov     edi, [rel nic_bdf]
    jmp     pci_config_read32
write_cfg:
    mov     edi, [rel nic_bdf]
    jmp     pci_config_write32
set_command:
    mov     edi, [rel nic_bdf]
    mov     esi, PCI_CMD
    jmp     pci_config_write16

reset_device:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     byte [rbx + vpci.status], 0
    call    timer_ns
    lea     r12, [rax + RESET_NS]
.wait:
    cmp     byte [rbx + vpci.status], 0
    je      .ready
    call    timer_ns
    cmp     rax, r12
    jb      .wait
    mov     eax, 1
    jmp     .done
.ready:
    xor     eax, eax
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

free_pages:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rbx, [rel dma_pages]
    mov     r12d, DMA_PAGES
.next:
    mov     rdi, [rbx]
    test    rdi, rdi
    jz      .advance
    mov     qword [rbx], 0
    call    page_free
.advance:
    add     rbx, 8
    dec     r12d
    jnz     .next
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

virtio_shutdown:
    cmp     byte [rel active], 0
    je      .done
    sub     rsp, 8
    mov     byte [rel active], 0
    mov     rdi, [rel config]
    call    reset_device
    movzx   edx, word [rel saved_command]
    and     edx, ~4
    call    set_command
    call    free_pages
    add     rsp, 8
.done:
    ret

virtio_link:
    xor     eax, eax
    cmp     byte [rel active], 0
    je      .done
    inc     eax
    test    dword [rel features], VNET_STATUS
    jz      .done
    mov     rcx, [rel device_config]
    movzx   eax, word [rcx + 6]
    and     eax, 1
.done:
    ret

; Return the completed RX count, with the avail index left unchanged.
virtio_rx_boundary:
    xor     eax, eax
    cmp     byte [rel active], 0
    je      .done
    mov     rdx, [rel dma_pages]
    mov     ax, [rdx + VQ_USED + 2]
    sub     ax, [rel rx_used]
    cmp     eax, VQ_COUNT
    jbe     .done
    xor     eax, eax
.done:
    ret

; rdi = destination, rsi = capacity, or rdi = 0 to discard one completion.
; Carry set if the completion does not own a valid posted descriptor.
take_rx:
    push    rbx
    push    r12
    mov     r12, rsi
    mov     rbx, [rel dma_pages]
    movzx   eax, word [rel rx_used]
    and     eax, VQ_MASK
    mfence
    mov     r8d, [rbx + VQ_USED + 4 + rax * 8]
    cmp     r8d, VQ_COUNT
    jae     .bad_id
    movzx   eax, byte [rel rx_owned]
    bt      eax, r8d
    jnc     .bad_id
    btr     eax, r8d
    mov     [rel rx_owned], al
    movzx   eax, word [rel rx_used]
    and     eax, VQ_MASK
    mov     r9d, [rbx + VQ_USED + 8 + rax * 8]
    inc     word [rel rx_used]
    xor     edx, edx
    xor     eax, eax
    test    rdi, rdi
    jz      .done
    cmp     r9d, VNET_HDR + ETH_MIN
    jb      .invalid
    cmp     r9d, VNET_HDR + ETH_MAX
    ja      .invalid
    sub     r9d, VNET_HDR
    cmp     r9, r12
    ja      .invalid
    mov     ecx, r8d
    shl     ecx, 4
    mov     rsi, [rbx + rcx]
    cmp     word [rsi + 10], 1
    jne     .invalid
    cmp     word [rsi + VNET_HDR + 12], 0x0081
    je      .invalid
    cmp     word [rsi + VNET_HDR + 12], 0xA888
    je      .invalid
    add     rsi, VNET_HDR
    mov     ecx, r9d
    rep     movsb
    mov     edx, r9d
    jmp     .done
.invalid:
    lea     rax, [rel invalid_frame]
.done:
    pop     r12
    pop     rbx
    clc
    ret
.bad_id:
    pop     r12
    pop     rbx
    stc
    ret

; Stage descriptor r8d at the supplied avail index, without publishing.
stage_rx:
    mov     rcx, [rel dma_pages]
    and     eax, VQ_MASK
    mov     [rcx + VQ_AVAIL + 4 + rax * 2], r8w
    mov     r11d, r8d
    shl     r11d, 4
    mov     r11, [rcx + r11]
    mov     word [r11 + 10], 1
    movzx   eax, byte [rel rx_owned]
    bts     eax, r8d
    mov     [rel rx_owned], al
    ret

virtio_rx_poll:
    cmp     byte [rel active], 0
    jne     .poll
    lea     rax, [rel device_stopped]
    ret
.poll:
    push    rbx
    mov     rbx, [rel dma_pages]
    mov     ax, [rbx + VQ_USED + 2]
    sub     ax, [rel rx_used]
    jz      .empty
    cmp     ax, VQ_COUNT
    ja      .fault
    call    take_rx
    jc      .fault
    push    rax
    movzx   eax, word [rbx + VQ_AVAIL + 2]
    call    stage_rx
    mfence
    inc     word [rbx + VQ_AVAIL + 2]
    mfence
    mov     rcx, [rel rx_notify]
    mov     word [rcx], 0
    pop     rax
    pop     rbx
    ret
.empty:
    xor     eax, eax
    xor     edx, edx
    pop     rbx
    ret
.fault:
    pop     rbx
    jmp     queue_fault

virtio_rx_recycle:
    test    edi, edi
    jz      .idle
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12, [rel dma_pages]
    movzx   r13d, word [r12 + VQ_AVAIL + 2]
.discard:
    xor     edi, edi
    call    take_rx
    jc      .fault
    mov     eax, r13d
    call    stage_rx
    inc     r13w
    dec     ebx
    jnz     .discard
    mfence
    mov     [r12 + VQ_AVAIL + 2], r13w
    mfence
    mov     rcx, [rel rx_notify]
    mov     word [rcx], 0
    jmp     .done
.fault:
    call    queue_fault
.done:
    pop     r13
    pop     r12
    pop     rbx
.idle:
    ret

virtio_tx_complete:
    cmp     byte [rel active], 0
    je      .inactive
%ifdef TEST_VIRTIO_TX
    cmp     byte [rel fixture_hold_tx], 0
    jne     .busy
%endif
    mov     r8, [rel dma_pages + 8]
    movzx   edx, word [r8 + VQ_USED + 2]
    sub     dx, [rel tx_used]
    cmp     edx, VQ_COUNT
    ja      queue_fault
    mfence
    movzx   r9d, byte [rel tx_owned]
    movzx   ecx, word [rel tx_used]
.next:
    test    edx, edx
    jz      .done
    mov     eax, ecx
    and     eax, VQ_MASK
    mov     eax, [r8 + VQ_USED + 4 + rax * 8]
    cmp     eax, VQ_COUNT
    jae     queue_fault
    btr     r9d, eax
    jnc     queue_fault
    inc     cx
    dec     edx
    jmp     .next
.done:
    mov     [rel tx_used], cx
    mov     [rel tx_owned], r9b
    xor     eax, eax
    test    r9d, r9d
    jz      .return
.busy:
    lea     rax, [rel tx_busy]
.return:
    ret
.inactive:
    lea     rax, [rel device_stopped]
    ret

virtio_tx_submit:
    cmp     rsi, ETH_MIN
    jb      .invalid
    cmp     rsi, ETH_MAX
    ja      .invalid
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13d, esi
    call    virtio_link
    test    eax, eax
    jz      .link_down
    call    virtio_tx_complete
    cmp     byte [rel active], 0
    je      .done
    movzx   eax, byte [rel tx_owned]
    xor     al, 0xFF
    jz      .busy
    bsf     edx, eax
    mov     ebx, edx
    mov     r8, [rel dma_pages + 8]
    mov     ecx, edx
    shl     ecx, 4
    lea     r9, [r8 + rcx]
    mov     rdi, [r9]
    xor     eax, eax
    stosq
    stosd
    mov     rsi, r12
    mov     ecx, r13d
    rep     movsb
    cmp     r13d, ETH_PAD
    jae     .post
    mov     ecx, ETH_PAD
    sub     ecx, r13d
    rep     stosb
    mov     r13d, ETH_PAD
.post:
    lea     eax, [r13 + VNET_HDR]
    mov     [r9 + 8], eax
    movzx   eax, byte [rel tx_owned]
    bts     eax, ebx
    mov     [rel tx_owned], al
    movzx   eax, word [r8 + VQ_AVAIL + 2]
    and     eax, VQ_MASK
    mov     [r8 + VQ_AVAIL + 4 + rax * 2], bx
    mfence
    inc     word [r8 + VQ_AVAIL + 2]
    mfence
    mov     rcx, [rel tx_notify]
    mov     word [rcx], 1
    mov     edx, r13d
    xor     eax, eax
    jmp     .done
.busy:
    lea     rax, [rel tx_busy]
    jmp     .done
.link_down:
    lea     rax, [rel link_down_error]
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret
.invalid:
    lea     rax, [rel invalid_tx_size]
    ret

queue_fault:
    sub     rsp, 8
    call    virtio_shutdown
    lea     rax, [rel invalid_frame]
    add     rsp, 8
    ret

section .rodata
init_error: db "Virtio-net PCI initialization failed.", 10, 0
device_stopped: db "Virtio-net is stopped.", 10, 0

section .bss
alignb 8
regions:
config: resq 1
notify_base: resq 1
isr_base: resq 1
device_config: resq 1
rx_notify: resq 1
tx_notify: resq 1
dma_pages: resq DMA_PAGES
bar_address: resq 1
bar_length: resq 1
notify_length: resd 1
notify_multiplier: resd 1
device_length: resd 1
features: resd 1
saved_command: resw 1
rx_used: resw 1
tx_used: resw 1
rx_owned: resb 1
tx_owned: resb 1
active: resb 1
