#!/usr/bin/env bash
# Separate from CI. Run via make bench-network in isolated user/net namespaces.
set -euo pipefail
export LC_ALL=C QEMU_TEST_ACCEL=kvm
source tests/qemu_serial.sh

cpu_ticks() {
    awk '{print $14 + $15}' "/proc/$qemu_pid/stat"
}

check_network_bench() {
    local before after received elapsed hz
    local -a args=(-I bo-tap -q -s 1472 192.0.2.10)
    expect_serial 'baremetal> '
    printf 'net static 192.0.2.10/24\r' >&"$serial_write"
    expect_serial 'IPv4: static'
    expect_serial 'baremetal> '
    printf 'net info\r' >&"$serial_write"
    expect_serial "Driver: $driver"
    expect_serial 'baremetal> '
    # Warm ARP and the virtual link before timing.
    ping -I bo-tap -c 3 -w 6 192.0.2.10 >/dev/null
    printf '%s idle latency\n' "$driver"
    ping -c 20 -i 0.1 -w 4 "${args[@]}"

    printf '%s sustained bidirectional echo traffic\n' "$driver"
    before=$(cpu_ticks)
    local start
    start=$(date +%s%N)
    ping -f -w 5 "${args[@]}" | tee "$files/ping"
    elapsed=$(( $(date +%s%N) - start ))
    after=$(cpu_ticks)
    received=$(awk '/packets transmitted/ {print $4}' "$files/ping")
    hz=$(getconf CLK_TCK)
    awk -v n="$received" -v ns="$elapsed" -v ticks="$((after - before))" -v hz="$hz" \
        'BEGIN {printf "Echo payload %.3f Mbit/s each way, QEMU %.2f%% of one host CPU\n",n*1472*8e3/ns,ticks*1e11/(ns*hz)}'

    printf 'mount -t ext2 -o ro disk0p1 /ext\r' >&"$serial_write"
    expect_serial 'Ext2 mounted read-only'
    expect_serial 'baremetal> '
    printf 'crc32range 0 16777216 /ext/Payload\r' >&"$serial_write"
    expect_serial $'crc32range 0 16777216 /ext/Payload\r?\n'
    printf '%s latency during ext2 ATA read\n' "$driver"
    ping -c 20 -i 0.1 -w 4 "${args[@]}"
    expect_serial "$expected_crc"$'\r?\n'
    expect_serial 'baremetal> '
}

files=$(mktemp -d)
trap 'find "$files" -depth -delete' EXIT
ip tuntap add dev bo-tap mode tap
ip address add 192.0.2.1/24 dev bo-tap
ip link set dev bo-tap up

dd if=/dev/urandom of="$files/Payload" bs=1M count=16 status=none
expected_crc=$(gzip -n < "$files/Payload" |
    tail -c 8 | od -An -N4 -t x4 | tr -d ' \n' | tr 'a-f' 'A-F')
truncate -s 24M "$files/volume"
mke2fs -q -F -t ext2 -b 4096 "$files/volume"
debugfs -w -R "write $files/Payload /Payload" "$files/volume" >"$files/debug.log" 2>&1
truncate -s 28M "$files/disk"
sgdisk -n 1:2048:+24M "$files/disk" >/dev/null
dd if="$files/volume" of="$files/disk" bs=1M seek=1 conv=sparse,notrunc status=none

kernel="${1:-build}/baremetal-os.elf"
for driver in e1000 virtio-net; do
    model=$driver
    [[ $driver != virtio-net ]] || model=virtio-net-pci,disable-legacy=on
    run_guest "$driver KVM comparison" 1 64M check_network_bench \
        -machine pc -cpu host -kernel "$kernel" \
        -drive "file=$files/disk,if=ide,format=raw,cache=none" \
        -netdev tap,id=wire,ifname=bo-tap,script=no,downscript=no,vhost=off \
        -device "$model,netdev=wire,mac=52:54:00:12:34:56"
done
