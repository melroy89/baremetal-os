#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

source tests/qemu_serial.sh

console_check() {
    printf '%s\r' "$1" >&"$serial_write"
    expect_serial "$2"
    expect_serial 'baremetal> '
}

check_no_nic() {
    expect_serial 'baremetal> '
    console_check 'net info' 'QEMU e1000 NIC unavailable\.'
}

check_network() {
    local attempt frame link peer wire_in wire_out
    expect_serial 'baremetal> '
    # O_RDWR keeps the FIFOs open while socat establishes the Unix socket.
    exec {wire_in}<>"$files/to-guest" {wire_out}<>"$files/from-guest"
    timeout 45 socat - "UNIX-CONNECT:$files/wire" <&"$wire_in" >&"$wire_out" &
    peer=$!

    for attempt in {1..20}; do
        printf 'net info\r' >&"$serial_write"
        expect_serial $'PCI: 00:07\\.0\r?\nMAC: 52:54:00:12:34:56\r?\nLink: (up|down)\r?\n'
        link=${BASH_REMATCH[1]}
        expect_serial 'baremetal> '
        if [[ $link == up ]]; then
            break
        fi
        sleep 0.2
    done
    if [[ $link != up ]]; then
        printf 'Timed out waiting for the isolated link\n' >&2
        return 1
    fi

    console_check 'net recv' 'Ethernet receive timed out\.'
    console_check 'echo Test > payload' 'echo Test > payload'
    console_check 'net send 52:54:00:AB:CD 88B5 payload' 'Usage: net info'
    for frame in {1..9}; do
        cat "$files/inbound" >&"$wire_in"
        console_check 'net recv' \
            $'Frame: 60 bytes\r?\nDestination: 52:54:00:12:34:56\r?\nSource: 52:54:00:AB:CD:EF\r?\nEtherType: 88B5\r?\n'
        console_check 'net send 52:54:00:AB:CD:EF 88B5 payload' 'Sent 60 bytes\.'
        timeout 5 dd bs=64 count=1 iflag=fullblock of="$files/captured" status=none <&"$wire_out"
        cmp "$files/expected" "$files/captured"
    done
    kill "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
}

files=$(mktemp -d)
trap 'find "$files" -depth -delete' EXIT
kernel="${1:-build}/baremetal-os.elf"
mkfifo "$files/to-guest" "$files/from-guest"
# QEMU stream packets have a four-byte big-endian length before Ethernet.
printf '\000\000\000\074\122\124\000\022\064\126\122\124\000\253\315\357\210\265%046d' 0 > "$files/inbound"
printf '\000\000\000\074\122\124\000\253\315\357\122\124\000\022\064\126\210\265Test\n' > "$files/expected"
dd if=/dev/zero bs=41 count=1 status=none >> "$files/expected"

run_guest 'e1000 absent' 1 64M check_no_nic -machine pc -kernel "$kernel"
run_guest 'e1000 Ethernet frame I/O' 1 64M check_network -machine pc -kernel "$kernel" \
    -device e1000,netdev=wire,addr=0x7,mac=52:54:00:12:34:56 \
    -netdev "stream,id=wire,server=on,addr.type=unix,addr.path=$files/wire"
