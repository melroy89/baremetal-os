; Kernel entry and built-in console commands.
bits 64
default rel

%include "os_constants.inc"
%include "build_id.inc"

%define BOOT_LOG_CAPACITY 4

extern g_mb_magic
extern g_mb_info
extern g_smp_total_cpus
extern g_smp_online_cpus
extern smp_stack_pages
extern serial_init
extern vga_clear
extern vga_set_color
extern console_putc
extern console_clear
extern console_write_cstr
extern console_input_init
extern console_readline
extern timer_init
extern timer_ns
extern smp_init
extern memory_usable_bytes
extern memory_map_print
extern pages_managed
extern pages_free
extern str_eq
extern write_u64
extern qemu_shutdown
extern qemu_reboot
extern command_cpu
extern ramfs_mount
extern ramfs_ls
extern ramfs_cat
extern ramfs_rm
extern command_echo

section .text
global kernel_main
global print_cpu_counts

kernel_main:
    sub     rsp, 8
    call    serial_init
    mov     edi, VGA_ATTR_GREY
    call    vga_clear

    cmp     dword [rel g_mb_magic], MB_BOOTLOADER_MAGIC
    jne     .bad_boot
    lea     rdi, [rel event_multiboot]
    call    record_boot_event
    call    timer_init
    lea     rdi, [rel event_timer]
    call    record_boot_event
    mov     edi, [rel g_mb_info]
    call    smp_init
    mov     edi, [rel g_mb_info]
    call    ramfs_mount
    mov     eax, [rel g_smp_online_cpus]
    mov     [rel boot_cpus_started], eax
    mov     eax, [rel g_smp_total_cpus]
    mov     [rel boot_cpus_total], eax
    lea     rdi, [rel event_smp]
    call    record_boot_event
    call    console_input_init
    lea     rdi, [rel event_console]
    call    record_boot_event

    lea     rdi, [rel welcome]
    call    console_write_cstr

.prompt:
    mov     edi, VGA_ATTR_GREEN
    call    vga_set_color
    lea     rdi, [rel prompt]
    call    console_write_cstr
    mov     edi, VGA_ATTR_WHITE
    call    vga_set_color

    lea     rdi, [rel line_buffer]
    mov     esi, LINE_BUF_SIZE
    call    console_readline
    cmp     rax, LINE_TOO_LONG
    je      .too_long
    test    rax, rax
    js      command_halt
    jz      .prompt

    ; Trim padding and accept a leading slash for existing console shortcuts.
    lea     r12, [rel line_buffer]
    lea     rcx, [r12 + rax]
.trim_end:
    cmp     byte [rcx - 1], ' '
    jne     .trim_start
    dec     rcx
    mov     byte [rcx], 0
    cmp     rcx, r12
    je      .prompt
    jmp     .trim_end
.trim_start:
    cmp     byte [r12], ' '
    jne     .command
    inc     r12
    jmp     .trim_start
.command:
    cmp     byte [r12], '/'
    jne     .lookup
    inc     r12
.lookup:
    mov     r13, r12
.scan_command:
    mov     al, [r13]
    test    al, al
    jz      .find_command
    cmp     al, ' '
    je      .split
    inc     r13
    jmp     .scan_command
.split:
    mov     byte [r13], 0
.skip_space:
    inc     r13
    cmp     byte [r13], ' '
    je      .skip_space
.find_command:
    lea     rbx, [rel commands]
.next:
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .unknown
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     .run
    add     rbx, 24
    jmp     .next
.run:
    mov     rdi, r13
    cmp     byte [rdi], 0
    je      .invoke
    cmp     qword [rbx + 16], 0         ; Does this command accept arguments?
    je      .unknown
.invoke:
    call    [rbx + 8]
    jmp     .prompt

.unknown:
    lea     rdi, [rel unknown]
    call    console_write_cstr
    jmp     .prompt

.too_long:
    lea     rdi, [rel command_too_long]
    call    console_write_cstr
    jmp     .prompt

.bad_boot:
    lea     rdi, [rel bad_boot]
    call    console_write_cstr
    jmp     qemu_shutdown

