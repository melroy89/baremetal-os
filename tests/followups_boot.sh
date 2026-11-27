#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
source tests/qemu_serial.sh

console_check() {
    printf '%s\r' "$1" >&"$serial_write"
    expect_serial "$2"
    expect_serial 'baremetal> '
}

check_input() {
    expect_serial 'baremetal> '
    console_check 'echo history' $'\nhistory\r?\n'
    printf '\033[A\n' >&"$serial_write"
    expect_serial $'baremetal> echo history\r?\nhistory\r?\n'
    expect_serial 'baremetal> '
    printf 'echo draft\033[A' >&"$serial_write"
    expect_serial 'baremetal> echo history'
    printf '\033OB\r' >&"$serial_write"
    expect_serial $'baremetal> echo draft\r?\n'
    expect_serial $'draft\r?\n'
    expect_serial 'baremetal> '
    printf '\033[A\177!\r' >&"$serial_write"
    expect_serial $'\ndraf!\r?\n'
    expect_serial 'baremetal> '
    # Use the emulated PS/2 device as a separate input source.
    printf 'sendkey up\n' | socat - UNIX-CONNECT:"$files/monitor" >/dev/null
    expect_serial 'baremetal> echo draf!'
    printf '\033[B\r' >&"$serial_write"
    expect_serial 'baremetal> '
    expect_serial 'baremetal> '

    local index key
    for index in {00..16}; do
        console_check "echo item$index" $'\n'"item$index"$'\r?\n'
    done
    printf -v key '\033[A%.0s' {1..17}
    printf '%s\r' "$key" >&"$serial_write"
    expect_serial $'\nitem01\r?\n'
    expect_serial 'baremetal> '
}

check_disks() {
    expect_serial 'baremetal> '
    console_check 'disk info' 'ATA disk:'
    console_check 'disk info disk1' 'Virtio disk: virtio-blk'
    console_check 'disk crc32 disk1 1' "$gpt_crc"
    console_check 'disk crc32 disk1 1000000' '[Oo]utside'
    console_check 'disk gpt disk1' 'Partition 2  LBA'
    console_check 'mount disk0p1 /ata' 'FAT32 mounted'
    console_check 'mount disk1p1 /fat' 'FAT32 mounted'
    console_check 'mount -t ext2 disk1p2 /ext' 'Ext2 mounted read-write'
    console_check 'echo ATA > /ata/OLD.TXT' 'Disk file saved'
    console_check 'echo Virtio > /fat/OLD.TXT' 'Disk file saved'
    console_check 'echo Occupied > /fat/BUSY.TXT' 'Disk file saved'
    console_check 'mv /fat/OLD.TXT /fat/BUSY.TXT' 'already exists'
    console_check 'mv /fat/OLD.TXT /fat/NEW.TXT' 'mv /fat/OLD.TXT /fat/NEW.TXT'
    console_check 'cat /fat/NEW.TXT' $'\nVirtio\r?\n'
    console_check 'cat /ata/OLD.TXT' $'\nATA\r?\n'
    console_check 'mv /ata/OLD.TXT /fat/NEW.TXT' 'same FAT32 or ext2 directory'
    console_check 'mv "/ext/Old Name" "/ext/New Name"' 'mv '
    console_check 'mv "/ext/New Name" /ext/Bulk' 'already exists'
    console_check 'cat /ext/New Name' $'\nExt2 original\r?\n'
    console_check 'crc32range 509 8193 /ext/Bulk' "$crc"
    console_check 'echo Writable > /ext/Write' 'Ext2 file saved'
    console_check 'reboot' 'Rebooting'
    console_check 'mount disk1p1 /fat' 'FAT32 mounted'
    console_check 'mount -t ext2 -o ro disk1p2 /ext' 'Ext2 mounted read-only'
    console_check 'cat /fat/NEW.TXT' $'\nVirtio\r?\n'
    console_check 'cat /ext/New Name' $'\nExt2 original\r?\n'
    console_check 'cat /ext/Write' $'\nWritable\r?\n'
}

check_read_only() {
    expect_serial 'baremetal> '
    console_check 'disk info' 'Virtio disk: virtio-blk'
    console_check 'mount disk1p1 /fat' 'read-only'
    console_check 'mount -o ro disk1p1 /fat' 'FAT32 mounted'
    console_check 'rm /fat/NEW.TXT' 'read-only'
    console_check 'cat /fat/NEW.TXT' $'\nVirtio\r?\n'
}

check_long_name_collision() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /fat' 'FAT32 mounted'
    console_check 'mv /fat/SRC.TXT /fat/DEST.TXT' 'Cannot verify FAT32 destination'
    console_check 'cat /fat/SRC.TXT' $'\nSource contents\r?\n'
    console_check 'cat /fat/DEST~1.TXT' $'\nLong-name contents\r?\n'
}

check_rename_cut() {
    expect_serial 'baremetal> '
    if [[ $fs == ext2 ]]; then
        console_check 'mount -t ext2 disk1p2 /ext' 'Ext2 mounted read-write'
        printf 'mv "/ext/New Name" "/ext/Cut Name"\r' >&"$serial_write"
    else
        console_check 'mount disk1p1 /fat' 'FAT32 mounted'
        console_check 'mv /fat/NEW.TXT /fat/MID.TXT' 'mv /fat/NEW.TXT /fat/MID.TXT'
        printf 'mv /fat/MID.TXT /fat/CUT.TXT\r' >&"$serial_write"
    fi
    expect_serial 'Test: ext2 flush complete'
}

crc_hex() {
    gzip -n | tail -c 8 | od -An -N4 -t x4 | tr -d ' \n' | tr 'a-f' 'A-F'
}

