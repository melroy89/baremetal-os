; PIIX3 primary-master ATA programmed I/O.
bits 64
default rel

%include "os_constants.inc"

%define PIIX3_ID         0x70108086
%define PCI_COMMAND      4
%define PCI_CLASS        8
%define PCI_IO_ENABLE    1
%define IDE_PRIMARY_NATIVE (1 << 8)

%define ATA_DATA         0x1F0
%define ATA_COUNT        0x1F2
%define ATA_DEVICE       0x1F6
%define ATA_COMMAND      0x1F7
%define ATA_CONTROL      0x3F6
%define ATA_NIEN         2
%define ATA_MASTER       0xA0
%define ATA_MASTER_LBA   0xE0
%define ATA_IDENTIFY     0xEC
%define ATA_READ         0x20
%define ATA_READ_EXT     0x24
%define ATA_WRITE        0x30
%define ATA_WRITE_EXT    0x34
%define ATA_FLUSH        0xE7
%define ATA_FLUSH_EXT    0xEA

%define ATA_ERR          (1 << 0)
%define ATA_DRQ          (1 << 3)
%define ATA_DF           (1 << 5)
%define ATA_BSY          (1 << 7)
%define ATA_TIMEOUT_NS   1000000000
%define ATA_LBA28_LIMIT  (1 << 28)

extern pci_walk
extern pci_config_read32
extern pci_config_write16
extern timer_ns
extern ip_checkpoint, ip_checkpoint_at

section .text
global ata_init
global ata_read
global ata_write
global ata_flush
global ata_count
global ata_model

global ata_writable

ata_writable:
    xor     eax, eax
    cmp     byte [rel flush_cmd], 0
    setne   al
    ret

; Return zero on success or a console error string in rax.
ata_init:
    cmp     qword [rel ata_count], 0
    jne     .ready
    push    rbx
    lea     rdi, [rel find_ide]
    xor     esi, esi
    xor     edx, edx
    call    pci_walk
    cmp     eax, 1
    jne     .no_controller

    mov     ebx, [rel ide_bdf]
    mov     edi, ebx
    mov     esi, PCI_CLASS
    call    pci_config_read32
    test    eax, IDE_PRIMARY_NATIVE
    jnz     .unsupported
    mov     edi, ebx
    mov     esi, PCI_COMMAND
    call    pci_config_read32
    test    eax, PCI_IO_ENABLE
    jnz     .identify
    movzx   edx, ax
    or      edx, PCI_IO_ENABLE
    mov     edi, ebx
    mov     esi, PCI_COMMAND
    call    pci_config_write16

.identify:
    mov     dx, ATA_CONTROL
    mov     al, ATA_NIEN
    out     dx, al
    mov     dx, ATA_DEVICE
    mov     al, ATA_MASTER
    out     dx, al
    call    ata_delay

    xor     edi, edi
    xor     esi, esi                   ; Ignore an earlier command's error.
    call    ata_wait
    test    rax, rax
    jnz     .done
    mov     dx, ATA_COUNT
    xor     eax, eax
    out     dx, al
    inc     dx
    out     dx, al
    inc     dx
    out     dx, al
    inc     dx
    out     dx, al
    mov     dx, ATA_COMMAND
    mov     al, ATA_IDENTIFY
    out     dx, al

    lea     rdi, [rel identify_data]
    call    ata_read_data
    test    rax, rax
    jnz     .done

    lea     rbx, [rel identify_data]
    test    word [rbx + 49 * 2], 1 << 9
    jz      .unsupported
    movzx   ecx, word [rbx + 106 * 2]
    and     ecx, 0xD000
    cmp     ecx, 0x5000                ; Valid long logical sector field.
    je      .unsupported

    mov     eax, [rbx + 60 * 2]
    cmp     eax, ATA_LBA28_LIMIT
    ja      .unsupported
    movzx   ecx, word [rbx + 83 * 2]
    and     ecx, 0xC400
    cmp     ecx, 0x4400
    jne     .capacity
    mov     rax, [rbx + 100 * 2]
    mov     rcx, 1 << 48
    cmp     rax, rcx
    ja      .unsupported
    mov     byte [rel ata_lba48], 1
.capacity:
    test    rax, rax
    jz      .unsupported
    mov     [rel ata_count], rax
    movzx   ecx, word [rbx + 83 * 2]
    and     ecx, 0xC000
    cmp     ecx, 0x4000
    jne     .model
    test    word [rbx + 83 * 2], 1 << 13
    jz      .check_flush
    mov     byte [rel flush_cmd], ATA_FLUSH_EXT
    jmp     .model
.check_flush:
    test    word [rbx + 83 * 2], 1 << 12
    jz      .model
    mov     byte [rel flush_cmd], ATA_FLUSH
.model:

    lea     rsi, [rbx + 27 * 2]
    lea     rdi, [rel ata_model]
    mov     ecx, 20                    ; Model is 20 byte-swapped words.
.model_word:
    lodsw
    xchg    al, ah
    stosw
    loop    .model_word
    mov     byte [rdi], 0
.trim_model:
    lea     rax, [rel ata_model]
    cmp     rdi, rax
    je      .identified
    cmp     byte [rdi - 1], ' '
    jne     .identified
    dec     rdi
    mov     byte [rdi], 0
    jmp     .trim_model
.identified:
    xor     eax, eax
    jmp     .done
.no_controller:
    lea     rax, [rel no_ide]
    jmp     .done
.unsupported:
    lea     rax, [rel unsupported_ata]
.done:
    pop     rbx
    ret
.ready:
    xor     eax, eax
    ret

find_ide:
    xor     eax, eax
    cmp     esi, PIIX3_ID
    jne     .done
    mov     [rel ide_bdf], edi
    inc     eax
