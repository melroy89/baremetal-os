; Physical 4 KiB pages for the boot CPU. Page addresses are identity mapped.
bits 64
default rel

%include "os_constants.inc"

%define BITMAP_WORDS (HIGH_MMIO_BASE / PAGE_SIZE / 64)
%define LOW_MEMORY_END 0x100000

extern _kernel_start
extern _kernel_end
extern memory_map_walk

section .text
global page_init
global page_alloc
global page_free
global pages_managed
global pages_free

; rdi = Multiboot info. An absent or invalid map leaves the allocator empty.
page_init:
    push    rbx
    mov     rbx, rdi
    xor     eax, eax
    mov     [rel pages_managed], rax
    mov     [rel pages_free], rax
    mov     [rel next_word], eax
    lea     rdi, [rel managed_bitmap]
    mov     ecx, BITMAP_WORDS
    rep     stosq
    lea     rdi, [rel free_bitmap]
    mov     ecx, BITMAP_WORDS
    rep     stosq

    test    rbx, rbx
    jz      .done
    mov     rax, PHYS_MAP_END - MBI_SIZE
    cmp     rbx, rax
    ja      .done

    mov     rdi, rbx
    lea     rsi, [rel add_usable_entry]
    call    memory_map_walk
    cmp     eax, 1
    jne     .done

    ; Reserved ranges override usable ranges regardless of their order.
    mov     rdi, rbx
    lea     rsi, [rel remove_reserved_entry]
    call    memory_map_walk

    xor     edi, edi
    mov     esi, LOW_MEMORY_END         ; Includes VGA, BIOS data and the AP trampoline.
    call    reserve_range

    lea     rdi, [rel _kernel_start]
    lea     rsi, [rel _kernel_end]
    sub     rsi, rdi
    call    reserve_range

    mov     rdi, rbx
    mov     esi, MBI_SIZE
    call    reserve_range
    mov     edi, [rbx + MBI_MMAP_ADDR]
    mov     esi, [rbx + MBI_MMAP_LENGTH]
    call    reserve_range

    test    dword [rbx + MBI_FLAGS], 1 << 3
    jz      .finalize
    mov     edi, [rbx + MBI_MODS_ADDR]
    mov     esi, [rbx + MBI_MODS_COUNT]
    call    reserve_modules
    test    eax, eax
    jnz     .done

.finalize:
    lea     rsi, [rel free_bitmap]
    lea     rdi, [rel managed_bitmap]
    mov     ecx, BITMAP_WORDS
    xor     edx, edx
.next_word:
    lodsq
    stosq
.count_bits:
    test    rax, rax
    jz      .word_done
    lea     r8, [rax - 1]
    and     rax, r8
    inc     rdx
    jmp     .count_bits
.word_done:
    dec     ecx
    jnz     .next_word
    mov     [rel pages_managed], rdx
    mov     [rel pages_free], rdx
.done:
    pop     rbx
    ret

; rdi = module descriptors, esi = descriptor count.
reserve_modules:
    test    esi, esi
    jz      .empty
    test    rdi, rdi
    jz      .invalid
    imul    rsi, MB_MODULE_SIZE
    lea     rax, [rdi + rsi]
    mov     rdx, PHYS_MAP_END
    cmp     rax, rdx
    ja      .invalid

    push    r12
    push    r13
    sub     rsp, 8
    mov     r12, rdi
    mov     r13, rax
    call    reserve_range              ; Descriptor array itself
.next:
    mov     edi, [r12]
    mov     esi, [r12 + 4]
    sub     rsi, rdi
    jb      .bad_range
    call    reserve_range
    add     r12, MB_MODULE_SIZE
    cmp     r12, r13
    jb      .next
    xor     eax, eax
    jmp     .done
.bad_range:
    mov     eax, -1
.done:
    add     rsp, 8
    pop     r13
    pop     r12
    ret
.empty:
    xor     eax, eax
    ret
.invalid:
    mov     eax, -1
    ret

add_usable_entry:
    cmp     dword [rdi + 20], 1
    jne     .done
    mov     rsi, [rdi + 12]
    mov     rdi, [rdi + 4]
    test    rsi, rsi
    jz      .done
    mov     eax, HIGH_MMIO_BASE
    cmp     rdi, rax
    jae     .done
    sub     rax, rdi
    cmp     rsi, rax
    cmova   rsi, rax
    add     rsi, rdi
    add     rdi, PAGE_SIZE - 1
    shr     rdi, PAGE_SHIFT
    shr     rsi, PAGE_SHIFT            ; Add only whole usable pages.
    lea     rdx, [rel free_bitmap]
.next:
    cmp     rdi, rsi
    jae     .done
    bts     qword [rdx], rdi
    inc     rdi
    jmp     .next
.done:
    ret

remove_reserved_entry:
    cmp     dword [rdi + 20], 1
    je      .done
    mov     rsi, [rdi + 12]
    mov     rdi, [rdi + 4]
    jmp     reserve_range
.done:
    ret

; Remove every page touched by the physical range (rdi = base, rsi = length).
reserve_range:
    test    rsi, rsi
    jz      .done
    mov     eax, HIGH_MMIO_BASE
    cmp     rdi, rax
    jae     .done
    sub     rax, rdi
    cmp     rsi, rax
    cmova   rsi, rax
    add     rsi, rdi
    add     rsi, PAGE_SIZE - 1
    shr     rdi, PAGE_SHIFT
    shr     rsi, PAGE_SHIFT
    lea     rdx, [rel free_bitmap]
.next:
    cmp     rdi, rsi
    jae     .done
    btr     qword [rdx], rdi
    inc     rdi
    jmp     .next
.done:
    ret

; Return a physical address in rax, or zero on exhaustion.
page_alloc:
    xor     eax, eax
    cmp     qword [rel pages_free], 0
    je      .done

    lea     rdx, [rel free_bitmap]
    mov     eax, [rel next_word]
.scan:
    mov     rcx, [rdx + rax * 8]
    test    rcx, rcx
    jnz     .found
    inc     eax
    jmp     .scan
.found:
    mov     [rel next_word], eax
    bsf     rcx, rcx
    btr     qword [rdx + rax * 8], rcx
    dec     qword [rel pages_free]
    shl     rax, 6
    add     rax, rcx
    shl     rax, PAGE_SHIFT
.done:
    ret

; Free the physical address in rdi. Return eax = 0, or -1 if invalid.
page_free:
    test    rdi, PAGE_SIZE - 1
    jnz     .invalid
    mov     eax, HIGH_MMIO_BASE
    cmp     rdi, rax
    jae     .invalid
    shr     rdi, PAGE_SHIFT
    lea     rdx, [rel managed_bitmap]
    bt      qword [rdx], rdi
    jnc     .invalid
    lea     rdx, [rel free_bitmap]
    bts     qword [rdx], rdi
    jc      .invalid
    inc     qword [rel pages_free]
    shr     edi, 6
    cmp     edi, [rel next_word]
    jae     .done
    mov     [rel next_word], edi
.done:
    xor     eax, eax
    ret
.invalid:
    mov     eax, -1
    ret

section .bss
alignb 8
pages_managed:  resq 1
pages_free:     resq 1
next_word:      resd 1
alignb 8
managed_bitmap: resq BITMAP_WORDS
free_bitmap:    resq BITMAP_WORDS
