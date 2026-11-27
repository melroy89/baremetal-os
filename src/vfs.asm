; Console paths and mount routing. Operations run serially on the boot CPU.
bits 64
default rel

%include "os_constants.inc"
%include "volume.inc"

%define RAM_MOUNT 1
%define PATH_DEPTH 32
%define PATH_REMOVE 3
%define PATH_NOFOLLOW 4
%define PATH_MOVE 5

struc location
    .volume: resq 1
    .cluster: resd 1
    .length: resd 1
endstruc

struc path_state
    .depth: resq 1
    .levels: resb (PATH_DEPTH + 1) * location_size
    .text: resb LINE_BUF_SIZE
endstruc

extern ramfs_ls, ramfs_cat, ramfs_write, ramfs_rm, ramfs_touch
extern fat_mount, fat_unmount, fat_list, fat_cat
extern fat_write, fat_rm, fat_touch, fat_find_dir, fat_check, fat_repair
extern fat_mkdir
extern fat_validate_root
extern ext_mount, ext_root, ext_find_dir, ext_list, ext_open, ext_read_at
extern ext_write, ext_copy_write, ext_copy_stream, ext_copy_sparse, ext_touch, ext_mkdir, ext_rm, ext_finish, fat_finish
extern console_write, parse_lba, crc32_update, write_hex32_raw
extern gpt_load, gpt_partition
extern block_selected, block_writable
extern console_write_cstr, console_putc, str_eq

section .text
global command_ls, command_cat, command_rm, command_touch, command_cd, command_pwd
global command_mkdir
global vfs_shutdown, vfs_dir_busy, path_not_directory
global vfs_write, command_mount, command_umount, vfs_mount_partition
global disk_check_volume, disk_repair_volume

command_pwd:
    lea     rdi, [rel current_path + path_state.text]
    cmp     byte [rdi], 0
    jne     print_line
    lea     rdi, [rel root_path]
    jmp     print_line

command_cd:
    cmp     byte [rdi], 0
    je      cd_missing
    xor     esi, esi
    sub     rsp, 8
    call    resolve_path
    add     rsp, 8
    test    rax, rax
    jnz     print_error
    lea     rsi, [rel work_path]
    lea     rdi, [rel current_path]
    mov     ecx, path_state_size / 8
    rep     movsq
    ret

command_ls:
    xor     esi, esi
    sub     rsp, 8
    call    resolve_path
    add     rsp, 8
    test    rax, rax
    jnz     print_error
    call    work_location
    test    rax, rax
    jz      list_mounts
    cmp     rax, RAM_MOUNT
    je      ramfs_ls
    push    rbp
    mov     rbp, rax
    mov     edi, edx
    cmp     byte [rbp + mount_volume.type], FS_EXT2
    je      .ext
    call    fat_list
    pop     rbp
    ret
.ext:
    call    ext_list
    pop     rbp
    test    rax, rax
    jnz     print_error
    ret

command_cat:
    cmp     byte [rdi], 0
    je      cat_missing
    lea     rsi, [rel cat_handlers]
    jmp     file_command

command_rm:
    cmp     byte [rdi], 0
    je      rm_missing
    lea     rsi, [rel rm_handlers]
    mov     edx, PATH_REMOVE
    jmp     dispatch_operand

command_mkdir:
    cmp     byte [rdi], 0
    je      mkdir_missing
    lea     rsi, [rel mkdir_handlers]
    mov     edx, 2
    jmp     dispatch_operand

command_touch:
    cmp     byte [rdi], 0
    je      touch_missing
    lea     rsi, [rel touch_handlers]
file_command:
    mov     edx, 1
dispatch_operand:
    push    rbx
    mov     rbx, rsi
    mov     esi, edx
    call    resolve_path
    test    rax, rax
    jnz     .error
    call    work_location
    lea     rdi, [rel component]
    mov     esi, edx
    mov     edx, r8d
    cmp     rax, RAM_MOUNT
    je      .ram
    push    rbp
    sub     rsp, 8
    mov     rbp, rax
    movzx   eax, byte [rbp + mount_volume.type]
    call    [rbx + 8 + rax * 8]
    add     rsp, 8
    pop     rbp
    pop     rbx
    ret
