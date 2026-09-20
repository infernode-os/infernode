/*
 * What this board's files share with one another. Nearly all of it is
 * the interface of the Broadcom family's drivers (../bcm), which both
 * those drivers and this board's code are written against, so it lives
 * with them; a declaration that is this board's alone goes below.
 */
#include "../bcm/bcm.h"

/* ethergenet.c */
void	ethergenetlink(void);