.done:
    ret

; rdi = LBA, rsi = destination for one logical block. Return zero or error.
ata_read:
    xor     edx, edx
    jmp     block_transfer

ata_write:
    cmp     byte [rel flush_cmd], 0
    je      flush_unsupported
    mov     edx, 1

; rdi = LBA, rsi = buffer, edx != 0 for writes.
block_transfer:
    cmp     rdi, [rel ata_count]
    jae     .range
    push    rbx
    push    r12
    push    r13
    push    r14
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12, rsi
    mov     r14d, edx
    call    ip_checkpoint
    mov     r13d, ATA_READ
    mov     al, ATA_MASTER_LBA
    cmp     byte [rel ata_lba48], 0
    jne     .extended
    mov     rax, rbx
    shr     eax, 24
    or      al, ATA_MASTER_LBA
    jmp     .select
.extended:
    mov     r13d, ATA_READ_EXT
.select:
    mov     dx, ATA_DEVICE
    out     dx, al
    call    ata_delay
    xor     edi, edi
    xor     esi, esi
    call    ata_wait
    test    rax, rax
    jnz     .done
    cmp     byte [rel ata_lba48], 0
    je      .low
    mov     dx, ATA_COUNT
    xor     eax, eax
    out     dx, al
    inc     dx
    mov     rax, rbx
    shr     rax, 24
    out     dx, al
    inc     dx
    shr     eax, 8
    out     dx, al
    inc     dx
    shr     eax, 8
    out     dx, al
.low:
    mov     dx, ATA_COUNT
    mov     al, 1
    out     dx, al
    inc     dx
    mov     eax, ebx
    out     dx, al
    inc     dx
    shr     eax, 8
    out     dx, al
    inc     dx
    shr     eax, 8
    out     dx, al
    mov     dx, ATA_COMMAND
    mov     eax, r13d
    test    r14d, r14d
    jz      .issue
    add     eax, ATA_WRITE - ATA_READ
.issue:
    out     dx, al
    mov     rdi, r12
    test    r14d, r14d
    jnz     .write_data
    call    ata_read_data
    jmp     .done
.write_data:
    call    ata_write_data
.done:
    add     rsp, 8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.range:
    lea     rax, [rel out_of_range]
    ret

ata_flush:
    cmp     byte [rel flush_cmd], 0
    je      flush_unsupported
    sub     rsp, 8
    call    ip_checkpoint
    xor     edi, edi
    xor     esi, esi
    call    ata_wait
    test    rax, rax
    jnz     .done
    mov     dx, ATA_COMMAND
    mov     al, [rel flush_cmd]
    out     dx, al
    call    ata_delay
    xor     edi, edi
    mov     esi, 1
    call    ata_wait
.done:
    add     rsp, 8
    ret

flush_unsupported:
    lea     rax, [rel no_flush]
    ret

ata_read_data:
    xor     esi, esi
    jmp     ata_data_phase

ata_write_data:
    mov     esi, 1

ata_data_phase:
    push    rbx
    push    r12
    sub     rsp, 8
    mov     rbx, rdi
    mov     r12d, esi
    call    ata_delay
    mov     edi, ATA_DRQ
    mov     esi, 1
    call    ata_wait
    test    rax, rax
    jnz     .done
    mov     rdi, rbx
    mov     dx, ATA_DATA
    mov     ecx, BLOCK_SIZE / 2
    test    r12d, r12d
    jnz     .write
    rep     insw
    jmp     .complete
.write:
    mov     rsi, rbx
    rep     outsw
.complete:
    call    ata_delay
    xor     edi, edi
    mov     esi, 1
    call    ata_wait
.done:
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

; Allow the ATA status register to settle after select or command/data phase.
ata_delay:
    mov     dx, ATA_CONTROL
    in      al, dx
    in      al, dx
    in      al, dx
    in      al, dx
    ret

; edi = desired DRQ bit, esi != 0 checks device errors. BSY must be clear.
ata_wait:
    push    rbx
    push    r12
    push    r13
    mov     r12d, edi
    mov     r13d, esi
    call    timer_ns
    lea     rbx, [rax + ATA_TIMEOUT_NS]
.poll:
    mov     dx, ATA_CONTROL
    in      al, dx
    cmp     al, 0xFF
    je      .absent
    test    al, al
    jz      .absent
    test    al, ATA_BSY
    jnz     .wait
    test    r13d, r13d
    jz      .check_drq
    test    al, ATA_ERR | ATA_DF
    jnz     .error
.check_drq:
    and     eax, ATA_DRQ
    cmp     eax, r12d
    je      .ready
.wait:
    call    timer_ns
    cmp     rax, rbx
    jae     .timeout
    call    ip_checkpoint_at
    pause
    jmp     .poll
.ready:
    xor     eax, eax
    jmp     .done
.absent:
    lea     rax, [rel no_disk]
    jmp     .done
.error:
    lea     rax, [rel device_error]
    jmp     .done
.timeout:
    lea     rax, [rel ata_timeout]
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

section .rodata
no_ide:          db "PIIX3 IDE controller unavailable.", 10, 0
no_disk:         db "No primary ATA disk.", 10, 0
unsupported_ata: db "Unsupported ATA mode or geometry.", 10, 0
device_error:    db "ATA device error.", 10, 0
ata_timeout:     db "ATA device timed out.", 10, 0
out_of_range:    db "Disk LBA out of range.", 10, 0
no_flush:        db "ATA disk lacks cache flush support.", 10, 0

section .bss
alignb 8
ata_count:   resq 1
ide_bdf:       resd 1
ata_lba48:     resb 1
flush_cmd:     resb 1
ata_model:   resb 41
alignb 2
identify_data: resb BLOCK_SIZE
