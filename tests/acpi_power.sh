#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
source tests/qemu_serial.sh

mount_writable() {
    expect_serial 'baremetal> '
    printf 'mount %s /ext\r' "${partition:-disk0p1}" >&"$serial_write"
    expect_serial 'Ext2 mounted read-write'
    expect_serial 'baremetal> '
}

request_powerdown() {
    python3 - "$files/qmp" "$1" <<'PYQMP'
import json
import socket
import sys

with socket.socket(socket.AF_UNIX) as sock:
    sock.settimeout(10)
    sock.connect(sys.argv[1])
    with sock.makefile("rwb") as qmp:
        assert "QMP" in json.loads(qmp.readline())
        shutdown = None
        for command in ("qmp_capabilities", "system_powerdown"):
            qmp.write(json.dumps({"execute": command}).encode() + b"\n")
            qmp.flush()
            while True:
                message = json.loads(qmp.readline())
                if message.get("event") == "SHUTDOWN":
                    shutdown = message["data"]
                elif "return" in message:
                    break
                else:
                    assert "error" not in message, message
        if sys.argv[2] == "wait":
            while shutdown is None:
                message = json.loads(qmp.readline())
                if message.get("event") == "SHUTDOWN":
                    shutdown = message["data"]
            assert shutdown == {"guest": True, "reason": "guest-shutdown"}, shutdown
PYQMP
}

check_shutdown() {
    mount_writable
    printf 'echo %s > /ext/sentinel\r' "$sentinel" >&"$serial_write"
    if [[ $sentinel == GATE ]]; then
        expect_serial 'Test write awaiting host power request'
    else
        expect_serial 'Ext2 file saved'
        expect_serial 'baremetal> '
    fi
    request_powerdown wait
    if [[ $sentinel == GATE ]]; then
        expect_serial 'Ext2 file saved'
    fi
    expect_serial 'Powering off'
}

check_flush_failure() {
    mount_writable
    printf 'echo GATEFAIL > /ext/sentinel\r' >&"$serial_write"
    expect_serial 'Test write awaiting host power request'
    request_powerdown async
    expect_serial 'Ext2 file saved'
    expect_serial 'Test shutdown flush failed'
    expect_serial 'baremetal> '
    printf 'cat /ext/sentinel\r' >&"$serial_write"
    expect_serial $'\nGATEFAIL\r?\n'
    expect_serial 'baremetal> '
    printf 'umount /ext\r' >&"$serial_write"
    expect_serial 'Ext2 unmounted dirty'
    expect_serial 'baremetal> '
}

files=$(mktemp -d)
trap 'find "$files" -depth -delete' EXIT
build_dir=$1
truncate -s 16M "$files/ext"
mkfs.ext2 -q -F "$files/ext"
truncate -s 20M "$files/base"
sgdisk -n 1:2048:+16M "$files/base" >/dev/null
dd if="$files/ext" of="$files/base" bs=1M seek=1 conv=sparse,notrunc status=none
monitor=(-qmp "unix:$files/qmp,server=on,wait=off")
ata=(-drive "file=$files/disk,if=ide,format=raw,cache=directsync")
virtio=(-drive "file=$files/disk,if=none,id=vd,format=raw,cache=directsync"
    -device virtio-blk-pci,drive=vd,disable-legacy=on)

for machine in pc q35; do
    cp --sparse=always "$files/base" "$files/disk"
    sentinel=saved
    partition=disk0p1
    drive=("${ata[@]}")
    kernel="$build_dir/baremetal-os.elf"
    if [[ $machine == q35 ]]; then
        sentinel=GATE
        partition=disk1p1
        drive=("${virtio[@]}")
        kernel="$build_dir/acpi-power-fixture.elf"
    fi
    QEMU_TEST_EXTERNAL_SHUTDOWN=1 run_guest "$machine ACPI powerdown preserves ext2" 1 64M \
        check_shutdown -machine "$machine" -kernel "$kernel" "${drive[@]}" "${monitor[@]}"
    dd if="$files/disk" of="$files/output" bs=1M skip=1 count=16 status=none
    e2fsck -fn "$files/output"
    dumpe2fs -h "$files/output" 2>/dev/null | grep -E '^Filesystem state:[[:space:]]+clean$'
    debugfs -R 'cat /sentinel' "$files/output" 2>/dev/null | cmp - <(printf '%s\n' "$sentinel")
done

cp --sparse=always "$files/base" "$files/disk"
partition=disk0p1 run_guest 'ACPI powerdown during a write recovers from a shutdown flush failure' 1 64M check_flush_failure \
    -machine pc -kernel "$build_dir/acpi-power-fixture.elf" "${ata[@]}" "${monitor[@]}"
