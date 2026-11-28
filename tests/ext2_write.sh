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
    console_check 'echo Modified > /ext/Replace' 'Ext2 file saved\.'
    console_check 'cp /ext/Replace /ext/CopyTime' 'Ext2 file saved\.'
    console_check 'touch /ext/empty' 'touch /ext/empty'
    console_check 'touch /ext/Unused/Fresh' 'touch /ext/Unused/Fresh'
    console_check 'echo Partial > /ext/partial' 'Ext2 file saved\.'
    console_check 'touch /ext/partial' 'touch /ext/partial'
    console_check 'cat /ext/partial' $'\nPartial\r?\n'
    console_check 'echo Replaced > /ext/partial' 'Ext2 file saved\.'
    console_check 'cat /ext/partial' $'\nReplaced\r?\n'
    console_check 'echo Replaced > /ext/Linked' 'Ext2 file saved\.'
    console_check 'cat /ext/Alias' $'\nReplaced\r?\n'
    console_check 'cp /ext/Linked /ext/Alias' 'Source and destination are the same file\.'
    console_check 'rm /ext/Linked' 'Ext2 entry removed\.'
    console_check 'cat /ext/Alias' $'\nReplaced\r?\n'
    console_check 'rm /ext/Alias' 'Ext2 entry removed\.'
    console_check 'cat /ext/Alias' 'Ext2 entry not found\.'
    console_check 'echo Short > /ext/HugeSparse' 'Ext2 file saved\.'
    console_check 'cat /ext/HugeSparse' $'\nShort\r?\n'
    console_check 'cp /ram/exact /ext/Nested/Exact' 'Ext2 file saved\.'
    console_check 'cp /ext/Sparse /ext/Dense' 'Ext2 file saved\.'
    console_check 'cp /ext/ExactBytes /ext/Limit' 'Ext2 file saved\.'
    console_check 'cp /ext/Indirect /ext/OneIndirect' 'Ext2 file saved\.'
    console_check 'cp /ext/Max /ext/LimitIndirect' 'Ext2 file saved\.'
    console_check 'cp /ext/Max /ext/OneIndirect' 'Ext2 file saved\.'
    console_check 'echo Small > /ext/OneIndirect' 'Ext2 file saved\.'
    console_check 'cp /ext/Indirect /ext/Transient' 'Ext2 file saved\.'
    console_check 'rm /ext/Transient' 'Ext2 entry removed\.'
    local long_name
    printf -v long_name "%0244d" 9
    console_check "echo Grown > /ext/Full/$long_name" "Ext2 file saved\."
    console_check "ls /ext/Full" "$long_name"
    console_check "cat /ext/Full/$long_name" $'\nGrown\r?\n'
    console_check "mkdir /ext/FullDir/$long_name" 'Ext2 directory created\.'
    printf 'cd /ext/FullDir/%s\r' "$long_name" >&"$serial_write"
    # A horizontally scrolled input row echoes only part of this path.
    expect_serial 'baremetal> '
    console_check 'pwd' $'\n'"/ext/FullDir/$long_name"$'\r?\n'
    console_check 'mkdir Nested' 'Ext2 directory created\.'
    console_check 'echo Inside > Nested/File' 'Ext2 file saved\.'
    console_check 'cd /' 'cd /'
    console_check "ls /ext/FullDir/$long_name" 'Nested/'
    console_check 'rm /ext/FullDir' 'Ext2 directory is not empty\.'
    printf 'cd /ext/FullDir/%s/Nested\r' "$long_name" >&"$serial_write"
    # A horizontally scrolled input row echoes only part of this path.
    expect_serial 'baremetal> '
    console_check 'pwd' $'\n'"/ext/FullDir/$long_name/Nested"$'\r?\n'
    console_check 'rm /ext/FullDir' 'Ext2 directory is in use\.'
    console_check "rm /ext/FullDir/$long_name/Nested" 'Ext2 directory is in use\.'
    console_check 'cd /' 'cd /'
    console_check 'mkdir /ext/Remove' 'Ext2 directory created\.'
    console_check 'touch /ext/Remove/Stale' 'touch /ext/Remove/Stale'
    console_check 'rm' 'Usage: rm PATH'
    console_check 'rm /ext/Remove/Stale/' 'Trailing slash requires a directory\.'
    console_check 'rm /ext/Remove/Stale' 'Ext2 entry removed\.'
    console_check 'rm /ext/Remove/' 'Ext2 entry removed\.'
    console_check 'mkdir /ext/Remove' 'Ext2 directory created\.'
    console_check 'rm /ext/Remove' 'Ext2 entry removed\.'
    console_check 'umount /ext' 'Ext2 unmounted\.'
    console_check 'mount -t ext2 -o ro disk0p1 /ext' 'Ext2 mounted read-only\.'
    console_check 'cat /ext/Nested/Exact' $'\nExact bytes\r?\n'
    console_check 'mkdir /ext/Refused' 'Ext2 is read-only\.'
    console_check 'rm /ext/partial' 'Ext2 is read-only\.'
    console_check 'echo Refused > /ext/partial' 'Ext2 is read-only\.'
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
    printf '%s\r' "${cut_command:-echo Fixture > /ext/new}" >&"$serial_write"
    expect_serial 'Test: ext2 flush complete\.'
}

