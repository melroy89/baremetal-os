#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
source tests/qemu_serial.sh

console_check() {
    printf '%s\r' "$1" >&"$serial_write"
    expect_serial "$2"
    expect_serial 'baremetal> '
}

mount_pair() {
    expect_serial 'baremetal> '
    console_check "mount -t ext2 -o ro disk${source_disk}p1 /src" 'Ext2 mounted read-only'
    console_check "mount -t ext2 disk${target_disk}p1 /dst" 'Ext2 mounted read-write'
}

check_stream_fault() {
    mount_pair
    console_check 'cp /src/Source /dst/Target' 'Test: ext2 I/O error'
    console_check 'echo Refused > /dst/Other' 'Ext2 writes are blocked'
    console_check 'cat /dst/Target' $'\r?\nOld\r?\n'
    console_check 'umount /dst' 'Ext2 unmounted dirty'
}

check_repaired_mount() {
    expect_serial 'baremetal> '
    console_check "mount -t ext2 disk${target_disk}p1 /dst" 'Ext2 mounted read-write'
    console_check 'umount /dst' 'Ext2 unmounted'
}

check_power_cut() {
    mount_pair
    printf 'cp /src/Source /dst/Target\r' >&"$serial_write"
    expect_serial 'Test: ext2 flush complete'
}

check_rename_cut() {
    expect_serial 'baremetal> '
    console_check 'mount -t ext2 disk0p1 /dst' 'Ext2 mounted read-write'
    printf 'mv /dst/Target /dst/Sub/Moved\r' >&"$serial_write"
    expect_serial 'Test: ext2 flush complete'
}

check_sparse_triple() {
    expect_serial 'baremetal> '
    console_check 'mount -t ext2 disk0p1 /dst' 'Ext2 mounted read-write'
    console_check 'cp /dst/Huge /dst/Copy' 'Ext2 file saved'
    console_check 'stat /dst/Copy' "Size: $huge_size"
    console_check 'stat /dst/Copy' 'Allocated sectors: 40'
    console_check "crc32range $triple_offset 1 /dst/Copy" "$last_crc"
    console_check 'umount /dst' 'Ext2 unmounted'
}

files=$(mktemp -d)
trap 'find "$files" -depth -delete' EXIT
build_dir=$1
kernel="$build_dir/baremetal-os.elf"
triple_offset=4299210752
huge_size=$((triple_offset + 1))
truncate -s "$huge_size" "$files/Huge"
printf A | dd of="$files/Huge" conv=notrunc status=none
printf Z | dd of="$files/Huge" bs=1 seek="$triple_offset" conv=notrunc status=none
last_crc=$(printf Z | gzip -n | tail -c 8 | od -An -N4 -t x4 | tr -d ' \n' | tr 'a-f' 'A-F')
head -c 49153 /dev/zero | tr '\000' X > "$files/Source"
printf 'Old\n' > "$files/Old"
head -c 65536 /dev/zero | tr '\000' S > "$files/Shrink"

truncate -s 16M "$files/volume"
mke2fs -q -F -t ext2 -b 4096 -O none,filetype,sparse_super,large_file "$files/volume"
{
    printf 'write %s /Source\nwrite %s /Target\nwrite %s /Huge\n' "$files/Source" "$files/Old" "$files/Huge"
    printf 'mkdir /Sub\nmkdir /Tree\nwrite %s /Tree/Marker\n' "$files/Old"
    printf 'write %s /Shrink\n' "$files/Shrink"
} | debugfs -w -f - "$files/volume" >"$files/debug.log" 2>&1
truncate -s 20M "$files/template"
sgdisk -n 1:2048:+16M "$files/template" >/dev/null
dd if="$files/volume" of="$files/template" bs=1M seek=1 conv=notrunc,sparse status=none

ata=(-drive "file=$files/disk0,if=ide,format=raw,cache=directsync")
virtio=(-drive "file=$files/disk1,if=none,id=vd,format=raw,cache=directsync"
    -device virtio-blk-pci,drive=vd,disable-legacy=on)

reset_disks() {
    cp --sparse=always "$files/template" "$files/disk0"
    cp --sparse=always "$files/template" "$files/disk1"
}

extract() {
    dd if="$files/disk$1" of="$files/result" bs=1M skip=1 count=16 status=none
}

repair() {
    local status=0
    e2fsck -fy "$files/result" || status=$?
    (( status <= 1 ))
    e2fsck -fn "$files/result"
}

reset_disks
run_guest 'ext2 sparse triple-indirect copy' 1 64M check_sparse_triple \
    -machine pc -kernel "$kernel" "${ata[@]}"
extract 0
e2fsck -fn "$files/result"
debugfs -R 'stat /Copy' "$files/result" 2>/dev/null | grep -Fq '(TIND)'

