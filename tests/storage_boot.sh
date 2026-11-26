#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

source tests/qemu_serial.sh

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
    console_check 'disk mount 1' 'No valid supported GPT\.'
}

check_fat_read() {
    expect_serial 'baremetal> '
    console_check 'disk ls' 'No FAT32 volume mounted\.'
    console_check 'disk mount 1' 'FAT32 mounted\.'
    console_check 'disk ls' 'HOST\.TXT'
    console_check 'disk cat host.txt' $'\r?\nHost seeded\r?\n'
    console_check 'disk ls' 'LONGFI~1\.TXT'
    console_check 'disk cat LONGFI~1.TXT' $'\r?\nAlias data\r?\n'
    console_check 'disk cat empty.txt' $'disk cat empty\\.txt\r?\n'
    console_check 'disk cat missing.txt' 'Disk file not found\.'
    console_check 'disk unmount' 'FAT32 unmounted\.'
}

check_fat_write() {
    expect_serial 'baremetal> '
    console_check 'disk mount 1' 'FAT32 mounted\.'
    console_check 'disk put long.txt save.txt' 'Disk file saved\.'
    console_check 'disk cat save.txt' $'\r?\nFirst line\r?\n'
    console_check 'echo Replacement > msg' 'echo Replacement'
    console_check 'disk put msg save.txt' 'Disk file saved\.'
    console_check 'disk put empty.txt empty.txt' 'Disk file saved\.'
    console_check 'disk unmount' 'FAT32 unmounted\.'
    console_check 'reboot' 'Rebooting'
    console_check 'disk mount 1' 'FAT32 mounted\.'
    console_check 'disk cat save.txt' $'\r?\nReplacement\r?\n'
    console_check 'disk unmount' 'FAT32 unmounted\.'
}

check_fat_interruption() {
    expect_serial 'baremetal> '
    console_check 'disk mount 1' 'FAT32 mounted\.'
    printf 'disk put long.txt host.txt\r' >&"$serial_write"
    expect_serial 'Test: replacement data flushed before directory update\.'
}

check_fat_orphans() {
    expect_serial 'baremetal> '
    console_check 'disk mount 1' 'FAT32 mounted\.'
    console_check 'disk check' $'Orphaned FAT32 clusters: 2\r?\n'
    console_check 'disk cat host.txt' $'\r?\nHost seeded\r?\n'
    console_check 'disk unmount' 'FAT32 unmounted\.'
}

check_fat_repair() {
    expect_serial 'baremetal> '
    console_check 'disk mount 1' 'FAT32 mounted\.'
    console_check 'disk repair' $'Reclaimed FAT32 clusters: 2\r?\n'
    console_check 'disk check' $'Orphaned FAT32 clusters: 0\r?\n'
    console_check 'disk repair' $'Reclaimed FAT32 clusters: 0\r?\n'
    console_check 'disk cat host.txt' $'\r?\nHost seeded\r?\n'
    console_check 'disk unmount' 'FAT32 unmounted\.'
}

check_fat_repair_refusal() {
    expect_serial 'baremetal> '
    console_check 'disk mount 1' 'FAT32 mounted\.'
    console_check 'disk check' "$repair_error"
    console_check 'disk repair' "$repair_error"
    console_check 'disk unmount' 'FAT32 unmounted\.'
}

check_fat_refusal() {
    expect_serial 'baremetal> '
    console_check 'disk mount 1' 'FAT32 mounted\.'
    console_check 'echo Replacement > msg' 'echo Replacement'
    console_check 'disk put msg host.txt' "$refusal"
    console_check 'disk cat host.txt' $'\r?\nHost seeded\r?\n'
    console_check 'disk unmount' 'FAT32 unmounted\.'
}