.ram:
    test    edx, edx
    jnz     .needs_directory
    mov     rax, [rbx]
    pop     rbx
    jmp     rax
.needs_directory:
    lea     rax, [rel path_not_directory]
.error:
    pop     rbx
    jmp     print_error

; rdi = path, rsi = data, rdx = length.
vfs_write:
    push    rbp
    push    r12
    push    r13
    mov     r12, rsi
    mov     r13, rdx
    mov     esi, 1
    call    resolve_path
    test    rax, rax
    jnz     .error
    call    work_location
    mov     ecx, edx
    lea     rdi, [rel component]
    mov     rsi, r12
    mov     rdx, r13
    cmp     rax, RAM_MOUNT
    je      .ram
    mov     rbp, rax
    cmp     byte [rbp + mount_volume.type], FS_EXT2
    je      .ext
    call    fat_write
    jmp     .done
.ram:
    call    ramfs_write
    jmp     .done
.ext:
    call    ext_write
.done:
    pop     r13
    pop     r12
    pop     rbp
    ret
.error:
    pop     r13
    pop     r12
    pop     rbp
    jmp     print_error

; esi = 0 for directory lookup, 1 for a file operand, 2 for mkdir, 3 for rm.
; Operand lookup leaves the final name for the backend. On success r8d
; is set for rm with trailing separators and clear for other operands.
resolve_path:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13d, esi
    mov     byte [rel symlink_budget], 40
    lea     rbx, [rel work_path]
    cmp     byte [r12], '/'
    je      .root
    lea     rsi, [rel current_path]
    mov     rdi, rbx
    mov     ecx, path_state_size / 8
    rep     movsq
    jmp     .skip
.root:
    mov     qword [rbx + path_state.depth], 0
    mov     byte [rbx + path_state.text], 0
.skip:
    cmp     byte [r12], '/'
    jne     .next
    inc     r12
    jmp     .skip
.next:
    cmp     byte [r12], 0
    je      .end
    lea     rdi, [rel component]
    xor     r14d, r14d
.copy:
    mov     al, [r12]
    test    al, al
    jz      .copied
    cmp     al, '/'
    je      .copied
    cmp     r14d, LINE_BUF_SIZE - 1
    jae     .long
    mov     [rdi + r14], al
    inc     r14d
    inc     r12
    jmp     .copy
.copied:
    mov     byte [rdi + r14], 0
    cmp     word [rdi], '.'
    je      .skip
    cmp     word [rdi], '..'
    jne     .ordinary
    cmp     byte [rdi + 2], 0
    jne     .ordinary
    cmp     qword [rbx + path_state.depth], 0
    je      .skip
    dec     qword [rbx + path_state.depth]
    call    work_level
    mov     edx, [rax + location.length]
    mov     byte [rbx + path_state.text + rdx], 0
    jmp     .skip
.ordinary:
    call    work_location
    cmp     rax, RAM_MOUNT
    jbe     .operand
    cmp     byte [rax + mount_volume.type], FS_EXT2
    jne     .operand
    cmp     r13d, 1
    jbe     .probe_link
    mov     rcx, r12
.link_suffix:
    cmp     byte [rcx], '/'
    jne     .link_end
    inc     rcx
    jmp     .link_suffix
.link_end:
    cmp     byte [rcx], 0
    je      .operand
.probe_link:
    push    rbp
    mov     rbp, rax
    mov     esi, edx
    lea     rdi, [rel component]
    lea     rdx, [rel symlink_target]
    call    ext_try_symlink
    pop     rbp
    test    rax, rax
    jnz     .done
    test    edx, edx
    jz      .operand
    sub     byte [rel symlink_budget], 1
    jc      .links
    lea     rdi, [rel symlink_target]
    lea     rsi, [rdi + rdx]
