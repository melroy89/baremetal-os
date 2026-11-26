#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
export QEMU_TEST_ACCEL=kvm
source tests/qemu_serial.sh

check_benchmark() {
    expect_serial 'baremetal> '
    printf 'mount -t ext2 -o ro disk0p1 /ext\r' >&"$serial_write"
    expect_serial 'Ext2 mounted read-only\.'
    expect_serial 'baremetal> '
    printf 'crc32range 0 16777216 /ext/Bench\r' >&"$serial_write"
    expect_serial $'Read ns: ([0-9]+)\r?\n'
    local nanos=${BASH_REMATCH[1]}
    expect_serial "$crc"$'\r?\n'
    expect_serial 'baremetal> '
    awk -v kib="$kib" -v ns="$nanos" 'BEGIN {printf "%d KiB  %.2f MiB/s (16 MiB in %.3f s)\n", kib, 16e9/ns, ns/1e9}'
}

files=$(mktemp -d)
trap 'find "$files" -depth -delete' EXIT
dd if=/dev/urandom of="$files/Bench" bs=1M count=16 status=none
crc=$(gzip -n <"$files/Bench" | tail -c 8 | od -An -N4 -t x4 | tr -d ' \n' | tr 'a-f' 'A-F')
truncate -s 32M "$files/volume"
mke2fs -q -F -t ext2 -b 4096 -I 256 "$files/volume"
debugfs -w -R "write $files/Bench /Bench" "$files/volume" >"$files/debug.log" 2>&1
truncate -s 36M "$files/disk"
sgdisk -n 1:2048:+32M "$files/disk" >/dev/null
dd if="$files/volume" of="$files/disk" bs=512 seek=2048 conv=sparse,notrunc status=none
for kib in 4 16 64; do
    run_guest "ext2 benchmark with $kib KiB reads" 1 64M check_benchmark -machine pc -cpu host \
        -kernel "${1:-build}/ext2-bench-$kib.elf" \
        -drive "file=$files/disk,if=ide,format=raw,cache=none"
done
