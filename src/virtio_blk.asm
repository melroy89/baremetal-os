; One modern PCI virtio block device. Requests use a private 4 KiB DMA buffer.
bits 64
default rel
%include "os_constants.inc"
%include "virtio_pci.inc"

%define VBLK_ID 0x10421af4
%define FEATURE_RO (1 << 5)
%define FEATURE_BLOCK_SIZE (1 << 6)
%define FEATURE_FLUSH (1 << 9)
%define Q_SIZE 8
%define Q_MASK (Q_SIZE - 1)
%define Q_AVAIL (16 * Q_SIZE)
%define Q_USED (Q_AVAIL + 8 + 2 * Q_SIZE)
%define IO_TIMEOUT_NS 1000000000
%define DMA_STATUS 16

extern pci_walk, pci_config_read32, pci_config_write16, pci_memory_bar
extern virtio_reset, timer_ns, ip_checkpoint_at, page_alloc, page_free
global virtio_blk_init, virtio_blk_transfer, virtio_blk_count, virtio_blk_writable
global virtio_blk_shutdown

section .text
virtio_blk_init:
    xor     eax, eax
    cmp     byte [rel online], 0
    jne     .done
    cmp     byte [rel disabled], 0
    jne     .failed
    sub     rsp, 8
    lea     rdi, [rel try_device]
    xor     esi, esi
    mov     edx, 1
    call    pci_walk
    add     rsp, 8
    cmp     eax, 1
    jne     .failed
    xor     eax, eax
.done:
    ret
.failed:
    lea     rax, [rel no_device]
    ret

try_device:
    xor     eax, eax
    cmp     esi, VBLK_ID
    jne     .done
    cmp     byte [rel disabled], 0
    jne     .done
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     [rel bdf], edi
    mov     esi, 4
    call    cfg
    test    eax, 1 << 20
    jz      .reject
    mov     [rel pci_cmd], ax
    movzx   edx, ax
    and     edx, ~6
    or      edx, 1 << 10
    call    set_cmd
    lea     rdi, [rel common_cfg]
    xor     eax, eax
    mov     ecx, 3
    rep     stosq
    mov     esi, 0x34
    call    cfg
    movzx   ebx, al
    mov     r12d, 48
.cap:
    test    ebx, ebx
    jz      .setup
    cmp     ebx, 0x40
    jb      .rollback
    test    ebx, 3
    jnz     .rollback
    dec     r12d
    js      .rollback
    mov     esi, ebx
    call    cfg
    mov     r13d, eax
    shr     r13d, 8
    and     r13d, 255
    cmp     al, 9
    jne     .next
    mov     r14d, eax
    shr     r14d, 24
    cmp     r14d, 1
    je      .region
    cmp     r14d, 2
    je      .region
    cmp     r14d, 4
    jne     .next
.region:
    mov     r15d, 16
    cmp     r14d, 2
    jne     .length
    mov     r15d, 20
.length:
    shr     eax, 16
    movzx   eax, al
    cmp     eax, r15d
    jb      .rollback
    add     eax, ebx
    cmp     eax, 256
    ja      .rollback
    lea     esi, [rbx + 4]
    call    cfg
    movzx   esi, al
    mov     edi, [rel bdf]
    call    pci_memory_bar
    test    rax, rax
    jz      .rollback
    push    rax
    push    rdx
    lea     esi, [rbx + 8]
    call    cfg
    mov     r15d, eax
    lea     esi, [rbx + 12]
    call    cfg
    pop     rdx
    pop     rcx
    add     rcx, r15
    add     r15, rax
    cmp     r15, rdx
    ja      .rollback
    cmp     r14d, 2
    je      .notify
    test    cl, 3
    jnz     .rollback
    cmp     r14d, 1
    jne     .device
    cmp     eax, vpci_size
    jb      .rollback
    mov     [rel common_cfg], rcx
    jmp     .next
.device:
    cmp     eax, 8
    jb      .rollback
    mov     [rel device], rcx
    mov     [rel device_size], eax
    jmp     .next
.notify:
    test    cl, 1
    jnz     .rollback
    cmp     eax, 2
    jb      .rollback
    mov     [rel notify], rcx
    mov     [rel notify_size], eax
    lea     esi, [rbx + 16]
    call    cfg
    mov     [rel notify_mul], eax
.next:
    mov     ebx, r13d
    jmp     .cap
