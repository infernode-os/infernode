# A board's entry to the boot: os/init/profile (built into the kernel
# image) runs this from the card, in the background of the serial
# console's shell.  The boot itself is lib/lucifer/boot.sh, the one
# every build runs; it knows a board ($emuhost unset) and does a
# board's part there: the desktop's name space narrowed, the
# remote-desktop listener, the headless check, the login required.
#
# The name is kept so that a kernel and a card of different releases
# still meet: an older kernel's profile calls this file, and an older
# card has its own, which narrows the name space as this boot does.

load std
run /lib/lucifer/boot.sh
