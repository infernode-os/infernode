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
	Client client;
	Memimage image;
	char first[] = "first";
	char second[] = "second";
	uchar ctl[12*12+1];
	int n;

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
	memset(&client, 0, sizeof client);
	memset(&image, 0, sizeof image);
	memset(ctl, 0x5A, sizeof ctl);
	client.clientid = 7;
	image.chan = GREY8;
	image.r = Rect(-1, -2, 3, 4);
	image.clipr = Rect(-5, -6, 7, 8);
	n = drawctlformat(ctl, &client, &image);
	if(n != 12*12 || ctl[12*12-1] != ' ' || ctl[12*12] != 0x5A){
		fprint(2, "FAIL: draw ctl record overflowed its exact-size buffer\n");
		return 1;
	}
	print("PASS: draw names and exact-size ctl records stay in bounds\n");
	return 0;
}