.link_append:
    mov     al, [r12]
    cmp     edx, LINE_BUF_SIZE
    jae     .long
    mov     [rsi], al
    inc     rsi
    inc     r12
    inc     edx
    test    al, al
    jnz     .link_append
    mov     rsi, rdi
    lea     rdi, [rel symlink_path]
    mov     r12, rdi
    mov     ecx, edx
    rep     movsb
    cmp     byte [r12], '/'
    je      .root
    jmp     .skip
.operand:
    call    work_location
    xor     r8d, r8d
    test    r13d, r13d
    jz      .directory
    cmp     r13d, 2
    jb      .operand_end
    cmp     r13d, PATH_NOFOLLOW
    je      .operand_end
.skip_operand_slash:
    cmp     byte [r12], '/'
    jne     .operand_end
    mov     r8d, 1
    inc     r12
    jmp     .skip_operand_slash
.operand_end:
    cmp     byte [r12], 0
    jne     .directory
    test    rax, rax
    jz      .is_directory
    cmp     r13d, 2
    jne     .operand_length
    cmp     qword [rbx + path_state.depth], PATH_DEPTH
    jae     .long
.operand_length:
    call    work_level
    mov     ecx, [rax + location.length]
    lea     eax, [rcx + r14 + 1]
    cmp     eax, LINE_BUF_SIZE
    jae     .long
    cmp     r13d, PATH_REMOVE
    je      .success
    cmp     r13d, PATH_MOVE
    je      .success
    xor     r8d, r8d
    jmp     .success
.directory:
    test    rax, rax
    jz      .mount_point
    cmp     rax, RAM_MOUNT
    je      .missing_directory
    mov     r15, rax
    mov     esi, edx
    lea     rdi, [rel component]
    push    rbp
    sub     rsp, 8
    mov     rbp, r15
    cmp     byte [rbp + mount_volume.type], FS_EXT2
    je      .ext_find
    call    fat_find_dir
    jmp     .found_dir
.ext_find:
    call    ext_find_dir
.found_dir:
    add     rsp, 8
    pop     rbp
    test    rax, rax
    jnz     .done
    jmp     .append
.mount_point:
    lea     rdi, [rel component]
    lea     rsi, [rel ram_name]
    call    str_eq
    mov     r15d, RAM_MOUNT
    test    eax, eax
    jnz     .mount_found
    lea     rdi, [rel component]
    call    find_mount_name
    mov     r15, rax
    test    rax, rax
    jz      .missing_directory
    push    rbp
    sub     rsp, 8
    mov     rbp, r15
    cmp     byte [rbp + mount_volume.type], FS_EXT2
    je      .ext_root
    call    fat_validate_root
    jmp     .root_validated
.ext_root:
    call    ext_root
.root_validated:
    add     rsp, 8
    pop     rbp
    test    rax, rax
    jnz     .done
.mount_found:
    xor     edx, edx
.append:
    cmp     qword [rbx + path_state.depth], PATH_DEPTH
    jae     .long
    call    work_level
    mov     ecx, [rax + location.length]
    lea     eax, [rcx + r14 + 1]
    cmp     eax, LINE_BUF_SIZE
    jae     .long
    lea     rdi, [rbx + path_state.text + rcx]
    mov     al, '/'
    stosb
    lea     rsi, [rel component]
    mov     ecx, r14d
    inc     ecx
    rep     movsb
    inc     qword [rbx + path_state.depth]
    call    work_level
    mov     [rax + location.volume], r15
    mov     [rax + location.cluster], edx
    sub     rdi, rbx
    sub     edi, path_state.text + 1
    mov     [rax + location.length], edi
    jmp     .skip
.end:
    test    r13d, r13d
    jnz     .is_directory
.success:
    xor     eax, eax
    jmp     .done
.long:
    lea     rax, [rel path_long]
    jmp     .done