command_help:
    lea     rdi, [rel help_text]
    jmp     console_write_cstr

command_info:
    sub     rsp, 8
    lea     rdi, [rel info_text]
    call    console_write_cstr
    mov     edi, [rel g_smp_online_cpus]
    mov     esi, [rel g_smp_total_cpus]
    call    print_cpu_counts
    lea     rdi, [rel ap_stack_text]
    call    console_write_cstr
    call    smp_stack_pages
    mov     edi, eax
    call    write_u64
    mov     edi, 10
    call    console_putc
    lea     rdi, [rel memory_text]
    call    console_write_cstr
    mov     edi, [rel g_mb_info]
    call    memory_usable_bytes
    shr     rax, 20
    mov     rdi, rax
    call    write_u64
    lea     rdi, [rel mib_text]
    add     rsp, 8
    jmp     console_write_cstr

; Print started and detected CPU counts passed in edi and esi.
print_cpu_counts:
    push    rbx
    mov     ebx, edi
    push    rsi
    sub     rsp, 8
    lea     rdi, [rel cpu_count_text]
    call    console_write_cstr
    mov     edi, ebx
    call    write_u64
    mov     edi, '/'
    call    console_putc
    mov     edi, [rsp + 8]
    call    write_u64
    mov     edi, 10
    add     rsp, 16
    pop     rbx
    jmp     console_putc

command_memmap:
    mov     edi, [rel g_mb_info]
    jmp     memory_map_print

command_mem:
    sub     rsp, 8
    lea     rdi, [rel pages_text]
    call    console_write_cstr
    mov     rdi, [rel pages_managed]
    call    write_u64
    lea     rdi, [rel pages_managed_text]
    call    console_write_cstr
    mov     rdi, [rel pages_managed]
    sub     rdi, [rel pages_free]
    call    write_u64
    lea     rdi, [rel pages_used_text]
    call    console_write_cstr
    mov     rdi, [rel pages_free]
    call    write_u64
    lea     rdi, [rel pages_free_text]
    add     rsp, 8
    jmp     console_write_cstr

command_version:
    lea     rdi, [rel version_text]
    jmp     console_write_cstr

command_reboot:
    sub     rsp, 8
    lea     rdi, [rel reboot_text]
    call    console_write_cstr
    call    qemu_reboot
    lea     rdi, [rel reboot_failed]
    add     rsp, 8
    jmp     console_write_cstr

record_boot_event:
    mov     eax, [rel boot_log_count]
    cmp     eax, BOOT_LOG_CAPACITY
    jae     .done
    lea     rdx, [rel boot_log]
    mov     [rdx + rax * 8], rdi
    inc     dword [rel boot_log_count]
.done:
    ret

command_log:
    push    rbx
    push    r12
    sub     rsp, 8
    lea     rdi, [rel log_text]
    call    console_write_cstr
    lea     r12, [rel boot_log]
    xor     ebx, ebx
.next:
    cmp     ebx, [rel boot_log_count]
    jae     .counts
    mov     rdi, [r12 + rbx * 8]
    call    console_write_cstr
    inc     ebx
    jmp     .next
.counts:
    mov     edi, [rel boot_cpus_started]
    mov     esi, [rel boot_cpus_total]
    add     rsp, 8
    pop     r12
    pop     rbx
    jmp     print_cpu_counts

command_uptime:
    sub     rsp, 8
    lea     rdi, [rel uptime_text]
    call    console_write_cstr
    call    timer_ns
    xor     edx, edx
    mov     ecx, 1000000
    div     rcx
    mov     rdi, rax
    call    write_u64
    lea     rdi, [rel milliseconds_text]
    add     rsp, 8
    jmp     console_write_cstr

command_halt:
    and     rsp, -16
    lea     rdi, [rel poweroff_text]
    call    console_write_cstr
    jmp     qemu_shutdown

