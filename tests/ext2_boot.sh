#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

source tests/qemu_serial.sh

console_check() {
    printf '%s\r' "$1" >&"$serial_write"
    expect_serial "$2"
    expect_serial 'baremetal> '
}

check_ext2() {
    expect_serial 'baremetal> '
    console_check 'mount -t ext2 disk0p1 /ext' 'Ext2 features require a read-only mount'
    console_check 'mount -t ext2 -o ro disk0p1 /ext' 'Ext2 mounted read-only\.'
    console_check 'mount disk0p2 /disk' 'FAT32 mounted\.'
    console_check 'mount -t ext2 -o ro disk0p1 /duplicate' 'Partition overlaps an active mount\.'
    console_check 'ls /ext' 'Nested/'
    console_check 'cd /ext/Nested' 'cd /ext/Nested'
    console_check 'pwd' $'\r?\n/ext/Nested\r?\n'
    console_check 'cd /ext/nested' 'Ext2 entry not found\.'
    console_check 'umount /ext' 'Current directory is on this volume\.'
    console_check 'cat Note.txt' $'\r?\nExt2 payload\r?\n'
    console_check 'ls /ext/Wide' 'entry175'
    console_check 'cd /ext/Indexed' 'Indexed ext2 directories are unsupported\.'
    console_check 'ls /ext/Broken' 'Invalid ext2 metadata or block pointer\.'
    console_check 'mount -t ext2 -o ro disk0p3 /other' 'Unsupported or invalid ext2 volume\.'
    console_check 'mount -t ext2 -o ro disk0p4 /dirty' 'Unsupported or invalid ext2 volume\.'

    console_check 'cp /ext/Nested/Note.txt /ram/note' 'cp /ext/Nested/Note\.txt'
    console_check 'cat /ram/note' $'\r?\nExt2 payload\r?\n'
    console_check 'cp /ext/Nested/Note.txt /disk/note.txt' 'Disk file saved\.'
    console_check 'crc32range 0 12 /disk/note.txt' "$note_crc"$'\r?\n'
    console_check 'cp /ext/Empty /disk/zero.txt' 'Disk file saved\.'
    console_check 'crc32range 0 0 /disk/zero.txt' $'\r?\n00000000\r?\n'
    console_check 'cp /disk/note.txt /ext/Note.txt' 'Ext2 is read-only\.'
    console_check 'touch /ext/x' 'Ext2 is read-only\.'
    console_check 'echo x > /ext/Nested/Note.txt' 'Ext2 is read-only\.'
    console_check 'rm /ext/Nested/Note.txt' 'Ext2 is read-only\.'
    console_check 'disk repair /ext' 'Ext2 is read-only\.'

    local offset
    for offset in "${offsets[@]}"; do
        console_check "crc32range $offset 24 /ext/Big" "${expected[$offset]}"$'\r?\n'
    done
    console_check 'crc32range 1048576 8192 /ext/Big' "$holes_crc"$'\r?\n'
    console_check 'crc32range 18446744073709551615 1 /ext/Big' 'Checksum range is outside the file\.'
    console_check 'crc32range 1 18446744073709551615 /ext/Big' 'Checksum range is outside the file\.'
    console_check 'crc32range 18446744073709551616 0 /ext/Big' 'Usage: crc32range'
    console_check 'crc32range 0 67108865 /ext/Big' 'Checksum range exceeds 64 MiB\.'
    console_check 'crc32range 0 0 /ext/Empty' $'\r?\n00000000\r?\n'
    console_check 'crc32range 12 0 /ext/Nested/Note.txt' $'\r?\n00000000\r?\n'
    console_check 'crc32range 13 0 /ext/Nested/Note.txt' 'Checksum range is outside the file\.'
    console_check 'crc32range 12 0 /ext/BadBlock' $'\r?\n00000000\r?\n'
    console_check 'crc32range 0 1 /ext/BadBlock' 'Invalid ext2 metadata or block pointer\.'
    console_check 'cd /' 'cd /'
    console_check 'umount /ext' 'Ext2 unmounted\.'
}

crc32() {
    gzip -n | tail -c 8 | od -An -N4 -t x4 | tr -d ' \n' | tr 'a-f' 'A-F'
}