.links:
    lea     rax, [rel symlink_loop]
    jmp     .done
.missing_directory:
    lea     rax, [rel path_missing]
    jmp     .done
.is_directory:
    lea     rax, [rel path_directory]
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

work_location:
    call    work_level
    mov     edx, [rax + location.cluster]
    mov     rax, [rax + location.volume]
    ret

work_level:
    lea     rax, [rel work_path + path_state.levels]
    mov     rcx, [rel work_path + path_state.depth]
    shl     rcx, 4
    add     rax, rcx
    ret

; rbp = volume, edi = directory identity. Return true if in the current path.
vfs_dir_busy:
    lea     rdx, [rel current_path + path_state.levels]
    mov     rcx, [rel current_path + path_state.depth]
.next:
    test    rcx, rcx
    jz      .free
    add     rdx, location_size
    cmp     rbp, [rdx + location.volume]
    jne     .advance
    cmp     edi, [rdx + location.cluster]
    je      .busy
.advance:
    dec     rcx
    jmp     .next
.busy:
    mov     eax, 1
    ret
.free:
    xor     eax, eax
    ret

; rdi = exact mount name, without slashes.
find_mount_name:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    lea     rbx, [rel mounts]
    mov     r13d, VOLUME_MOUNT_COUNT
.next:
    cmp     byte [rbx + mount_volume.mounted], 0
    je      .advance
    mov     rdi, r12
    lea     rsi, [rbx + mount_volume.name]
    call    str_eq
    test    eax, eax
    jnz     .found
.advance:
    add     rbx, mount_volume_size
    dec     r13d
    jnz     .next
    xor     ebx, ebx
.found:
    mov     rax, rbx
    pop     r13
    pop     r12
    pop     rbx
    ret

; rbp = unpublished mount record, rdi = partition number string.
; Store the validated GPT bounds and return zero or a console error.
vfs_mount_partition:
    push    rbx
    call    parse_lba
    jc      .partition
    cmp     rax, 128
    ja      .partition
    mov     ebx, eax
    mov     eax, [rbp + mount_volume.device]
    mov     [rel block_selected], eax
    call    gpt_load
    test    rax, rax
    jnz     .done
    cmp     byte [rbp + mount_volume.read_only], 0
    jne     .partition_info
    call    block_writable
    test    eax, eax
    jz      .readonly_disk
.partition_info:
    mov     edi, ebx
    call    gpt_partition
    test    rax, rax
    jz      .partition
    mov     rdi, rax
    mov     rsi, rdx
    mov     edx, [rbp + mount_volume.device]
    call    vfs_mount_overlap
    test    eax, eax
    jnz     .overlap
    mov     [rbp + mount_volume.volume_base], rdi
    mov     [rbp + mount_volume.partition_last], rsi
.done:
    pop     rbx
    ret
.partition:
    lea     rax, [rel missing_partition]
    jmp     .done
.readonly_disk:
    lea     rax, [rel disk_needs_ro]
    jmp     .done
.overlap:
    lea     rax, [rel overlapping_mount]
    jmp     .done

; rdi = proposed first LBA, rsi = last LBA, edx = device.
vfs_mount_overlap:
    lea     rcx, [rel mounts]
    mov     r8d, VOLUME_MOUNT_COUNT
.next:
    cmp     byte [rcx + mount_volume.mounted], 0
    je      .advance
    cmp     edx, [rcx + mount_volume.device]
    jne     .advance
    cmp     rdi, [rcx + mount_volume.partition_last]
    ja      .advance
    cmp     rsi, [rcx + mount_volume.volume_base]
    jae     .overlap
.advance:
    add     rcx, mount_volume_size
    dec     r8d
    jnz     .next
    xor     eax, eax
    ret
.overlap:
    mov     eax, 1
    ret

list_mounts:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rdi, [rel ram_path]
    call    print_line
    lea     rbx, [rel mounts]
    mov     r12d, VOLUME_MOUNT_COUNT
