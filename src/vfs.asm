; Console paths and mount routing. Operations run serially on the boot CPU.
bits 64
default rel

%include "os_constants.inc"
%include "fat32_mount.inc"

%define RAM_MOUNT 1
%define PATH_DEPTH 32

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
extern fat_mount, fat_unmount, fat_list, fat_cat, fat_put
extern fat_write, fat_rm, fat_touch, fat_find_dir, fat_check, fat_repair
extern fat_validate_root
extern console_write_cstr, console_putc, str_eq

section .text
global command_ls, command_cat, command_rm, command_touch, command_cd, command_pwd
global vfs_write, command_mount, command_umount, vfs_mount_overlap
global disk_mount_default, disk_unmount_default, disk_ls_default
global disk_cat_default, disk_put_default, disk_check_volume, disk_repair_volume

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
    call    fat_list
    pop     rbp
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
    jmp     file_command

command_touch:
    cmp     byte [rdi], 0
    je      touch_missing
    lea     rsi, [rel touch_handlers]
file_command:
    push    rbx
    mov     rbx, rsi
    mov     esi, 1
    call    resolve_path
    test    rax, rax
    jnz     .error
    call    work_location
    lea     rdi, [rel component]
    mov     esi, edx
    cmp     rax, RAM_MOUNT
    je      .ram
    push    rbp
    sub     rsp, 8
    mov     rbp, rax
    call    [rbx + 8]
    add     rsp, 8
    pop     rbp
    pop     rbx
    ret
.ram:
    mov     rax, [rbx]
    pop     rbx
    jmp     rax
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
    call    fat_write
    jmp     .done
.ram:
    call    ramfs_write
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

; esi = 1 for a file operand, 0 for a directory. Resolve components in order.
; File resolution leaves the last component intact for backend validation.
resolve_path:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13d, esi
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
    test    r13d, r13d
    jz      .directory
    cmp     byte [r12], 0
    jne     .directory
    test    rax, rax
    jz      .is_directory
    call    work_level
    mov     ecx, [rax + location.length]
    lea     eax, [rcx + r14 + 1]
    cmp     eax, LINE_BUF_SIZE
    jae     .long
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
    call    fat_find_dir
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
    call    fat_validate_root
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

; rdi = exact mount name, without slashes.
find_mount_name:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    lea     rbx, [rel fat_mounts]
    mov     r13d, FAT_MOUNT_COUNT
.next:
    cmp     byte [rbx + fat_volume.mounted], 0
    je      .advance
    mov     rdi, r12
    lea     rsi, [rbx + fat_volume.name]
    call    str_eq
    test    eax, eax
    jnz     .found
.advance:
    add     rbx, fat_volume_size
    dec     r13d
    jnz     .next
    xor     ebx, ebx
.found:
    mov     rax, rbx
    pop     r13
    pop     r12
    pop     rbx
    ret

; rdi = proposed first LBA, rsi = last LBA, edx = device.
vfs_mount_overlap:
    lea     rcx, [rel fat_mounts]
    mov     r8d, FAT_MOUNT_COUNT
.next:
    cmp     byte [rcx + fat_volume.mounted], 0
    je      .advance
    cmp     edx, [rcx + fat_volume.device]
    jne     .advance
    cmp     rdi, [rcx + fat_volume.partition_last]
    ja      .advance
    cmp     rsi, [rcx + fat_volume.volume_base]
    jae     .overlap
.advance:
    add     rcx, fat_volume_size
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
    lea     rbx, [rel fat_mounts]
    mov     r12d, FAT_MOUNT_COUNT
.next:
    cmp     byte [rbx + fat_volume.mounted], 0
    je      .advance
    mov     edi, '/'
    call    console_putc
    lea     rdi, [rbx + fat_volume.name]
    call    print_line
.advance:
    add     rbx, fat_volume_size
    dec     r12d
    jnz     .next
    add     rsp, 8
    pop     r12
    pop     rbx
    ret

command_mount:
    cmp     byte [rdi], 0
    je      list_mounts
    cmp     dword [rdi], 'disk'
    jne     mount_usage
    cmp     word [rdi + 4], '0p'
    jne     mount_usage
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
    jmp     mount_named

disk_mount_default:
    lea     rsi, [rel disk_name]
mount_named:
    push    rbp
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13, rsi
    xor     ecx, ecx
.name:
    mov     al, [r13 + rcx]
    test    al, al
    jz      .end_name
    cmp     ecx, FAT_MOUNT_NAME_SIZE - 1
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
    lea     rbp, [rel fat_mounts]
    mov     ecx, FAT_MOUNT_COUNT
.slot:
    cmp     byte [rbp + fat_volume.mounted], 0
    je      .open
    add     rbp, fat_volume_size
    dec     ecx
    jnz     .slot
    lea     rax, [rel mount_full]
    jmp     .error
.open:
    lea     rdi, [rbp + fat_volume.name]
    mov     rsi, r13
.copy:
    lodsb
    stosb
    test    al, al
    jnz     .copy
    mov     dword [rbp + fat_volume.device], 0
    mov     rdi, r12
    call    fat_mount
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
    cmp     ecx, FAT_MOUNT_NAME_SIZE - 1
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
    jmp     unmount_selected

disk_unmount_default:
    sub     rsp, 8
    call    default_volume
    add     rsp, 8
unmount_selected:
    test    rax, rax
    jz      mount_missing
    mov     rcx, [rel current_path + path_state.depth]
    shl     rcx, 4
    lea     rdx, [rel current_path + path_state.levels]
    cmp     rax, [rdx + rcx + location.volume]
    je      .busy
    push    rbp
    mov     rbp, rax
    call    fat_unmount
    pop     rbp
    ret
.busy:
    lea     rdi, [rel mount_in_use]
    jmp     console_write_cstr

%macro disk_wrapper 3
%1:
    push    rbp
    push    r12
    sub     rsp, 8
    mov     r12, rdi
    call    %2
    test    rax, rax
    jz      .missing
    mov     rbp, rax
    mov     rdi, r12
    %ifidni %3, fat_list
        xor edi, edi
    %endif
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
%endmacro

disk_wrapper disk_ls_default, default_volume, fat_list
disk_wrapper disk_cat_default, default_volume, fat_cat
disk_wrapper disk_put_default, default_volume, fat_put
disk_wrapper disk_check_volume, select_volume, fat_check
disk_wrapper disk_repair_volume, select_volume, fat_repair

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
rm_help:        db "Usage: rm FILE", 10, 0
touch_help:     db "Usage: touch PATH", 10, 0
mount_help:     db "Usage: mount [disk0pN /NAME] or umount /NAME", 10, 0
mount_taken:    db "Mount point is already in use.", 10, 0
mount_full:     db "No free FAT32 mount slots.", 10, 0
mount_in_use:   db "Current directory is on this volume. Change directory first.", 10, 0
no_fat_mount:   db "No FAT32 volume mounted.", 10, 0
path_missing:   db "Directory not found.", 10, 0
path_directory: db "Expected a file path, found a directory.", 10, 0
path_long:      db "Path is too long or has too many components.", 10, 0

align 8
cat_handlers: dq ramfs_cat, fat_cat
rm_handlers:  dq ramfs_rm, fat_rm
touch_handlers: dq ramfs_touch, fat_touch

section .bss
alignb 8
fat_mounts:   resb FAT_MOUNT_COUNT * fat_volume_size
current_path: resb path_state_size   ; The zeroed state represents / at boot.
work_path:    resb path_state_size
component:    resb LINE_BUF_SIZE
