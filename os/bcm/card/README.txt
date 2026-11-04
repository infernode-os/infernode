InferNode for the Raspberry Pi
==============================

This card boots InferNode -- Inferno running natively, with no other
operating system under it -- on the board its image was built for: a
Raspberry Pi 3B+ (infernode-*-rpi3bplus.img) or a Raspberry Pi 4B
(infernode-*-rpi4b.img). The kernels differ; a card for one board does
not boot the other.

First boot
----------

With a screen attached (HDMI, or the official 7" panel) the machine
starts the login screen. The first time, it asks for a new password
twice and keeps your keys under usr/ on this card. A USB keyboard and
mouse work; wired Ethernet is configured by DHCP.

With no screen it runs headless: a shell on the serial console (a 3.3 V
USB-serial cable on GPIO 14 and 15, 115200 8N1). The serial console is a
shell in either case, and everything printed before the screen comes up,
including a panic, appears only there.

Files on this card that change what the machine does
-----------------------------------------------------

All are optional, and absent from a new card:

  wifi        essid <name> and password <phrase>, one per line: join
              that network at boot (the radio's firmware is already in
              firmware/). This file is plain text on a FAT card: anyone
              holding the card can read the passphrase.
  bt          Bluetooth: /net/bt ctl lines, one per line, run at boot.
              Typically "firmware /n/dos/firmware/BCM4345C0.hcd" (the
              patch is already in firmware/), "up", "name ...", and
              "pairable on" and "discoverable on" only if you mean
              anyone in range to be able to pair. The manual's section
              5 and docs/BLUETOOTH.md have the rest.
  netconsole  a shell on TCP port 17010. Read the manual first: the
              token on its first line is sent in clear.
  skiplogon   start the desktop with no login. Keys will not persist.

Security and updates
--------------------

There is no default password: the first boot asks you to choose one. A
new card offers nothing on the network that lets anyone in; the files
above (netconsole, and cpulisten in the manual) are what turn that on.
The serial console on GPIO 14 and 15 is a shell for anyone who can
reach those pins.

Nothing updates itself. Security fixes come as a new release, with new
card images; write the new image to the card as you wrote this one.
That replaces the whole card, usr/ too, which holds your keys and
secstore account: copy usr/, and any control files, off it first and
back after. How long each release gets fixes is in SECURITY.md:
https://github.com/infernode-os/infernode/blob/master/SECURITY.md

Report a security problem privately, not as a public issue:
https://github.com/infernode-os/infernode/security/advisories/new

The manual, and every other file the machine reads:
https://github.com/infernode-os/infernode/blob/master/docs/BAREMETAL.md

The firmware files beside this one (bootcode.bin, start*.elf, fixup*.dat,
the .dtb) are Broadcom's and Raspberry Pi's, under LICENCE.broadcom. The
radio's Wi-Fi firmware and Bluetooth patch, in firmware/, are Cypress's,
under firmware/LICENCE.cypress: for
use with the Cypress radio on this board, and not to be copied elsewhere.
InferNode itself is under LICENSE, with NOTICE.