.next:
    cmp     byte [rbx + mount_volume.mounted], 0
    je      .advance
    mov     edi, '/'
    call    console_putc
    lea     rdi, [rbx + mount_volume.name]
    call    print_line
.advance:
    add     rbx, mount_volume_size
    dec     r12d
    jnz     .next
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

command_mount:
    cmp     byte [rdi], 0
    je      list_mounts
    xor     edx, edx
    cmp     word [rdi], '-t'
    jne     .option
    cmp     dword [rdi + 2], ' ext'
    jne     mount_usage
    cmp     word [rdi + 6], '2 '
    jne     mount_usage
    add     rdi, 8
    mov     edx, FS_EXT2
.option:
    cmp     dword [rdi], '-o r'
    jne     .device
    cmp     word [rdi + 4], 'o '
    jne     mount_usage
    add     rdi, 6
    or      edx, 0x100
.device:
    cmp     dword [rdi], 'disk'
    jne     mount_usage
    cmp     byte [rdi + 5], 'p'
    jne     mount_usage
    movzx   ecx, byte [rdi + 4]
    sub     ecx, '0'
    cmp     ecx, 1
    ja      mount_usage
    shl     ecx, 16
    or      edx, ecx
    add     rdi, 6
    mov     rsi, rdi
.partition:
    cmp     byte [rsi], 0
    je      mount_usage
    cmp     byte [rsi], ' '
    je      .split
    inc     rsi
    jmp     .partition
.split:
    mov     byte [rsi], 0
.skip:
    inc     rsi
    cmp     byte [rsi], ' '
    je      .skip
    cmp     byte [rsi], '/'
    jne     mount_usage
    inc     rsi
    push    rbp
    push    r12
    push    r13
    sub     rsp, 16
    mov     [rsp], edx
    mov     r12, rdi
    mov     r13, rsi
    xor     ecx, ecx
.name:
    mov     al, [r13 + rcx]
    test    al, al
    jz      .end_name
    cmp     ecx, VOLUME_MOUNT_NAME_SIZE - 1
    jae     .usage
    cmp     al, '_'
    je      .next_byte
    cmp     al, '-'
    je      .next_byte
    cmp     al, '0'
    jb      .usage
    cmp     al, '9'
    jbe     .next_byte
    or      al, 0x20
    cmp     al, 'a'
    jb      .usage
    cmp     al, 'z'
    ja      .usage
.next_byte:
    inc     ecx
    jmp     .name
.end_name:
    test    ecx, ecx
    jz      .usage
    mov     rdi, r13
    lea     rsi, [rel ram_name]
    call    str_eq
    test    eax, eax
    jnz     .occupied
    mov     rdi, r13
    call    find_mount_name
    test    rax, rax
    jnz     .occupied
    lea     rbp, [rel mounts]
    mov     ecx, VOLUME_MOUNT_COUNT
.slot:
    cmp     byte [rbp + mount_volume.mounted], 0
    je      .open
    add     rbp, mount_volume_size
    dec     ecx
    jnz     .slot
    lea     rax, [rel mount_full]
    jmp     .error
.open:
    lea     rdi, [rbp + mount_volume.name]
    mov     rsi, r13
.copy:
    lodsb
    stosb
    test    al, al
    jnz     .copy
    movzx   eax, byte [rsp + 2]
    mov     [rbp + mount_volume.device], eax
    mov     al, [rsp]
    mov     [rbp + mount_volume.type], al
    mov     al, [rsp + 1]
    mov     [rbp + mount_volume.read_only], al
    mov     rdi, r12
    cmp     byte [rbp + mount_volume.type], FS_EXT2
    je      .ext_mount
    call    fat_mount
    jmp     .mounted
.ext_mount:
    call    ext_mount
    test    rax, rax
    jnz     .error
    lea     rdi, [rel ext_mounted]
    cmp     byte [rbp + mount_volume.read_only], 0
    jne     .ext_message
    lea     rdi, [rel ext_mounted_rw]
