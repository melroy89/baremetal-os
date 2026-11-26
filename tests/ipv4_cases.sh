# Deterministic host endpoint for the isolated QEMU stream fixture.
guest_mac=525400123456
peer_mac=525400abcdef
new_peer_mac=525400987654
guest_ip=c000020a                     # 192.0.2.10
peer_ip=c0000201                      # 192.0.2.1
remote_ip=c6336409                    # 198.51.100.9

wire_hex() {
    printf '%b' "$(sed 's/../\\x&/g' <<< "$1")"
}

wire_receive() {
    local length
    length=$(timeout 5 dd bs=4 count=1 iflag=fullblock status=none <&"$wire_out" |
        od -An -v -t x1 | tr -d ' \n')
    [[ ${#length} == 8 ]]
    frame=$(timeout 5 dd bs="$((16#$length))" count=1 iflag=fullblock status=none <&"$wire_out" |
        od -An -v -t x1 | tr -d ' \n')
    [[ ${#frame} == "$((2 * 16#$length))" ]]
}

wire_send() {
    local body=$1
    local prefix
    printf -v prefix '%08x' "$((${#body} / 2))"
    wire_hex "$prefix$body" >&"$wire_in"
}

# Internet checksum of a hex string in wire order.
checksum_hex() {
    local body=$1 sum=0 i
    if (( ${#body} % 4 )); then
        body+=00
    fi
    for ((i = 0; i < ${#body}; i += 4)); do
        ((sum += 16#${body:i:4})) || true
    done
    while (( sum > 65535 )); do
        ((sum = (sum & 65535) + (sum >> 16)))
    done
    printf '%04x' "$((65535 ^ sum))"
}

arp_packet() {
    local op=$1 source_ip=$2 target_ip=$3 source_mac=${4:-$peer_mac} destination_mac=$5
    local target_mac=$destination_mac
    if [[ $destination_mac == ffffffffffff ]]; then
        target_mac=000000000000
    fi
    wire_send "$destination_mac${source_mac}0806000108000604$op$source_mac$source_ip$target_mac$target_ip"
}

ip_packet() {
    local type=$1 source=$2 destination=$3 payload=$4
    local header length checksum
    printf -v length '%04x' "$((20 + ${#payload} / 2))"
    header="4500${length}0123400040${type}0000$source$destination"
    checksum=$(checksum_hex "$header")
    wire_send "$guest_mac${peer_mac}0800${header:0:20}$checksum${header:24}$payload"
}

udp_packet() {
    local source=$1 destination=$2 ports=$3 payload=$4
    local length checksum
    printf -v length '%04x' "$((8 + ${#payload} / 2))"
    checksum=$(checksum_hex "$source${destination}0011$length$ports${length}0000$payload")
    [[ $checksum != 0000 ]] || checksum=ffff
    ip_packet 11 "$source" "$destination" "$ports$length$checksum$payload"
}

icmp_packet() {
    local type=$1 source=$2 tail=$3
    local checksum
    checksum=$(checksum_hex "${type}000000$tail")
    ip_packet 01 "$source" "$guest_ip" "${type}00$checksum$tail"
}

connect_wire() {
    # Open both ends of each FIFO while socat connects to the Unix socket.
    exec {wire_in}<>"$files/to-guest" {wire_out}<>"$files/from-guest"
    timeout "$1" socat - "UNIX-CONNECT:$files/wire" <&"$wire_in" >&"$wire_out" &
    peer=$!
}

start_wire() {
    connect_wire 100
    local attempt
    for attempt in {1..20}; do
        printf 'net info\r' >&"$serial_write"
        expect_serial 'Link: (up|down)'
        [[ ${BASH_REMATCH[1]} == up ]] && break
        expect_serial 'baremetal> '
        sleep 0.2
    done
    [[ ${BASH_REMATCH[1]} == up ]]
    expect_serial 'baremetal> '
}

assert_icmp_frame() {
    local frame=$1 from=$2 to=$3 type=$4
    [[ ${frame:24:4} == 0800 && ${frame:46:2} == 01 && ${frame:52:8} == "$from" &&
        ${frame:60:8} == "$to" && ${frame:68:2} == "$type" ]]
    local len=$((16#${frame:32:4} - 20))
    [[ $(checksum_hex "${frame:28:40}") == 0000 ]]
    [[ $(checksum_hex "${frame:68:len*2}") == 0000 ]]
}

check_bulk_output() {
    printf 'cat /ram/bulk.txt\r' >&"$serial_write"
    expect_serial $'bulk-start\r?\n'
    (
        local line
        while IFS= read -r -t 15 -u "$serial_read" line; do
            if [[ $line == bulk-end ]]; then
                touch "$files/bulk-ended"
                exit
            fi
        done
        exit 1
    ) &
    local drain=$!
    icmp_packet 08 "$peer_ip" 01020304
    wire_receive
    assert_icmp_frame "$frame" "$guest_ip" "$peer_ip" 00
    [[ ! -e $files/bulk-ended ]]
    wait "$drain"
    unlink "$files/bulk-ended"
    expect_serial 'baremetal> '
}

check_ram_checksum() {
    local command=$1 expected_crc=$2 echo_id=$3
    printf '%s\r' "$command" >&"$serial_write"
    expect_serial "$command"$'\r?\n'
    (
        expect_serial "$expected_crc"$'\r?\n'
        touch "$files/checksum-ended-$echo_id"
    ) &
    local drain=$!
    icmp_packet 08 "$peer_ip" "$echo_id"
    wire_receive
    assert_icmp_frame "$frame" "$guest_ip" "$peer_ip" 00
    [[ ${frame:76:8} == "$echo_id" && ! -e $files/checksum-ended-$echo_id ]]
    wait "$drain"
    unlink "$files/checksum-ended-$echo_id"
    expect_serial 'baremetal> '
}

dns_query_fields() {
    wire_receive
    [[ ${frame:46:2} == 11 && ${frame:72:4} == 0035 ]]
    query_port=${frame:68:4}
    query_id=${frame:84:4}
    local bytes=$((16#${frame:76:4} - 8 - 12))
    query_name=${frame:108:bytes*2}
    [[ $(checksum_hex "${frame:52:16}0011${frame:76:4}${frame:68:(bytes+20)*2}") == 0000 ]]
}

dns_reply() {
    local flags=$1 question=$2 count=$3 records=$4
    udp_packet "$peer_ip" "$guest_ip" "0035$query_port" \
        "$query_id${flags}0001${count}00000000$question$records"
}

check_ipv4() {
    local peer wire_in wire_out frame query_port query_id query_name
    expect_serial 'baremetal> '
    console_check 'net off' 'IPv4: off'
    start_wire
    cat "$files/inbound" >&"$wire_in"
    console_check "net recv" "EtherType: 88B5"
    # An already completed raw ARP frame must not be consumed by IPv4.
    arp_packet 0001 "$peer_ip" "$guest_ip" "$peer_mac" ffffffffffff
    sleep 0.1
    console_check 'net static 192.0.2.10/24 192.0.2.1' 'IPv4: static'
    console_check 'net recv' 'Raw Ethernet commands require net off'
    arp_packet 0001 "$peer_ip" "$guest_ip" "$peer_mac" ffffffffffff
    wire_receive
    [[ ${frame:40:4} == 0002 && ${frame:56:8} == "$guest_ip" && ${frame:76:8} == "$peer_ip" ]]
    # If both ARP requests got replies, the next frame would be ARP instead of ICMP.
    icmp_packet 08 "$peer_ip" 12345678a1b2c3
    wire_receive
    assert_icmp_frame "$frame" "$guest_ip" "$peer_ip" 00
    [[ ${frame:76:14} == 12345678a1b2c3 ]]

    printf 'ping 198.51.100.9\r' >&"$serial_write"
    wire_receive
    assert_icmp_frame "$frame" "$guest_ip" "$remote_ip" 08
    [[ ${frame:0:12} == "$peer_mac" ]]
    icmp_packet 00 "$remote_ip" "${frame:76:8}"
    expect_serial 'Reply from 198\.51\.100\.9'
    expect_serial 'baremetal> '
    console_check 'ping 192.0.2.99' 'Ping timed out\.'
    # Consume the bounded ARP retries while replying to the next traffic.
    printf 'ping 192.0.2.1\r' >&"$serial_write"
    while :; do
        wire_receive
        [[ ${frame:24:4} == 0800 ]] && break
        [[ ${frame:76:8} == c0000263 ]]
    done
    assert_icmp_frame "$frame" "$guest_ip" "$peer_ip" 08
    icmp_packet 00 "$peer_ip" "${frame:76:8}"
    expect_serial 'Reply from 192\.0\.2\.1'
    expect_serial 'baremetal> '

    console_check 'net dns 192.0.2.1' 'DNS configured\.'
    printf 'net resolve foo.bar\r' >&"$serial_write"
    dns_query_fields
    [[ $query_name == 03666f6f036261720000010001 ]]
    # Same flattened bytes, different labels. Then a matching mixed-case reply.
    dns_reply 8180 04666f6f620261720000010001 0001 c00c00010001000000000004c00002fd
    dns_reply 8180 03666f6f0362617200001c0001 0001 c00c00010001000000000004c00002fd
    dns_reply 8180 03666f6f036261720000010003 0001 c00c00010001000000000004c00002fd
    dns_reply 8180 "$query_name" 0001 c00c00010001000000000004c00002fe
    # The next lookups prove status handling and reject a compression loop.
    expect_serial $'\r?\n192\\.0\\.2\\.254\r?\n'
    expect_serial 'baremetal> '
    printf 'net resolve Foo.Bar\r' >&"$serial_write"
    dns_query_fields
    dns_reply 8180 03664f6f034261520000010001 0001 c00c00010001000000000004c0000201
    expect_serial $'\r?\n192\\.0\\.2\\.1\r?\n'
    expect_serial 'baremetal> '
    printf 'ping alias.test\r' >&"$serial_write"
    dns_query_fields
    dns_reply 8180 "$query_name" 0002 \
        c00c0005000100000000000d067461726765740474657374000674617267657404746573740000010001000000000004c0000201
    wire_receive
    assert_icmp_frame "$frame" "$guest_ip" "$peer_ip" 08
    icmp_packet 00 "$peer_ip" "${frame:76:8}"
    expect_serial 'Reply from 192\.0\.2\.1'
    expect_serial 'baremetal> '
    local flags count question status
    while read -r flags count question status; do
        printf 'net resolve state.test\r' >&"$serial_write"
        dns_query_fields
        if [[ $question == good ]]; then
            question=$query_name
        fi
        dns_reply "$flags" "$question" "$count" ''
        expect_serial "$status"
        expect_serial 'baremetal> '
    done <<'STATES'
8183 0000 good DNS.name.does.not.exist
8180 0000 good DNS.reply.has.no.A.record
8380 0000 good DNS.reply.truncated
8182 0000 good DNS.server.returned.an.error
8180 0000 c00c00010001 DNS.query.timed.out
STATES

    check_bulk_output
    check_ram_checksum 'crc32range 1 67108864 /ram/checksum.bin' "$ram_range_crc" 05060708
    check_ram_checksum 'crc32 checksum.bin' "$ram_file_crc" 05060709
    console_check 'clear' $'\x1b\\[2J\x1b\\[H'
    console_check 'net off' 'IPv4: off'
    cat "$files/inbound" >&"$wire_in"
    console_check 'net recv' 'EtherType: 88B5'
    kill "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
}

dhcp_request_frame() {
    local type=$1
    wire_receive
    [[ ${frame:46:2} == 11 && ${frame:68:8} == 00440043 && ${frame:568:2} == "$type" ]]
    dhcp_xid=${frame:92:8}
}

dhcp_response() {
    local type=$1 lease=$2 t1=$3 t2=$4 address=${5:-$guest_ip} message
    printf -v message '02010600%s%016d%s%016d%s%0404d638253633501%s3604%s0104ffffff000308cb007101%s0604%s3304%08x3a04%08x3b04%08xff' \
        "$dhcp_xid" 0 "$address" 0 "$guest_mac" 0 "$type" "$peer_ip" "$peer_ip" "$peer_ip" "$lease" "$t1" "$t2"
    udp_packet "$peer_ip" ffffffff 00430044 "$message"
}

dhcp_handshake() {
    local lease=$1 t1=$2 t2=$3 address=${4:-$guest_ip}
    dhcp_response 02 "$lease" "$t1" "$t2" "$address"
    dhcp_request_frame 03
    [[ ${frame:52:8} == 00000000 && ${frame:60:8} == ffffffff ]]
    dhcp_response 05 "$lease" "$t1" "$t2" "$address"
}

dhcp_probes() {
    local address=$1 attempt
    for attempt in {1..3}; do
        wire_receive
        [[ ${frame:24:4} == 0806 && ${frame:56:8} == 00000000 && ${frame:76:8} == "$address" ]]
    done
}

check_dhcp() {
    local peer wire_in wire_out frame dhcp_xid query_port query_name query_id
    expect_serial 'baremetal> '
    [[ $transcript != *'No free DMA pages'* && $transcript != *'IPv4: DHCP'* ]]
    console_check 'net off' 'IPv4: off'
    start_wire
    cat "$files/inbound" >&"$wire_in"
    console_check 'net recv' 'EtherType: 88B5'
    cat "$files/inbound" >&"$wire_in"
    console_check 'net dhcp' 'IPv4: DHCP'
    dhcp_request_frame 01
    local first_xid=$dhcp_xid
    dhcp_handshake 14 6 12
    [[ $dhcp_xid == "$first_xid" ]]
    dhcp_probes "$guest_ip"

    # The idle guest must resolve a MAC and renew without a console command.
    wire_receive
    [[ ${frame:24:4} == 0806 && ${frame:76:8} == "$peer_ip" ]]
    arp_packet 0002 "$peer_ip" "$guest_ip" "$peer_mac" "$guest_mac"
    dhcp_request_frame 03
    [[ $dhcp_xid != "$first_xid" && ${frame:52:8} == "$guest_ip" && ${frame:60:8} == "$peer_ip" ]]
    dhcp_response 05 9 2 7
    console_check 'net info' $'Address: 192\\.0\\.2\\.10/24\r?\nGateway: 192\\.0\\.2\\.1\r?\nDNS: 192\\.0\\.2\\.1'

    udp_packet "$peer_ip" "$guest_ip" 7d00c000 426f72656420554450
    wire_receive
    [[ ${frame:46:2} == 11 && ${frame:68:8} == c0007d00 && ${frame:84:18} == 426f72656420554450 ]]
    dhcp_request_frame 03
    [[ ${frame:60:8} == "$peer_ip" ]]
    while :; do
        dhcp_request_frame 03
        [[ ${frame:60:8} == ffffffff ]] && break
        [[ ${frame:60:8} == "$peer_ip" ]]
    done
    printf 'net resolve expiry.test\r' >&"$serial_write"
    # A rebinding retransmit can precede the query.
    while :; do
        wire_receive
        [[ ${frame:72:4} == 0035 ]] && break
        [[ ${frame:72:4} == 0043 ]]
    done
    query_port=${frame:68:4}
    query_id=${frame:84:4}
    query_name=${frame:108:34}
    expect_serial 'IPv4 configuration changed\.'
    expect_serial 'baremetal> '
    while :; do
        wire_receive
        [[ ${frame:68:8} == 00440043 ]]
        [[ ${frame:568:2} == 01 ]] && break
        [[ ${frame:568:2} == 03 && ${frame:60:8} == ffffffff ]]
    done
    dhcp_xid=${frame:92:8}
    dns_reply 8180 "$query_name" 0001 c00c00010001000000000004c0000201
    console_check 'ping 192.0.2.1' 'IPv4 address unavailable\.'

    # Decline a conflicting offer, then explicitly acquire a changed address.
    local moved=c0000214
    dhcp_handshake 30 20 25 "$moved"
    wire_receive
    [[ ${frame:24:4} == 0806 && ${frame:76:8} == "$moved" ]]
    arp_packet 0001 "$moved" "$moved" "$new_peer_mac" ffffffffffff
    dhcp_request_frame 04
    console_check 'net dhcp' 'IPv4: DHCP'
    dhcp_request_frame 01
    dhcp_handshake 30 20 25 "$moved"
    dhcp_probes "$moved"
    sleep 2.1
    console_check 'net info' 'Address: 192\.0\.2\.20/24'
    printf 'ping 198.51.100.9\r' >&"$serial_write"
    wire_receive
    [[ ${frame:24:4} == 0806 && ${frame:76:8} == "$peer_ip" ]]
    guest_ip=$moved peer_mac=$new_peer_mac
    arp_packet 0002 "$peer_ip" "$guest_ip" "$peer_mac" "$guest_mac"
    wire_receive
    assert_icmp_frame "$frame" "$guest_ip" "$remote_ip" 08
    [[ ${frame:0:12} == "$peer_mac" ]]
    icmp_packet 00 "$remote_ip" "${frame:76:8}"
    expect_serial 'Reply from 198\.51\.100\.9'
    expect_serial 'baremetal> '
    console_check 'net dhcp' 'IPv4: DHCP'
    dhcp_request_frame 01
    dhcp_response 02 3 1 2 "$moved"
    dhcp_request_frame 01
    # Five seconds spans the probe schedule and leaves time to use the address.
    dhcp_handshake 5 2 4 "$moved"
    dhcp_probes "$moved"
    sleep 2.1
    console_check 'net info' 'Address: 192\.0\.2\.20/24'
    console_check 'net static 192.0.2.10/24' 'IPv4: static'
    console_check 'net info' $'Address: 192\\.0\\.2\\.10/24\r?\nGateway: 0\\.0\\.0\\.0\r?\nDNS: 0\\.0\\.0\\.0'
    kill "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
}

dns_failure_setup() {
    expect_serial 'baremetal> '
    console_check 'net off' 'IPv4: off'
    start_wire
    cat "$files/inbound" >&"$wire_in"
    console_check 'net recv' 'EtherType: 88B5'
    console_check 'net static 192.0.2.10/24' 'IPv4: static'
    console_check 'net dns 192.0.2.1' 'DNS configured'
    console_check 'net resolve foo.bar' 'DNS entropy unavailable\.'
}

check_dns_no_feature() {
    local peer wire_in wire_out
    dns_failure_setup
    assert_wire_idle
    kill "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
}

check_dns_fault() {
    local peer wire_in wire_out frame query_port query_id query_name
    dns_failure_setup
    console_check 'net resolve foo.bar' 'Unable to reserve a DNS source port\.'
    assert_wire_idle
    printf 'net resolve foo.bar\r' >&"$serial_write"
    wire_receive
    [[ ${frame:24:4} == 0806 && ${frame:76:8} == "$peer_ip" ]]
    arp_packet 0002 "$peer_ip" "$guest_ip" "$peer_mac" "$guest_mac"
    dns_query_fields
    [[ $query_port == c001 ]]
    dns_reply 8180 "$query_name" 0001 c00c00010001000000000004c0000201
    expect_serial $'\r?\n192\\.0\\.2\\.1\r?\n'
    expect_serial 'baremetal> '
    kill "$peer" 2>/dev/null || true
    wait "$peer" 2>/dev/null || true
}

assert_wire_idle() {
    local status=0
    timeout 0.15 dd bs=1 count=1 status=none <&"$wire_out" >/dev/null || status=$?
    [[ $status == 124 ]]
}
