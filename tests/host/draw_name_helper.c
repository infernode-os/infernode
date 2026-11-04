static void *freedname;

#define free drawtestfree
#include "../../emu/port/devdraw.c"
#undef free

void
drawtestfree(void *p)
{
	freedname = p;
}

int
main(void)
{
	DName names[2];
	char first[] = "first";
	char second[] = "second";

	memset(names, 0, sizeof names);
	names[0].name = first;
	names[0].vers = 1;
	names[1].name = second;
	names[1].vers = 2;
	sdraw.name = names;
	sdraw.nname = 2;
	drawdelname(&names[0]);
	if(freedname != first){
		fprint(2, "FAIL: drawdelname did not release the removed name\n");
		return 1;
	}
	if(sdraw.nname != 1 || names[0].name != second || names[0].vers != 2){
		fprint(2, "FAIL: drawdelname did not compact the remaining names\n");
		return 1;
	}
	print("PASS: drawdelname releases and compacts names\n");
	return 0;
}
