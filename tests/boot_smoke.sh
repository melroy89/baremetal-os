#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

expect_serial() {
    local pattern=$1 char received= remaining
    local deadline=$((SECONDS + 30))

    while (( (remaining = deadline - SECONDS) > 0 )) &&
        IFS= read -r -N 1 -t "$remaining" -u "$serial_read" char; do
        received+=$char
        transcript+=$char
        if [[ $received =~ $pattern ]]; then
            return 0
        fi
    done

    printf 'Serial output did not contain %q\n' "$pattern" >&2
    return 1
}

check_memory() {
    printf 'mem\r' >&"$serial_write"
    expect_serial '4 KiB pages: ([1-9][0-9]*) managed, 0 used, ([1-9][0-9]*) free'$'\r?\n'
    if [[ ${BASH_REMATCH[1]} != "${BASH_REMATCH[2]}" ]]; then
        printf 'Expected all managed pages to be free after boot\n' >&2
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
    expect_serial 'baremetal> '

    check_memory
}

cleanup_guest() {
    local status=$?
    if [[ -n $qemu_pid ]]; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi
    if (( status != 0 )); then
        printf '%s serial output: %q\n' "$label" "$transcript" >&2
    fi
}

check_boot() (
    local label=$1 cpus=$2 ram=$3
    shift 3
    local qemu_pid= serial_read serial_write transcript= remainder= status=0

    printf 'Booting %s with %s vCPU(s)\n' "$label" "$cpus"
    trap cleanup_guest EXIT
    coproc GUEST {
        exec qemu-system-x86_64 -accel tcg -m "$ram" -smp "$cpus" -nic none \
            -display none -serial stdio -monitor none "$@"
    }
    qemu_pid=$!
    # Keep both pipes open while Bash reaps the coprocess.
    exec {serial_read}<&"${GUEST[0]}" {serial_write}>&"${GUEST[1]}"

    check_console
    if [[ $1 == -kernel ]]; then
        printf 'reboot\r' >&"$serial_write"
        expect_serial 'Rebooting\.\.\.'
        check_console
    fi

    printf 'halt\r' >&"$serial_write"
    expect_serial $'Powering off\\.\\.\\.\r?\n'
    IFS= read -r -d '' -t 30 -u "$serial_read" remainder || status=$?
    transcript+=$remainder
    if (( status != 1 )); then
        printf 'Expected QEMU to close the serial console after halt\n' >&2
        exit 1
    fi
    status=0
    wait "$qemu_pid" || status=$?
    qemu_pid=
    if (( status != 0 )); then
        printf 'QEMU exited with status %d\n' "$status" >&2
        exit "$status"
    fi
    printf '%s passed\n' "$label"
)

build_id_pattern='^%define BUILD_ID "([0-9a-f]{12})"$'
if ! IFS= read -r build_id_line < build/build_id.inc || [[ ! $build_id_line =~ $build_id_pattern ]]; then
    printf 'Expected a generated build ID in build/build_id.inc\n' >&2
    exit 1
fi
build_id=${BASH_REMATCH[1]}

check_boot 'Direct kernel' 4 64M -kernel build/baremetal-os.elf
iso=(-cdrom build/baremetal-os.iso -boot d)
check_boot 'SeaBIOS ISO' 1 64M "${iso[@]}"
check_boot 'OVMF ISO' 1 128M -bios /usr/share/ovmf/OVMF.fd "${iso[@]}"
