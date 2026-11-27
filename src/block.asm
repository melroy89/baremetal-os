; The boot CPU owns the disk selector and performs one block operation at a time.
bits 64
default rel

extern ata_init, ata_read, ata_write, ata_flush, ata_count, ata_model
extern virtio_blk_init, virtio_blk_transfer, virtio_blk_count, virtio_blk_writable
extern ata_writable
global block_selected, block_init, block_capacity, block_model, block_writable
global block_read, block_read_range, block_write, block_flush

section .text
block_init:
    cmp     dword [rel block_selected], -1
    je      block_default
    cmp     dword [rel block_selected], 0
    jne     virtio_blk_init
    jmp     ata_init

block_default:
    push    rbx
    mov     dword [rel block_selected], 0
    call    ata_init
    test    rax, rax
    jz      .done
    mov     rbx, rax
    mov     dword [rel block_selected], 1
    call    virtio_blk_init
    test    rax, rax
    jz      .done
    mov     dword [rel block_selected], 0
    mov     rax, rbx
.done:
    pop     rbx
    ret

block_capacity:
    mov     rax, [rel ata_count]
    cmp     dword [rel block_selected], 0
    cmovne  rax, [rel virtio_blk_count]
    ret

block_model:
    lea     rax, [rel ata_model]
    lea     rdx, [rel virtio_name]
    cmp     dword [rel block_selected], 0
    cmovne  rax, rdx
    ret

block_writable:
    cmp     dword [rel block_selected], 0
    jne     virtio_blk_writable
    jmp     ata_writable

block_read:
    cmp     dword [rel block_selected], 0
    je      ata_read
    mov     ecx, 1
block_read_range:
    xor     edx, edx
    jmp     virtio_blk_transfer
block_write:
    cmp     dword [rel block_selected], 0
    je      ata_write
    mov     edx, 1
    mov     ecx, 1
    jmp     virtio_blk_transfer
block_flush:
    cmp     dword [rel block_selected], 0
    je      ata_flush
    mov     edx, 4
    jmp     virtio_blk_transfer

section .rodata
virtio_name: db "virtio-blk", 0
section .bss
alignb 4
block_selected: resd 1
