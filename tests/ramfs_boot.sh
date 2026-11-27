#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

source tests/qemu_serial.sh

enter_ram() {
    printf 'cd /ram\r' >&"$serial_write"
    expect_serial 'baremetal> '
}

check_root() {
    printf 'pwd\r' >&"$serial_write"
    expect_serial $'\r?\n/\r?\nbaremetal> '
}

check_copy_quotes() {
    printf '%s\r' 'echo Quoted data > seed.txt' >&"$serial_write"
    expect_serial 'baremetal> '
    printf '%s\r' 'cp seed.txt a"b.txt' >&"$serial_write"
    expect_serial 'baremetal> '
    printf '%s\r' 'cp a"b.txt "a \"b.txt"' >&"$serial_write"
    expect_serial 'baremetal> '
    printf '%s\r' 'cp "a \"b.txt" copied.txt' >&"$serial_write"
    expect_serial 'baremetal> '
    printf '%s\r' 'cat copied.txt' >&"$serial_write"
    expect_serial $'\r?\nQuoted data\r?\nbaremetal> '
    local path
    for path in seed.txt 'a"b.txt' 'a "b.txt' copied.txt; do
        printf 'rm %s\r' "$path" >&"$serial_write"
        expect_serial 'baremetal> '
    done
}

check_no_archive() {
    expect_serial 'baremetal> '
    check_root
    printf 'ls\r' >&"$serial_write"
    expect_serial $'\r?\n/ram\r?\nbaremetal> '
    printf 'echo invalid > note.txt\r' >&"$serial_write"
    expect_serial 'Expected a file path, found a directory\.'
    expect_serial 'baremetal> '
    enter_ram
    printf 'touch\r' >&"$serial_write"
    expect_serial $'Usage: touch PATH\r?\nbaremetal> '
    printf 'touch empty file.txt\r' >&"$serial_write"
    expect_serial $'touch empty file\\.txt\r?\nbaremetal> '
    printf 'cat empty file.txt\r' >&"$serial_write"
    expect_serial $'cat empty file\\.txt\r?\nbaremetal> '
    printf 'ls\r' >&"$serial_write"
    expect_serial $'\r?\nempty file\\.txt\r?\nbaremetal> '
    printf 'rm empty file.txt\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'ls\r' >&"$serial_write"
    expect_serial 'No RAM filesystem loaded\.'
    expect_serial 'baremetal> '
    printf 'cat hello.txt\r' >&"$serial_write"
    expect_serial 'No RAM filesystem loaded\.'
    expect_serial 'baremetal> '
    check_copy_quotes

    printf 'echo "This is some text"\r' >&"$serial_write"
    expect_serial $'\r?\nThis is some text\r?\nbaremetal> '
    printf 'echo "  3 > 2  " > note.txt\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'echo > blank.txt\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'ls\r' >&"$serial_write"
    expect_serial $'ls\r?\nnote\\.txt\r?\nblank\\.txt\r?\nbaremetal> '
    printf 'cat blank.txt\r' >&"$serial_write"
    expect_serial $'cat blank\\.txt\r?\n\r?\nbaremetal> '
    printf 'echo 123456789 > digits\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'crc32 digits\r' >&"$serial_write"
    expect_serial $'\r?\nE0117757\r?\nbaremetal> '
    printf 'rm digits\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'echo "unclosed > note.txt\r' >&"$serial_write"
    expect_serial 'Usage: echo'
    expect_serial 'baremetal> '
    printf 'echo invalid >> note.txt\r' >&"$serial_write"
    expect_serial 'Usage: echo'
    expect_serial 'baremetal> '
    printf 'echo invalid > sub/note.txt\r' >&"$serial_write"
    expect_serial 'Directory not found\.'
    expect_serial 'baremetal> '
    printf 'cat note.txt\r' >&"$serial_write"
    expect_serial $'\r?\n  3 > 2  \r?\nbaremetal> '
    printf 'rm note.txt\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'rm note.txt\r' >&"$serial_write"
    expect_serial 'File not found\.'
    expect_serial 'baremetal> '
    printf 'ls\r' >&"$serial_write"
    expect_serial $'ls\r?\nblank\\.txt\r?\nbaremetal> '
    check_overlong_commands
    printf 'reboot\r' >&"$serial_write"
    expect_serial 'baremetal> '
    check_root
    enter_ram
    printf 'ls\r' >&"$serial_write"
    expect_serial 'No RAM filesystem loaded\.'
    expect_serial 'baremetal> '
}

