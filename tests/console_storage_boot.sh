#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
source tests/qemu_serial.sh

console_check() {
    printf '%s\r' "$1" >&"$serial_write"
    expect_serial "$2"
    expect_serial 'baremetal> '
}

check_history() {
    expect_serial 'baremetal> '
    printf 'his\t\r' >&"$serial_write"
    expect_serial $'\nhistory\r?\nbaremetal> '
    console_check 'echo once' $'\nonce\r?\n'
    console_check 'echo once' $'\nonce\r?\n'
    printf 'history\r' >&"$serial_write"
    expect_serial $'\nhistory\r?\necho once\r?\nhistory\r?\nbaremetal> '
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

    local listing=$'^history\r?\n'
    for index in {03..16}; do
        listing+="echo item$index"$'\r?\n'
    done
    printf 'history\r' >&"$serial_write"
    expect_serial "$listing"$'echo item01\r?\nhistory\r?\nbaremetal> '

    printf '\033[A\033[A\r' >&"$serial_write"
    expect_serial $'\nitem01\r?\nbaremetal> '
}

monitor_key() {
    printf 'sendkey %s\n' "$1" | socat - UNIX-CONNECT:"$files/monitor" >/dev/null
}

check_editor() {
    printf 'echo discarded\033[D\003' >&"$serial_write"
    expect_serial '\^C'
    expect_serial 'baremetal> '

    printf 'echo ac\033[Db\033[F\004\r' >&"$serial_write"
    expect_serial $'\nabc\r?\n'
    expect_serial 'baremetal> '
    printf 'throwaway echo keep erase\001' >&"$serial_write"
    printf '\033[C%.0s' {1..10} >&"$serial_write"
    printf '\025\033[F\027\r' >&"$serial_write"
    expect_serial $'\nkeep\r?\n'
    expect_serial 'baremetal> '
    printf 'echo axz\033[D\033[D\004\033[3~b\005\004\r' >&"$serial_write"
    expect_serial $'\nab\r?\n'
    expect_serial 'baremetal> '
    printf 'echo à🙂é\033[D\177\033[3~z\r' >&"$serial_write"
    expect_serial $'\nàz\r?\n'
    expect_serial 'baremetal> '

    printf 'echo axc\033[D\033[D\033[A\033[B\004b\r' >&"$serial_write"
    expect_serial $'\nabc\r?\n'
    expect_serial 'baremetal> '
    console_check 'echo SCROLLBACK-MARKER' $'\nSCROLLBACK-MARKER\r?\n'
    printf 'echo axc\033[D\033[D' >&"$serial_write"
    monitor_key ctrl-l
    expect_serial $'\033\\[2J'
    expect_serial 'baremetal> echo a'
    monitor_key pgup
    # Take a VGA text-memory snapshot after the emulated key reaches the guest.
    {
        sleep 0.2
        printf 'pmemsave 0xb8000 4000 "%s"\n' "$files/vga"
    } | socat - UNIX-CONNECT:"$files/monitor" >/dev/null
    od -An -v -tu1 "$files/vga" | awk '
        { for (i = 1; i <= NF; i++) { if (cell++ % 2 == 0) printf "%c", $i } }
    ' | grep -Fq SCROLLBACK-MARKER
    monitor_key delete
    printf 'b\r' >&"$serial_write"
    expect_serial $'\nabc\r?\n'
    expect_serial 'baremetal> '

    printf 'echo axc' >&"$serial_write"
    expect_serial 'echo axc'
    monitor_key left
    monitor_key left
    monitor_key ctrl-d
    monitor_key b
    monitor_key end
    monitor_key ret
    expect_serial $'\nabc\r?\n'
    expect_serial 'baremetal> '
    printf 'echo discarded' >&"$serial_write"
    expect_serial 'echo discarded'
    monitor_key ctrl-c
    expect_serial '\^C'
    expect_serial 'baremetal> '
    console_check 'echo still-ready' $'\nstill-ready\r?\n'

    printf 'echo x%1016sy\033[D\013z\r' '' >&"$serial_write"
    expect_serial $'\nx {1016}z\r?\n'
    expect_serial 'baremetal> '
}

