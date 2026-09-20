/*
 * What devdraw expects a platform to provide.
 *
 * The whole contract is four functions and a blanking hook. devdraw
 * does every pixel of the actual drawing through libmemdraw; the board
 * only has to say where the screen is, what shape it is, and how to
 * make changes visible.
 */

typedef struct Cursor Cursor;

#define	CURSWID	16
#define	CURSHGT	16

/*
 * 8 rather than BI2BY: this header is reached from board.h as well as
 * from devdraw, and BI2BY is a draw-library constant that is not in
 * scope on every path here. The value it stands for is bits per byte.
 */
struct Cursor {
	Point	offset;
	uchar	clr[CURSWID/8*CURSHGT];
	uchar	set[CURSWID/8*CURSHGT];
};

/*
 * Hand back the framebuffer and its geometry. nil if there is no
 * screen, which devdraw treats as "this machine has no display" rather
 * than as an error.
 */
uchar*	attachscreen(Rectangle*, ulong*, int*, int*, int*);

/*
 * Make a rectangle visible. A no-op here -- see screen.c.
 */
void	flushmemscreen(Rectangle);

/*
 * Palette, for indexed-colour screens. This one is 32-bit direct
 * colour, so there is no palette to read or write.
 *
 * Not declared here: os/port/portfns.h already declares both, and
 * getcolor returns void there. Declaring them again with a different
 * return type is a conflict, and portfns is the one devdraw sees.
 */

/*
 * Screen blanking, which devdraw drives from an idle timer.
 */
extern void	blankscreen(int);
extern void	drawblankscreen(int);
extern ulong	blanktime;
