#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
source tests/qemu_serial.sh

console_check() {
    printf '%s\r' "$1" >&"$serial_write"
    expect_serial "$2"
    expect_serial 'baremetal> '
}

mount_ext() {
    expect_serial 'baremetal> '
    console_check 'mount -t ext2 disk0p1 /ext' 'Ext2 mounted read-write\.'
}

check_write() {
    mount_ext
    console_check 'touch /ext/empty' 'touch /ext/empty'
    console_check 'touch /ext/Unused/Fresh' 'touch /ext/Unused/Fresh'
    console_check 'echo Partial > /ext/partial' 'Ext2 file saved\.'
    console_check 'touch /ext/partial' 'touch /ext/partial'
    console_check 'echo Cannot replace > /ext/partial' 'Ext2 entry already exists\.'
    console_check 'cp /ram/exact /ext/Nested/Exact' 'Ext2 file saved\.'
    console_check 'cp /ext/Sparse /ext/Dense' 'Ext2 file saved\.'
    console_check 'cp /ext/ExactBytes /ext/Limit' 'Ext2 file saved\.'
    console_check 'cp /ext/TooBig /ext/Refused' 'Ext2 create limit is 48 KiB\.'
    local long_name
    printf -v long_name "%0244d" 9
    console_check "touch /ext/Full/$long_name" "Ext2 directory has no writable slot in one sector"
    console_check 'umount /ext' 'Ext2 unmounted\.'
    console_check 'mount -t ext2 -o ro disk0p1 /ext' 'Ext2 mounted read-only\.'
    console_check 'cat /ext/Nested/Exact' $'\nExact bytes\r?\n'
    console_check 'umount /ext' 'Ext2 unmounted\.'
}

check_reboot() {
    mount_ext
    console_check 'echo Rebooted > /ext/new' 'Ext2 file saved\.'
    console_check 'reboot' 'Rebooting'
    console_check 'mount -t ext2 -o ro disk0p1 /ext' 'Ext2 mounted read-only\.'
    console_check 'cat /ext/new' $'\nRebooted\r?\n'
}

check_halt() {
    mount_ext
    console_check 'echo Halted > /ext/new' 'Ext2 file saved\.'
}

check_fault() {
    mount_ext
    if [[ $fixture == FINAL ]]; then
        console_check 'echo Fixture > /ext/new' 'Ext2 file saved\.'
        console_check 'halt' 'Test: ext2 I/O error\.'
    else
        console_check 'echo Fixture > /ext/new' 'Test: ext2 I/O error\.'
    fi
    console_check 'echo Refused > /ext/blocked' 'Ext2 writes are blocked\.'
    console_check 'umount /ext' 'Ext2 unmounted dirty\.'
}

check_cut() {
    mount_ext
    printf 'echo Fixture > /ext/new\r' >&"$serial_write"
    expect_serial 'Test: ext2 flush complete\.'
}

check_dirty_refused() {
    expect_serial 'baremetal> '
    console_check 'mount -t ext2 disk0p1 /ext' 'Unsupported or invalid ext2 volume\.'
}

check_bad_allocation() {
    expect_serial 'baremetal> '
    console_check 'mount -t ext2 disk0p1 /ext' 'Ext2 allocation or ownership could not be verified.'
}

check_repaired_mount() {
    mount_ext
    console_check 'cat /ext/Existing' $'\nOriginal\r?\n'
    console_check 'umount /ext' 'Ext2 unmounted\.'
}

attach_image() {
    run_guest "$1" 1 64M "$2" -machine pc -kernel "$3" -initrd "$files/ram.tar" \
        -drive "file=$disk,format=raw,if=ide,cache=directsync"
}

extract_volume() {
    dd if="$disk" of="$files/result" bs=1M skip=1 count=12 status=none
}

clean_check() {
    dumpe2fs -h "$files/result" 2>/dev/null | grep -Eq 'Filesystem state:[[:space:]]+clean$'
    e2fsck -fn "$files/result"
}

files=$(mktemp -d)
trap 'find "$files" -depth -delete' EXIT
build_dir="${1:-build}"
kernel="$build_dir/baremetal-os.elf"
disk="$files/current.raw"

