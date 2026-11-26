#!/usr/bin/env bash
set -euo pipefail
source tests/qemu_serial.sh
export QEMU_TEST_ACCEL=kvm

check_tap() {
    expect_serial 'baremetal> '
    printf 'net static 192.0.2.10/24\r' >&"$serial_write"
    expect_serial 'IPv4: static'
    expect_serial 'baremetal> '
    ping -I bo-tap -c 3 -w 6 192.0.2.10
    printf 'ping 192.0.2.1\r' >&"$serial_write"
    expect_serial 'Reply from 192\.0\.2\.1'
    expect_serial 'baremetal> '
}

# Make invokes this script in its own user and network namespaces.
ip tuntap add dev bo-tap mode tap
ip address add 192.0.2.1/24 dev bo-tap
ip link set dev bo-tap up
run_guest 'bidirectional IPv4 over an isolated TAP' 1 64M check_tap \
    -machine pc -cpu host -kernel "${1:-build}/baremetal-os.elf" \
    -netdev tap,id=wire,ifname=bo-tap,script=no,downscript=no \
    -device e1000,netdev=wire,mac=52:54:00:12:34:56
