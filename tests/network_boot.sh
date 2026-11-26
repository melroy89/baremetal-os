#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

source tests/qemu_serial.sh
source tests/ipv4_cases.sh

console_check() {
    printf '%s\r' "$1" >&"$serial_write"
    expect_serial "$2"
    expect_serial 'baremetal> '
}

check_no_nic() {
    expect_serial 'baremetal> '
    [[ $transcript != *'NIC unavailable'* && $transcript != *'IPv4: DHCP'* ]]
    console_check 'net info' 'QEMU e1000 NIC unavailable\.'
}

check_boot_dhcp() {
    local attempt
    expect_serial 'baremetal> '
    console_check 'net info' "Driver: $driver"
    for attempt in {1..15}; do
        printf 'net info\r' >&"$serial_write"
        expect_serial 'IPv4: DHCP'
        expect_serial 'baremetal> '
        if [[ $transcript == *'Address: 10.0.2.15/24'* ]]; then
            console_check 'ping 10.0.2.2' 'Reply from 10\.0\.2\.2'
            return
        fi
        sleep 0.5
    done
    printf 'Boot DHCP did not obtain a lease\n' >&2
    return 1
}

check_fallback() {
    expect_serial 'baremetal> '
    console_check 'net info' 'Driver: e1000'
}

check_network() {
    local attempt frame link peer wire_in wire_out
    expect_serial 'baremetal> '
    console_check 'net off' 'IPv4: off'
    connect_wire 45

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
    console_check 'echo Test > /ram/payload' 'echo Test > /ram/payload'
    console_check 'net send 52:54:00:AB:CD 88B5 payload' 'Usage: net info'
    for frame in {1..9}; do
        cat "$files/inbound" >&"$wire_in"
        console_check 'net recv' \
            $'Frame: 60 bytes\r?\nDestination: 52:54:00:12:34:56\r?\nSource: 52:54:00:AB:CD:EF\r?\nEtherType: 88B5\r?\n'
        console_check 'net send 52:54:00:AB:CD:EF 88B5 payload' 'Sent 60 bytes\.'
        timeout 5 dd bs=64 count=1 iflag=fullblock of="$files/captured" status=none <&"$wire_out"
        cmp "$files/expected" "$files/captured"
    done
    cat "$files/inbound-max" >&"$wire_in"
    console_check 'net recv' 'Frame: 1514 bytes'
    console_check 'net send 52:54:00:AB:CD:EF 88B5 maximum.bin' 'Sent 1514 bytes'
    timeout 5 dd bs=1518 count=1 iflag=fullblock of="$files/captured" status=none <&"$wire_out"
    cmp "$files/expected-max" "$files/captured"
    kill "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
}

files=$(mktemp -d)
trap 'find "$files" -depth -delete' EXIT
build_dir="${1:-build}"
kernel="$build_dir/baremetal-os.elf"
mkfifo "$files/to-guest" "$files/from-guest"
# QEMU stream packets have a four-byte big-endian length before Ethernet.
printf '\000\000\000\074\122\124\000\022\064\126\122\124\000\253\315\357\210\265%046d' 0 > "$files/inbound"
printf '\000\000\000\074\122\124\000\253\315\357\122\124\000\022\064\126\210\265Test\n' > "$files/expected"
dd if=/dev/zero bs=41 count=1 status=none >> "$files/expected"
{
    printf 'bulk-start\n'
    for ((row = 0; row < 4096; row++)); do
        printf '%064d\n' "$row"
    done
    printf 'bulk-end\n'
} > "$files/bulk.txt"
printf 'XY' > "$files/checksum.bin"
printf 'Z' | dd of="$files/checksum.bin" bs=1 seek=67108864 conv=notrunc status=none
ram_range_crc=$(tail -c +2 "$files/checksum.bin" |
    gzip -n | tail -c 8 | od -An -N4 -t x4 | tr -d ' \n' | tr 'a-f' 'A-F')
ram_file_crc=$(gzip -n < "$files/checksum.bin" |
    tail -c 8 | od -An -N4 -t x4 | tr -d ' \n' | tr 'a-f' 'A-F')
tar --format=ustar -C "$files" -cf "$files/bulk.tar" bulk.txt checksum.bin
printf "%01500d" 42 > "$files/maximum.bin"
tar --format=ustar -C "$files" -cf "$files/maximum.tar" maximum.bin
printf "\\000\\000\\005\\352\\122\\124\\000\\022\\064\\126\\122\\124\\000\\253\\315\\357\\210\\265" > "$files/inbound-max"
printf "\\000\\000\\005\\352\\122\\124\\000\\253\\315\\357\\122\\124\\000\\022\\064\\126\\210\\265" > "$files/expected-max"
cat "$files/maximum.bin" >> "$files/inbound-max"
cat "$files/maximum.bin" >> "$files/expected-max"