files=$(mktemp -d)
trap 'find "$files" -depth -delete' EXIT
build_dir="${1:-build}"
kernel="$build_dir/baremetal-os.elf"
run_guest 'serial and PS/2 command history' 1 64M check_input -machine pc -kernel "$kernel" \
    -monitor "unix:$files/monitor,server=on,wait=off"

truncate -s 40M "$files/fat"
mkfs.fat -F 32 "$files/fat" >/dev/null
truncate -s 16M "$files/ext"
mke2fs -q -F -t ext2 -b 4096 -I 256 -O none,filetype,sparse_super,large_file "$files/ext"
printf 'Ext2 original\n' > "$files/original"
dd if=/dev/urandom of="$files/bulk" bs=4096 count=3 status=none
crc=$(dd if="$files/bulk" bs=1 skip=509 count=8193 status=none | crc_hex)
printf 'write %s "/Old Name"\nwrite %s /Bulk\n' "$files/original" "$files/bulk" > "$files/ext.commands"
debugfs -w -f "$files/ext.commands" "$files/ext" >"$files/debug.log" 2>&1

truncate -s 60M "$files/virtio"
sgdisk -n 1:2048:+40M -n 2:86016:+16M "$files/virtio" >/dev/null
gpt_crc=$(dd if="$files/virtio" bs=512 skip=1 count=1 status=none | crc_hex)
dd if="$files/fat" of="$files/virtio" bs=1M seek=1 conv=sparse,notrunc status=none
dd if="$files/ext" of="$files/virtio" bs=1M seek=42 conv=sparse,notrunc status=none
truncate -s 44M "$files/ata"
sgdisk -n 1:2048:+40M "$files/ata" >/dev/null
dd if="$files/fat" of="$files/ata" bs=1M seek=1 conv=sparse,notrunc status=none
run_guest 'ATA and modern virtio-blk mounts and renames' 1 64M check_disks -machine pc -kernel "$kernel" \
    -drive "file=$files/ata,if=ide,format=raw,cache=directsync" \
    -drive "file=$files/virtio,if=none,id=vd,format=raw,cache=directsync" \
    -device virtio-blk-pci,drive=vd,disable-legacy=on

dd if="$files/virtio" of="$files/fat" bs=1M skip=1 count=40 status=none
dd if="$files/virtio" of="$files/ext" bs=1M skip=42 count=16 status=none
fsck.fat -n "$files/fat"
e2fsck -fn "$files/ext"
debugfs -R 'cat "/New Name"' "$files/ext" 2>/dev/null | cmp - "$files/original"
before=$(sha256sum "$files/virtio")
run_guest 'virtio-blk read-only disk and default disk selection' 1 64M check_read_only -machine pc -kernel "$kernel" \
    -drive "file=$files/virtio,if=none,id=vd,format=raw,readonly=on" \
    -device virtio-blk-pci,drive=vd,disable-legacy=on
[[ $before == "$(sha256sum "$files/virtio")" ]]

# Give the mixed-case LFN its own short alias and shorten the name in place.
# The alias and its LFN checksum remain intact.
cp --sparse=always "$files/ata" "$files/lfn"
printf 'Source contents\n' > "$files/source"
printf 'Long-name contents\n' > "$files/long"
mcopy -i "$files/lfn@@1048576" "$files/source" ::SRC.TXT
mcopy -i "$files/lfn@@1048576" "$files/long" ::DeSt.TxTxx
alias_offset=$(grep -aob 'DEST~1  TXT' "$files/lfn" | cut -d: -f1)
printf '\000\000\377\377\377\377' |
    dd of="$files/lfn" bs=1 seek="$((alias_offset - 12))" conv=notrunc status=none
mtype -i "$files/lfn@@1048576" ::DeSt.TxT | cmp - "$files/long"
before=$(sha256sum "$files/lfn")
run_guest 'FAT32 rename refuses a long-name collision' 1 64M check_long_name_collision \
    -machine pc -kernel "$kernel" -drive "file=$files/lfn,if=ide,format=raw,cache=directsync"
[[ $before == "$(sha256sum "$files/lfn")" ]]

for fs in fat32 ext2; do
    cp --sparse=always "$files/virtio" "$files/cut"
    QEMU_TEST_POWER_CUT=1 run_guest "$fs flush and power cut during virtio-blk rename" 1 64M check_rename_cut \
        -machine pc -kernel "$build_dir/ext2-fixture-BEFORE.elf" \
        -drive "file=$files/cut,if=none,id=vd,format=raw,cache=directsync" \
        -device virtio-blk-pci,drive=vd,disable-legacy=on
    if [[ $fs == ext2 ]]; then
        dd if="$files/cut" of="$files/ext" bs=1M skip=42 count=16 status=none
        e2fsck -fn "$files/ext"
        debugfs -R 'cat "/Cut Name"' "$files/ext" 2>/dev/null | cmp - "$files/original"
        if debugfs -R 'stat "/New Name"' "$files/ext" 2>/dev/null | grep -q 'Inode:'; then
            printf 'Old ext2 name survived the rename\n' >&2
            exit 1
        fi
    else
        dd if="$files/cut" of="$files/fat" bs=1M skip=1 count=40 status=none
        fsck.fat -n "$files/fat"
        mtype -i "$files/fat" ::CUT.TXT | cmp - <(printf 'Virtio\n')
        if grep -aEq '(MID|NEW)     TXT' "$files/fat"; then
            printf 'Old FAT32 name survived the rename\n' >&2
            exit 1
        fi
    fi
done
