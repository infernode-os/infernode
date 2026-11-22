#include "dat.h"
#include "fns.h"

static int
check(int ok, char *what)
{
	if(ok)
		return 0;
	fprint(2, "FAIL: %s\n", what);
	return 1;
}

int
main(void)
{
	char b[8];
	int failed;

	failed = 0;
	memset(b, 0x5A, sizeof b);
	kstrcpy(b, "abcdef", 1);
	failed += check(b[0] == 0 && b[1] == 0x5A,
		"one-byte destination was not terminated in bounds");
	memset(b, 0x5A, sizeof b);
	kstrcpy(b, "abcdef", 3);
	failed += check(b[0] == 'a' && b[1] == 'b' && b[2] == 0 && b[3] == 0x5A,
		"short destination was not truncated and terminated in bounds");
	memset(b, 0x5A, sizeof b);
	kstrcpy(b, "abcdefgh", sizeof b);
	failed += check(strcmp(b, "abc...") == 0,
		"long destination did not receive a terminated ellipsis");
	if(failed != 0)
		return 1;
	print("PASS: kstrcpy terminates every nonempty destination\n");
	return 0;
}
