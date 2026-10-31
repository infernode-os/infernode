#include "lib9.h"
#include "draw.h"

static void *nameptr;
static void *infoptr;
static void *fontptr;
static int namefreed;
static int infofreed;
static int fontfreed;

void
testfree(void *p)
{
	if(p == nameptr)
		namefreed++;
	if(p == infoptr)
		infofreed++;
	if(p == fontptr)
		fontfreed++;
}

void
uninstallsubfont(Subfont *f)
{
	(void)f;
}

int
freeimage(Image *i)
{
	(void)i;
	return 0;
}

void freesubfont_under_test(Subfont*);

int
main(void)
{
	Subfont f;
	Fontchar info[2];
	char name[] = "owned name";

	memset(&f, 0, sizeof f);
	f.name = name;
	f.info = info;
	f.ref = 1;
	nameptr = name;
	infoptr = info;
	fontptr = &f;
	freesubfont_under_test(&f);
	if(namefreed != 1 || infofreed != 1 || fontfreed != 1){
		fprint(2, "FAIL: freesubfont ownership: name %d info %d font %d\n",
			namefreed, infofreed, fontfreed);
		return 1;
	}
	print("PASS: freesubfont releases its owned name\n");
	return 0;
}
