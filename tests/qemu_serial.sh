# Shared QEMU serial-console harness. Source it from a test script.

expect_serial() {
    local pattern=$1 char received= remaining
    local deadline=$((SECONDS + 30))

    while (( (remaining = deadline - SECONDS) > 0 )) &&
        IFS= read -r -N 1 -t "$remaining" -u "$serial_read" char; do
        received+=$char
        transcript+=$char
        if [[ $received =~ $pattern ]]; then
            return 0
        fi
    done

    printf 'Serial output did not contain %q\n' "$pattern" >&2
    return 1
}

cleanup_guest() {
    local status=$?
    if [[ -n $qemu_pid ]]; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi
    if (( status != 0 )); then
        printf '%s serial output: %q\n' "$label" "$transcript" >&2
    fi
}

run_guest() (
    local label=$1 cpus=$2 ram=$3 check=$4
    shift 4
    local qemu_pid= serial_read serial_write transcript= remainder= status=0

    printf 'Booting %s with %s vCPU(s)\n' "$label" "$cpus"
    trap cleanup_guest EXIT
    coproc GUEST {
        exec qemu-system-x86_64 -accel "${QEMU_TEST_ACCEL:-tcg}" -m "$ram" -smp "$cpus" -nic none \
            -display none -serial stdio -monitor none "$@"
    }
    qemu_pid=$!
    # Keep both pipes open while Bash reaps the coprocess.
    exec {serial_read}<&"${GUEST[0]}" {serial_write}>&"${GUEST[1]}"

    "$check" "$@"

    if [[ ${QEMU_TEST_POWER_CUT:-0} == 1 ]]; then
        kill -KILL "$qemu_pid"
        wait "$qemu_pid" 2>/dev/null || status=$?
        qemu_pid=
        if (( status != 137 )); then
            printf 'Expected the disposable guest to be stopped during disk I/O\n' >&2
            return 1
        fi
        printf '%s passed\n' "$label"
        return
    fi

    printf 'halt\r' >&"$serial_write"
    expect_serial $'Powering off\\.\\.\\.\r?\n'
    IFS= read -r -d '' -t 30 -u "$serial_read" remainder || status=$?
    transcript+=$remainder
    if (( status != 1 )); then
        printf 'Expected QEMU to close the serial console after halt\n' >&2
        exit 1
    fi
    status=0
    wait "$qemu_pid" || status=$?
    qemu_pid=
    if (( status != 0 )); then
        printf 'QEMU exited with status %d\n' "$status" >&2
        exit "$status"
    fi
    printf '%s passed\n' "$label"
)