truncate -s 12M "$files/vol"
mke2fs -q -F -t ext2 -b 4096 -g 1024 -I 256 -O none,filetype,sparse_super,large_file "$files/vol"
printf 'Original\n' > "$files/Existing"
printf 'Exact bytes' > "$files/exact"
tar --format=ustar -C "$files" -cf "$files/ram.tar" exact
truncate -s 9001 "$files/Sparse"
printf 'end' | dd of="$files/Sparse" bs=1 seek=8998 conv=notrunc status=none
truncate -s 49152 "$files/ExactBytes"
printf 'end' | dd of="$files/ExactBytes" bs=1 seek=49149 conv=notrunc status=none
truncate -s 49153 "$files/TooBig"
touch "$files/Empty"
{
    printf 'mkdir /Nested\nmkdir /Full\nmkdir /Unused\n'
    printf 'write %s /Existing\nwrite %s /Sparse\nwrite %s /ExactBytes\nwrite %s /TooBig\n' \
        "$files/Existing" "$files/Sparse" "$files/ExactBytes" "$files/TooBig"
    # Sixteen records of 252 bytes after the dot entries use all but 40
    # bytes. The 40-byte tail has no sector-local header/name slot.
    for ((i = 0; i < 16; i++)); do
        printf 'write %s /Full/%0241d\n' "$files/Empty" "$i"
    done
} > "$files/commands"
debugfs -w -f "$files/commands" "$files/vol" >"$files/debug.log" 2>&1
# Split the '..' record into its minimum-size entry followed by an unused
# record, to cover reuse independently from splitting a live entry.
unused_block=$(debugfs -R 'bmap /Unused 0' "$files/vol" 2>/dev/null)
printf '\014\000' | dd of="$files/vol" bs=1 seek="$((unused_block * 4096 + 16))" conv=notrunc status=none
printf '\350\017' | dd of="$files/vol" bs=1 seek="$((unused_block * 4096 + 28))" conv=notrunc status=none
e2fsck -fn "$files/vol"
# The last record in Full has slack. The test's long requested name cannot fit.
truncate -s 16M "$files/base.raw"
sgdisk -n 1:2048:+12M "$files/base.raw" >/dev/null
dd if="$files/vol" of="$files/base.raw" bs=1M seek=1 conv=notrunc,sparse status=none
cp --sparse=always "$files/base.raw" "$disk"
attach_image 'ext2 create, copy and clean unmount' check_write "$kernel"
extract_volume
clean_check
debugfs -R 'cat /Nested/Exact' "$files/result" 2>/dev/null | cmp - "$files/exact"
debugfs -R 'cat /Dense' "$files/result" 2>/dev/null | cmp - "$files/Sparse"
debugfs -R 'cat /Limit' "$files/result" 2>/dev/null | cmp - "$files/ExactBytes"
debugfs -R 'stat /Dense' "$files/result" 2>/dev/null | grep -q 'Blockcount: 24'
debugfs -R 'stat /empty' "$files/result" 2>/dev/null | grep -q 'Blockcount: 0'
debugfs -R 'stat /Unused/Fresh' "$files/result" 2>/dev/null | grep -q 'Blockcount: 0'

for closure in reboot halt; do
    cp --sparse=always "$files/base.raw" "$disk"
    attach_image "ext2 clean $closure" "check_$closure" "$kernel"
    extract_volume
    clean_check
    output=Rebooted
    [[ $closure == reboot ]] || output=Halted
    debugfs -R 'cat /new' "$files/result" 2>/dev/null | cmp - <(printf '%s\n' "$output")
done

cp --sparse=always "$files/base.raw" "$disk"
extract_volume
existing_block=$(debugfs -R 'bmap /Existing 0' "$files/result" 2>/dev/null)
# Keep both counters consistent with the bitmap so validation reaches the
# referenced inode's data block.
dumpe2fs "$files/result" >"$files/layout" 2>/dev/null
blocks_per_group=$(awk '/^Blocks per group:/ {print $4}' "$files/layout")
group=$((existing_block / blocks_per_group))
free_blocks=$(awk '/^Free blocks:/ {print $3}' "$files/layout")
group_free=$(awk -v group="$group" '
    $1 == "Group" {found = ($2 == group ":")}
    found && $2 == "free" && $3 == "blocks," {print $1; exit}
' "$files/layout")
{
    printf 'freeb %s\n' "$existing_block"
    printf 'set_bg %s free_blocks_count %s\n' "$group" "$((group_free + 1))"
    printf 'set_super_value free_blocks_count %s\n' "$((free_blocks + 1))"
} | debugfs -w -f - "$files/result" >>"$files/debug.log" 2>&1
dd if="$files/result" of="$disk" bs=1M seek=1 conv=notrunc status=none
sha256sum "$disk" > "$files/invalid.sha"
attach_image 'ext2 refuses a referenced block marked free' check_bad_allocation "$kernel"
sha256sum -c --status "$files/invalid.sha"

for fixture in ALLOC PUBLISH FINAL BEFORE AFTER; do
    cp --sparse=always "$files/base.raw" "$disk"
    fixture_kernel="$build_dir/ext2-fixture-$fixture.elf"
    case $fixture in
        BEFORE|AFTER) QEMU_TEST_POWER_CUT=1 attach_image "ext2 power cut $fixture" check_cut "$fixture_kernel" ;;
        *) attach_image "ext2 fault $fixture" check_fault "$fixture_kernel" ;;
    esac
    sha256sum "$disk" > "$files/dirty.sha"
    attach_image 'ext2 refuses a dirty writable mount' check_dirty_refused "$kernel"
    sha256sum -c --status "$files/dirty.sha"
    extract_volume
    debugfs -R 'cat /Existing' "$files/result" 2>/dev/null | cmp - "$files/Existing"
    case $fixture in
        FINAL|AFTER) debugfs -R 'cat /new' "$files/result" 2>/dev/null | cmp - <(printf 'Fixture\n') ;;
        *) debugfs -R 'stat /new' "$files/result" 2>&1 | grep -q 'File not found' ;;
    esac
    fsck_status=0
    e2fsck -fy "$files/result" || fsck_status=$?
    (( fsck_status <= 1 ))
    clean_check
    dd if="$files/result" of="$disk" bs=1M seek=1 conv=notrunc status=none
    attach_image 'ext2 remounts after offline repair' check_repaired_mount "$kernel"
done
