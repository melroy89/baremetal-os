#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

source tests/qemu_serial.sh

check_cpu_status() {
    printf 'info\r' >&"$serial_write"
    expect_serial "CPUs started: $1/4"$'\r?\n'
    expect_serial "Secondary CPU stack pages: $2"$'\r?\n'
    expect_serial "Usable memory: $3 MiB"$'\r?\n'
    expect_serial 'baremetal> '
}

check_page_status() {
    printf 'mem\r' >&"$serial_write"
    expect_serial "4 KiB pages: $1 managed, $2 used, $3 free"$'\r?\n'
    expect_serial 'baremetal> '
}

check_missing_map() {
    expect_serial 'baremetal> '
    check_cpu_status 4 3 '[1-9][0-9]*'
    check_page_status 0 0 0
}

check_one_page() {
    expect_serial 'baremetal> '
    check_cpu_status 4 3 0
    check_page_status 1 0 1
}

check_delayed_aps() {
    local deadline online
    expect_serial 'baremetal> '
    check_cpu_status 1 3 '[1-9][0-9]*'
    printf 'go\r' >&"$serial_write"
    expect_serial 'baremetal> '

    deadline=$((SECONDS + 3))
    while (( SECONDS < deadline )); do
        printf 'info\r' >&"$serial_write"
        expect_serial 'CPUs started: ([1-4])/4'$'\r?\n'
        online=${BASH_REMATCH[1]}
        expect_serial 'Secondary CPU stack pages: 3'$'\r?\n'
        expect_serial 'baremetal> '
        if (( online == 4 )); then
            check_page_status '[1-9][0-9]*' 3 '[1-9][0-9]*'
            return
        fi
        sleep 0.02
    done

    printf 'Secondary CPUs did not check in after the test gate opened\n' >&2
    return 1
}

build_dir=${1:-build}
run_guest 'SMP without a Multiboot memory map' 4 64M check_missing_map \
    -kernel "$build_dir/smp-fixture-missing_map.elf"
run_guest 'SMP with one allocatable page' 4 64M check_one_page \
    -kernel "$build_dir/smp-fixture-one_page.elf"
run_guest 'SMP with delayed secondary CPUs' 4 64M check_delayed_aps \
    -kernel "$build_dir/smp-fixture-delayed_ap.elf"