files=$(mktemp -d)
trap 'find "$files" -depth -delete' EXIT
kernel="${1:-build}/baremetal-os.elf"
volume="$files/ext2.img"
disk="$files/disk.raw"
truncate -s 16M "$volume"
mke2fs -q -F -t ext2 -b 4096 -I 256 -O filetype,sparse_super,large_file,ext_attr,resize_inode,dir_index "$volume"
printf 'Ext2 payload' > "$files/Note"
note_crc=$(crc32 < "$files/Note")
touch "$files/Empty"
truncate -s 4300000000 "$files/Big"
offsets=(49144 4243448 4294967288 4299210744)
declare -A expected
for offset in "${offsets[@]}"; do
    printf 'left%04dRIGHT%06dtail' "$((offset % 10000))" "$((offset % 1000000))" |
        dd of="$files/Big" bs=1 seek="$offset" conv=notrunc status=none
    expected[$offset]=$(dd if="$files/Big" bs=1 skip="$offset" count=24 status=none | crc32)
done
holes_crc=$(dd if=/dev/zero bs=8192 count=1 status=none | crc32)

{
    printf 'mkdir /Indexed\n'
    for entry in {1..450}; do
        printf 'write %s /Indexed/entry%03d\n' "$files/Empty" "$entry"
    done
} > "$files/index.cmd"
debugfs -w -f "$files/index.cmd" "$volume" >"$files/debug.log" 2>&1
fsck_status=0
e2fsck -fyD "$volume" >>"$files/debug.log" 2>&1 || fsck_status=$?
(( fsck_status <= 1 ))
debugfs -R 'stat /Indexed' "$volume" 2>/dev/null | grep -q 'Flags: 0x1000'

{
    printf 'mkdir /Nested\nmkdir /Wide\nmkdir /Broken\n'
    printf 'write %s /Nested/Note.txt\nwrite %s /Big\nwrite %s /Empty\nwrite %s /BadBlock\n' \
        "$files/Note" "$files/Big" "$files/Empty" "$files/Note"
    for entry in {1..175}; do
        printf 'write %s /Wide/entry%03d-with-a-long-name\n' "$files/Empty" "$entry"
    done
    printf 'set_inode_field /Broken block[0] 0\n'
    printf 'set_inode_field /BadBlock block[0] 99999\n'
} > "$files/linear.cmd"
debugfs -w -f "$files/linear.cmd" "$volume" >>"$files/debug.log" 2>&1
map=$(debugfs -R 'stat /Big' "$volume" 2>/dev/null)
[[ $map == *'(TIND)'* && $map == *'1049612'* ]]
debugfs -R 'stat /Wide' "$volume" 2>/dev/null | grep -Eq '\(0-[1-9][0-9]*\):|\(1\):'

truncate -s 96M "$disk"
sgdisk -n 1:2048:+16M -n 2:34816:+64M -t 2:0700 -n 3:165888:+4M -n 4:174080:+4M "$disk" >/dev/null
dd if="$volume" of="$disk" bs=512 seek=2048 conv=sparse,notrunc status=none
truncate -s 64M "$files/fat.img"
mkfs.fat -F 32 "$files/fat.img" >/dev/null
dd if="$files/fat.img" of="$disk" bs=512 seek=34816 conv=sparse,notrunc status=none
truncate -s 4M "$files/unsupported.img"
mke2fs -q -F -t ext2 -b 4096 -O extent "$files/unsupported.img"
dd if="$files/unsupported.img" of="$disk" bs=512 seek=165888 conv=sparse,notrunc status=none
truncate -s 4M "$files/dirty.img"
mke2fs -q -F -t ext2 -b 4096 "$files/dirty.img"
debugfs -w -R 'set_super_value state 2' "$files/dirty.img" >>"$files/debug.log" 2>&1
dd if="$files/dirty.img" of="$disk" bs=512 seek=174080 conv=sparse,notrunc status=none

run_guest 'read-only ext2 and FAT32' 1 64M check_ext2 -machine pc -kernel "$kernel" \
    -drive "file=$disk,format=raw,if=ide"
dd if="$disk" bs=512 skip=2048 count=32768 status=none | cmp "$volume" -