check_disk_mounts_and_renames() {
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
    console_check 'mv /ata/OLD.TXT /fat/NEW.TXT' 'requires one mounted volume'
    console_check 'mv "/ext/Old Name" "/ext/New Name"' 'mv '
    console_check 'mv /ext/Missing /ext/Bulk' 'Ext2 entry not found'
    console_check 'cat /ext/New Name' $'\nExt2 original\r?\n'
    console_check 'crc32range 509 8193 /ext/Bulk' "$crc"
    console_check 'echo Writable > /ext/Write' 'Ext2 file saved'
    console_check 'cp /ata/STREAM.TXT /ext/Stream' 'Ext2 file saved'
    console_check 'reboot' 'Rebooting'
    console_check 'mount disk1p1 /fat' 'FAT32 mounted'
    console_check 'mount -t ext2 -o ro disk1p2 /ext' 'Ext2 mounted read-only'
    console_check 'cat /fat/NEW.TXT' $'\nVirtio\r?\n'
    console_check 'cat /ext/New Name' $'\nExt2 original\r?\n'
    console_check 'cat /ext/Write' $'\nWritable\r?\n'
}

check_inventory_listing() {
    local ata_status=$1 probe_label=$2
    printf 'disk list\r' >&"$serial_write"
    expect_serial $'disk0  ATA\r?\n    '"$ata_status"$'\r?\n'
    expect_serial $'disk1  Virtio\r?\n    disk1p1  ambiguous\r?\n    disk1p3  Ext2\r?\n    disk1p5  '"$probe_label"$'\r?\n'
    expect_serial 'baremetal> '
    console_check 'disk gpt disk1' 'GPT: backup'
    console_check 'mount -o ro disk1p5 /probe' "Filesystem detection: $probe_label"
}

check_inventory() {
    expect_serial 'baremetal> '
    check_inventory_listing 'No valid supported GPT\.' unknown
    console_check 'mount -o ro disk1p1 /ambiguous' 'Filesystem detection: ambiguous'
    console_check 'mount -o ro disk1p3 /ext' 'Ext2 mounted read-only'
    console_check 'mount -o ro -t fat32 disk1p1 /fat' 'FAT32 mounted read-only'
    console_check 'disk list disk1' 'Usage: disk info'
}

