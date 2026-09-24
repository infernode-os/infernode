# Patches to QEMU that the harness depends on

QEMU is the harness's test bed for the bare-metal kernel, and where its
device models are wrong the kernel is tested against the wrong thing.
Each file here is one such place, as a patch against the QEMU version
CI builds (`.github/workflows/baremetal.yml`), with the bug described at
the top of the patch. CI applies every patch before it builds; a
machine that runs the harness with a distribution's QEMU does not have
them, and the harness says which checks depend on one.

| patch | what QEMU did | what the kernel saw |
|-|-|-|
| `hcd-dwc2-halted-channel.patch` | The Raspberry Pi's USB controller model kept servicing a channel after the guest halted it, with whatever the guest had since programmed into that channel. | On `raspi3b`/`raspi4b` with `-device usb-net`, the DHCP OFFER was read by a stale transaction and lost, and every DISCOVER after the first was garbled by a duplicated packet inside the adapter's RNDIS reassembly: an address on two boots in five (#664). `usbdwc.c` halts a bulk IN that has waited 200 ms for nothing, which is what a real controller expects and what makes the model fail. |

To use them by hand: unpack the QEMU version named in the workflow,
`patch -p1 < <file>` in its top directory, configure with the flags the
workflow uses, build. `BAREMETAL_QEMU_PATCHED=1` tells the harness it is
running on such a QEMU, so the checks that only hold there are made
rather than skipped.

Found on 2026-09-24 by tracing the model's packets (`-trace
'usb_dwc2_*'`) against the driver's own log of each transfer; the
patch's header is the description meant for QEMU's maintainers.
