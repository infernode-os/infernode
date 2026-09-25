# InferNode from U-Boot, on any RISC-V board whose U-Boot runs in
# S-mode (the BeagleV-Fire's, after the HSS and its OpenSBI; QEMU's
# qemu-riscv64_smode). tools/mkbootscr.py wraps this as boot.scr:
# put that and infernode.img in the root of the boot partition and
# U-Boot's standard boot finds and runs it with no one at the prompt.
#
# The kernel is linked at 0x80200000 and is not relocatable, so it is
# loaded there, not at kernel_addr_r, and booti runs it in place.
# U-Boot's own device tree -- the board's -- is the one the kernel
# gets. It lives in memory U-Boot has reserved for itself, which booti
# will not hand over, so it is copied to fdt_addr_r first, at its own
# size.

echo "InferNode: ${prefix}infernode.img from ${devtype} ${devnum}:${distro_bootpart}"
load ${devtype} ${devnum}:${distro_bootpart} 0x80200000 ${prefix}infernode.img
fdt addr ${fdtcontroladdr}
fdt header get infernode_fdtsize totalsize
fdt move ${fdtcontroladdr} ${fdt_addr_r} ${infernode_fdtsize}
booti 0x80200000 - ${fdt_addr_r}