.setup:
    mov     r12, [rel common_cfg]
    mov     r13, [rel device]
    test    r12, r12
    jz      .rollback
    test    r13, r13
    jz      .rollback
    cmp     qword [rel notify], 0
    je      .rollback
    movzx   edx, word [rel pci_cmd]
    or      edx, 2 | (1 << 10)
    and     edx, ~4
    call    set_cmd
    mov     rdi, r12
    call    virtio_reset
    test    eax, eax
    jnz     .rollback
    mov     byte [r12 + vpci.status], 3
    mov     dword [r12 + vpci.feature_select], 1
    test    dword [r12 + vpci.features], 1
    jz      .reset
    mov     dword [r12 + vpci.driver_select], 1
    mov     dword [r12 + vpci.driver_features], 1
    mov     dword [r12 + vpci.feature_select], 0
    mov     eax, [r12 + vpci.features]
    and     eax, FEATURE_RO | FEATURE_BLOCK_SIZE | FEATURE_FLUSH
    mov     [rel features], eax
    mov     dword [r12 + vpci.driver_select], 0
    mov     [r12 + vpci.driver_features], eax
    mov     byte [r12 + vpci.status], 11
    test    byte [r12 + vpci.status], 8
    jz      .reset
    mov     ecx, 8
.geometry:
    mov     r8b, [r12 + vpci.generation]
    mov     eax, [r13]
    mov     edx, [r13 + 4]
    mov     esi, BLOCK_SIZE
    test    dword [rel features], FEATURE_BLOCK_SIZE
    jz      .stable
    cmp     dword [rel device_size], 24
    jb      .reset
    mov     esi, [r13 + 20]
.stable:
    cmp     r8b, [r12 + vpci.generation]
    je      .capacity
    loop    .geometry
    jmp     .reset
.capacity:
    cmp     esi, BLOCK_SIZE
    jne     .reset
    shl     rdx, 32
    or      rax, rdx
    jz      .reset
    mov     [rel virtio_blk_count], rax
    mov     word [r12 + vpci.queue_select], 0
    cmp     word [r12 + vpci.queue_size], Q_SIZE
    jb      .reset
    mov     word [r12 + vpci.queue_size], Q_SIZE
    mov     word [r12 + vpci.queue_msix], -1
    movzx   eax, word [r12 + vpci.queue_notify]
    mov     edx, [rel notify_mul]
    imul    rax, rdx
    lea     rdx, [rax + 2]
    mov     ecx, [rel notify_size]
    cmp     rdx, rcx
    ja      .reset
    add     rax, [rel notify]
    test    al, 1
    jnz     .reset
    mov     [rel queue_notify], rax
    xor     ebx, ebx
    lea     r14, [rel pages]
.allocate:
    call    page_alloc
    test    rax, rax
    jz      .reset
    mov     [r14 + rbx * 8], rax
    mov     rdi, rax
    xor     eax, eax
    mov     ecx, PAGE_SIZE / 8
    rep     stosq
    inc     ebx
    cmp     ebx, 3
    jb      .allocate
    mov     rax, [rel queue]
    mov     [r12 + vpci.desc], eax
    mov     dword [r12 + vpci.desc + 4], 0
    mov     word [rax + Q_AVAIL], 1
    lea     edx, [rax + Q_AVAIL]
    mov     [r12 + vpci.avail], edx
    mov     dword [r12 + vpci.avail + 4], 0
    lea     edx, [rax + Q_USED]
    mov     [r12 + vpci.used], edx
    mov     dword [r12 + vpci.used + 4], 0
    mov     word [rel seen_used], 0
    mov     word [r12 + vpci.queue_enable], 1
    movzx   edx, word [rel pci_cmd]
    or      edx, 6 | (1 << 10)
    call    set_cmd
    mfence
    mov     byte [r12 + vpci.status], 15
    mov     byte [rel online], 1
    mov     eax, 1
    jmp     .restore
.reset:
    mov     rdi, r12
    call    virtio_reset
    ; Bus mastering has not been enabled on this initialization path.
    call    release_pages
.rollback:
    movzx   edx, word [rel pci_cmd]
    and     edx, ~4
    call    set_cmd
.reject:
    mov     qword [rel virtio_blk_count], 0
    xor     eax, eax
.restore:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.done:
    ret

cfg:
    mov     edi, [rel bdf]
    jmp     pci_config_read32
set_cmd:
    mov     edi, [rel bdf]
    mov     esi, 4
    jmp     pci_config_write16

virtio_blk_writable:
    xor     eax, eax
    cmp     byte [rel online], 0
    je      .done
    mov     eax, [rel features]
    and     eax, FEATURE_RO | FEATURE_FLUSH
    cmp     eax, FEATURE_FLUSH
    sete    al
    movzx   eax, al
.done:
    ret

; rdi = starting LBA, rsi = buffer, edx = operation, ecx = sectors.
; Flush uses neither a caller buffer nor a sector number.
virtio_blk_transfer:
    cmp     byte [rel online], 0
    je      offline
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rsi
    mov     r13d, edx
    xor     r14d, r14d
    mov     rbx, [rel queue]
    mov     r15, [rel header]
    test    edx, edx
    jz      .bounds
    call    virtio_blk_writable
    test    eax, eax
    jz      .readonly
    cmp     r13d, 4
    jne     .bounds
    xor     edi, edi
    jmp     .request
