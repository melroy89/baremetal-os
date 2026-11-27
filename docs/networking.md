# Ethernet and IPv4

Attach a modern `virtio-net` or QEMU `e1000` adapter. The kernel prefers a usable `virtio-net` device and starts DHCP in the background once the selected adapter initializes. Use `net info` to check which driver is active and whether an address has been assigned.

| Command                               | Action                                                          |
| ------------------------------------- | --------------------------------------------------------------- |
| `net info`                            | Show the adapter, link state, and IPv4 configuration.           |
| `net dhcp`                            | Switch to DHCP or restart lease discovery.                      |
| `net static ADDRESS/PREFIX [GATEWAY]` | Set an IPv4 address and an optional on-link gateway.            |
| `net dns ADDRESS`                     | Set the DNS server for static IPv4.                             |
| `net resolve NAME`                    | Look up an IPv4 address through the configured resolver.        |
| `ping HOST`                           | Send one IPv4 echo request to an address or DNS name.           |
| `net off`                             | Clear IPv4 configuration and return to raw Ethernet mode.       |
| `net recv`                            | Receive one raw frame and show its addresses, type, and length. |
| `net send MAC ETHERTYPE RAMFILE`      | Send up to 1,500 bytes from a RAM file as one frame.            |

## Try IPv4 in QEMU

For direct boot with QEMU's user network, replace `-nic none` with `-netdev user,id=net0 -device virtio-net-pci,netdev=net0,disable-legacy=on`. For `e1000`, use `-nic user,model=e1000`. Wait for `net info` to show an IPv4 address before running the ping.

```text
net info
ping 10.0.2.2
```

IPv4 fragmentation is unsupported. DNS uses UDP A queries and requires the guest CPU to expose `RDRAND`.

## Send a raw frame

Use the peer's colon-separated MAC address and a four-digit hexadecimal EtherType of `0600` or higher.

```text
net off
echo Hello Ethernet > /ram/payload.txt
net send 52:54:00:AB:CD:EF 88B5 payload.txt
```

Run `make test-network` for the isolated QEMU stream tests. On a Linux host with KVM, TUN/TAP, and user namespaces, `make test-network-tap` checks ping in both directions.
Run `make bench-network` on that host to compare the two drivers over TAP with the same polling cadence.
