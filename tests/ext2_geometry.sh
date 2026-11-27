#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

source tests/qemu_serial.sh

console_check() {
    printf '%s\r' "$1" >&"$serial_write"
    expect_serial "$2"
    expect_serial 'baremetal> '
}

check_mixed_geometry() {
    expect_serial 'baremetal> '
    console_check 'mount -t ext2 -o ro disk0p1 /small' 'Ext2 mounted read-only'
    console_check 'mount -t ext2 disk1p1 /medium' 'Ext2 mounted read-write'
    console_check 'cp /small/Input /medium/First' 'Ext2 file saved'
    console_check 'touch /medium/Indexed/Added' 'touch '
    console_check 'cp /small/Input /medium/Attr' 'Ext2 file saved'
    console_check 'rm /medium/AttrPeer' 'Ext2 entry removed'
    console_check 'cp /medium/First /small/Denied' 'Ext2 is read-only'
    console_check 'umount /small' 'Ext2 unmounted'
    console_check 'mount -t ext2 disk0p1 /small' 'Ext2 mounted read-write'
    console_check 'mkdir /small/Nested' 'Ext2 directory created'
    console_check 'cp /medium/First /small/Nested/Second' 'Ext2 file saved'
    console_check 'mv /small/Nested/Second /small/Nested/Result' 'mv '
    console_check 'ln /medium/First /medium/Hard' 'ln '
    console_check 'stat /medium/Hard' 'Links: 2'
    console_check 'stat /medium' 'Type: directory'
    console_check 'ln -s First /medium/Relative' 'Ext2 file saved'
    console_check 'readlink /medium/Relative' $'\r?\nFirst\r?\n'
    console_check 'ln -s /small/Nested /medium/Directory' 'Ext2 file saved'
    console_check 'cp /medium/Directory/Result /medium/Dereferenced' 'Ext2 file saved'
    console_check 'ln -s Loop /medium/Loop' 'Ext2 file saved'
    console_check 'cat /medium/Loop' 'Too many symbolic links'
    console_check 'rm /medium/Loop' 'Ext2 entry removed'
    console_check "ln -s $long_target /medium/Long" 'Ext2 file saved'
    console_check 'readlink /medium/Long' "$long_target"
    console_check 'rm /medium/Long' 'Ext2 entry removed'
    console_check "ln -s $inline_target /medium/Inline" 'Ext2 file saved'
    console_check 'readlink /medium/Inline' "$inline_target"
    console_check "ln -s $block_target /medium/BlockLink" 'Ext2 file saved'
    console_check 'readlink /medium/BlockLink' "$block_target"
    console_check 'cp /medium/Relative /medium/Hard' 'Source and destination are the same file'
    console_check 'mv /medium/Relative /medium/Renamed' 'mv '
    console_check 'readlink /medium/Renamed' $'\r?\nFirst\r?\n'
    console_check 'rm /medium/Renamed' 'Ext2 entry removed'
    console_check 'cp /small/Nested/Result /medium/Transient' 'Ext2 file saved'
    console_check 'rm /medium/Transient' 'Ext2 entry removed'
    console_check 'cp /medium/First /medium/Resize' 'Ext2 file saved'
    console_check 'truncate /medium/Resize 3' 'Ext2 file saved'
    console_check 'truncate /medium/Resize 4097' 'Ext2 file saved'
    console_check 'stat /medium/Resize' 'Size: 4097'
    console_check 'mkdir /medium/Box' 'Ext2 directory created'
    console_check 'echo Move > /medium/Source' 'Ext2 file saved'
    console_check 'echo Old > /medium/Box/Result' 'Ext2 file saved'
    console_check 'ln /medium/Box/Result /medium/OldAlias' 'ln '
    console_check 'mv /medium/Source /medium/Box/Result' 'mv '
    console_check 'cat /medium/Box/Result' $'\r?\nMove\r?\n'
    console_check 'cat /medium/OldAlias' $'\r?\nOld\r?\n'
    console_check 'stat /medium/OldAlias' 'Links: 1'
    console_check 'mkdir /medium/Parent' 'Ext2 directory created'
    console_check 'mkdir /medium/Parent/Child' 'Ext2 directory created'
    console_check 'mv /medium/Parent /medium/Parent/Child/Loop' 'Cannot move an ext2 directory into itself'
    console_check 'mkdir /medium/Box/Target' 'Ext2 directory created'
    console_check 'mv /medium/OldAlias/ /medium/Bad' 'Trailing slash requires a directory'
    console_check 'mv /medium/OldAlias /medium/Bad/' 'Trailing slash requires a directory'
    console_check 'mv /medium/Parent/ /medium/NewParent' 'mv '
    console_check 'mv /medium/NewParent /medium/Box/Target/' 'mv '
    console_check 'ls /medium/Box/Target' 'Child/'
    console_check 'umount /medium' 'Ext2 unmounted'
    console_check 'umount /small' 'Ext2 unmounted'
}

files=$(mktemp -d)
trap 'find "$files" -depth -delete' EXIT
kernel="$1/baremetal-os.elf"
printf -v inline_target '%059d' 1
printf -v block_target '%060d' 1
printf -v long_target "/missing/%060d" 1

# Cross the direct-block boundary on both filesystems and end mid-sector.
truncate -s 274433 "$files/Input"
printf 'header' | dd of="$files/Input" conv=notrunc status=none
printf x | dd of="$files/Input" bs=1 seek=274432 conv=notrunc status=none