check_bad_allocation() {
    expect_serial 'baremetal> '
    console_check 'mount -t ext2 disk0p1 /ext' 'Ext2 allocation or ownership could not be verified.'
}

# Each fault needs its own guest and image. The mount checks can share one
# guest because every snapshot occupies a separate partition.
check_recovery_mounts() {
    local index partition
    expect_serial 'baremetal> '
    for index in "${!recovery_cases[@]}"; do
        printf 'Checking ext2 recovery for %s\n' "${recovery_cases[index]}"
        partition=$((2 * index + 1))
        console_check "mount -t ext2 disk0p$partition /ext" 'Unsupported or invalid ext2 volume\.'
        console_check "mount -t ext2 disk0p$((partition + 1)) /ext" 'Ext2 mounted read-write\.'
        console_check 'cat /ext/Existing' $'\nOriginal\r?\n'
        console_check 'umount /ext' 'Ext2 unmounted\.'
    done
}

queue_dirty_mount() {
    local index=${#recovery_cases[@]}
    recovery_cases+=("$1")
    recovery_offset=$((1 + 24 * index))
    dirty_hashes+=("$(sha256sum < "$files/result")")
    dd if="$files/result" of="$files/recovery.raw" bs=1M seek="$recovery_offset" \
        conv=sparse,notrunc status=none
}

queue_repaired_mount() {
    dd if="$files/result" of="$files/recovery.raw" bs=1M seek="$((recovery_offset + 12))" \
        conv=sparse,notrunc status=none
}

run_recovery_mounts() {
    local index partition sector
    local -a partitions=()
    for index in "${!recovery_cases[@]}"; do
        partition=$((2 * index + 1))
        sector=$(((1 + 24 * index) * 2048))
        partitions+=(-n "$partition:$sector:+12M"
            -n "$((partition + 1)):$((sector + 12 * 2048)):+12M")
    done
    truncate -s "$((2 + 24 * ${#recovery_cases[@]}))M" "$files/recovery.raw"
    sgdisk "${partitions[@]}" "$files/recovery.raw" >/dev/null
    disk="$files/recovery.raw" attach_image 'ext2 dirty mount refusals and repaired remounts' check_recovery_mounts "$kernel"

    for index in "${!recovery_cases[@]}"; do
        if [[ $(dd if="$files/recovery.raw" bs=1M skip="$((1 + 24 * index))" count=12 status=none |
            sha256sum) != "${dirty_hashes[index]}" ]]; then
            printf 'Refused mount modified the image for %s\n' "${recovery_cases[index]}" >&2
            return 1
        fi
    done
}

attach_image() {
    run_guest "$1" 1 64M "$2" -machine pc -kernel "$3" -initrd "$files/ram.tar" \
        -rtc "base=${ext2_rtc_base:-utc},clock=vm" -drive "file=$disk,format=raw,if=ide,cache=directsync"
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
{ head -c 49149 /dev/zero | tr '\000' A; printf end; } > "$files/ExactBytes"
truncate -s 49153 "$files/Indirect"
printf x | dd of="$files/Indirect" bs=1 seek=49152 conv=notrunc status=none
truncate -s 4243456 "$files/Max"
printf 'end' | dd of="$files/Max" bs=1 seek=4243453 conv=notrunc status=none
truncate -s 0 "$files/TooBig"
touch "$files/Empty"
{
    printf 'mkdir /Nested\nmkdir /Full\nmkdir /FullDir\nmkdir /Unused\nmkdir /EmptyDir\n'
    printf 'write %s /Existing\nwrite %s /Sparse\nwrite %s /ExactBytes\n' \
        "$files/Existing" "$files/Sparse" "$files/ExactBytes"
    printf 'write %s /Indirect\nwrite %s /Max\n'  "$files/Indirect" "$files/Max"
    for name in Replace CopyTime; do
        printf 'write %s /%s\n' "$files/Existing" "$name"
        printf 'set_inode_field /%s mtime @1577836800\nset_inode_field /%s ctime @1577836800\n' "$name" "$name"
        printf 'set_inode_field /%s atime @1577836800\nset_inode_field /%s crtime @1577836800\n' "$name" "$name"
        printf 'set_inode_field /%s mtime_extra 4000000\nset_inode_field /%s ctime_extra 8000000\n' "$name" "$name"
    done
    printf 'write %s /Linked\nlink /Linked /Alias\nset_inode_field /Linked links_count 2\n' "$files/Existing"
    printf 'set_inode_field /Linked ctime @1577836800\nset_inode_field /Linked ctime_extra 8000000\n'
    printf 'set_inode_field /Linked mtime @1577836800\nset_inode_field /Linked mtime_extra 4000000\n'
    printf 'write %s /HugeSparse\nset_inode_field /HugeSparse size 4294967296\n' "$files/Empty"
    # Sixteen records of 252 bytes after the dot entries use all but 40
    # bytes. The 40-byte tail has no sector-local header/name slot.
    for ((i = 0; i < 16; i++)); do
        printf 'write %s /Full/%0241d\nwrite %s /FullDir/%0241d\n' "$files/Empty" "$i" "$files/Empty" "$i"
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
replacement_rtc=2032-02-29T12:34:56
replacement_epoch=$(date -u -d "$replacement_rtc" +%s)
ext2_rtc_base="$replacement_rtc" attach_image 'ext2 create, copy and clean unmount' check_write "$kernel"
extract_volume
clean_check
check_replacement_time() {
    local inode=$1 expected=$2 mtime= ctime= field value _
    while read -r field value _; do
        case "$field" in
            mtime:) mtime=$value ;;
            ctime:) ctime=$value ;;
        esac
    done < <(debugfs -R "stat $inode" "$files/result" 2>/dev/null)
    [[ -n $mtime && $mtime == "$ctime" && ${mtime#*:} == 00000000 ]]
    local seconds=$(( ${mtime%:*} ))
    (( seconds >= expected && seconds < expected + 15 ))
}
for name in Replace CopyTime; do
    check_replacement_time "/$name" "$replacement_epoch"
    debugfs -R "cat /$name" "$files/result" 2>/dev/null | cmp - <(printf 'Modified\n')
    debugfs -R "stat /$name" "$files/result" 2>/dev/null |
        grep -E '^[[:space:]]*(atime|crtime):' >"$files/after-time"
    debugfs -R "stat /$name" "$files/vol" 2>/dev/null |
        grep -E '^[[:space:]]*(atime|crtime):' | cmp - "$files/after-time"
done
debugfs -R 'cat /Nested/Exact' "$files/result" 2>/dev/null | cmp - "$files/exact"
debugfs -R 'cat /Dense' "$files/result" 2>/dev/null | cmp - "$files/Sparse"
debugfs -R 'cat /Limit' "$files/result" 2>/dev/null | cmp - "$files/ExactBytes"
debugfs -R 'cat /OneIndirect' "$files/result" 2>/dev/null | cmp - <(printf 'Small\n')
debugfs -R 'cat /LimitIndirect' "$files/result" 2>/dev/null | cmp - "$files/Max"
debugfs -R 'stat /LimitIndirect' "$files/result" 2>/dev/null | grep -q 'Blockcount: 16'
debugfs -R 'stat /Transient' "$files/result" 2>&1 | grep -q 'File not found'
debugfs -R 'stat /Dense' "$files/result" 2>/dev/null | grep -q 'Blockcount: 8'
debugfs -R 'stat /empty' "$files/result" 2>/dev/null | grep -q 'Blockcount: 0'
printf -v grown_name "%0244d" 9
debugfs -R "cat /FullDir/$grown_name/Nested/File" "$files/result" 2>/dev/null | cmp - <(printf 'Inside\n')
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

recovery_cases=()
dirty_hashes=()
for fixture in ALLOC PUBLISH READ FINAL BEFORE AFTER; do
    cp --sparse=always "$files/base.raw" "$disk"
    fixture_kernel="$build_dir/ext2-fixture-$fixture.elf"
    case $fixture in
        BEFORE|AFTER) QEMU_TEST_POWER_CUT=1 attach_image "ext2 power cut $fixture" check_cut "$fixture_kernel" ;;
        *) attach_image "ext2 fault $fixture" check_fault "$fixture_kernel" ;;
    esac
    extract_volume
    queue_dirty_mount "$fixture"
    debugfs -R 'cat /Existing' "$files/result" 2>/dev/null | cmp - "$files/Existing"
    case $fixture in
        FINAL|AFTER) debugfs -R 'cat /new' "$files/result" 2>/dev/null | cmp - <(printf 'Fixture\n') ;;
        *) debugfs -R 'stat /new' "$files/result" 2>&1 | grep -q 'File not found' ;;
    esac
    fsck_status=0
    e2fsck -fy "$files/result" || fsck_status=$?
    (( fsck_status <= 1 ))
    clean_check
    queue_repaired_mount
