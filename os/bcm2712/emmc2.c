/*
 * The card: the SoC's Broadcom SDHCI, which is ../bcm/emmc.c as it is
 * for a Pi 4's EMMC2 (../bcm2711/emmc2.c), at another address and on a
 * fixed clock (Linux's bcm2712.dtsi, clk_emmc2).
 */
#define EMMCIO		emmc2io
#define EMMCNAME	"emmc2"
#define EMMCBASE	0x1000FFF000ULL
#define EMMCCLK		0
#define EMMCBASEHZ	200000000
#define EMMCBUSPOWER

#include "../bcm/emmc.c"