.ext_message:
    call    console_write_cstr
.mounted:
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbp
    ret
.usage:
    lea     rax, [rel mount_help]
    jmp     .error
.occupied:
    lea     rax, [rel mount_taken]
.error:
    add     rsp, 16
    pop     r13
    pop     r12
    pop     rbp
    jmp     print_error

; Separate from path traversal. Permit one optional final slash.
select_volume:
    cmp     byte [rdi], 0
    je      default_volume
    cmp     byte [rdi], '/'
    jne     .bad
    inc     rdi
    cmp     byte [rdi], 0
    je      .bad
    lea     rsi, [rel component]
    xor     ecx, ecx
.copy:
    mov     al, [rdi + rcx]
    test    al, al
    jz      .end
    cmp     al, '/'
    je      .tail
    cmp     ecx, VOLUME_MOUNT_NAME_SIZE - 1
    jae     .bad
    mov     [rsi + rcx], al
    inc     ecx
    jmp     .copy
.tail:
    cmp     byte [rdi + rcx + 1], 0
    jne     .bad
.end:
    mov     byte [rsi + rcx], 0
    mov     rdi, rsi
    jmp     find_mount_name
.bad:
    xor     eax, eax
    ret

default_volume:
    lea     rdi, [rel disk_name]
    jmp     find_mount_name

command_umount:
    cmp     byte [rdi], 0
    je      mount_usage
    sub     rsp, 8
    call    select_volume
    add     rsp, 8
    test    rax, rax
    jz      mount_missing
    mov     rcx, [rel current_path + path_state.depth]
    shl     rcx, 4
    lea     rdx, [rel current_path + path_state.levels]
    cmp     rax, [rdx + rcx + location.volume]
    je      .busy
    cmp     byte [rax + mount_volume.type], FS_EXT2
    je      .ext
    push    rbp
    mov     rbp, rax
    call    fat_unmount
    pop     rbp
    ret
.ext:
    push    rbp
    mov     rbp, rax
    call    ext_finish
    pop     rbp
    test    rax, rax
    jnz     print_error
    lea     rdi, [rel ext_unmounted]
    jmp     console_write_cstr
.busy:
    lea     rdi, [rel mount_in_use]
    jmp     console_write_cstr

; Close all mounts before a guest-requested power transition.
vfs_shutdown:
    push    rbp
    push    rbx
    sub     rsp, 8
    lea     rbp, [rel mounts]
    mov     ebx, VOLUME_MOUNT_COUNT
.next:
    cmp     byte [rbp + mount_volume.mounted], 0
    je      .advance
    cmp     byte [rbp + mount_volume.type], FS_EXT2
    je      .ext
    call    fat_finish
    jmp     .check
.ext:
    call    ext_finish
.check:
    cmp     byte [rbp + mount_volume.mounted], 0
    jne     .result
    mov     rcx, [rel current_path + path_state.levels + location_size + location.volume]
    cmp     rcx, rbp
    jne     .result
    mov     qword [rel current_path + path_state.depth], 0
    mov     byte [rel current_path + path_state.text], 0
.result:
    test    rax, rax
    jnz     .done
.advance:
    add     rbp, mount_volume_size
    dec     ebx
    jnz     .next
    xor     eax, eax
.done:
    add     rsp, 8
    pop     rbx
    pop     rbp
    ret

%macro disk_wrapper 3
%1:
    push    rbp
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    call    %2
    test    rax, rax
    jz      .missing
    cmp     byte [rax + mount_volume.type], FS_EXT2
    je      .ext
    mov     rbp, rax
    mov     rdi, r12
    xor     esi, esi
    call    %3
    add     rsp, 8
    pop     r12
    pop     rbp
    ret
.missing:
    add     rsp, 8
    pop     r12
    pop     rbp
    jmp     mount_missing
.ext:
    add     rsp, 8
    pop     r12
    pop     rbp
