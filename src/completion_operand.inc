; Match the command at the start of the draft. Return the active operand
; bounds in rdi/rsi and its completion mode in r15d. CF means inapplicable.
completion_operand:
    mov     byte [rel completion_ext_only], 0
    mov     byte [rel completion_quote], 0
    lea     r10, [r12 + r13]
    mov     rdi, r12
    call    completion_skip_spaces
    cmp     byte [rdi], '/'
    jne     .command
    ; A bare slash is the optional command prefix at the prompt.
    inc     rdi
.command:
    call    completion_plain_word
    xor     r15d, r15d
    cmp     r10, rsi
    jbe     .selected
    mov     r9, rdi
    mov     r8, rsi
    sub     r8, rdi
    lea     r11, [rel commands]
.find:
    mov     rsi, [r11]
    test    rsi, rsi
    jz      .none
    mov     rdi, r9
    mov     rcx, r8
    repe    cmpsb
    jne     .next
    cmp     byte [rsi], 0
    je      .handler
.next:
    add     r11, 24
    jmp     .find
.handler:
    mov     r11, [r11 + 8]
    lea     rdi, [r9 + r8]
    call    completion_skip_spaces

%macro completion_handler 2
    lea     rax, [rel %1]
    cmp     r11, rax
    je      %2
%endmacro
    completion_handler command_cd, .directory
    completion_handler command_ls, .directory
    completion_handler command_cat, .path
    completion_handler command_rm, .path
    completion_handler command_touch, .path
    completion_handler command_mkdir, .directory
    completion_handler command_stat, .ext_path
    completion_handler command_readlink, .ext_path
    completion_handler command_cp, .two_words
    completion_handler command_mv, .two_words
    completion_handler command_ln, .link
    completion_handler command_truncate, .truncate
    completion_handler command_crc32, .ram
    completion_handler command_crc32range, .range
    completion_handler command_echo, .echo
    completion_handler command_mount, .partition
    completion_handler command_umount, .mounts
    completion_handler command_disk, .disk
    jmp     .none

.directory:
    mov     r15d, COMPLETE_DIRECTORY
    jmp     .raw
.ext_path:
    mov     byte [rel completion_ext_only], 1
.path:
    mov     r15d, COMPLETE_PATH
    jmp     .raw
.ram:
    mov     r15d, COMPLETE_RAM
    jmp     .raw
.mounts:
    mov     r15d, COMPLETE_MOUNTS
    jmp     .raw
.disk:
    call    completion_plain_word
    cmp     r10, rsi
    jbe     .none
    mov     rax, rsi
    sub     rax, rdi
    cmp     eax, 5
    jne     .repair
    cmp     dword [rdi], 'chec'
    jne     .none
    cmp     byte [rdi + 4], 'k'
    jne     .none
    jmp     .fat_mounts
.repair:
    cmp     eax, 6
    jne     .none
    cmp     dword [rdi], 'repa'
    jne     .none
    cmp     word [rdi + 4], 'ir'
    jne     .none
.fat_mounts:
    mov     rdi, rsi
    call    completion_skip_spaces
    mov     r15d, COMPLETE_FAT_MOUNTS
    jmp     .raw

.link:
    mov     byte [rel completion_ext_only], 1
    cmp     word [rdi], '-s'
    jne     .two_words
    cmp     byte [rdi + 2], ' '
    jne     .two_words
    mov     byte [rel completion_ext_only], 0
    add     rdi, 3
.two_words:
    mov     r15d, COMPLETE_WORD_PATH
    call    completion_word
    jc      .none
    cmp     r10, rsi
    jbe     .selected
    ; The second operand of ln must be on ext2, including with -s.
    lea     rax, [rel command_ln]
    cmp     r11, rax
    jne     .second_word
    mov     byte [rel completion_ext_only], 1
.second_word:
    mov     rdi, rsi
    call    completion_skip_spaces
    jmp     .one_word
.truncate:
    mov     byte [rel completion_ext_only], 1
.one_word:
    mov     r15d, COMPLETE_WORD_PATH
    call    completion_word
    jc      .none
    jmp     .selected

.range:
    call    completion_skip_number
    jc      .none
    call    completion_skip_number
    jc      .none
    jmp     .path
.echo:
    cmp     byte [rdi], '"'
    jne     .echo_text
.echo_quote:
    inc     rdi
    cmp     byte [rdi], 0
    je      .none
    cmp     byte [rdi], '"'
    jne     .echo_quote
    inc     rdi
    call    completion_skip_spaces
    cmp     byte [rdi], '>'
    jne     .none
    jmp     .redirect
.echo_text:
    mov     al, [rdi]
    test    al, al
    jz      .none
    cmp     al, '"'
    je      .none
    cmp     al, '>'
    je      .redirect
    inc     rdi
    jmp     .echo_text