truncate -s 16M "$files/small.img"
small_mkfs=(-q -F -t ext2 -b 1024 -I 128 -O none)
# e2fsprogs 1.47.2 moved revision selection from -r to -E.
if ! mke2fs "${small_mkfs[@]}" -E revision=0 "$files/small.img" 2>"$files/mkfs.log"; then
    mke2fs "${small_mkfs[@]}" -r 0 "$files/small.img" || { cat "$files/mkfs.log" >&2; exit 1; }
fi
dumpe2fs -h "$files/small.img" 2>/dev/null | grep -Eq 'Filesystem revision #:[[:space:]]+0 '
debugfs -w -R "write $files/Input /Input" "$files/small.img" >/dev/null 2>&1
truncate -s 16M "$files/medium.img"
mke2fs -q -F -t ext2 -b 2048 -g 1024 "$files/medium.img"
touch "$files/Empty"
printf '%0200d' 42 > "$files/Attribute"
{
    printf 'mkdir /Indexed\n'
    for entry in {1..400}; do
        printf 'write %s /Indexed/entry%03d\n' "$files/Empty" "$entry"
    done
    printf 'write %s /Attr\nwrite %s /AttrPeer\n' "$files/Empty" "$files/Empty"
    printf 'ea_set -f %s /Attr user.saved\n' "$files/Attribute"
} > "$files/commands"
debugfs -w -f "$files/commands" "$files/medium.img" > "$files/debug" 2>&1
attr_block=$(debugfs -R 'stat /Attr' "$files/medium.img" 2>/dev/null |
    awk '/File ACL:/ {print $3}')
(( attr_block > 0 ))
debugfs -w -R "set_inode_field /AttrPeer file_acl $attr_block" "$files/medium.img" >> "$files/debug" 2>&1
debugfs -w -R 'set_inode_field /AttrPeer blocks 4' "$files/medium.img" >> "$files/debug" 2>&1
printf '\002\000\000\000' |
    dd of="$files/medium.img" bs=1 seek="$((attr_block * 2048 + 4))" conv=notrunc status=none
status=0
e2fsck -fyD "$files/medium.img" >> "$files/debug" 2>&1 || status=$?
(( status <= 1 ))
debugfs -R 'stat /Indexed' "$files/medium.img" 2>/dev/null | grep -q 'Flags: 0x1000'

for name in small medium; do
    truncate -s 20M "$files/$name.raw"
    sgdisk -n 1:2048:+16M "$files/$name.raw" >/dev/null
    dd if="$files/$name.img" of="$files/$name.raw" bs=1M seek=1 conv=notrunc,sparse status=none
done

run_guest 'Ext2 1 KiB ATA and 2 KiB virtio-blk interchange' 1 64M \
    check_mixed_geometry -machine pc -kernel "$kernel" \
    -drive "file=$files/small.raw,if=ide,format=raw,cache=directsync" \
    -drive "file=$files/medium.raw,if=none,id=vd,format=raw,cache=directsync" \
    -device virtio-blk-pci,drive=vd,disable-legacy=on

for name in small medium; do
    dd if="$files/$name.raw" of="$files/$name.img" bs=1M skip=1 count=16 status=none
    e2fsck -fn "$files/$name.img"
done
debugfs -R 'cat /Input' "$files/small.img" 2>/dev/null | cmp - "$files/Input"
debugfs -R 'cat /Nested/Result' "$files/small.img" 2>/dev/null | cmp - "$files/Input"
debugfs -R 'cat /First' "$files/medium.img" 2>/dev/null | cmp - "$files/Input"
debugfs -R 'stat /Denied' "$files/small.img" 2>&1 | grep -q 'File not found'
debugfs -R 'stat /Transient' "$files/medium.img" 2>&1 | grep -q 'File not found'

debugfs -R 'stat /Indexed' "$files/medium.img" 2>/dev/null | grep -q 'Flags: 0x0'
debugfs -R 'stat /Indexed/Added' "$files/medium.img" 2>/dev/null | grep -q 'Type: regular'
debugfs -R 'cat /Attr' "$files/medium.img" 2>/dev/null | cmp - "$files/Input"
debugfs -R "ea_get -f $files/Saved /Attr user.saved" "$files/medium.img" >/dev/null 2>&1
cmp "$files/Attribute" "$files/Saved"
debugfs -R 'stat /AttrPeer' "$files/medium.img" 2>&1 | grep -q 'File not found'
debugfs -R 'cat /Dereferenced' "$files/medium.img" 2>/dev/null | cmp - "$files/Input"
debugfs -R 'stat /Hard' "$files/medium.img" 2>/dev/null | grep -q 'Links: 2'
debugfs -R 'stat /Nested/Result' "$files/small.img" 2>/dev/null | grep -Fq '(DIND)'
printf hea > "$files/Resized"
truncate -s 4097 "$files/Resized"
debugfs -R 'cat /Resize' "$files/medium.img" 2>/dev/null | cmp - "$files/Resized"
debugfs -R 'cat /Box/Result' "$files/medium.img" 2>/dev/null | cmp - <(printf 'Move\n')
debugfs -R 'cat /OldAlias' "$files/medium.img" 2>/dev/null | cmp - <(printf 'Old\n')
debugfs -R 'stat /Box/Target/Child' "$files/medium.img" 2>/dev/null | grep -q 'Type: directory'

debugfs -R 'stat /Inline' "$files/medium.img" 2>/dev/null | grep -q 'Blockcount: 0'
debugfs -R 'stat /BlockLink' "$files/medium.img" 2>/dev/null | grep -q 'Blockcount: 4'