check_completion() {
    expect_serial 'baremetal> '
    check_inventory_listing 'GPT contains no partitions\.' unreadable
    local start=${#transcript}
    console_check 'help' 'Show console commands'
    [[ ${transcript:start} != *'Ctrl+'* ]]

    # The cursor is between the command and its argument.
    printf 'ec preserved\001\033[C\033[C\t\r' >&"$serial_write"
    expect_serial $'\npreserved\r?\n'
    expect_serial 'baremetal> '
    printf 'ecx\033[D\t cursor-prefix\r' >&"$serial_write"
    expect_serial $'\ncursor-prefix\r?\n'
    expect_serial 'baremetal> '
    printf '/ver\t\r' >&"$serial_write"
    expect_serial 'Build: [0-9a-f]{12}'
    expect_serial 'baremetal> '
    printf 'cr\t\t' >&"$serial_write"
    expect_serial $'\ncrc32\r?\ncrc32range\r?\n'
    expect_serial 'baremetal> crc32'
    printf '\003' >&"$serial_write"
    expect_serial '\^C'
    expect_serial 'baremetal> '

    printf 'mount -o ro -t ext2 disk1p\t' >&"$serial_write"
    expect_serial $'\ndisk1p1\r?\ndisk1p3\r?\ndisk1p5\r?\n'
    expect_serial 'baremetal> mount -o ro -t ext2 disk1p'
    printf '3 /ext\r' >&"$serial_write"
    expect_serial 'Ext2 mounted read-only'
    expect_serial 'baremetal> '
    printf 'mount -t fat32 -o ro disk1p1x\033[D\t /fat\r' >&"$serial_write"
    expect_serial 'FAT32 mounted read-only'
    expect_serial 'baremetal> '

    printf 'cd /ext/Vi\t\r' >&"$serial_write"
    expect_serial $'cd /ext/Via/\r?\n'
    expect_serial 'baremetal> '
    console_check 'pwd' $'\n/ext/Nested\r?\n'
    printf 'ls /ext/Directory-L\t\r' >&"$serial_write"
    expect_serial $'ls /ext/Directory-Link/\r?\nentry\r?\n'
    expect_serial 'baremetal> '
    # Only the directory link qualifies despite sharing a prefix.
    printf 'cd /ext/Link-\t\r' >&"$serial_write"
    expect_serial $'cd /ext/Link-Dir/\r?\n'
    expect_serial 'baremetal> '
    console_check 'pwd' $'\n/ext/Nested\r?\n'
    printf 'cd /e\tN\t\r' >&"$serial_write"
    expect_serial 'baremetal> '
    console_check 'pwd' $'\n/ext/Nested\r?\n'
    printf 'cat ../Via/en' >&"$serial_write"
    expect_serial 'cat ../Via/en'
    monitor_key tab
    expect_serial 'cat ../Via/entry'
    printf '\r' >&"$serial_write"
    expect_serial $'\nExt2 original\r?\n'
    expect_serial 'baremetal> '
    printf 'cat /fat/lo\t\r' >&"$serial_write"
    expect_serial $'\nExt2 original\r?\n'
    expect_serial 'baremetal> '
    printf 'cat /ext/UTF-éN\t\r' >&"$serial_write"
    expect_serial $'\nExt2 original\r?\n'
    expect_serial 'baremetal> '
    printf 'cat /ext/U-\t' >&"$serial_write"
    expect_serial $'\nU-é\r?\nU-ê\r?\n'
    expect_serial 'baremetal> cat /ext/U-'
    printf '\003' >&"$serial_write"
    expect_serial '\^C'
    expect_serial 'baremetal> '

    printf 'cp /ext/Olwrong /ram/copied\001' >&"$serial_write"
    printf '\033[C%.0s' {1..10} >&"$serial_write"
    printf '\t\r' >&"$serial_write"
    expect_serial 'baremetal> '
    console_check 'cat /ram/copied' $'\nExt2 original\r?\n'
    printf 'cp "/ext/Olwrong" /ram/copy-quoted\001' >&"$serial_write"
    printf '\033[C%.0s' {1..11} >&"$serial_write"
    printf '\t\r' >&"$serial_write"
    expect_serial 'baremetal> '
    console_check 'cat /ram/copy-quoted' $'\nExt2 original\r?\n'
    printf 'cp "/ext/Nes\ten\t /ram/quoted\r' >&"$serial_write"
    expect_serial 'baremetal> '
    console_check 'cat /ram/quoted' $'\nExt2 original\r?\n'
    printf 'cp "/ram/Sp\t /ram/escaped\r' >&"$serial_write"
    expect_serial 'baremetal> '
    console_check 'cat /ram/escaped' $'\nescaped name\r?\n'
    printf 'cp /ext/Ol\t /ram/copi\t\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'crc32 copi\t\r' >&"$serial_write"
    expect_serial "$original_crc"
    expect_serial 'baremetal> '
    printf 'crc32range 0 14 /ext/Via/en\t\r' >&"$serial_write"
    expect_serial "$original_crc"
    expect_serial 'baremetal> '
    printf 'echo revised > /ram/quo\t\r' >&"$serial_write"
    expect_serial 'baremetal> '
    console_check 'cat /ram/quoted' $'\nrevised\r?\n'
    printf 'echo /ram/quo\t\r' >&"$serial_write"
    expect_serial $'\n/ram/quo\r?\n'
    expect_serial 'baremetal> '

    printf 'cat /ext/Slow/C\t' >&"$serial_write"
    expect_serial 'Test completion read boundary'
    printf '\003echo queued-after-tab\r' >&"$serial_write"
    expect_serial '\^C'
    expect_serial $'\nqueued-after-tab\r?\n'
    expect_serial 'baremetal> '

    printf 'cat /missing/place\t\r' >&"$serial_write"
    expect_serial 'Directory not found'
    expect_serial 'baremetal> '
    printf 'cat /ram/no-such-file\t\r' >&"$serial_write"
    expect_serial 'File not found'
    expect_serial 'baremetal> '
    start=${#transcript}
    printf 'cat /ram/complete\t' >&"$serial_write"
    expect_serial '\.\.\. \(more matches\)'
    [[ $(grep -Ec $'^complete[0-9]{2}\r?$' <<<"${transcript:start}") == 32 ]]
    expect_serial 'baremetal> cat /ram/complete'
    printf '\003' >&"$serial_write"
    expect_serial '\^C'
    expect_serial 'baremetal> '

    printf '%1020sver\t\r' '' >&"$serial_write"
    expect_serial 'Unknown command'
    expect_serial 'baremetal> '
    printf '%1016sver\t\r' '' >&"$serial_write"
    expect_serial 'Build: [0-9a-f]{12}'
    expect_serial 'baremetal> '

    console_check 'cd /' 'cd /'
    printf 'disk check /f\t\r' >&"$serial_write"
    expect_serial 'Orphaned FAT32 clusters: 0'
    expect_serial 'baremetal> '
    printf 'umount /e\t\r' >&"$serial_write"
    expect_serial 'Ext2 unmounted'
    expect_serial 'baremetal> '
}

interrupt_copy() {
    local command=$1 result=$2
    printf '%s\r' "$command" >&"$serial_write"
    expect_serial 'Test write boundary\.'
    printf '\003echo queued\r' >&"$serial_write"
    expect_serial "$result"
    expect_serial $'\nqueued\r?\n'
    expect_serial 'baremetal> '
}

check_full_typeahead() {
    local interrupt=$1 padding start=${#transcript}
    padding=$(printf '%4075s' '' | tr ' ' '\002')
    printf 'echo CANC > /ext/Full Queue\r' >&"$serial_write"
    expect_serial 'Test write boundary\.'
    # Fill all 4,095 slots. Unbound Ctrl+B is silent when the editor drains it.
    printf 'echo kept\r%secho edge\r' "$padding" >&"$serial_write"
    sleep 0.5
    printf 'echo dropped\r' >&"$serial_write"
    if [[ $interrupt == ps2 ]]; then
        monitor_key ctrl-c
    else
        printf '\003' >&"$serial_write"
    fi
    expect_serial 'Interrupted\.'
    expect_serial $'\nkept\r?\n'
    expect_serial $'\nedge\r?\n'
    expect_serial 'baremetal> '
    console_check 'cat /ext/Full Queue' 'Ext2 entry not found'
    [[ ${transcript:start} != *dropped* ]]
}

check_cancellation() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /fat' 'FAT32 mounted'
    console_check 'mount disk1p2 /ext' 'Ext2 mounted read-write'
    console_check 'echo old > /fat/OLD.TXT' 'Disk file saved'

    printf 'cat /ext/sparse-copy.bin\r' >&"$serial_write"
    expect_serial $'\nS'
    printf '\003echo after-ext2\r' >&"$serial_write"
    expect_serial 'Interrupted\.'
    expect_serial $'\nafter-ext2\r?\n'
    expect_serial 'baremetal> '

    printf 'cat /fat/STREAM.TXT\r' >&"$serial_write"
    expect_serial $'\nX'
    printf '\003' >&"$serial_write"
    expect_serial 'Interrupted\.'
    expect_serial 'baremetal> '
    printf 'cat /ram/cancel.bin\r' >&"$serial_write"
    expect_serial $'\nC'
    printf '\003' >&"$serial_write"
    expect_serial 'Interrupted\.'
    expect_serial 'baremetal> '

    interrupt_copy 'cp /ram/cancel.bin /fat/OLD.TXT' 'Interrupted\.'
    console_check 'cat /fat/OLD.TXT' $'\nold\r?\n'
    interrupt_copy 'echo FLUS > /fat/NEW.TXT' 'Interrupted\.'
    console_check 'cat /fat/NEW.TXT' 'Disk file not found'
    interrupt_copy 'cp /ram/cancel.bin /ext/absent' 'Interrupted\.'
    console_check 'cat /ext/absent' 'Ext2 entry not found'
    interrupt_copy 'echo CANC > /ext/Old Name' 'Interrupted\.'
    console_check 'cat /ext/Old Name' $'\nExt2 original\r?\n'
    check_full_typeahead ps2
    check_full_typeahead serial

    interrupt_copy 'cp /ram/keep.bin /fat/OLD.TXT' 'Disk file saved'
    interrupt_copy 'cp /ram/keep.bin /ext/committed' 'Ext2 file saved'
    console_check 'crc32range 0 49153 /fat/OLD.TXT' "$keep_crc"
    console_check 'crc32range 0 49153 /ext/committed' "$keep_crc"
    console_check 'umount /fat' 'FAT32 unmounted'
    console_check 'umount /ext' 'Ext2 unmounted'
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
check_console_editor() {
    check_history
    check_editor
}

QEMU_TEST_HALT_INPUT=$'\004' run_guest 'serial and PS/2 history and editing' 1 64M check_console_editor \
    -machine pc -kernel "$kernel" -monitor "unix:$files/monitor,server=on,wait=off"

truncate -s 40M "$files/fat"
mkfs.fat -F 32 "$files/fat" >/dev/null
head -c 49153 /dev/zero | tr '\000' X > "$files/stream"
mcopy -i "$files/fat" "$files/stream" ::STREAM.TXT
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
cp --sparse=always "$files/virtio" "$files/inventory"
sgdisk -d 2 -n 3:86016:+16M -n 5:118784:+1M "$files/inventory" >/dev/null
# The FAT boot sector and ext2 superblock can coexist in the FAT reserved area.
dd if="$files/ext" of="$files/inventory" bs=512 skip=2 seek=2050 count=1 conv=notrunc status=none
printf '\0' | dd of="$files/inventory" bs=1 seek=512 conv=notrunc status=none
truncate -s 4M "$files/empty"
cp --sparse=always "$files/empty" "$files/invalid"
sgdisk -o "$files/empty" >/dev/null
before=$(sha256sum "$files/invalid" "$files/inventory")
run_guest 'read-only disk inventory with GPT fallback and gaps' 1 64M check_inventory \
    -machine pc -kernel "$kernel" -drive "file=$files/invalid,if=ide,format=raw" \
    -drive "file=$files/inventory,if=none,id=vd,format=raw,cache=directsync" \
    -device virtio-blk-pci,drive=vd,disable-legacy=on
[[ $before == "$(sha256sum "$files/invalid" "$files/inventory")" ]]
# Use a separate writable image so read-only completion can be checked by hash.
cp --sparse=always "$files/inventory" "$files/completion-disk"
cp --sparse=always "$files/ext" "$files/completion-ext"
{
    printf 'mkdir /Nested\nsymlink /Via Nested\nsymlink /Directory-Link /ext/Nested\n'
    printf 'symlink /Link-Dir Via\nsymlink /Link-File Nested/entry\nsymlink /Link-Dangling Missing\nsymlink /Link-Loop Link-Loop\nmkdir /Slow\n'
    printf 'write %s /Slow/CANCELTAB\n' "$files/original"
    printf 'write %s /Nested/entry\n' "$files/original"
    printf 'write %s /UTF-éName\nwrite %s /U-é\nwrite %s /U-ê\n' \
        "$files/original" "$files/original" "$files/original"
} > "$files/completion.commands"
debugfs -w -f "$files/completion.commands" "$files/completion-ext" >"$files/completion.log" 2>&1
dd if="$files/completion-ext" of="$files/completion-disk" bs=1M seek=42 conv=sparse,notrunc status=none
mcopy -i "$files/completion-disk@@1048576" "$files/original" '::Long Filename.txt'
mkdir "$files/completion-ram"
for entry in {00..34}; do
    printf 'candidate\n' > "$files/completion-ram/complete$entry"
done
escaped_name='Spaced "quote" \ name'
printf 'escaped name\n' > "$files/completion-ram/$escaped_name"
tar --format=ustar -cf "$files/completion.tar" -C "$files/completion-ram" complete{00..34} "$escaped_name"
original_crc=$(crc_hex < "$files/original")
completion_before=$(sha256sum "$files/empty" "$files/completion-disk")
run_guest 'Tab completion, empty GPT and unreadable probe' 1 64M check_completion \
    -machine pc -kernel "$build_dir/console-cancel.elf" -initrd "$files/completion.tar" \
    -monitor "unix:$files/monitor,server=on,wait=off" \
    -drive "file=$files/empty,if=ide,format=raw,cache=directsync" \
    -drive "file=$files/completion-disk,if=none,id=vd,format=raw,cache=directsync" \
    -device virtio-blk-pci,drive=vd,disable-legacy=on
[[ $completion_before == "$(sha256sum "$files/empty" "$files/completion-disk")" ]]

cp --sparse=always "$files/ata" "$files/cancel-ata"
cp --sparse=always "$files/virtio" "$files/cancel-virtio"
cp --sparse=always "$files/ext" "$files/cancel-ext"
printf 'S' > "$files/sparse-copy.bin"
truncate -s 32M "$files/sparse-copy.bin"
debugfs -w -R "write $files/sparse-copy.bin /sparse-copy.bin" "$files/cancel-ext" >/dev/null 2>&1
dd if="$files/cancel-ext" of="$files/cancel-virtio" bs=1M seek=42 conv=sparse,notrunc status=none
cp "$files/stream" "$files/cancel.bin"
cp "$files/stream" "$files/keep.bin"
printf 'CANC' | dd of="$files/cancel.bin" conv=notrunc status=none
printf 'KEEP' | dd of="$files/keep.bin" conv=notrunc status=none
keep_crc=$(crc_hex < "$files/keep.bin")
tar --format=ustar -C "$files" -cf "$files/cancel.tar" cancel.bin keep.bin
run_guest 'Cooperative cancellation before and after publication' 1 64M check_cancellation \
    -machine pc -kernel "$build_dir/console-cancel.elf" -initrd "$files/cancel.tar" \
    -monitor "unix:$files/monitor,server=on,wait=off" \
    -drive "file=$files/cancel-ata,if=ide,format=raw,cache=directsync" \
    -drive "file=$files/cancel-virtio,if=none,id=vd,format=raw,cache=directsync" \
    -device virtio-blk-pci,drive=vd,disable-legacy=on
dd if="$files/cancel-ata" of="$files/cancel-fat" bs=1M skip=1 count=40 status=none
dd if="$files/cancel-virtio" of="$files/cancel-ext" bs=1M skip=42 count=16 status=none
fsck.fat -n "$files/cancel-fat"
e2fsck -fn "$files/cancel-ext"
mtype -i "$files/cancel-fat" ::OLD.TXT | cmp - "$files/keep.bin"
debugfs -R 'cat /committed' "$files/cancel-ext" 2>/dev/null | cmp - "$files/keep.bin"

run_guest 'ATA and modern virtio-blk mounts and renames' 1 64M check_disk_mounts_and_renames -machine pc -kernel "$kernel" \
    -drive "file=$files/ata,if=ide,format=raw,cache=directsync" \
    -drive "file=$files/virtio,if=none,id=vd,format=raw,cache=directsync" \
    -device virtio-blk-pci,drive=vd,disable-legacy=on

dd if="$files/virtio" of="$files/fat" bs=1M skip=1 count=40 status=none
dd if="$files/virtio" of="$files/ext" bs=1M skip=42 count=16 status=none
fsck.fat -n "$files/fat"
e2fsck -fn "$files/ext"
debugfs -R 'cat "/New Name"' "$files/ext" 2>/dev/null | cmp - "$files/original"
debugfs -R 'cat /Stream' "$files/ext" 2>/dev/null | cmp - "$files/stream"
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