section .rodata
welcome:           db "Bare Metal OS | x86-64", 10, "Type help for commands.", 10, 0
prompt:            db "baremetal> ", 0
unknown:           db "Unknown command. Type help.", 10, 0
command_too_long:  db "Command too long.", 10, 0
bad_boot:          db "Invalid Multiboot bootloader magic.", 10, 0

%macro help_row 2
    %strlen %%label_length %1
    db %1
    times 9 - %%label_length db ' '
    db ' ', %2, 10
%endmacro

help_text:
    help_row "help",     "Show console commands"
    help_row "info",     "Show CPU and usable memory information"
    help_row "cpu",      "Show boot CPU capabilities and processors started"
    help_row "cpu ping", "Check which secondary CPUs respond"
    help_row "mem",      "Show pages managed, used and free by the kernel"
    help_row "memmap",   "Show the Multiboot memory map"
    help_row "ls",       "List files in the RAM filesystem"
    help_row "cat FILE", "Print a file from the RAM filesystem"
    help_row "echo",     "Print text or write it to a RAM file with >"
    help_row "rm FILE",  "Remove a writable RAM file"
    help_row "uptime",   "Show time since boot"
    help_row "log",      "Show boot milestones"
    help_row "version",  "Show the kernel version and build identifier"
    help_row "clear",    "Clear the console"
    help_row "reboot",   "Restart the machine"
    help_row "halt",     "Power off the machine"
    db 0
info_text:         db "Architecture: x86-64", 10, 0
cpu_count_text:    db "CPUs started: ", 0
ap_stack_text:     db "Secondary CPU stack pages: ", 0
memory_text:       db "Usable memory: ", 0
mib_text:          db " MiB", 10, 0
pages_text:        db "4 KiB pages: ", 0
pages_managed_text: db " managed, ", 0
pages_used_text:   db " used, ", 0
pages_free_text:   db " free", 10, 0
uptime_text:       db "Uptime: ", 0
milliseconds_text: db " ms", 10, 0
poweroff_text:     db "Powering off...", 10, 0
reboot_text:       db "Rebooting...", 10, 0
reboot_failed:     db "Reboot failed.", 10, 0
version_text:      db "Bare Metal OS 1.2.0 (x86-64)", 10, "Build: ", BUILD_ID, 10, 0
log_text:          db "Boot log", 10, 0
event_multiboot:   db "Multiboot handoff accepted.", 10, 0
event_timer:       db "Timer initialized.", 10, 0
event_smp:         db "CPU startup complete.", 10, 0
event_console:     db "Console input ready.", 10, 0

help_name:         db "help", 0
info_name:         db "info", 0
cpu_name:          db "cpu", 0
mem_name:          db "mem", 0
memmap_name:       db "memmap", 0
ls_name:           db "ls", 0
cat_name:          db "cat", 0
echo_name:         db "echo", 0
rm_name:           db "rm", 0
uptime_name:       db "uptime", 0
log_name:          db "log", 0
version_name:      db "version", 0
clear_name:        db "clear", 0
reboot_name:       db "reboot", 0
halt_name:         db "halt", 0
quit_name:         db "quit", 0
exit_name:         db "exit", 0

align 8
commands:
    ; Name, handler, accepts arguments
    dq help_name, command_help, 0
    dq info_name, command_info, 0
    dq cpu_name, command_cpu, 1
    dq mem_name, command_mem, 0
    dq memmap_name, command_memmap, 0
    dq ls_name, ramfs_ls, 0
    dq cat_name, ramfs_cat, 1
    dq echo_name, command_echo, 1
    dq rm_name, ramfs_rm, 1
    dq uptime_name, command_uptime, 0
    dq log_name, command_log, 0
    dq version_name, command_version, 0
    dq clear_name, console_clear, 0
    dq reboot_name, command_reboot, 0
    dq halt_name, command_halt, 0
    dq quit_name, command_halt, 0
    dq exit_name, command_halt, 0
    dq 0

section .bss
alignb 8
boot_log:          resq BOOT_LOG_CAPACITY
boot_log_count:    resd 1
boot_cpus_started: resd 1
boot_cpus_total:   resd 1
line_buffer:       resb LINE_BUF_SIZE
