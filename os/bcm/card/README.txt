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
  netconsole  a shell on TCP port 17010. Read the manual first: the
              token on its first line is sent in clear.
  skiplogon   start the desktop with no login. Keys will not persist.

The manual, and every other file the machine reads:
https://github.com/infernode-os/infernode/blob/master/docs/BAREMETAL.md

The firmware files beside this one (bootcode.bin, start*.elf, fixup*.dat,
the .dtb) are Broadcom's and Raspberry Pi's, under LICENCE.broadcom. The
radio's, in firmware/, are Cypress's, under firmware/LICENCE.cypress: for
use with the Cypress radio on this board, and not to be copied elsewhere.
InferNode itself is under LICENSE, with NOTICE.