%ifidn %1, disk_repair_volume
    jmp     ext_readonly
%else
    lea     rdi, [rel ext_check]
    jmp     console_write_cstr
%endif
%endmacro

disk_wrapper disk_check_volume, select_volume, fat_check
disk_wrapper disk_repair_volume, select_volume, fat_repair

ext_readonly:
    lea     rdi, [rel ext_readonly_text]
    jmp     console_write_cstr

print_line:
    sub     rsp, 8
    call    console_write_cstr
    add     rsp, 8
    mov     edi, 10
    jmp     console_putc
print_error:
    mov     rdi, rax
    jmp     console_write_cstr
mount_usage:
    lea     rdi, [rel mount_help]
    jmp     console_write_cstr
mount_missing:
    lea     rdi, [rel no_fat_mount]
    jmp     console_write_cstr
cd_missing:
    lea     rdi, [rel cd_help]
    jmp     console_write_cstr
cat_missing:
    lea     rdi, [rel cat_help]
    jmp     console_write_cstr
rm_missing:
    lea     rdi, [rel rm_help]
    jmp     console_write_cstr
mkdir_missing:
    lea     rdi, [rel mkdir_help]
    jmp     console_write_cstr
mkdir_unsupported:
    lea     rdi, [rel mkdir_mount_required]
    jmp     console_write_cstr
touch_missing:
    lea     rdi, [rel touch_help]
    jmp     console_write_cstr

section .rodata
root_path:      db "/", 0
ram_path:       db "/ram", 0
ram_name:       db "ram", 0
disk_name:      db "disk", 0
cd_help:        db "Usage: cd PATH", 10, 0
cat_help:       db "Usage: cat FILE", 10, 0
rm_help:        db "Usage: rm PATH", 10, 0
touch_help:     db "Usage: touch PATH", 10, 0
mkdir_help:     db "Usage: mkdir PATH", 10, 0
mkdir_mount_required: db "mkdir requires a writable FAT32 or ext2 mount.", 10, 0
mount_help:     db "Usage: mount [[-t ext2] [-o ro] diskNpM /NAME] or umount /NAME", 10, 0
mount_taken:    db "Mount point is already in use.", 10, 0
mount_full:     db "No free volume mount slots.", 10, 0
mount_in_use:   db "Current directory is on this volume. Change directory first.", 10, 0
no_fat_mount:   db "No FAT32 volume mounted.", 10, 0
disk_needs_ro: db "Disk is read-only or lacks flush support. Use -o ro.", 10, 0
missing_partition: db "Invalid or missing GPT partition.", 10, 0
overlapping_mount: db "Partition overlaps an active mount.", 10, 0
path_missing:   db "Directory not found.", 10, 0
path_directory: db "Expected a file path, found a directory.", 10, 0
path_not_directory: db "Trailing slash requires a directory.", 10, 0
path_long:      db "Path is too long or has too many components.", 10, 0

ext_mounted: db "Ext2 mounted read-only.", 10, 0
ext_mounted_rw: db "Ext2 mounted read-write.", 10, 0
ext_unmounted: db "Ext2 unmounted.", 10, 0
ext_readonly_text: db "Ext2 is read-only.", 10, 0
ext_check: db "disk check requires a FAT32 volume.", 10, 0

align 8
cat_handlers: dq ramfs_cat, fat_cat, ext_cat
rm_handlers:  dq ramfs_rm, fat_rm, ext_rm
touch_handlers: dq ramfs_touch, fat_touch, ext_touch
mkdir_handlers: dq mkdir_unsupported, fat_mkdir, ext_mkdir

section .bss
alignb 8
mounts:   resb VOLUME_MOUNT_COUNT * mount_volume_size
current_path: resb path_state_size   ; The zeroed state represents / at boot.
work_path:    resb path_state_size
component:    resb LINE_BUF_SIZE

%include "vfs_copy.inc"
%include "vfs_read.inc"
%include "vfs_move.inc"
%include "vfs_namespace.inc"
