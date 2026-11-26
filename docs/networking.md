# Ethernet

Attach QEMU's `e1000` adapter on a virtual link.

## Network commands

| Command                          | Action                                                                |
| -------------------------------- | --------------------------------------------------------------------- |
| `net info`                       | Show the PCI address, MAC address, and link state.                    |
| `net recv`                       | Poll for one frame and show its MAC addresses, EtherType, and length. |
| `net send MAC ETHERTYPE RAMFILE` | Send a RAM file of up to 1,500 bytes as one Ethernet frame.           |

## Send a frame

Use the peer's colon-separated MAC address and a four-digit hexadecimal EtherType of `0600` or higher.

```text
net info
echo Hello Ethernet > payload.txt
net send 52:54:00:AB:CD:EF 88B5 payload.txt
```

For an isolated send and receive test, install `socat` and run `make test-network`.
