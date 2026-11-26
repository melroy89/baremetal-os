#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

source tests/qemu_serial.sh

check_memory() {
    local stack_pages=$((cpus - 1))
    printf 'mem\r' >&"$serial_write"
    expect_serial "4 KiB pages: ([1-9][0-9]*) managed, $stack_pages used, ([1-9][0-9]*) free"$'\r?\n'
    if (( BASH_REMATCH[1] != BASH_REMATCH[2] + stack_pages )); then
        printf 'Managed page count does not match free pages plus stack pages\n' >&2
        return 1
    fi
    expect_serial 'baremetal> '
}

check_console() {
    expect_serial 'Bare Metal OS \| x86-64'
    expect_serial 'baremetal> '

    printf 'version\r' >&"$serial_write"
    expect_serial 'Bare Metal OS [0-9]+\.[0-9]+\.[0-9]+ \(x86-64\)'
    expect_serial "Build: $build_id"$'\r?\n'
    expect_serial 'baremetal> '

    printf 'info\r' >&"$serial_write"
    expect_serial "CPUs started: $cpus/$cpus"$'\r?\n'
    expect_serial "Secondary CPU stack pages: $((cpus - 1))"$'\r?\n'
    expect_serial 'baremetal> '

    check_memory
}

check_smoke() {
    check_console
    check_cpu_ping
    if [[ $1 == -kernel ]]; then
        printf 'reboot\r' >&"$serial_write"
        expect_serial 'Rebooting\.\.\.'
        check_console
    fi
}

check_cpu_ping() {
    local attempt ap
    for attempt in 1 2; do
        printf 'cpu ping\r' >&"$serial_write"
        if (( cpus == 1 )); then
            expect_serial 'No online secondary CPUs\.'
        else
            for ((ap = 1; ap < cpus; ap++)); do
                expect_serial "APIC ID $ap: replied"$'\r?\n'
            done
            expect_serial "Secondary CPUs replied: $((cpus - 1))/$((cpus - 1))"$'\r?\n'
        fi
        expect_serial 'baremetal> '
    done
}

build_id_pattern='^%define BUILD_ID "([0-9a-f]{12})"$'
if ! IFS= read -r build_id_line < build/build_id.inc || [[ ! $build_id_line =~ $build_id_pattern ]]; then
    printf 'Expected a generated build ID in build/build_id.inc\n' >&2
    exit 1
fi
build_id=${BASH_REMATCH[1]}

run_guest 'Direct kernel' 1 64M check_smoke -kernel build/baremetal-os.elf
run_guest 'Direct kernel SMP' 4 64M check_smoke -kernel build/baremetal-os.elf
iso=(-cdrom build/baremetal-os.iso -boot d)
run_guest 'SeaBIOS ISO' 1 64M check_smoke "${iso[@]}"
run_guest 'OVMF ISO' 1 128M check_smoke -bios /usr/share/ovmf/OVMF.fd "${iso[@]}"