.redirect:
    inc     rdi
    call    completion_skip_spaces
    mov     r15d, COMPLETE_REDIRECT
    jmp     .raw

.partition:
    xor     r9d, r9d
.option:
    call    completion_plain_word
    cmp     byte [rdi], '-'
    jne     .partition_name
    cmp     r10, rsi
    jbe     .none
    lea     rax, [rdi + 2]
    cmp     rsi, rax
    jne     .none
    cmp     word [rdi], '-o'
    je      .ro
    cmp     word [rdi], '-t'
    jne     .none
    bts     r9d, 0
    jc      .none
    call    completion_option_value
    jc      .none
    cmp     eax, 4
    jne     .fat32
    cmp     dword [rdi], 'ext2'
    jne     .none
    jmp     .next_option
.fat32:
    cmp     eax, 5
    jne     .none
    cmp     dword [rdi], 'fat3'
    jne     .none
    cmp     byte [rdi + 4], '2'
    jne     .none
    jmp     .next_option
.ro:
    bts     r9d, 1
    jc      .none
    call    completion_option_value
    jc      .none
    cmp     eax, 2
    jne     .none
    cmp     word [rdi], 'ro'
    jne     .none
.next_option:
    mov     rdi, rsi
    call    completion_skip_spaces
    jmp     .option
.partition_name:
    mov     r15d, COMPLETE_PARTITION
    jmp     .selected

.raw:
    lea     rsi, [r12 + rbx]
.selected:
    cmp     r10, rdi
    jb      .none
    cmp     r10, rsi
    ja      .none
    clc
    ret
.none:
    stc
    ret

completion_skip_spaces:
    cmp     byte [rdi], ' '
    jne     .done
    inc     rdi
    jmp     completion_skip_spaces
.done:
    ret

; Find a bare word's end without touching the draft.
completion_plain_word:
    mov     rsi, rdi
.next:
    mov     al, [rsi]
    test    al, al
    jz      .done
    cmp     al, ' '
    je      .done
    inc     rsi
    jmp     .next
.done:
    ret

; Accept an incomplete opening quote while editing, using copy_operand's
; escape rules. A closed quote must be followed by a space or NUL.
completion_word:
    mov     byte [rel completion_quote], 0
    cmp     byte [rdi], '"'
    jne     .plain
    mov     byte [rel completion_quote], 1
    lea     rsi, [rdi + 1]
.quote:
    mov     al, [rsi]
    test    al, al
    jz      .done
    cmp     al, '"'
    je      .close
    cmp     al, 0x5C
    jne     .advance
    cmp     byte [rsi + 1], '"'
    je      .escape
    cmp     byte [rsi + 1], 0x5C
    jne     .advance
.escape:
    inc     rsi
.advance:
    inc     rsi
    jmp     .quote
.close:
    mov     byte [rel completion_quote], 2
    inc     rsi
    cmp     byte [rsi], 0
    je      .done
    cmp     byte [rsi], ' '
    je      .done
    stc
    ret
.plain:
    call    completion_plain_word
.done:
    clc
    ret

completion_option_value:
    mov     rdi, rsi
    call    completion_skip_spaces
    call    completion_plain_word
    cmp     r10, rsi
    jbe     .bad
    mov     rax, rsi
    sub     rax, rdi
    clc
    ret
.bad:
    stc
    ret

completion_skip_number:
    mov     rsi, rdi
.next:
    movzx   eax, byte [rsi]
    sub     eax, '0'
    cmp     eax, 9
    ja      .end
    inc     rsi
    jmp     .next
.end:
    cmp     rsi, rdi
    je      .bad
    cmp     byte [rsi], ' '
    jne     .bad
    mov     rdi, rsi
    call    completion_skip_spaces
    clc
    ret
.bad:
    stc
    ret

; Decode the operand prefix to a separate buffer without modifying the draft.
; Return its decoded length in ecx.
completion_decode:
    xor     ecx, ecx
    lea     rdx, [rel completion_token]
    cmp     byte [rel completion_quote], 0
    je      .copy
    inc     rdi
.copy:
    cmp     rdi, rsi
    jae     .done
    mov     al, [rdi]
    inc     rdi
    cmp     byte [rel completion_quote], 0
    je      .store
    cmp     al, '"'
    je      .done
    cmp     al, 0x5C
    jne     .store
    cmp     rdi, rsi
    jae     .store
    cmp     byte [rdi], '"'
    je      .escape
    cmp     byte [rdi], 0x5C
    jne     .store
.escape:
    mov     al, [rdi]
    inc     rdi
.store:
    mov     [rdx + rcx], al
    inc     ecx
    jmp     .copy
.done:
    mov     byte [rdx + rcx], 0
    ret