.bounds:
    lea     eax, [rcx - 1]
    cmp     eax, PAGE_SIZE / BLOCK_SIZE
    jae     .range
    mov     rax, [rel virtio_blk_count]
    sub     rax, rdi
    jc      .range
    cmp     rax, rcx
    jb      .range
    mov     r14d, ecx
    shl     r14d, 9
.request:
    mov     [r15], r13d
    mov     dword [r15 + 4], 0
    mov     [r15 + 8], rdi
    mov     byte [r15 + DMA_STATUS], 0xff
    mov     [rbx], r15
    mov     dword [rbx + 8], 16
    mov     dword [rbx + 12], 0x10001
    lea     rax, [r15 + DMA_STATUS]
    mov     [rbx + 16], rax
    mov     dword [rbx + 24], 1
    mov     dword [rbx + 28], 2
    test    r14d, r14d
    jz      .submit
    mov     [rbx + 32], rax
    mov     dword [rbx + 40], 1
    mov     dword [rbx + 44], 2
    mov     rax, [rel data_page]
    mov     [rbx + 16], rax
    mov     [rbx + 24], r14d
    mov     dword [rbx + 28], 0x20003
    test    r13d, r13d
    jz      .submit
    mov     dword [rbx + 28], 0x20001
    mov     rdi, rax
    mov     rsi, r12
    mov     ecx, r14d
    rep     movsb
.submit:
    movzx   eax, word [rbx + Q_AVAIL + 2]
    and     eax, Q_MASK
    mov     word [rbx + Q_AVAIL + 4 + rax * 2], 0
    mfence
    inc     word [rbx + Q_AVAIL + 2]
    mfence
    mov     rax, [rel queue_notify]
    mov     word [rax], 0
    call    timer_ns
    lea     r15, [rax + IO_TIMEOUT_NS]
.wait:
    mov     ax, [rbx + Q_USED + 2]
    sub     ax, [rel seen_used]
    jnz     .complete
    call    timer_ns
    cmp     rax, r15
    jae     .lost
    call    ip_checkpoint_at
    pause
    jmp     .wait
.complete:
    cmp     ax, 1
    jne     .lost
    mfence
    movzx   eax, word [rel seen_used]
    and     eax, Q_MASK
    lea     rdx, [rbx + Q_USED + 4 + rax * 8]
    cmp     dword [rdx], 0
    jne     .lost
    inc     word [rel seen_used]
    mov     rax, [rel header]
    movzx   eax, byte [rax + DMA_STATUS]
    cmp     eax, 2
    ja      .lost
    test    eax, eax
    jnz     .io_error
    mov     eax, 1
    test    r13d, r13d
    cmovz   eax, r14d
    test    r13d, r13d
    jnz     .length_check
    inc     eax
.length_check:
    cmp     [rdx + 4], eax
    jne     .lost
    test    r13d, r13d
    jnz     .success
    mov     rdi, r12
    mov     rsi, [rel data_page]
    mov     ecx, r14d
    rep     movsb
.success:
    xor     eax, eax
    jmp     .done
.lost:
    call    virtio_blk_shutdown
    lea     rax, [rel lost_request]
    jmp     .done
.io_error:
    lea     rax, [rel io_error]
    jmp     .done
.range:
    lea     rax, [rel out_of_range]
    jmp     .done
.readonly:
    lea     rax, [rel dev_readonly]
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
offline:
    lea     rax, [rel no_device]
    ret

virtio_blk_shutdown:
    cmp     byte [rel online], 0
    je      .done
    push    rbx
    mov     byte [rel online], 0
    mov     byte [rel disabled], 1
    mov     rdi, [rel common_cfg]
    call    virtio_reset
    mov     ebx, eax
    movzx   edx, word [rel pci_cmd]
    and     edx, ~4
    call    set_cmd
    test    ebx, ebx
    jnz     .keep                   ; Retain buffers if reset did not settle.
    call    release_pages
.keep:
    pop     rbx
.done:
    ret

release_pages:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rbx, [rel pages]
    mov     r12d, 3
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

section .rodata
no_device: db "No usable modern virtio-blk disk at disk1.", 10, 0
out_of_range: db "LBA is outside the disk.", 10, 0
dev_readonly: db "Virtio disk is read-only or lacks flush support.", 10, 0
io_error: db "Virtio block request failed.", 10, 0
lost_request: db "Virtio block completion was lost or invalid. Disk stopped.", 10, 0

section .bss
alignb 8
common_cfg: resq 1
device: resq 1
notify: resq 1
queue_notify: resq 1
pages:
queue: resq 1
header: resq 1
data_page: resq 1
virtio_blk_count: resq 1
bdf: resd 1
features: resd 1
device_size: resd 1
notify_size: resd 1
notify_mul: resd 1
pci_cmd: resw 1
seen_used: resw 1
online: resb 1
disabled: resb 1
