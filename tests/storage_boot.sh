#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

source tests/qemu_serial.sh
source tests/vfs_cases.sh

console_check() {
    printf '%s\r' "$1" >&"$serial_write"
    expect_serial "$2"
    expect_serial 'baremetal> '
}

check_ata() {
    expect_serial 'baremetal> '
    console_check 'disk info' $'ATA disk: QEMU HARDDISK\r?\nLogical sector size: 512 bytes\r?\nSectors: 2048\r?\n'
    console_check 'disk crc32 0' "$crc0"$'\r?\n'
    console_check 'disk crc32 1' "$crc1"$'\r?\n'
    console_check 'disk crc32 2048' 'Disk LBA out of range\.'
    console_check 'disk crc32 18446744073709551616' 'Invalid decimal LBA\.'
}

check_lba48() {
    expect_serial 'baremetal> '
    console_check 'disk crc32 268435456' "$crc48"$'\r?\n'
    console_check 'disk crc32 268435457' 'Disk LBA out of range\.'
}

check_absent() {
    expect_serial 'baremetal> '
    console_check 'disk info' 'No primary ATA disk\.'
    console_check 'disk crc32 0' 'No primary ATA disk\.'
}

check_gpt_primary() {
    expect_serial 'baremetal> '
    console_check 'disk gpt' $'GPT: primary\r?\nPartition 1  LBA 2048-133119\r?\n'
}

check_gpt_backup() {
    expect_serial 'baremetal> '
    console_check 'disk gpt' $'GPT: backup\r?\nPartition 1  LBA 2048-133119\r?\n'
}

check_gpt_invalid() {
    expect_serial 'baremetal> '
    console_check 'disk gpt' 'No valid supported GPT\.'
    console_check 'mount disk0p1 /disk' 'No valid supported GPT\.'
}