done


assert_missing() {
    debugfs -R "stat $1" "$files/result" 2>&1 | grep -q 'File not found'
}

cut_and_extract() {
    cp --sparse=always "$files/base.raw" "$disk"
    QEMU_TEST_POWER_CUT=1 cut_command="$3"         attach_image "$1" check_cut "$build_dir/ext2-fixture-$2.elf"
    extract_volume
    queue_dirty_mount "$1"
    debugfs -R 'cat /Existing' "$files/result" 2>/dev/null | cmp - "$files/Existing"
}

repair_and_check() {
    local result=0
    e2fsck -fy "$files/result" || result=$?
    (( result == 0 || result == 1 ))
    clean_check
    queue_repaired_mount
}

for fixture in BEFORE AFTER CUT5 CUT6; do
    cut_and_extract "ext2 mkdir power cut $fixture" "$fixture" "mkdir /ext/FullDir/$grown_name"
    if [[ $fixture == CUT6 ]]; then
        debugfs -R "stat /FullDir/$grown_name" "$files/result" 2>/dev/null | grep -q 'Type: directory'
    else
        assert_missing "/FullDir/$grown_name"
    fi
    expected_size=8192
    [[ $fixture != BEFORE ]] || expected_size=4096
    debugfs -R 'stat /FullDir' "$files/result" 2>/dev/null | grep -Eq "Size: $expected_size$"
    repair_and_check
    if [[ $fixture == CUT5 ]]; then
        debugfs -R 'ls -l /lost+found' "$files/result" 2>/dev/null | grep -Eq '#[0-9]+'
    fi
