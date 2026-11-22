#include "lib9.h"

char*
strdup(const char *s) 
{  
	char *os;
	size_t n;

	n = strlen(s) + 1;
	os = malloc(n);
	if(os == 0)
		return 0;
	memmove(os, s, n);
	return os;
}