check_archive() {
    local command_label padded_label
    expect_serial 'baremetal> '
    check_root
    enter_ram
    printf 'ls\r' >&"$serial_write"
    expect_serial $'hello\\.txt\r?\n'
    expect_serial $'two words\\.txt\r?\n'
    expect_serial $'empty\\.txt\r?\n'
    expect_serial 'baremetal> '

    printf 'cat hello.txt\r' >&"$serial_write"
    expect_serial $'Hello from RAM\r?\n'
    expect_serial 'baremetal> '
    printf '/cat   two words.txt\r' >&"$serial_write"
    expect_serial $'No final newline\r?\n'
    expect_serial 'baremetal> '
    printf 'cat empty.txt\r' >&"$serial_write"
    expect_serial $'cat empty\\.txt\r?\nbaremetal> '

    printf 'cat missing.txt\r' >&"$serial_write"
    expect_serial 'File not found\.'
    expect_serial 'baremetal> '
    printf 'cat\r' >&"$serial_write"
    expect_serial 'Usage: cat FILE'
    expect_serial 'baremetal> '

    printf 'rm\r' >&"$serial_write"
    expect_serial 'Usage: rm PATH'
    expect_serial 'baremetal> '
    printf 'rm hello.txt\r' >&"$serial_write"
    expect_serial 'Archive file is read-only\.'
    expect_serial 'baremetal> '
    printf 'echo updated > hello.txt\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'touch hello.txt\r' >&"$serial_write"
    expect_serial $'touch hello\\.txt\r?\nbaremetal> '
    printf 'ls\r' >&"$serial_write"
    expect_serial $'ls\r?\ntwo words\\.txt\r?\nempty\\.txt\r?\nhello\\.txt\r?\nbaremetal> '
    printf 'cat hello.txt\r' >&"$serial_write"
    expect_serial $'\r?\nupdated\r?\nbaremetal> '
    printf 'rm hello.txt\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'touch hello.txt\r' >&"$serial_write"
    expect_serial $'touch hello\\.txt\r?\nbaremetal> '
    printf 'cat hello.txt\r' >&"$serial_write"
    expect_serial $'\r?\nHello from RAM\r?\nbaremetal> '

    printf 'help\r' >&"$serial_write"
    for command_label in help info cpu 'cpu ping' mem memmap lspci disk net 'ls [PATH]' 'cd PATH' pwd mount umount 'cat PATH' 'crc32 FILE' echo 'cp SRC DST' 'touch PATH' 'rm PATH' uptime log version clear reboot halt; do
        printf -v padded_label '%-11s' "$command_label"
        padded_label=${padded_label//\[/\\[}
        padded_label=${padded_label//\]/\\]}
        expect_serial $'\r?\n'"$padded_label"'[^[:space:]]'
    done
    expect_serial 'baremetal> '
}

check_crc_archive() {
    expect_serial 'baremetal> '
    enter_ram
    printf 'crc32 digits\r' >&"$serial_write"
    expect_serial $'\r?\nCBF43926\r?\nbaremetal> '
    printf 'crc32 binary\r' >&"$serial_write"
    expect_serial $'\r?\nE9C0AED4\r?\nbaremetal> '
    printf 'crc32 empty.txt\r' >&"$serial_write"
    expect_serial $'\r?\n00000000\r?\nbaremetal> '
    printf 'echo 123456789 > digits\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'crc32 digits\r' >&"$serial_write"
    expect_serial $'\r?\nE0117757\r?\nbaremetal> '
    printf 'rm digits\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'crc32 digits\r' >&"$serial_write"
    expect_serial $'\r?\nCBF43926\r?\nbaremetal> '
    printf 'crc32 missing\r' >&"$serial_write"
    expect_serial 'File not found\.'
    expect_serial 'baremetal> '
    printf 'crc32\r' >&"$serial_write"
    expect_serial 'Usage: crc32 FILE'
    expect_serial 'baremetal> '
}

check_overlong_commands() {
    printf 'echo original > note\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'echo separate > note.txt\r' >&"$serial_write"
    expect_serial 'baremetal> '

    # The old reader executed the first 1023 bytes, ending at "note".
    printf '%1016srm note.txt\r' '' >&"$serial_write"
    expect_serial 'Command too long\.'
    expect_serial 'baremetal> '
    printf '%1003secho replaced > note.txt\r' '' >&"$serial_write"
    expect_serial 'Command too long\.'
    expect_serial 'baremetal> '
    printf 'cat note\r' >&"$serial_write"
    expect_serial $'\r?\noriginal\r?\nbaremetal> '
    printf 'cat note.txt\r' >&"$serial_write"
    expect_serial $'\r?\nseparate\r?\nbaremetal> '

    printf '%1016srm note\r' '' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'cat note\r' >&"$serial_write"
    expect_serial 'File not found\.'
    expect_serial 'baremetal> '
}

check_duplicate_archive() {
    expect_serial 'baremetal> '
    enter_ram
    printf 'cat hello.txt\r' >&"$serial_write"
    expect_serial $'\r?\nLatest in archive\r?\nbaremetal> '
    printf 'ls\r' >&"$serial_write"
    expect_serial $'ls\r?\ntwo words\\.txt\r?\nempty\\.txt\r?\nhello\\.txt\r?\nbaremetal> '
    printf 'echo override > hello.txt\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'ls\r' >&"$serial_write"
    expect_serial $'ls\r?\ntwo words\\.txt\r?\nempty\\.txt\r?\nhello\\.txt\r?\nbaremetal> '
    printf 'rm hello.txt\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'cat hello.txt\r' >&"$serial_write"
    expect_serial $'\r?\nLatest in archive\r?\nbaremetal> '
}

check_one_page() {
    expect_serial 'baremetal> '
    enter_ram
    printf 'echo first > note.txt\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'echo second > other.txt\r' >&"$serial_write"
    expect_serial 'No free pages for a RAM file\.'
    expect_serial 'baremetal> '
    printf 'ls\r' >&"$serial_write"
    expect_serial $'ls\r?\nnote\\.txt\r?\nbaremetal> '
    printf 'echo replaced in place > note.txt\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'cat note.txt\r' >&"$serial_write"
    expect_serial $'\r?\nreplaced in place\r?\nbaremetal> '
    printf 'mem\r' >&"$serial_write"
    expect_serial '4 KiB pages: 1 managed, 1 used, 0 free'
    expect_serial 'baremetal> '
    printf 'rm note.txt\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'mem\r' >&"$serial_write"
    expect_serial '4 KiB pages: 1 managed, 0 used, 1 free'
    expect_serial 'baremetal> '
    printf 'echo second > other.txt\r' >&"$serial_write"
    expect_serial 'baremetal> '
    printf 'cat other.txt\r' >&"$serial_write"
    expect_serial $'\r?\nsecond\r?\nbaremetal> '
}

check_bad_archive() {
    expect_serial 'baremetal> '
    enter_ram
    printf 'ls\r' >&"$serial_write"
    expect_serial $'ls\r?\nInvalid RAM filesystem archive\\.'
    expect_serial 'baremetal> '
    printf 'cat hello.txt\r' >&"$serial_write"
    expect_serial 'Invalid RAM filesystem archive\.'
    expect_serial 'baremetal> '
}

check_index_pages() {
    local n name
    expect_serial 'baremetal> '
    enter_ram
    printf 'ls\r' >&"$serial_write"
    expect_serial $'ls\r?\n'
    for ((n = 1; n <= 350; n++)); do
        printf -v name 'file-%03d' "$n"
        expect_serial "^$name"$'\r?\n'
    done
    expect_serial '^baremetal> '
    printf 'cat file-350\r' >&"$serial_write"
    expect_serial $'\r?\nLast file\r?\nbaremetal> '
}

check_failed_index() {
    local error=$1
    expect_serial 'baremetal> '
    enter_ram
    printf 'ls\r' >&"$serial_write"
    expect_serial $'ls\r?\n'"$error"$'\r?\nbaremetal> '
    printf 'cat file-001\r' >&"$serial_write"
    expect_serial $'cat file-001\r?\n'"$error"$'\r?\nbaremetal> '
    printf 'mem\r' >&"$serial_write"
    expect_serial '4 KiB pages: 1 managed, 0 used, 1 free'
    expect_serial 'baremetal> '
}

check_index_oom() {
    check_failed_index 'No free pages for the RAM filesystem index\.'
}

check_truncated_index() {
    check_failed_index 'Invalid RAM filesystem archive\.'
}

files=$(mktemp -d)
trap 'find "$files" -depth -delete' EXIT
mkdir "$files/root"
printf 'Hello from RAM\n' > "$files/root/hello.txt"
printf 'No final newline' > "$files/root/two words.txt"
touch "$files/root/empty.txt"
tar --format=ustar -C "$files/root" -cf "$files/ramfs.tar" hello.txt 'two words.txt' empty.txt
printf '123456789' > "$files/root/digits"
printf '\000\200\377' > "$files/root/binary"
tar --format=ustar -C "$files/root" -cf "$files/crc.tar" digits binary empty.txt
cp "$files/ramfs.tar" "$files/duplicates.tar"
printf 'Latest in archive\n' > "$files/root/hello.txt"
tar --format=ustar -C "$files/root" -rf "$files/duplicates.tar" hello.txt

# Keep the first file intact and damage the second header.
head -c 1025 "$files/ramfs.tar" > "$files/truncated.tar"
cp "$files/ramfs.tar" "$files/corrupt.tar"
printf '9' | dd of="$files/corrupt.tar" bs=1 seek=$((1024 + 124)) conv=notrunc status=none

# Span several index pages. The truncated copy fails after allocating a page.
mkdir "$files/many"
for ((n = 1; n <= 350; n++)); do
    printf -v name 'file-%03d' "$n"
    touch "$files/many/$name"
    printf '%s\n' "$name"
done > "$files/names"
printf 'Last file\n' > "$files/many/file-350"
tar --format=ustar -C "$files/many" -cf "$files/many.tar" -T "$files/names"
head -c $((199 * 512 + 1)) "$files/many.tar" > "$files/truncated-index.tar"

build_dir=${1:-build}
kernel="$build_dir/baremetal-os.elf"
one_page="$build_dir/smp-fixture-one_page.elf"
run_guest 'RAM filesystem without a boot archive' 1 64M check_no_archive -kernel "$kernel"
run_guest 'RAM filesystem with a boot archive' 1 64M check_archive -kernel "$kernel" -initrd "$files/ramfs.tar"
run_guest 'CRC-32 of archive and writable files' 4 64M check_crc_archive \
    -kernel "$kernel" -initrd "$files/crc.tar"
run_guest 'RAM filesystem with duplicate archive entries' 1 64M check_duplicate_archive \
    -kernel "$kernel" -initrd "$files/duplicates.tar"
run_guest 'RAM filesystem with one allocatable page' 1 64M check_one_page \
    -kernel "$one_page"
run_guest 'RAM filesystem index spanning multiple pages' 1 64M check_index_pages \
    -kernel "$kernel" -initrd "$files/many.tar"
run_guest 'RAM filesystem index without enough memory' 1 64M check_index_oom \
    -kernel "$one_page" -initrd "$files/many.tar"
run_guest 'RAM filesystem index with a late invalid header' 1 64M check_truncated_index \
    -kernel "$one_page" -initrd "$files/truncated-index.tar"
run_guest 'Truncated RAM filesystem' 1 64M check_bad_archive -kernel "$kernel" -initrd "$files/truncated.tar"
run_guest 'Corrupt RAM filesystem header' 1 64M check_bad_archive -kernel "$kernel" -initrd "$files/corrupt.tar"
