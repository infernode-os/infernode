/*
 * os/amd64/console.h -- the 16550 console, provided by main.c.
 *
 * The board and the machine both use it; it is declared here so that
 * neither has to include the other's headers.
 */

#ifndef _OS_AMD64_CONSOLE_H_
#define _OS_AMD64_CONSOLE_H_

#include <stdint.h>

void	consputc(int);
void	consprint(const char*);
void	consprinthex(uint64_t);
void	consprintdec(uint64_t);
void	conshalt(void);
void	conswrite(char*, int);

#endif
