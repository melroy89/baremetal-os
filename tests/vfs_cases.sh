# FAT32 shell and mount checks sourced by storage_boot.sh.

check_vfs_files() {
    expect_serial 'baremetal> '
    console_check 'pwd' $'\r?\n/\r?\n'
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'ls /' $'\r?\n/ram\r?\n/disk\r?\n'
    console_check 'echo RAM > /ram/name with spaces' 'echo RAM'
    console_check 'cat /ram/name with spaces' $'\r?\nRAM\r?\n'
    console_check 'cd //disk/./' 'cd //disk/\./'
    console_check 'cd missing/../note.txt' 'FAT32 directory not found\.'
    console_check 'pwd' $'\r?\n/disk\r?\n'
    console_check 'echo "Left > right">note.txt' 'Disk file saved\.'
    console_check 'echo "" > /disk/empty1.txt' 'Disk file saved\.'
    console_check 'echo >/disk/empty2.txt' 'Disk file saved\.'
    console_check 'cp "/ram/no newline.txt" /disk/raw.txt' 'Disk file saved\.'
    console_check 'cp /ram/empty.txt /disk/zero.txt' 'Disk file saved\.'
    console_check 'crc32 no newline.txt' "$raw_crc"$'\r?\n'
    console_check 'echo Files here > /file.txt' 'Expected a file path, found a directory\.'
    console_check 'rm /disk' 'Expected a file path, found a directory\.'
    console_check 'rm /ram' 'Expected a file path, found a directory\.'
    console_check 'cd subdir/' 'cd subdir/'
    console_check 'pwd' $'\r?\n/disk/subdir\r?\n'
    console_check 'cat nested.txt' $'\r?\nPeer seeded\r?\n'
    printf 'touch empty.txt\r' >&"$serial_write"
    expect_serial $'touch empty\\.txt\r?\nbaremetal> '
    console_check 'touch /disk/subdir' 'Disk name refers to a directory\.'
    console_check 'echo Saved > nested.txt' 'Disk file saved\.'
    console_check 'cat nested.txt' $'\r?\nSaved\r?\n'
    console_check 'cat /disk/host.txt' $'\r?\nHost seeded\r?\n'
    console_check 'umount /disk' 'Current directory is on this volume\.'
    console_check 'cd ../..' 'cd \.\./\.\.'
    console_check 'cd ..' 'cd \.\.'
    console_check 'pwd' $'\r?\n/\r?\n'
    console_check 'umount /disk' 'FAT32 unmounted\.'
    console_check 'reboot' 'Rebooting'
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'cat /disk/note.txt' $'\r?\nLeft > right\r?\n'
    console_check 'cat /disk/subdir/nested.txt' $'\r?\nSaved\r?\n'
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_touch_existing() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    printf 'touch /disk/host.txt\r' >&"$serial_write"
    expect_serial $'touch /disk/host\\.txt\r?\nbaremetal> '
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_existing_file_refusals() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'echo Replacement > /ram/msg' 'echo Replacement'
    console_check 'echo Replacement > /disk/host.txt' "$refusal"
    console_check 'cp /ram/msg /disk/host.txt' "$refusal"
    console_check 'rm /disk/host.txt' "$refusal"
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_invalid_file_commands() {
    local padding
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'echo "unterminated > /disk/host.txt' 'Usage: echo'
    console_check 'echo invalid >> /disk/host.txt' 'Usage: echo'
    printf -v padding '%01024d' 0
    console_check "echo ${padding}>/disk/host.txt" 'Command too long\.'
    console_check 'rm /disk' 'Expected a file path, found a directory\.'
    console_check 'rm /disk/subdir' 'Disk name refers to a directory\.'
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_vfs_lfn() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'echo "Alias replacement" > /disk/longfi~1.txt' 'Disk file saved\.'
    console_check 'cat /disk/longfi~1.txt' $'\r?\nAlias replacement\r?\n'
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_vfs_remove() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check "rm /disk/$remove_name" "rm /disk/$remove_name"
    console_check "cat /disk/$remove_name" 'Disk file not found\.'
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_lfn_remove_refusal() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'rm /disk/longfi~1.txt' 'Cannot remove a FAT32 file with long-name entries\.'
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_deletion_interrupted() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    printf 'rm /disk/cut.txt\r' >&"$serial_write"
    expect_serial 'Test: second FAT32 flush complete\.'
}

check_replacement_interrupted() {
    local replacement
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    printf -v replacement '%0600d' 1
    printf 'echo %s > /disk/host.txt\r' "$replacement" >&"$serial_write"
    expect_serial 'Test: second FAT32 flush complete\.'
}

check_deletion_check() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'cat /disk/cut.txt' 'Disk file not found\.'
    console_check 'disk check' $'Orphaned FAT32 clusters: 2\r?\n'
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_deletion_repair() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'disk repair' $'Reclaimed FAT32 clusters: 2\r?\n'
    console_check 'cat /disk/cut.txt' 'Disk file not found\.'
    console_check 'cat /disk/host.txt' $'\r?\nHost seeded\r?\n'
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_mount_volumes() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'mount disk0p2 /backup' 'FAT32 mounted\.'
    console_check 'mount' $'\r?\n/ram\r?\n/disk\r?\n/backup\r?\n'
    console_check 'mount disk0p2 /duplicate' 'Partition overlaps an active mount\.'
    console_check 'cd /backup' 'cd /backup'
    console_check 'umount /backup/' 'Current directory is on this volume\.'
    console_check 'echo Backup > host.txt' 'Disk file saved\.'
    console_check 'cp /backup/host.txt /disk/copied.txt' 'Disk file saved\.'
    console_check 'cat /disk/host.txt' $'\r?\nHost seeded\r?\n'
    console_check 'cat host.txt' $'\r?\nBackup\r?\n'
    console_check 'disk check' $'Orphaned FAT32 clusters: 0\r?\n'
    console_check 'disk repair' $'Reclaimed FAT32 clusters: 0\r?\n'
    console_check 'disk check /backup' $'Orphaned FAT32 clusters: 1\r?\n'
    console_check 'disk check /backup/' $'Orphaned FAT32 clusters: 1\r?\n'
    console_check 'disk repair /backup' $'Reclaimed FAT32 clusters: 1\r?\n'
    console_check 'disk repair /backup/' $'Reclaimed FAT32 clusters: 0\r?\n'
    for invalid in / /backup/foo /backup//; do
        console_check "disk check $invalid" 'No FAT32 volume mounted\.'
        console_check "disk repair $invalid" 'No FAT32 volume mounted\.'
    done
    console_check 'umount /disk' 'FAT32 unmounted\.'
    console_check 'disk check' 'No FAT32 volume mounted\.'
    console_check 'cat host.txt' $'\r?\nBackup\r?\n'
    console_check 'cd /' 'cd /'
    console_check 'umount /backup' 'FAT32 unmounted\.'
}

