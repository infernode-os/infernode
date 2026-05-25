/*
 * Host filesystem device. Reuses the macOS forward (which pulls in
 * ../port/devfs-posix.c via -I../port and supplies osdisksize).
 */
#include "../MacOSX/devfs.c"