done

for fixture in BEFORE AFTER CUT4; do
    cut_and_extract "ext2 replacement power cut $fixture" "$fixture" 'echo Updated > /ext/Replace'
    expected=Updated
    [[ $fixture != BEFORE ]] || expected=Original
    debugfs -R 'cat /Replace' "$files/result" 2>/dev/null | cmp - <(printf '%s\n' "$expected")
    repair_and_check
    debugfs -R 'cat /Replace' "$files/result" 2>/dev/null | cmp - <(printf '%s\n' "$expected")
done

for fixture in BEFORE AFTER CUT4 CUT5 CUT6; do
    cut_and_extract "ext2 directory removal power cut $fixture" "$fixture" 'rm /ext/EmptyDir'
    assert_missing /EmptyDir
    repair_and_check
    assert_missing /EmptyDir
    if [[ $fixture == BEFORE || $fixture == AFTER ]]; then
        debugfs -R 'ls -l /lost+found' "$files/result" 2>/dev/null | grep -Eq '#[0-9]+'
    else
        if debugfs -R 'ls -l /lost+found' "$files/result" 2>/dev/null | grep -Eq '#[0-9]+'; then
            printf 'Removed directory was reconnected after its inode was cleared\n' >&2
            exit 1
        fi
    fi
done

cut_and_extract 'ext2 surviving hard link after interrupted unlink' BEFORE 'rm /ext/Linked'
assert_missing /Linked
debugfs -R 'stat /Alias' "$files/result" 2>/dev/null | grep -q 'Links: 2'
repair_and_check
debugfs -R 'stat /Alias' "$files/result" 2>/dev/null | grep -q 'Links: 1'
debugfs -R 'cat /Alias' "$files/result" 2>/dev/null | cmp - "$files/Existing"