check_mount_fault() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'mount disk0p2 /backup' 'FAT32 mounted\.'
    console_check 'echo Fail > /disk/host.txt' 'Test: ATA write failed\.'
    console_check 'cat /disk/host.txt' $'\r?\nHost seeded\r?\n'
    console_check 'disk check' $'Orphaned FAT32 clusters: 0\r?\n'
    console_check 'disk repair' 'FAT32 writes stopped'
    console_check 'rm /disk/host.txt' 'FAT32 writes stopped'
    console_check 'echo OK > /backup/fault.txt' 'Disk file saved\.'
    console_check 'umount /disk' 'Test: ATA flush failed\.'
    console_check 'mount disk0p1 /duplicate' 'Partition overlaps an active mount\.'
    console_check 'echo Still blocked > /disk/host.txt' 'FAT32 writes stopped'
    console_check 'umount /disk' 'FAT32 unmounted\.'
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'echo Remounted > /disk/host.txt' 'Disk file saved\.'
    console_check 'umount /disk' 'FAT32 unmounted\.'
    console_check 'umount /backup' 'FAT32 unmounted\.'
}

check_mount_overlap() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'mount disk0p2 /backup' 'Partition overlaps an active mount\.'
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_directory_growth() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'echo First > /disk/subdir/next.txt' 'Disk file saved\.'
    console_check 'echo Second > /disk/subdir/after.txt' 'Disk file saved\.'
    console_check 'disk check' $'Orphaned FAT32 clusters: 0\r?\n'
    console_check 'reboot' 'Rebooting'
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'cat /disk/subdir/nested.txt' $'\r?\nPeer seeded\r?\n'
    console_check 'cat /disk/subdir/next.txt' $'\r?\nFirst\r?\n'
    console_check 'cat /disk/subdir/after.txt' $'\r?\nSecond\r?\n'
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_growth_power_cut() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    printf 'echo First > /disk/subdir/next.txt\r' >&"$serial_write"
    expect_serial 'Test: second FAT32 flush complete\.'
}

