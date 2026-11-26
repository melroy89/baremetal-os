# Ethernet

Attach QEMU's `e1000` adapter on a virtual link.

| Command                   | Action                                                                                                                      |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `net info`                | Show PCI address, MAC, and link state.                                                                                      |
| `net recv`                | Poll for one frame and show its MAC addresses, EtherType, and length.                                                       |
| `net send DEST TYPE FILE` | Send a RAM file of up to 1,500 bytes to a colon-separated MAC. Use a four-digit hexadecimal EtherType of `0600` or greater. |

```text
net info
echo Hello Ethernet > payload.txt
net send 52:54:00:AB:CD:EF 88B5 payload.txt
```

Replace the destination with the peer's MAC. For an isolated send and receive test, install `socat` and run `make test-network`.