run_guest 'NIC absent' 1 64M check_no_nic -machine pc -kernel "$kernel"

run_adapter() {
    local nic_model=$1 adapter driver
    case $nic_model in
        e1000) adapter=e1000 driver=e1000 ;;
        virtio) adapter=virtio-net-pci,disable-legacy=on driver=virtio-net ;;
    esac
    local -a stream=(
        -machine pc -device "$adapter,netdev=wire,addr=0x7,mac=52:54:00:12:34:56"
        -netdev "stream,id=wire,server=on,addr.type=unix,addr.path=$files/wire"
    )
    run_guest "$driver Ethernet frame I/O" 1 64M check_network -kernel "$kernel" -initrd "$files/maximum.tar" "${stream[@]}"
    run_guest "$driver IPv4, ARP, ICMP and DNS" 1 128M check_ipv4 -cpu max -kernel "$kernel" \
        -initrd "$files/bulk.tar" "${stream[@]}"
    run_guest "$driver DHCP renewal, rebinding, expiry, and conflict" 1 64M check_dhcp -cpu max \
        -kernel "$build_dir/network-fixture.elf" "${stream[@]}"
}

driver=e1000 run_guest 'automatic DHCP on e1000' 1 64M check_boot_dhcp \
    -machine pc -kernel "$kernel" -device e1000,netdev=wire -netdev user,id=wire
run_adapter e1000
run_adapter virtio

run_guest 'virtio initialization falls back to e1000' 1 64M check_fallback -machine pc -kernel "$kernel" \
    -device virtio-net-pci,disable-modern=on,netdev=legacy,addr=0x6 -netdev user,id=legacy \
    -device e1000,netdev=wire,addr=0x7 -netdev user,id=wire
driver=virtio-net run_guest 'virtio gets a DHCP lease after skipping a legacy-only adapter' \
    1 64M check_boot_dhcp -machine pc -kernel "$kernel" \
    -device virtio-net-pci,disable-modern=on,netdev=legacy,addr=0x6 -netdev user,id=legacy \
    -device virtio-net-pci,disable-legacy=on,netdev=wire,addr=0x7 -netdev user,id=wire

check_virtio_retry() {
    local peer wire_in wire_out sender attempt
    expect_serial 'baremetal> '
    # The first net recv must trigger initialization.
    connect_wire 10
    (
        for attempt in {1..5}; do
            sleep 0.1
            cat "$files/inbound" >&"$wire_in"
        done
    ) &
    sender=$!
    console_check 'net recv' 'EtherType: 88B5'
    console_check 'net info' 'Driver: virtio-net'
    wait "$sender"
    kill "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
}

run_guest 'virtio first raw receive retries initialization with an odd ISR' 1 64M check_virtio_retry \
    -machine pc -kernel "$build_dir/virtio-retry.elf" \
    -device virtio-net-pci,disable-legacy=on,netdev=wire,addr=0x7,mac=52:54:00:12:34:56 \
    -netdev "stream,id=wire,server=on,addr.type=unix,addr.path=$files/wire"

run_guest 'DNS without RDRAND' 1 64M check_dns_no_feature -machine pc -cpu max,-rdrand -kernel "$kernel" \
    -device e1000,netdev=wire,addr=0x7,mac=52:54:00:12:34:56 \
    -netdev "stream,id=wire,server=on,addr.type=unix,addr.path=$files/wire"
run_guest 'DNS entropy retry and port collision' 1 64M check_dns_fault \
    -machine pc -cpu max -kernel "$build_dir/dns-fault.elf" \
    -device e1000,netdev=wire,addr=0x7,mac=52:54:00:12:34:56 \
    -netdev "stream,id=wire,server=on,addr.type=unix,addr.path=$files/wire"

check_virtio_queue() {
    local peer wire_in wire_out frame number header
    expect_serial 'baremetal> '
    console_check 'net off' 'IPv4: off'
    start_wire
    cat "$files/inbound" >&"$wire_in"
    console_check 'net recv' 'EtherType: 88B5'
    console_check 'queue-test' 'Test: Virtio TX backpressure recovered\.'
    for number in {0..8}; do
        wire_receive
        [[ ${#frame} == 120 && ${frame:0:28} == 525400abcdef52540012345688b5 ]]
        printf -v header '%02x' "$number"
        [[ ${frame:28:2} == "$header" ]]
    done
    kill "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
}

run_guest 'virtio TX backpressure, completion and reuse' 1 64M check_virtio_queue \
    -machine pc -kernel "$build_dir/virtio-queue.elf" \
    -device virtio-net-pci,disable-legacy=on,netdev=wire,addr=0x7,mac=52:54:00:12:34:56 \
    -netdev "stream,id=wire,server=on,addr.type=unix,addr.path=$files/wire"
