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
    printf 'cpu ping\r' >&"$serial_write"
    expect_serial 'No online secondary CPUs\.'
    expect_serial 'baremetal> '
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
            check_delayed_ping
            return
        fi
        sleep 0.02
    done

    printf 'Secondary CPUs did not check in after the test gate opened\n' >&2
    return 1
}

check_ping_result() {
    local status=$1 replies=$2
    printf 'cpu ping\r' >&"$serial_write"
    expect_serial "APIC ID 1: $status"$'\r?\n'
    expect_serial $'APIC ID 2: replied\r?\n'
    expect_serial $'APIC ID 3: replied\r?\n'
    expect_serial "Secondary CPUs replied: $replies/3"$'\r?\n'
    expect_serial 'baremetal> '
}

check_delayed_ping() {
    check_ping_result 'timed out' 2
    check_ping_result 'timed out waiting to retry' 2

    printf 'ping-go\r' >&"$serial_write"
    expect_serial 'baremetal> '
    # Release the old reply during recovery, then drop the fresh IPI.
    check_ping_result 'timed out' 2
    check_ping_result 'replied' 3
}

check_lost_ping() {
    expect_serial 'baremetal> '
    check_ping_result 'IPI send failed' 2
    check_ping_result 'timed out' 2
    check_ping_result 'timed out waiting to retry' 2
    check_ping_result 'replied' 3
}

check_crc_worker() {
    local deadline result
    expect_serial 'baremetal> '
    printf 'echo 123456789 > /ram/test.txt\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'crc32 test.txt\r' >&"$serial_write"
    expect_serial $'\r?\nE0117756\r?\nbaremetal> '

    # A lost wake cancels an unclaimed job. The following request is
    # claimed by the worker but delayed past the timeout.
    printf 'crc32 test.txt\r' >&"$serial_write"
    expect_serial $'\r?\nE0117757\r?\nbaremetal> '
    printf 'crc32 test.txt\r' >&"$serial_write"
    expect_serial $'\r?\nE0117757\r?\nbaremetal> '
    check_ping_result 'replied' 3

    printf 'echo replacement > /ram/test.txt\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'crc32 test.txt\r' >&"$serial_write"
    expect_serial $'\r?\nA48A7BE9\r?\nbaremetal> '
    printf 'crc-go\r' >&"$serial_write"
    expect_serial 'baremetal> '

    deadline=$((SECONDS + 3))
    while (( SECONDS < deadline )); do
        printf 'crc32 test.txt\r' >&"$serial_write"
        expect_serial $'\r?\n(A48A7BE[89]|FFFFFFFF)\r?\n'
        result=${BASH_REMATCH[1]}
        expect_serial 'baremetal> '
        case "$result" in
            A48A7BE8) return 0 ;;
            FFFFFFFF)
                printf 'The delayed worker read overwritten file data\n' >&2
                return 1
                ;;
        esac
        sleep 0.02
    done
    printf 'The CRC-32 worker did not become available after completing its delayed job\n' >&2
    return 1
}

build_dir=${1:-build}
run_guest 'SMP without a Multiboot memory map' 4 64M check_missing_map \
    -kernel "$build_dir/smp-fixture-missing_map.elf"
run_guest 'SMP with one allocatable page' 4 64M check_one_page \
    -kernel "$build_dir/smp-fixture-one_page.elf"
run_guest 'SMP with delayed secondary CPUs' 4 64M check_delayed_aps \
    -kernel "$build_dir/smp-fixture-delayed_ap.elf"
run_guest 'SMP with rejected and lost ping IPIs' 4 64M check_lost_ping \
    -kernel "$build_dir/smp-fixture-lost_ping.elf"
run_guest 'CRC-32 worker dispatch, timeout and recovery' 4 64M check_crc_worker \
    -kernel "$build_dir/smp-fixture-crc32_work.elf"