check_fat_read() {
    expect_serial 'baremetal> '
    console_check 'ls /disk' 'Directory not found\.'
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'disk mount 1' 'Usage: disk info'
    console_check 'disk unmount' 'Usage: disk info'
    console_check 'disk ls' 'Usage: disk info'
    console_check 'disk cat host.txt' 'Usage: disk info'
    console_check 'disk put msg host.txt' 'Usage: disk info'
    console_check 'ls /disk' 'HOST\.TXT'
    console_check 'cat /disk/host.txt' $'\r?\nHost seeded\r?\n'
    console_check 'ls /disk' 'LONGFI~1\.TXT'
    console_check 'cat /disk/LONGFI~1.TXT' $'\r?\nAlias data\r?\n'
    console_check 'cat /disk/empty.txt' $'cat /disk/empty\\.txt\r?\n'
    console_check 'cat /disk/missing.txt' 'Disk file not found\.'
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_fat_write() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'cp /ram/long.txt /disk/save.txt' 'Disk file saved\.'
    console_check 'cat /disk/save.txt' $'\r?\nFirst line\r?\n'
    console_check 'cp /disk/save.txt /disk/copy.txt' 'Disk file saved\.'
    console_check 'cp /disk/copy.txt /ram/readback.txt' 'cp /disk/copy\.txt'
    console_check 'cp /ram/readback.txt /ram/second.txt' 'cp /ram/readback\.txt'
    console_check 'crc32 second.txt' "$long_crc"$'\r?\n'
    console_check 'cp /disk/COPY.TXT /disk/copy.txt' 'Source and destination are the same file\.'
    console_check 'cp /ram/readback.txt /ram/readback.txt' 'Source and destination are the same file\.'
    console_check 'echo Replacement > /ram/msg' 'echo Replacement'
    console_check 'cp /ram/msg /disk/save.txt' 'Disk file saved\.'
    console_check 'cp /ram/empty.txt /disk/empty.txt' 'Disk file saved\.'
    console_check 'umount /disk' 'FAT32 unmounted\.'
    console_check 'reboot' 'Rebooting'
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'cat /disk/save.txt' $'\r?\nReplacement\r?\n'
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_fat_orphans() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'disk check' $'Orphaned FAT32 clusters: 2\r?\n'
    console_check 'cat /disk/host.txt' $'\r?\nHost seeded\r?\n'
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_fat_repair() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'disk repair' $'Reclaimed FAT32 clusters: 2\r?\n'
    console_check 'disk check' $'Orphaned FAT32 clusters: 0\r?\n'
    console_check 'disk repair' $'Reclaimed FAT32 clusters: 0\r?\n'
    console_check 'cat /disk/host.txt' $'\r?\nHost seeded\r?\n'
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_fat_repair_refusal() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'disk check' "$repair_error"
    console_check 'disk repair' "$repair_error"
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_fat_ownership_refusal() {
    local error='FAT32 check failed: cluster ownership could not be verified\.'
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'echo Replacement > /ram/msg' 'echo Replacement'
    console_check 'cp /ram/msg /disk/host.txt' "$error"
    console_check "echo Fresh > $create_target" "$error"
    console_check 'disk check' "$error"
    console_check 'disk repair' "$error"
    console_check 'cat /disk/host.txt' $'\r?\nHost seeded\r?\n'
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_fat_mirror_refusal() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'echo Fresh > /disk/new.txt' 'FAT32 check failed: FAT copies disagree\.'
    console_check 'echo Replacement > /ram/msg' 'echo Replacement'
    console_check 'cp /ram/msg /disk/host.txt' "$replacement_error"
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_fat_replace() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'echo Replacement > /ram/msg' 'echo Replacement'
    console_check 'cp /ram/msg /disk/host.txt' 'Disk file saved\.'
    console_check 'cat /disk/host.txt' $'\r?\nReplacement\r?\n'
    console_check 'cp /ram/msg /disk/lower.txt' 'Disk file saved\.'
    console_check 'disk check' $'Orphaned FAT32 clusters: 0\r?\n'
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_fat_create_with_bad_mirror() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'echo New file > /ram/msg' 'echo New file'
    console_check 'cp /ram/msg /disk/new.txt' 'Disk file saved\.'
    console_check 'cat /disk/new.txt' $'\r?\nNew file\r?\n'
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

# The fixtures below place their short entries in the first sector of
# each directory. Locate them by name before editing a cluster pointer.
short_entry_offset() {
    local image=$1 base=$2 name=$3 offset
    for ((offset = base; offset < base + 512; offset += 32)); do
        if dd if="$image" bs=1 skip="$offset" count=11 status=none | cmp -s - <(printf '%s' "$name"); then
            printf '%s\n' "$offset"
            return
        fi
    done
    printf 'FAT fixture entry missing: %s\n' "$name" >&2
    return 1
}

copy_cluster_pointer() {
    local image=$1 source=$2 target=$3 offset
    for offset in 20 26; do
        dd if="$image" bs=1 skip=$((source + offset)) count=2 status=none |
            dd of="$image" bs=1 seek=$((target + offset)) conv=notrunc status=none
    done
}

host_crc() {
    dd if="$1" bs=512 skip="$2" count=1 status=none |
        gzip -n | tail -c 8 | od -An -N4 -t x4 | tr -d ' \n' | tr 'a-f' 'A-F'
}

files=$(mktemp -d)
trap 'find "$files" -depth -delete' EXIT
build_dir="${1:-build}"
kernel="$build_dir/baremetal-os.elf"
slice="${2:-all}"

if [[ $slice == all || $slice == ata ]]; then
    truncate -s 1M "$files/ata.raw"
    printf 'Known first sector\n' | dd of="$files/ata.raw" conv=notrunc status=none
    printf 'A different sector\n' | dd of="$files/ata.raw" bs=512 seek=1 conv=notrunc status=none
    crc0=$(host_crc "$files/ata.raw" 0)
    crc1=$(host_crc "$files/ata.raw" 1)
    qemu-img convert -f raw -O qcow2 "$files/ata.raw" "$files/ata.qcow2"
    sha256sum "$files/ata.raw" "$files/ata.qcow2" > "$files/read-only.sha"

    run_guest 'ATA sector reads on RAW' 1 64M check_ata -machine pc -kernel "$kernel" \
        -drive "file=$files/ata.raw,format=raw,if=ide,index=0,snapshot=on"
    run_guest 'ATA sector reads on QCOW2' 1 64M check_ata -machine pc -kernel "$kernel" \
        -drive "file=$files/ata.qcow2,format=qcow2,if=ide,index=0,snapshot=on"
    run_guest 'ATA without a disk' 1 64M check_absent -machine pc -kernel "$kernel"
    sha256sum --check --status "$files/read-only.sha"

    truncate -s "$((268435457 * 512))" "$files/lba48.raw"
    printf 'Sector beyond the LBA28 range\n' |
        dd of="$files/lba48.raw" bs=512 seek=268435456 conv=notrunc status=none
    crc48=$(host_crc "$files/lba48.raw" 268435456)
    run_guest 'ATA sector above the LBA28 range' 1 64M check_lba48 -machine pc -kernel "$kernel" \
        -drive "file=$files/lba48.raw,format=raw,if=ide,index=0,snapshot=on"
fi

if [[ $slice == all || $slice == gpt || $slice == fat32 ]]; then
    truncate -s 68M "$files/disk.raw"
    sgdisk -n 1:2048:+64M -t 1:0700 "$files/disk.raw" >/dev/null
fi

if [[ $slice == all || $slice == gpt ]]; then
    cp --sparse=always "$files/disk.raw" "$files/backup.raw"
    # Damage the primary entry array without touching its header.
    printf 'X' | dd of="$files/backup.raw" bs=512 seek=2 conv=notrunc status=none
    cp --sparse=always "$files/backup.raw" "$files/invalid.raw"
    printf 'X' | dd of="$files/invalid.raw" bs=512 seek=$((68 * 2048 - 1)) conv=notrunc status=none

    run_guest 'Valid primary GPT' 1 64M check_gpt_primary -machine pc -kernel "$kernel" \
        -drive "file=$files/disk.raw,format=raw,if=ide,index=0,snapshot=on"
    run_guest 'GPT backup after primary-array corruption' 1 64M check_gpt_backup -machine pc -kernel "$kernel" \
        -drive "file=$files/backup.raw,format=raw,if=ide,index=0,snapshot=on"
    run_guest 'GPT with both copies invalid' 1 64M check_gpt_invalid -machine pc -kernel "$kernel" \
        -drive "file=$files/invalid.raw,format=raw,if=ide,index=0,snapshot=on"
fi

if [[ $slice == all || $slice == fat32 ]]; then
    truncate -s 64M "$files/volume"
    mkfs.fat -F 32 -s 1 "$files/volume" >/dev/null
    printf 'Host seeded\n' > "$files/host.txt"
    printf 'Peer seeded\n' > "$files/peer.txt"
    printf 'Alias data\n' > "$files/LongFileName.txt"
    touch "$files/empty.txt"
    mcopy -i "$files/volume" "$files/host.txt" "$files/empty.txt" \
        "$files/peer.txt" "$files/LongFileName.txt" ::
    mmd -i "$files/volume" ::SUBDIR
    mcopy -i "$files/volume" "$files/peer.txt" ::SUBDIR/NESTED.TXT
    dd if="$files/volume" of="$files/disk.raw" bs=1M seek=1 conv=notrunc status=none
    run_guest 'FAT32 read-only mount' 1 64M check_fat_read -machine pc -kernel "$kernel" \
        -drive "file=$files/disk.raw,format=raw,if=ide,index=0,snapshot=on"

    fat_reserved=$(od -An -tu2 -j 14 -N 2 "$files/volume")
    fat_size=$(od -An -tu4 -j 36 -N 4 "$files/volume")
    fat_count=$(od -An -tu1 -j 16 -N 1 "$files/volume")
    root_cluster=$(od -An -tu4 -j 44 -N 4 "$files/volume")
    data_offset=$((1048576 + (fat_reserved + fat_count * fat_size) * 512))
    root_offset=$((data_offset + (root_cluster - 2) * 512))
    host_entry=$(short_entry_offset "$files/disk.raw" "$root_offset" 'HOST    TXT')
    peer_entry=$(short_entry_offset "$files/disk.raw" "$root_offset" 'PEER    TXT')
    subdir_entry=$(short_entry_offset "$files/disk.raw" "$root_offset" 'SUBDIR     ')
    subdir_high=$(od -An -tu2 -j $((subdir_entry + 20)) -N 2 "$files/disk.raw")
    subdir_low=$(od -An -tu2 -j $((subdir_entry + 26)) -N 2 "$files/disk.raw")
    subdir_offset=$((data_offset + ((subdir_high << 16) + subdir_low - 2) * 512))
    nested_entry=$(short_entry_offset "$files/disk.raw" "$subdir_offset" 'NESTED  TXT')

    cp --sparse=always "$files/disk.raw" "$files/shared-root.raw"
    copy_cluster_pointer "$files/shared-root.raw" "$host_entry" "$peer_entry"
    create_target=/disk/new.txt check_image_unchanged 'FAT32 refuses writes on a root cross-link' \
        "$files/shared-root.raw" check_fat_ownership_refusal

    cp --sparse=always "$files/disk.raw" "$files/shared-subdir.raw"
    copy_cluster_pointer "$files/shared-subdir.raw" "$host_entry" "$nested_entry"
    create_target=/disk/subdir/new.txt check_image_unchanged 'FAT32 refuses writes on a subdirectory cross-link' \
        "$files/shared-subdir.raw" check_fat_ownership_refusal

    host_high=$(od -An -tu2 -j $((host_entry + 20)) -N 2 "$files/disk.raw")
    host_low=$(od -An -tu2 -j $((host_entry + 26)) -N 2 "$files/disk.raw")
    host_cluster=$(((host_high << 16) + host_low))
    for ((fat_index = 0; fat_index < fat_count; fat_index++)); do
        image="$files/bad-allocation-$fat_index.raw"
        cp --sparse=always "$files/disk.raw" "$image"
        free_offset=$((1048576 + (fat_reserved + fat_index * fat_size) * 512 + host_cluster * 4))
        printf '\000\000\000\000' | dd of="$image" bs=1 seek="$free_offset" conv=notrunc status=none
        replacement_error='FAT32 check failed: FAT copies disagree\.'
        if (( fat_index == 0 )); then
            replacement_error='Invalid or unsupported FAT32 cluster chain\.'
        fi
        check_image_unchanged "FAT32 refuses a reachable mismatch in FAT $((fat_index + 1))" \
            "$image" check_fat_mirror_refusal
    done

    # An unreferenced cluster claimed by only one FAT must still not be allocated.
    reserved_cluster=2
    while (( $(od -An -tu4 -j $((1048576 + fat_reserved * 512 + reserved_cluster * 4)) -N 4 "$files/disk.raw") != 0 )); do
        ((reserved_cluster += 1))
    done
    cp --sparse=always "$files/disk.raw" "$files/disputed-free.raw"
    reserved_offset=$((1048576 + (fat_reserved + fat_size) * 512 + reserved_cluster * 4))
    printf '\377\377\377\017' | dd of="$files/disputed-free.raw" bs=1 seek="$reserved_offset" conv=notrunc status=none
    reserved_lba=$((data_offset / 512 + reserved_cluster - 2))
    printf 'Unreferenced data' | dd of="$files/disputed-free.raw" bs=512 seek="$reserved_lba" conv=notrunc status=none
    run_guest 'FAT32 allocator skips an unreferenced disputed cluster' 1 64M check_fat_create_with_bad_mirror \
        -machine pc -kernel "$kernel" -drive "file=$files/disputed-free.raw,format=raw,if=ide,index=0"
    dd if="$files/disputed-free.raw" bs=1 skip="$(((reserved_lba * 512)))" count=17 status=none |
        cmp - <(printf 'Unreferenced data')
    mtype -i "$files/disputed-free.raw@@1048576" ::NEW.TXT | cmp - <(printf 'New file\n')

    image="$files/replacement.raw"
    cp --sparse=always "$files/disk.raw" "$image"
    mcopy -i "$image@@1048576" "$files/host.txt" ::lower.txt
    lower_entry=$(short_entry_offset "$image" "$root_offset" 'LOWER   TXT')
    printf '\006' | dd of="$image" bs=1 seek=$((host_entry + 11)) conv=notrunc status=none
    printf '\115\134\144\106\130' > "$files/creation-time"
    dd if="$files/creation-time" of="$image" bs=1 seek=$((host_entry + 13)) conv=notrunc status=none
    dd if="$image" bs=1 skip=$((lower_entry + 12)) count=1 status=none | cmp - <(printf '\030')
    truncate -s 34M "$files/large.bin"
    printf 'last sector' | dd of="$files/large.bin" bs=512 seek=$((34 * 2048 - 1)) conv=notrunc status=none
    mcopy -i "$image@@1048576" "$files/large.bin" ::LARGE.BIN
    run_guest 'FAT32 replacement preserves metadata beside a large file' 1 64M check_fat_replace \
        -machine pc -kernel "$kernel" -drive "file=$image,format=raw,if=ide,index=0"
    dd if="$image" bs=1 skip=$((host_entry + 11)) count=1 status=none | cmp - <(printf '\046')
    dd if="$image" bs=1 skip=$((host_entry + 13)) count=5 status=none | cmp - "$files/creation-time"
    mdir -b -i "$image@@1048576" :: | grep -Fx '::/lower.txt'
    dd if="$image" bs=1 skip=$((lower_entry + 12)) count=1 status=none | cmp - <(printf '\030')
    mtype -i "$image@@1048576" ::lower.txt | cmp - <(printf 'Replacement\n')
    mtype -i "$image@@1048576" ::HOST.TXT | cmp - <(printf 'Replacement\n')
    mtype -i "$image@@1048576" ::LARGE.BIN | cmp - "$files/large.bin"

    cp --sparse=always "$files/disk.raw" "$files/cycle.raw"
    peer_high=$(od -An -tu2 -j $((peer_entry + 20)) -N 2 "$files/disk.raw")
    peer_low=$(od -An -tu2 -j $((peer_entry + 26)) -N 2 "$files/disk.raw")
    peer_cluster=$(((peer_high << 16) + peer_low))
    printf -v self_link '\\%03o\\%03o\\%03o\\%03o' \
        "$((peer_cluster & 255))" "$((peer_cluster >> 8 & 255))" \
        "$((peer_cluster >> 16 & 255))" "$((peer_cluster >> 24 & 255))"
    for ((fat_index = 0; fat_index < fat_count; fat_index++)); do
        cycle_offset=$((1048576 + (fat_reserved + fat_index * fat_size) * 512 + peer_cluster * 4))
        printf '%b' "$self_link" | dd of="$files/cycle.raw" bs=1 seek="$cycle_offset" conv=notrunc status=none
    done
    create_target=/disk/new.txt check_image_unchanged 'FAT32 refuses writes if a file chain loops' \
        "$files/cycle.raw" check_fat_ownership_refusal

    printf 'First line\n%0600d\n' 1 > "$files/long.txt"
    long_crc=$(gzip -n < "$files/long.txt" | tail -c 8 | od -An -N4 -t x4 | tr -d ' \n' | tr 'a-f' 'A-F')
    tar --format=ustar -C "$files" -cf "$files/ramfs.tar" long.txt empty.txt

    run_vfs_fixtures

    qemu-img convert -f raw -O qcow2 "$files/disk.raw" "$files/disk.qcow2"
    for format in raw qcow2; do
        run_guest "FAT32 create, replace, and reboot on $format" 1 64M check_fat_write \
            -machine pc -kernel "$kernel" -initrd "$files/ramfs.tar" \
            -drive "file=$files/disk.$format,format=$format,if=ide,index=0"
    done
    qemu-img convert -f qcow2 -O raw "$files/disk.qcow2" "$files/readback.raw"
    for image in "$files/disk.raw" "$files/readback.raw"; do
        mtype -i "$image@@1048576" ::SAVE.TXT | cmp - <(printf 'Replacement\n')
        mtype -i "$image@@1048576" ::COPY.TXT | cmp - "$files/long.txt"
        mtype -i "$image@@1048576" ::HOST.TXT | cmp - "$files/host.txt"
        mtype -i "$image@@1048576" ::EMPTY.TXT | cmp - /dev/null
        dd if="$image" of="$files/check-volume" bs=1M skip=1 count=64 status=none
        fsck.fat -n "$files/check-volume"
    done
fi