check_deep_directory_tree() {
    local pages_in_use
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check "cat /disk/$guest_deep_path/leaf.txt" $'\r?\nPeer seeded\r?\n'
    printf 'mem\r' >&"$serial_write"
    expect_serial '4 KiB pages: [0-9]+ managed, ([0-9]+) used,'
    pages_in_use=${BASH_REMATCH[1]}
    expect_serial 'baremetal> '
    console_check 'echo Saved > /disk/root.txt' 'Disk file saved\.'
    console_check 'disk check' $'Orphaned FAT32 clusters: 0\r?\n'
    console_check 'mem' "4 KiB pages: [0-9]+ managed, $pages_in_use used,"
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

check_corrupt_root_traversal() {
    expect_serial 'baremetal> '
    console_check 'mount disk0p1 /disk' 'FAT32 mounted\.'
    console_check 'cd /disk' 'Invalid or unsupported FAT32 cluster chain\.'
    console_check 'pwd' $'\r?\n/\r?\n'
    console_check 'cd /disk/..' 'Invalid or unsupported FAT32 cluster chain\.'
    console_check 'pwd' $'\r?\n/\r?\n'
    console_check 'disk check /disk' 'FAT32 check failed: cluster ownership could not be verified\.'
    console_check 'umount /disk' 'FAT32 unmounted\.'
}

# Verify a rejected operation against the same on-disk bytes seen at boot.
check_image_unchanged() {
    local label=$1 image=$2 check=$3
    sha256sum "$image" > "$files/vfs-before.sha"
    run_guest "$label" 1 64M "$check" -machine pc -kernel "$kernel" \
        -drive "file=$image,format=raw,if=ide,index=0"
    sha256sum --check --status "$files/vfs-before.sha"
}

check_lfn_boundary() {
    local spc=$1 part_size=$2
    local volume="$files/lfn-$spc.vol" image="$files/lfn-$spc.raw"
    local fill names=()
    truncate -s "${part_size}M" "$volume"
    mkfs.fat -F 32 -s "$spc" "$volume" >/dev/null
    for ((fill = 0; fill < 15; fill++)); do
        names+=("$files/fill$fill")
        touch "${names[-1]}"
    done
    mcopy -i "$volume" "${names[@]}" ::
    mcopy -i "$volume" "$files/LongFileName.txt" ::
    mcopy -i "$volume" "$files/peer.txt" ::AFTER.TXT
    truncate -s "$((part_size + 4))M" "$image"
    sgdisk -n "1:2048:+${part_size}M" -t 1:0700 "$image" >/dev/null
    dd if="$volume" of="$image" bs=1M seek=1 conv=sparse,notrunc status=none

    # The first LFN slot is the last slot in the first directory sector.
    local reserved size copies root root_lba
    reserved=$(od -An -tu2 -j 14 -N 2 "$volume")
    size=$(od -An -tu4 -j 36 -N 4 "$volume")
    copies=$(od -An -tu1 -j 16 -N 1 "$volume")
    root=$(od -An -tu4 -j 44 -N 4 "$volume")
    root_lba=$((2048 + reserved + copies * size + (root - 2) * spc))
    [[ $(od -An -tu1 -j $((root_lba * 512 + 15 * 32 + 11)) -N 1 "$image") -eq 15 ]]
    check_image_unchanged "FAT32 refuses an LFN crossing a boundary ($spc sectors per cluster)" \
        "$image" check_lfn_remove_refusal
    remove_name=after.txt run_guest 'FAT32 clears the LFN state for later files' 1 64M check_vfs_remove \
        -machine pc -kernel "$kernel" -drive "file=$image,format=raw,if=ide,index=0"
    mtype -i "$image@@1048576" ::LONGFI~1.TXT | cmp - "$files/LongFileName.txt"
}

# Write a little-endian integer in a disposable image.
write_image_le() {
    local image=$1 offset=$2 value=$3 size=$4 byte encoded=
    for ((byte = 0; byte < size; byte++)); do
        printf -v encoded '%s\\%03o' "$encoded" "$((value >> (8 * byte) & 255))"
    done
    printf '%b' "$encoded" | dd of="$image" bs=1 seek="$offset" conv=notrunc status=none
}

gpt_checksum() {
    local image=$1 offset=$2 size=$3
    dd if="$image" bs=1 skip="$offset" count="$size" status=none |
        gzip -n | tail -c 8 | od -An -N4 -tu4
}

make_overlapping_gpt() {
    local image=$1 header_lba entry_lba header_offset entry_offset checksum
    local last_lba=$((132 * 2048 - 1))
    for header_lba in 1 "$last_lba"; do
        header_offset=$((header_lba * 512))
        entry_lba=$(od -An -tu8 -j $((header_offset + 72)) -N 8 "$image")
        entry_offset=$((entry_lba * 512))
        write_image_le "$image" "$((entry_offset + 128 + 32))" 133119 8
        checksum=$(gpt_checksum "$image" "$entry_offset" 16384)
        write_image_le "$image" "$((header_offset + 88))" "$checksum" 4
        write_image_le "$image" "$((header_offset + 16))" 0 4
        checksum=$(gpt_checksum "$image" "$header_offset" 92)
        write_image_le "$image" "$((header_offset + 16))" "$checksum" 4
    done
}

run_directory_fixtures() {
    local image="$files/directory-growth.raw" cut_image="$files/growth-cut.raw"
    local entry copy offset depth deep_path= guest_deep_path=
    local cluster=2 free_clusters=0 stale_sector
    local directories=()
    cp --sparse=always "$files/disk.raw" "$image"
    # SUBDIR has dot entries and NESTED.TXT, leaving 13 of its 16 slots free.
    for ((entry = 1; entry <= 13; entry++)); do
        mcopy -i "$image@@1048576" "$files/peer.txt" "::SUBDIR/F$entry.TXT"
    done
    # The new file takes the first free cluster and the extension the second.
    # Seed the extension with stale bytes so the zeroing step is observable.
    while (( free_clusters < 2 )); do
        offset=$((1048576 + fat_reserved * 512 + cluster * 4))
        if (( $(od -An -tu4 -j "$offset" -N 4 "$image") == 0 )); then
            ((free_clusters += 1))
        fi
        ((cluster += 1))
    done
    stale_sector=$((data_offset / 512 + cluster - 3))
    printf '%0512d' 0 | dd of="$image" bs=512 seek="$stale_sector" conv=notrunc status=none
    cp --sparse=always "$image" "$cut_image"
    run_guest 'FAT32 grows a full subdirectory' 1 64M check_directory_growth \
        -machine pc -kernel "$kernel" -drive "file=$image,format=raw,if=ide,index=0"
    mtype -i "$image@@1048576" ::SUBDIR/NEXT.TXT | cmp - <(printf 'First\n')
    mtype -i "$image@@1048576" ::SUBDIR/AFTER.TXT | cmp - <(printf 'Second\n')
    mtype -i "$image@@1048576" ::SUBDIR/F13.TXT | cmp - "$files/peer.txt"
    dd if="$image" of="$files/growth-volume" bs=1M skip=1 count=64 status=none
    fsck.fat -n "$files/growth-volume"

    QEMU_TEST_POWER_CUT=1 run_guest 'FAT32 interrupted before linking the directory extension' 1 64M check_growth_power_cut \
        -machine pc -kernel "$build_dir/fat32-interrupt.elf" -drive "file=$cut_image,format=raw,if=ide,index=0"
    dd if="$cut_image" bs=512 skip="$stale_sector" count=1 status=none |
        cmp - <(head -c 512 /dev/zero)
    if mtype -i "$cut_image@@1048576" ::SUBDIR/NEXT.TXT 2>/dev/null; then
        printf 'Interrupted directory extension published a file\n' >&2
        return 1
    fi
    check_image_unchanged 'FAT32 checks the interrupted directory extension' "$cut_image" check_fat_orphans
    run_guest 'FAT32 reclaims the unpublished directory extension and file' 1 64M check_fat_repair \
        -machine pc -kernel "$kernel" -drive "file=$cut_image,format=raw,if=ide,index=0"
    mtype -i "$cut_image@@1048576" ::SUBDIR/F13.TXT | cmp - "$files/peer.txt"

    image="$files/deep-tree.raw"
    cp --sparse=always "$files/disk.raw" "$image"
    # 128 descents span two traversal pages. The console reaches level 16.
    for ((depth = 1; depth <= 128; depth++)); do
        deep_path+="D/"
        directories+=("::${deep_path%/}")
        if (( depth == 16 )); then
            guest_deep_path=${deep_path%/}
        fi
    done
    mmd -i "$image@@1048576" "${directories[@]}"
    mcopy -i "$image@@1048576" "$files/peer.txt" "::$guest_deep_path/LEAF.TXT"
    run_guest 'FAT32 ownership walks a deep directory tree' 1 64M check_deep_directory_tree \
        -machine pc -kernel "$kernel" -drive "file=$image,format=raw,if=ide,index=0"
    mtype -i "$image@@1048576" ::ROOT.TXT | cmp - <(printf 'Saved\n')

    image="$files/corrupt-root.raw"
    cp --sparse=always "$files/disk.raw" "$image"
    for ((copy = 0; copy < fat_count; copy++)); do
        offset=$((1048576 + (fat_reserved + copy * fat_size) * 512 + root_cluster * 4))
        write_image_le "$image" "$offset" 0 4
    done
    check_image_unchanged 'VFS rejects a FAT32 root marked free' "$image" check_corrupt_root_traversal
}

run_vfs_fixtures() {
    local image="$files/vfs.raw" alias_entry
    local test_image fat_lba=$((2048 + fat_reserved)) fat_sectors=$((fat_size * fat_count))
    local raw_crc
    run_directory_fixtures
    printf 'Original RAM bytes' > "$files/no newline.txt"
    raw_crc=$(gzip -n < "$files/no newline.txt" | tail -c 8 | od -An -N4 -t x4 | tr -d ' \n' | tr 'a-f' 'A-F')
    tar --format=ustar -C "$files" -cf "$files/vfs.tar" 'no newline.txt' empty.txt
    cp --sparse=always "$files/disk.raw" "$image"
    run_guest 'VFS paths and exact persisted bytes' 1 64M check_vfs_files -machine pc -kernel "$kernel" \
        -initrd "$files/vfs.tar" -drive "file=$image,format=raw,if=ide,index=0"
    mtype -i "$image@@1048576" ::NOTE.TXT | cmp - <(printf 'Left > right\n')
    mtype -i "$image@@1048576" ::EMPTY1.TXT | cmp - <(printf '\n')
    mtype -i "$image@@1048576" ::EMPTY2.TXT | cmp - <(printf '\n')
    mtype -i "$image@@1048576" ::RAW.TXT | cmp - "$files/no newline.txt"
    mtype -i "$image@@1048576" ::ZERO.TXT | cmp - /dev/null
    mtype -i "$image@@1048576" ::SUBDIR/NESTED.TXT | cmp - <(printf 'Saved\n')
    mtype -i "$image@@1048576" ::SUBDIR/EMPTY.TXT | cmp - /dev/null
    local touched_entry
    touched_entry=$(short_entry_offset "$image" "$subdir_offset" 'EMPTY   TXT')
    [[ $(od -An -tu2 -j $((touched_entry + 20)) -N 2 "$image") -eq 0 ]]
    [[ $(od -An -tu2 -j $((touched_entry + 26)) -N 2 "$image") -eq 0 ]]

    check_image_unchanged 'VFS rejects malformed writes and directory deletion' "$files/disk.raw" check_invalid_file_commands

    test_image="$files/read-only.raw"
    cp --sparse=always "$files/disk.raw" "$test_image"
    printf '\041' | dd of="$test_image" bs=1 seek=$((host_entry + 11)) conv=notrunc status=none
    refusal='Disk file is read-only\.' check_image_unchanged \
        'FAT32 refuses writes to a read-only file' "$test_image" check_existing_file_refusals
    check_image_unchanged 'FAT32 touch preserves an existing file and its metadata' "$test_image" check_touch_existing

    test_image="$files/duplicate-name.raw"
    cp --sparse=always "$files/disk.raw" "$test_image"
    printf 'host    txt' | dd of="$test_image" bs=1 seek="$peer_entry" conv=notrunc status=none
    refusal='Duplicate FAT32 short name\.' check_image_unchanged \
        'FAT32 refuses writes to duplicate short names' "$test_image" check_existing_file_refusals

    test_image="$files/alias-replace.raw"
    cp --sparse=always "$files/disk.raw" "$test_image"
    alias_entry=$(short_entry_offset "$test_image" "$root_offset" 'LONGFI~1TXT')
    printf '\030' | dd of="$test_image" bs=1 seek=$((alias_entry + 12)) conv=notrunc status=none
    dd if="$test_image" of="$files/alias-before" bs=1 skip=$((alias_entry - 64)) count=77 status=none
    run_guest 'FAT32 replacement through a short alias preserves its metadata' 1 64M check_vfs_lfn \
        -machine pc -kernel "$kernel" -drive "file=$test_image,format=raw,if=ide,index=0"
    dd if="$test_image" bs=1 skip=$((alias_entry - 64)) count=77 status=none | cmp - "$files/alias-before"
    mtype -i "$test_image@@1048576" ::LongFileName.txt | cmp - <(printf 'Alias replacement\n')
    check_lfn_boundary 1 64
    check_lfn_boundary 2 128

    test_image="$files/vfs-replace-interrupted.raw"
    cp --sparse=always "$files/disk.raw" "$test_image"
    QEMU_TEST_POWER_CUT=1 run_guest 'FAT32 power cut during direct replacement' 1 64M check_replacement_interrupted \
        -machine pc -kernel "$build_dir/fat32-interrupt.elf" -drive "file=$test_image,format=raw,if=ide,index=0"
    check_image_unchanged 'FAT32 checks the interrupted direct write' "$test_image" check_fat_orphans
    cp --sparse=always "$test_image" "$files/repair-mismatch.raw"
    # The mismatch is in a later FAT sector than the orphaned chain.
    local mismatch_offset=$((1048576 + (fat_reserved + fat_size) * 512 + 50000 * 4))
    write_image_le "$files/repair-mismatch.raw" "$mismatch_offset" 0x0FFFFFFF 4
    repair_error='FAT32 check failed: FAT copies disagree\.' check_image_unchanged \
        'FAT32 repair refuses a late FAT mismatch' "$files/repair-mismatch.raw" check_fat_repair_refusal
    run_guest 'FAT32 repairs the interrupted direct write' 1 64M check_fat_repair \
        -machine pc -kernel "$kernel" -drive "file=$test_image,format=raw,if=ide,index=0"
    mtype -i "$test_image@@1048576" ::HOST.TXT | cmp - "$files/host.txt"
    dd if="$test_image" bs=512 skip="$fat_lba" count="$fat_sectors" status=none |
        cmp - <(dd if="$files/disk.raw" bs=512 skip="$fat_lba" count="$fat_sectors" status=none)

    test_image="$files/empty-remove.raw"
    cp --sparse=always "$files/disk.raw" "$test_image"
    remove_name=empty.txt run_guest 'FAT32 deletes an empty file without freeing clusters' 1 64M check_vfs_remove \
        -machine pc -kernel "$kernel" -drive "file=$test_image,format=raw,if=ide,index=0"
    dd if="$test_image" bs=512 skip="$fat_lba" count="$fat_sectors" status=none |
        cmp - <(dd if="$files/disk.raw" bs=512 skip="$fat_lba" count="$fat_sectors" status=none)

    test_image="$files/delete-interrupted.raw"
    cp --sparse=always "$files/disk.raw" "$test_image"
    mcopy -i "$test_image@@1048576" "$files/long.txt" ::CUT.TXT
    QEMU_TEST_POWER_CUT=1 run_guest 'FAT32 power cut after deletion is published' 1 64M check_deletion_interrupted \
        -machine pc -kernel "$build_dir/fat32-interrupt.elf" -drive "file=$test_image,format=raw,if=ide,index=0"
    check_image_unchanged 'FAT32 checks the orphaned deletion without writing' "$test_image" check_deletion_check
    run_guest 'FAT32 repairs orphans after an interrupted deletion' 1 64M check_deletion_repair \
        -machine pc -kernel "$kernel" -drive "file=$test_image,format=raw,if=ide,index=0"
    mtype -i "$test_image@@1048576" ::HOST.TXT | cmp - "$files/host.txt"
    mtype -i "$test_image@@1048576" ::PEER.TXT | cmp - "$files/peer.txt"

    image="$files/mounts.raw"
    truncate -s 132M "$image"
    sgdisk -n 1:2048:133119 -t 1:0700 -n 2:133120:264191 -t 2:0700 "$image" >/dev/null
    dd if="$files/volume" of="$image" bs=1M seek=1 conv=sparse,notrunc status=none
    dd if="$files/volume" of="$image" bs=1M seek=65 conv=sparse,notrunc status=none
    cp --sparse=always "$image" "$files/mount-overlap.raw"
    make_overlapping_gpt "$files/mount-overlap.raw"
    run_guest 'GPT rejects partitions that share one sector' 1 64M check_gpt_invalid \
        -machine pc -kernel "$kernel" -drive "file=$files/mount-overlap.raw,format=raw,if=ide,index=0,snapshot=on"
    run_guest 'Mount table rejects a one-sector overlap' 1 64M check_mount_overlap \
        -machine pc -kernel "$build_dir/fat32-overlap.elf" -drive "file=$image,format=raw,if=ide,index=0,snapshot=on"
    cp --sparse=always "$image" "$files/mount-fault.raw"
    local copy orphan
    for ((copy = 0; copy < fat_count; copy++)); do
        orphan=$((68157440 + (fat_reserved + copy * fat_size) * 512 + reserved_cluster * 4))
        printf '\377\377\377\017' | dd of="$image" bs=1 seek="$orphan" conv=notrunc status=none
    done
    run_guest 'Independent FAT32 volumes and exact selectors' 1 64M check_mount_volumes \
        -machine pc -kernel "$kernel" -drive "file=$image,format=raw,if=ide,index=0"
    mtype -i "$image@@1048576" ::HOST.TXT | cmp - "$files/host.txt"
    mtype -i "$image@@68157440" ::HOST.TXT | cmp - <(printf 'Backup\n')
    mtype -i "$image@@1048576" ::COPIED.TXT | cmp - <(printf 'Backup\n')
    run_guest 'FAT32 write error stays latched until a successful unmount' 1 64M check_mount_fault \
        -machine pc -kernel "$build_dir/fat32-fault.elf" -drive "file=$files/mount-fault.raw,format=raw,if=ide,index=0"
    mtype -i "$files/mount-fault.raw@@1048576" ::HOST.TXT | cmp - <(printf 'Remounted\n')
    mtype -i "$files/mount-fault.raw@@68157440" ::FAULT.TXT | cmp - <(printf 'OK\n')
}