for target_disk in 0 1; do
    source_disk=$((1 - target_disk))
    for fixture in STREAM_READ STREAM_WRITE STREAM_FLUSH BEFORE AFTER; do
        reset_disks
        fixture_kernel="$build_dir/ext2-fixture-$fixture.elf"
        if [[ $fixture == STREAM_* ]]; then
            run_guest "ext2 $fixture failure writing disk$target_disk" 1 64M check_stream_fault \
                -machine pc -kernel "$fixture_kernel" "${ata[@]}" "${virtio[@]}"
        else
            QEMU_TEST_POWER_CUT=1 run_guest "ext2 $fixture inode switch on disk$target_disk" \
                1 64M check_power_cut -machine pc -kernel "$fixture_kernel" "${ata[@]}" "${virtio[@]}"
        fi
        cmp "$files/template" "$files/disk$source_disk"
        extract "$target_disk"
        dumpe2fs -h "$files/result" 2>/dev/null | grep -Eq 'Filesystem state:[[:space:]]+not clean'
        repair
        expected="$files/Old"
        [[ $fixture != AFTER ]] || expected="$files/Source"
        debugfs -R 'cat /Target' "$files/result" 2>/dev/null | cmp - "$expected"
        dd if="$files/result" of="$files/disk$target_disk" bs=1M seek=1 conv=notrunc status=none
        run_guest "ext2 repaired destination disk$target_disk after $fixture" 1 64M check_repaired_mount \
            -machine pc -kernel "$kernel" "${ata[@]}" "${virtio[@]}"
    done
done

for fixture in BEFORE AFTER; do
    reset_disks
    QEMU_TEST_POWER_CUT=1 run_guest "ext2 cross-directory rename cut $fixture" 1 64M \
        check_rename_cut -machine pc -kernel "$build_dir/ext2-fixture-$fixture.elf" "${ata[@]}"
    extract 0
    repair
    debugfs -R 'cat /Sub/Moved' "$files/result" 2>/dev/null | cmp - "$files/Old"
    if [[ $fixture == AFTER ]]; then
        debugfs -R 'stat /Target' "$files/result" 2>&1 | grep -q 'File not found'
    fi
done

check_directory_cut() {
    expect_serial 'baremetal> '
    console_check 'mount -t ext2 disk0p1 /dst' 'Ext2 mounted read-write'
    printf 'mv /dst/Tree /dst/Sub/MovedTree\r' >&"$serial_write"
    expect_serial 'Test: ext2 flush complete'
}

tree_inode=$(debugfs -R 'stat /Tree' "$files/volume" 2>/dev/null |
    awk '$1 == "Inode:" {print $2}')
for fixture in BEFORE AFTER CUT5; do
    reset_disks
    QEMU_TEST_POWER_CUT=1 run_guest "ext2 directory move cut $fixture" 1 64M \
        check_directory_cut -machine pc -kernel "$build_dir/ext2-fixture-$fixture.elf" "${ata[@]}"
    extract 0
    repair
    recovered=0
    for path in /Tree /Sub/MovedTree "/lost+found/#$tree_inode"; do
        if debugfs -R "cat $path/Marker" "$files/result" 2>/dev/null | cmp -s - "$files/Old"; then
            recovered=1
            break
        fi
    done
    (( recovered == 1 ))
done

check_shrink_cut() {
    expect_serial 'baremetal> '
    console_check 'mount -t ext2 disk0p1 /dst' 'Ext2 mounted read-write'
    printf 'truncate /dst/Shrink 49153\r' >&"$serial_write"
    expect_serial 'Test: ext2 flush complete'
}

head -c 49153 "$files/Shrink" > "$files/ExpectedShrink"
target_disk=0
for fixture in BEFORE AFTER; do
    reset_disks
    QEMU_TEST_POWER_CUT=1 run_guest "ext2 indirect shrink cut $fixture" 1 64M \
        check_shrink_cut -machine pc -kernel "$build_dir/ext2-fixture-$fixture.elf" "${ata[@]}"
    extract 0
    repair
    expected="$files/ExpectedShrink"
    if [[ $fixture == BEFORE ]]; then
        # At the size-only cut e2fsck restores the extent described by the
        # still-attached table. The old data must still be intact.
        expected="$files/Shrink"
    fi
    debugfs -R 'cat /Shrink' "$files/result" 2>/dev/null | cmp - "$expected"
    dd if="$files/result" of="$files/disk0" bs=1M seek=1 conv=notrunc status=none
    run_guest "ext2 remounts after shrink cut $fixture" 1 64M check_repaired_mount \
        -machine pc -kernel "$kernel" "${ata[@]}"
done
