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
extern str_eq
extern write_u64
extern qemu_shutdown
extern qemu_reboot
extern command_cpu

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
    call    smp_init
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
    lea     rbx, [rel commands]
.next:
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .unknown
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     .run
    add     rbx, 16
    jmp     .next
.run:
    call    [rbx + 8]
    jmp     .prompt

.unknown:
    lea     rdi, [rel unknown]
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
bad_boot:          db "Invalid Multiboot bootloader magic.", 10, 0
help_text:         db "help    Show console commands", 10
                   db "info    Show CPU and usable memory information", 10
                   db "cpu     Show boot CPU capabilities and processors started", 10
                   db "memmap  Show the Multiboot memory map", 10
                   db "uptime  Show time since boot", 10
                   db "log     Show boot milestones", 10
                   db "version Show the kernel version and build identifier", 10
                   db "clear   Clear the console", 10
                   db "reboot  Restart the machine", 10
                   db "halt    Power off the machine", 10, 0
info_text:         db "Architecture: x86-64", 10, 0
cpu_count_text:    db "CPUs started: ", 0
memory_text:       db "Usable memory: ", 0
mib_text:          db " MiB", 10, 0
uptime_text:       db "Uptime: ", 0
milliseconds_text: db " ms", 10, 0
poweroff_text:     db "Powering off...", 10, 0
reboot_text:       db "Rebooting...", 10, 0
reboot_failed:     db "Reboot failed.", 10, 0
version_text:      db "Bare Metal OS 1.0.0 (x86-64)", 10, "Build: ", BUILD_ID, 10, 0
log_text:          db "Boot log", 10, 0
event_multiboot:   db "Multiboot handoff accepted.", 10, 0
event_timer:       db "Timer initialized.", 10, 0
event_smp:         db "CPU startup complete.", 10, 0
event_console:     db "Console input ready.", 10, 0

help_name:         db "help", 0
info_name:         db "info", 0
cpu_name:          db "cpu", 0
memmap_name:       db "memmap", 0
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
    dq help_name, command_help
    dq info_name, command_info
    dq cpu_name, command_cpu
    dq memmap_name, command_memmap
    dq uptime_name, command_uptime
    dq log_name, command_log
    dq version_name, command_version
    dq clear_name, console_clear
    dq reboot_name, command_reboot
    dq halt_name, command_halt
    dq quit_name, command_halt
    dq exit_name, command_halt
    dq 0

section .bss
alignb 8
boot_log:          resq BOOT_LOG_CAPACITY
boot_log_count:    resd 1
boot_cpus_started: resd 1
boot_cpus_total:   resd 1
line_buffer:       resb LINE_BUF_SIZE