check_fat_replace() {
    expect_serial 'baremetal> '
    console_check 'disk mount 1' 'FAT32 mounted\.'
    console_check 'echo Replacement > msg' 'echo Replacement'
    console_check 'disk put msg host.txt' 'Disk file saved\.'
    console_check 'disk cat host.txt' $'\r?\nReplacement\r?\n'
    console_check 'disk check' $'Orphaned FAT32 clusters: 0\r?\n'
    console_check 'disk unmount' 'FAT32 unmounted\.'
}

check_fat_create_with_bad_mirror() {
    expect_serial 'baremetal> '
    console_check 'disk mount 1' 'FAT32 mounted\.'
    console_check 'echo New file > msg' 'echo New file'
    console_check 'disk put msg new.txt' 'Disk file saved\.'
    console_check 'disk cat new.txt' $'\r?\nNew file\r?\n'
    console_check 'disk unmount' 'FAT32 unmounted\.'
}

check_fat_replace_lowercase() {
    expect_serial 'baremetal> '
    console_check 'disk mount 1' 'FAT32 mounted\.'
    console_check 'echo Replacement > msg' 'echo Replacement'
    console_check 'disk put msg lower.txt' 'Disk file saved\.'
    console_check 'disk cat lower.txt' $'\r?\nReplacement\r?\n'
    console_check 'disk unmount' 'FAT32 unmounted\.'
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

check_unchanged_image() {
    local label=$1 image=$2 refusal=$3
    sha256sum "$image" > "$files/rejected.sha"
    run_guest "$label" 1 64M check_fat_refusal \
        -machine pc -kernel "$kernel" -drive "file=$image,format=raw,if=ide,index=0"
    sha256sum --check --status "$files/rejected.sha"
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
    check_unchanged_image 'FAT32 rejects a root cross-link' "$files/shared-root.raw" \
        'FAT32 replacement refused: shared cluster chain\.'
    mtype -i "$files/shared-root.raw@@1048576" ::PEER.TXT | cmp - "$files/host.txt"

    cp --sparse=always "$files/disk.raw" "$files/shared-subdir.raw"
    copy_cluster_pointer "$files/shared-subdir.raw" "$host_entry" "$nested_entry"
    check_unchanged_image 'FAT32 rejects a subdirectory cross-link' "$files/shared-subdir.raw" \
        'FAT32 replacement refused: shared cluster chain\.'
    mtype -i "$files/shared-subdir.raw@@1048576" ::SUBDIR/NESTED.TXT | cmp - "$files/host.txt"

    cp --sparse=always "$files/disk.raw" "$files/bad-mirror.raw"
    host_high=$(od -An -tu2 -j $((host_entry + 20)) -N 2 "$files/disk.raw")
    host_low=$(od -An -tu2 -j $((host_entry + 26)) -N 2 "$files/disk.raw")
    mirror_offset=$((1048576 + (fat_reserved + fat_size) * 512 + ((host_high << 16) + host_low) * 4))
    printf '\000\000\000\000' | dd of="$files/bad-mirror.raw" bs=1 seek="$mirror_offset" conv=notrunc status=none
    check_unchanged_image 'FAT32 refuses replacement if FAT copies disagree' "$files/bad-mirror.raw" \
        'FAT32 replacement refused: cluster ownership could not be verified\.'

    host_cluster=$(((host_high << 16) + host_low))
    host_lba=$((data_offset / 512 + host_cluster - 2))
    for ((fat_index = 0; fat_index < fat_count; fat_index++)); do
        image="$files/bad-allocation-$fat_index.raw"
        cp --sparse=always "$files/disk.raw" "$image"
        free_offset=$((1048576 + (fat_reserved + fat_index * fat_size) * 512 + host_cluster * 4))
        printf '\000\000\000\000' | dd of="$image" bs=1 seek="$free_offset" conv=notrunc status=none
        run_guest "FAT32 skips a live cluster marked free in FAT $((fat_index + 1))" 1 64M \
            check_fat_create_with_bad_mirror -machine pc -kernel "$kernel" \
            -drive "file=$image,format=raw,if=ide,index=0"
        dd if="$image" bs=1 skip="$free_offset" count=4 status=none | cmp - <(printf '\000\000\000\000')
        # Read the original data directly when the first FAT's chain is invalid.
        dd if="$image" bs=512 skip="$host_lba" count=1 status=none |
            cmp - <(dd if="$files/disk.raw" bs=512 skip="$host_lba" count=1 status=none)
        mtype -i "$image@@1048576" ::NEW.TXT | cmp - <(printf 'New file\n')
    done

    cp --sparse=always "$files/disk.raw" "$files/attributes.raw"
    printf '\006' | dd of="$files/attributes.raw" bs=1 seek=$((host_entry + 11)) conv=notrunc status=none
    printf '\115\134\144\106\130' > "$files/creation-time"
    dd if="$files/creation-time" of="$files/attributes.raw" bs=1 seek=$((host_entry + 13)) conv=notrunc status=none
    run_guest 'FAT32 replacement preserves attributes and creation time' 1 64M check_fat_replace \
        -machine pc -kernel "$kernel" -drive "file=$files/attributes.raw,format=raw,if=ide,index=0"
    dd if="$files/attributes.raw" bs=1 skip=$((host_entry + 11)) count=1 status=none | cmp - <(printf '\046')
    dd if="$files/attributes.raw" bs=1 skip=$((host_entry + 13)) count=5 status=none | cmp - "$files/creation-time"

    cp --sparse=always "$files/disk.raw" "$files/lowercase.raw"
    mcopy -i "$files/lowercase.raw@@1048576" "$files/host.txt" ::lower.txt
    lower_entry=$(short_entry_offset "$files/lowercase.raw" "$root_offset" 'LOWER   TXT')
    dd if="$files/lowercase.raw" bs=1 skip=$((lower_entry + 12)) count=1 status=none | cmp - <(printf '\030')
    run_guest 'FAT32 replacement preserves short-name case' 1 64M check_fat_replace_lowercase \
        -machine pc -kernel "$kernel" -drive "file=$files/lowercase.raw,format=raw,if=ide,index=0"
    mdir -b -i "$files/lowercase.raw@@1048576" :: | grep -Fx '::/lower.txt'
    dd if="$files/lowercase.raw" bs=1 skip=$((lower_entry + 12)) count=1 status=none | cmp - <(printf '\030')
    mtype -i "$files/lowercase.raw@@1048576" ::lower.txt | cmp - <(printf 'Replacement\n')

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
    check_unchanged_image 'FAT32 refuses replacement if a file chain loops' "$files/cycle.raw" \
        'FAT32 replacement refused: cluster ownership could not be verified\.'

    cp --sparse=always "$files/disk.raw" "$files/large-peer.raw"
    truncate -s 34M "$files/large.bin"
    printf 'last sector' | dd of="$files/large.bin" bs=512 seek=$((34 * 2048 - 1)) conv=notrunc status=none
    mcopy -i "$files/large-peer.raw@@1048576" "$files/large.bin" ::LARGE.BIN
    run_guest 'FAT32 replacement beside an unrelated 34 MiB file' 1 64M check_fat_replace \
        -machine pc -kernel "$kernel" -drive "file=$files/large-peer.raw,format=raw,if=ide,index=0"
    mtype -i "$files/large-peer.raw@@1048576" ::HOST.TXT | cmp - <(printf 'Replacement\n')
    mtype -i "$files/large-peer.raw@@1048576" ::LARGE.BIN | cmp - "$files/large.bin"

    printf 'First line\n%0600d\n' 1 > "$files/long.txt"
    tar --format=ustar -C "$files" -cf "$files/ramfs.tar" long.txt empty.txt
    cp --sparse=always "$files/disk.raw" "$files/interrupted.raw"
    QEMU_TEST_POWER_CUT=1 run_guest 'FAT32 interrupted before directory publication' 1 64M \
        check_fat_interruption -machine pc -kernel "$build_dir/fat32-interrupt.elf" \
        -initrd "$files/ramfs.tar" -drive "file=$files/interrupted.raw,format=raw,if=ide,index=0"
    mtype -i "$files/interrupted.raw@@1048576" ::HOST.TXT | cmp - "$files/host.txt"
    sha256sum "$files/interrupted.raw" > "$files/interrupted.sha"
    run_guest 'FAT32 check reports orphans without writing' 1 64M check_fat_orphans \
        -machine pc -kernel "$kernel" -drive "file=$files/interrupted.raw,format=raw,if=ide,index=0"
    sha256sum --check --status "$files/interrupted.sha"

    cp --sparse=always "$files/interrupted.raw" "$files/repair-mismatch.raw"
    # The mismatch is in a later FAT sector than the orphaned chain.
    mismatch_offset=$((1048576 + (fat_reserved + fat_size) * 512 + 50000 * 4))
    printf '\377\377\377\017' | dd of="$files/repair-mismatch.raw" bs=1 seek="$mismatch_offset" conv=notrunc status=none
    sha256sum "$files/repair-mismatch.raw" > "$files/repair-mismatch.sha"
    repair_error='FAT32 check failed: FAT copies disagree\.' \
        run_guest 'FAT32 repair refuses a late FAT mismatch' 1 64M check_fat_repair_refusal \
        -machine pc -kernel "$kernel" -drive "file=$files/repair-mismatch.raw,format=raw,if=ide,index=0"
    sha256sum --check --status "$files/repair-mismatch.sha"

    cp --sparse=always "$files/interrupted.raw" "$files/repair-cross-link.raw"
    copy_cluster_pointer "$files/repair-cross-link.raw" "$host_entry" "$nested_entry"
    sha256sum "$files/repair-cross-link.raw" > "$files/repair-cross-link.sha"
    repair_error='FAT32 check failed: cluster ownership could not be verified\.' \
        run_guest 'FAT32 repair refuses a cross-linked directory tree' 1 64M check_fat_repair_refusal \
        -machine pc -kernel "$kernel" -drive "file=$files/repair-cross-link.raw,format=raw,if=ide,index=0"
    sha256sum --check --status "$files/repair-cross-link.sha"

    run_guest 'FAT32 repair reclaims an interrupted replacement' 1 64M check_fat_repair \
        -machine pc -kernel "$kernel" -drive "file=$files/interrupted.raw,format=raw,if=ide,index=0"
    mtype -i "$files/interrupted.raw@@1048576" ::HOST.TXT | cmp - "$files/host.txt"
    mtype -i "$files/interrupted.raw@@1048576" ::SUBDIR/NESTED.TXT | cmp - "$files/peer.txt"
    # Both tables must match their contents before the interrupted write.
    fat_lba=$((2048 + fat_reserved))
    fat_sectors=$((fat_size * fat_count))
    dd if="$files/interrupted.raw" bs=512 skip="$fat_lba" count="$fat_sectors" status=none |
        cmp - <(dd if="$files/disk.raw" bs=512 skip="$fat_lba" count="$fat_sectors" status=none)

    qemu-img convert -f raw -O qcow2 "$files/disk.raw" "$files/disk.qcow2"
    for format in raw qcow2; do
        run_guest "FAT32 create, replace, and reboot on $format" 1 64M check_fat_write \
            -machine pc -kernel "$kernel" -initrd "$files/ramfs.tar" \
            -drive "file=$files/disk.$format,format=$format,if=ide,index=0"
    done
    qemu-img convert -f qcow2 -O raw "$files/disk.qcow2" "$files/readback.raw"
    for image in "$files/disk.raw" "$files/readback.raw"; do
        mtype -i "$image@@1048576" ::SAVE.TXT | cmp - <(printf 'Replacement\n')
        mtype -i "$image@@1048576" ::HOST.TXT | cmp - "$files/host.txt"
        mtype -i "$image@@1048576" ::EMPTY.TXT | cmp - /dev/null
        dd if="$image" of="$files/check-volume" bs=1M skip=1 count=64 status=none
        fsck.fat -n "$files/check-volume"
    done
fi