# A real 1975 date remains valid when the CMOS century is 19. Cut after
# the link count and ctime have been flushed together.
unlink_rtc=1975-01-02T03:04:05
unlink_epoch=$(date -u -d "$unlink_rtc" +%s)
ext2_rtc_base="$unlink_rtc" cut_and_extract 'ext2 publishes ctime with the surviving link count' AFTER 'rm /ext/Linked'
assert_missing /Linked
debugfs -R 'stat /Alias' "$files/result" 2>/dev/null >"$files/alias-stat"
grep -q 'Links: 1' "$files/alias-stat"
mtime=$(awk '$1 == "mtime:" {print $2}' "$files/alias-stat")
original_mtime=$(debugfs -R 'stat /Alias' "$files/vol" 2>/dev/null | awk '$1 == "mtime:" {print $2}')
[[ "$mtime" == "$original_mtime" ]]
ctime=$(awk '$1 == "ctime:" {print $2}' "$files/alias-stat")
[[ -n $ctime && ${ctime#*:} == 00000000 ]]
(( ${ctime%:*} >= unlink_epoch && ${ctime%:*} < unlink_epoch + 15 ))
repair_and_check
debugfs -R 'cat /Alias' "$files/result" 2>/dev/null | cmp - "$files/Existing"

run_recovery_mounts

# Use the same GPT container with a separately prepared ext2 filesystem.
install_volume() {
    cp --sparse=always "$files/base.raw" "$disk"
    dd if="$1" of="$disk" bs=1M seek=1 conv=notrunc status=none
}

check_limits() {
    mount_ext
    cp "$disk" "$files/mounted.raw"
    console_check 'mkdir /ext/Immutable/New' 'Ext2 writes are blocked\.'
    console_check 'mkdir /ext/AppendOnly/New' 'Ext2 writes are blocked\.'
    console_check 'mkdir /ext/LinkLimit/New' 'Ext2 parent directory link limit reached\.'
    cmp "$files/mounted.raw" "$disk"
    console_check "echo Extended > /ext/AtLimit/$grown_name" 'Ext2 file saved\.'
    local first second extra wide_name
    printf -v first '%0241d' 0
    printf -v second '%0241d' 1
    console_check "rm /ext/AtLimit/$first" 'Ext2 entry removed\.'
    console_check "rm /ext/AtLimit/$second" 'Ext2 entry removed\.'
    console_check "echo Reused > /ext/AtLimit/$reused_name" 'Ext2 file saved\.'
    for extra in {1000..1017}; do
        printf -v wide_name '%0241d' "$extra"
        console_check "touch /ext/AtLimit/$wide_name" 'touch '
    done
    console_check 'mkdir /ext/LinkBelow/New' 'Ext2 directory created\.'
    console_check 'mkdir /ext/Wide' 'Ext2 directory created\.'
    local i
    for ((i = 1; i <= 25; i++)); do
        printf -v wide_name '%0200d' "$i"
        console_check "echo Kept > /ext/Wide/$wide_name" 'Ext2 file saved\.'
    done
    console_check "cat /ext/Wide/$wide_name" $'\nKept\r?\n'
    console_check "cp /ext/ExactBytes /ext/Full/$grown_name" 'Ext2 file saved\.'
    console_check 'ls /ext/Full' "$grown_name"
    console_check "crc32range 49149 3 /ext/Full/$grown_name" '00FC33B1'
    console_check "mkdir /ext/Full/$grown_name-dir" 'Ext2 directory created\.'
    console_check "echo Nested > /ext/Full/$grown_name-dir/File" 'Ext2 file saved\.'
    console_check 'umount /ext' 'Ext2 unmounted\.'
}

truncate -s 12M "$files/limits"
mke2fs -q -F -t ext2 -b 4096 -g 1024 -I 128 -O none,sparse_super,large_file "$files/limits"
{
    printf 'mkdir /Full\nmkdir /AtLimit\nmkdir /Immutable\nmkdir /AppendOnly\nmkdir /LinkLimit\nmkdir /LinkBelow\n'
    printf 'write %s /ExactBytes\n' "$files/ExactBytes"
    printf 'set_inode_field /Immutable flags 0x10\nset_inode_field /AppendOnly flags 0x20\n'
    for ((i = 0; i < 192; i++)); do
        printf 'write %s /AtLimit/%0241d\n' "$files/Empty" "$i"
        if (( i < 16 )); then
            printf 'write %s /Full/%0241d\n' "$files/Empty" "$i"
        fi
    done
} | debugfs -w -f - "$files/limits" >>"$files/debug.log" 2>&1
e2fsck -fn "$files/limits"
debugfs -R 'stat /AtLimit' "$files/limits" 2>/dev/null | grep -Eq 'Size: 49152$'
# Deliberately synthetic counts test the guard independently of growing a
# directory with over thirty thousand real child inodes.
{
    printf 'set_inode_field /LinkBelow links_count 31999\n'
    printf 'set_inode_field /LinkLimit links_count 32000\n'
} | debugfs -w -f - "$files/limits" >>"$files/debug.log" 2>&1
printf -v reused_name '%0245d' 999
install_volume "$files/limits"
attach_image 'ext2 legacy dirents, indirect directory growth and parent guards' check_limits "$kernel"
extract_volume
debugfs -R 'stat /AtLimit' "$files/result" 2>/dev/null | grep -Eq 'Size: 57344$'
debugfs -R 'stat /Wide' "$files/result" 2>/dev/null | grep -Eq 'Size: 8192$'
debugfs -R "cat /AtLimit/$reused_name" "$files/result" 2>/dev/null | cmp - <(printf 'Reused\n')
# The two original 252-byte records span past the first 512-byte sector.
# The replacement header, name, and rec_len only touch the first sector.
reused_block=$(debugfs -R 'bmap /AtLimit 0' "$files/limits" 2>/dev/null)
dd if="$files/limits" bs=512 skip="$((reused_block * 8 + 1))" count=7 status=none |
    cmp - <(dd if="$files/result" bs=512 skip="$((reused_block * 8 + 1))" count=7 status=none)
debugfs -R 'stat /LinkBelow' "$files/result" 2>/dev/null | grep -q 'Links: 32000'
debugfs -R 'stat /LinkLimit' "$files/result" 2>/dev/null | grep -q 'Links: 32000'
debugfs -R "cat /Full/$grown_name" "$files/result" 2>/dev/null | cmp - "$files/ExactBytes"
debugfs -R "cat /Full/$grown_name-dir/File" "$files/result" 2>/dev/null | cmp - <(printf 'Nested\n')
{
    printf 'set_inode_field /LinkBelow links_count 3\n'
    printf 'set_inode_field /LinkLimit links_count 2\n'
} | debugfs -w -f - "$files/result" >>"$files/debug.log" 2>&1
clean_check

check_no_blocks() {
    mount_ext
    console_check 'cp /ext/Empty /ext/Existing' 'Ext2 file saved\.'
    console_check 'umount /ext' 'Ext2 unmounted\.'
}

check_shrink_full() {
    mount_ext
    console_check 'truncate /ext/Filler 49153' 'Ext2 file saved\.'
    console_check 'stat /ext/Filler' 'Allocated sectors: 112'
    console_check 'truncate /ext/DenseIndirect 49152' 'Ext2 file saved\.'
    console_check 'umount /ext' 'Ext2 unmounted\.'
}

check_shrink_tail_full() {
    mount_ext
    console_check 'truncate /ext/Keep 1' 'Ext2 file saved\.'
    console_check 'stat /ext/Keep' 'Allocated sectors: 8'
    console_check 'truncate /ext/Keep 4097' 'Ext2 file saved\.'
    console_check 'umount /ext' 'Ext2 unmounted\.'
}

check_cross_group() {
    mount_ext
    console_check 'cp /ext/ExactBytes /ext/Existing' 'Ext2 file saved\.'
    console_check 'umount /ext' 'Ext2 unmounted\.'
}

check_cross_group_remove() {
    mount_ext
    console_check 'rm /ext/Existing' 'Ext2 entry removed\.'
    console_check 'umount /ext' 'Ext2 unmounted\.'
}

check_one_block_short() {
    mount_ext
    cp "$disk" "$files/mounted.raw"
    console_check 'cp /ext/ExactBytes /ext/Existing' 'Ext2 has no free inode or data blocks\.'
    cmp "$files/mounted.raw" "$disk"
    console_check 'cat /ext/Existing' $'\nOriginal\r?\n'
    console_check 'cp /ext/Empty /ext/Existing' 'Ext2 file saved\.'
    console_check 'umount /ext' 'Ext2 unmounted\.'
}

check_growth_short() {
    mount_ext
    cp "$disk" "$files/mounted.raw"
    console_check "cp /ext/ExactBytes /ext/Full/$grown_name" 'Ext2 has no free inode or data blocks\.'
    cmp "$files/mounted.raw" "$disk"
    console_check 'umount /ext' 'Ext2 unmounted\.'
}

check_indirect_short() {
    mount_ext
    cp "$disk" "$files/mounted.raw"
    console_check 'cp /ext/DenseIndirect /ext/Existing' 'Ext2 has no free inode or data blocks\.'
    cmp "$files/mounted.raw" "$disk"
    console_check 'cat /ext/Existing' $'\nOriginal\r?\n'
    console_check 'umount /ext' 'Ext2 unmounted\.'
}

free_count() {
    dumpe2fs -h "$1" 2>/dev/null | awk -v kind="$2" '$1 == "Free" && $2 == kind ":" {print $3}'
}

head -c 8192 /dev/zero | tr '\000' A > "$files/Keep"
head -c 49153 /dev/zero | tr '\000' X > "$files/DenseIndirect"
truncate -s 8M "$files/capacity"
mke2fs -q -F -t ext2 -b 4096 -g 1024 -N 128 -I 256 -O none,filetype,sparse_super,large_file "$files/capacity"
{
    printf 'mkdir /Pool\nmkdir /Full\nwrite %s /Filler\nwrite %s /Empty\n' "$files/Empty" "$files/Empty"
    printf 'write %s /Existing\nwrite %s /ExactBytes\n' "$files/Existing" "$files/ExactBytes"
    printf 'write %s /DenseIndirect\n' "$files/DenseIndirect"
    printf 'write %s /Keep\n' "$files/Keep"
    for ((i = 0; i < 16; i++)); do
        printf 'write %s /Full/%0241d\n' "$files/Empty" "$i"
    done
} | debugfs -w -f - "$files/capacity" >>"$files/debug.log" 2>&1
free_inodes=$(free_count "$files/capacity" inodes)
{
    for ((i = 0; i < free_inodes; i++)); do
        printf 'write %s /Pool/i%d\n' "$files/Empty" "$i"
    done
} | debugfs -w -f - "$files/capacity" >>"$files/debug.log" 2>&1
free_blocks=$(free_count "$files/capacity" blocks)
# Filling to the last free block also consumes the pointer blocks needed
# by the filler. Leave those allocated so punching data frees exact counts.
{
    printf 'fallocate /Filler 0 %d\n' "$((free_blocks - 1))"
    printf 'set_inode_field /Filler size %d\n' "$((free_blocks * 4096))"
} | debugfs -w -f - "$files/capacity" >>"$files/debug.log" 2>&1
[[ $(free_count "$files/capacity" blocks) == 0 && $(free_count "$files/capacity" inodes) == 0 ]]
e2fsck -fn "$files/capacity"
install_volume "$files/capacity"
attach_image 'ext2 zero-length overwrite with all blocks and inodes in use' check_no_blocks "$kernel"
extract_volume
clean_check
debugfs -R 'stat /Existing' "$files/result" 2>/dev/null | grep -Eq 'Size: 0$'

install_volume "$files/capacity"
attach_image 'ext2 shrinks files without free blocks' check_shrink_full "$kernel"
extract_volume
clean_check
head -c 49152 "$files/DenseIndirect" > "$files/ShrunkIndirect"
debugfs -R 'cat /DenseIndirect' "$files/result" 2>/dev/null | cmp - "$files/ShrunkIndirect"
debugfs -R 'stat /Filler' "$files/result" 2>/dev/null | grep -q 'Blockcount: 112'

install_volume "$files/capacity"
attach_image 'ext2 shrinks and regrows a partial block on a full volume' check_shrink_tail_full "$kernel"
extract_volume
clean_check
printf A > "$files/Shrunk"
truncate -s 4097 "$files/Shrunk"
debugfs -R 'cat /Keep' "$files/result" 2>/dev/null | cmp - "$files/Shrunk"
[[ $(free_count "$files/result" blocks) == 1 ]]

# Free blocks from two groups, six in the first and five or six in the
# second. No group alone can satisfy the 12-block overwrite.
first_block=$(debugfs -R 'bmap /Filler 0' "$files/capacity" 2>/dev/null)
second_block=$(debugfs -R 'bmap /Filler 1200' "$files/capacity" 2>/dev/null)
(( first_block > 0 && first_block < 1024 && second_block >= 1024 ))
for available in 11 12; do
    cp "$files/capacity" "$files/free"
    {
        printf 'punch /Filler 0 5\n'
        printf 'punch /Filler 1200 %d\n' "$((1200 + available - 7))"
    } | debugfs -w -f - "$files/free" >>"$files/debug.log" 2>&1
    [[ $(free_count "$files/free" blocks) == "$available" ]]
    e2fsck -fn "$files/free"
    install_volume "$files/free"
    if [[ $available == 11 ]]; then
        attach_image 'ext2 overwrite refused one block short' check_one_block_short "$kernel"
    else
        attach_image 'ext2 cross-group overwrite with no free inodes' check_cross_group "$kernel"
    fi
    extract_volume
    clean_check
    if [[ $available == 12 ]]; then
        debugfs -R 'cat /Existing' "$files/result" 2>/dev/null | cmp - "$files/ExactBytes"
        first_block=$(debugfs -R 'bmap /Existing 0' "$files/result" 2>/dev/null)
        second_block=$(debugfs -R 'bmap /Existing 11' "$files/result" 2>/dev/null)
        (( first_block > 0 && first_block < 1024 && second_block >= 1024 ))
        attach_image 'ext2 reclaims file blocks across group boundaries' check_cross_group_remove "$kernel"
        extract_volume
        clean_check
        [[ $(free_count "$files/result" blocks) == 13 && $(free_count "$files/result" inodes) == 1 ]]
    fi
done

debugfs -w -R 'rm /Pool/i0' "$files/free" >>"$files/debug.log" 2>&1
[[ $(free_count "$files/free" blocks) == 12 && $(free_count "$files/free" inodes) == 1 ]]
install_volume "$files/free"
attach_image 'ext2 48 KiB create refused without a thirteenth block for directory growth' check_growth_short "$kernel"
extract_volume
clean_check

debugfs -w -R 'punch /Filler 6 6' "$files/free" >>"$files/debug.log" 2>&1
[[ $(free_count "$files/free" blocks) == 13 ]]
install_volume "$files/free"
attach_image 'ext2 refuses data allocation without the indirect table block' check_indirect_short "$kernel"
extract_volume
clean_check

check_ambiguous() {
    mount_ext
    cp "$disk" "$files/mounted.raw"
    console_check 'echo Refused > /ext/Duplicate/Early' 'Duplicate ext2 directory entries\.'
    console_check 'rm /ext/Duplicate/Early' 'Duplicate ext2 directory entries\.'
    console_check 'touch /ext/Malformed/New' 'Invalid ext2 metadata or block pointer\.'
    cmp "$files/mounted.raw" "$disk"
    console_check 'echo Allowed > /ext/Valid' 'Ext2 file saved\.'
    console_check 'umount /ext' 'Ext2 unmounted\.'
}

cp "$files/vol" "$files/ambiguous"
{
    printf 'mkdir /Duplicate\nmkdir /Malformed\n'
    printf 'write %s /Duplicate/Early\nwrite %s /Duplicate/Later\n' "$files/Empty" "$files/Empty"
    printf 'write %s /Malformed/Invalid\n' "$files/Empty"
} | debugfs -w -f - "$files/ambiguous" >>"$files/debug.log" 2>&1
patch_name() {
    local dir="$1" old="$2" new="$3" position block
    block=$(debugfs -R "bmap $dir 0" "$files/ambiguous" 2>/dev/null)
    position=$(dd if="$files/ambiguous" bs=4096 skip="$block" count=1 status=none |
        grep -aobF "$old" | cut -d: -f1)
    printf '%s' "$new" | dd of="$files/ambiguous" bs=1 seek="$((block * 4096 + position))" conv=notrunc status=none
}
patch_name /Duplicate Later Early
patch_name /Malformed Invalid /nvalid
install_volume "$files/ambiguous"
attach_image 'ext2 refuses duplicate names and malformed records before writing' check_ambiguous "$kernel"

cp "$files/vol" "$files/bad-directory-count"
debugfs -w -R 'set_bg 0 used_dirs_count 0' "$files/bad-directory-count" >>"$files/debug.log" 2>&1
install_volume "$files/bad-directory-count"
sha256sum "$disk" > "$files/invalid.sha"
attach_image 'ext2 refuses an inconsistent directory allocation counter' check_bad_allocation "$kernel"
sha256sum -c --status "$files/invalid.sha"


check_clock_unavailable() {
    mount_ext
    cp "$disk" "$files/mounted.raw"
    console_check 'echo Refused > /ext/Replace' 'Ext2 replacement requires a valid UTC hardware clock\.'
    console_check 'rm /ext/Linked' 'Unlinking an ext2 hard link requires a valid UTC hardware clock\.'
    cmp "$files/mounted.raw" "$disk"
    console_check 'cat /ext/Replace' $'\nOriginal\r?\n'
    console_check 'echo Allowed > /ext/New' 'Ext2 file saved\.'
    console_check 'umount /ext' 'Ext2 unmounted\.'
}

cp --sparse=always "$files/base.raw" "$disk"
ext2_rtc_base=2075-01-01T00:00:00 \
    attach_image 'ext2 refuses replacement with an unrepresentable hardware clock' check_clock_unavailable "$kernel"
extract_volume
clean_check
