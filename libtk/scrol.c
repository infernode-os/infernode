#include "lib9.h"
#include "draw.h"
#include "tk.h"

#define	O(t, e)		((long)(&((t*)0)->e))

/* Layout constants */
enum {
	Triangle	= 8,	/* bar thickness (was triangle height; no arrows now) */
	Elembw	= 1,		/* border around elements */
	Scrollbw	= 1,		/* bevel border on scrollbar */
	Tribw=	1,	/* shadow border on triangle */
	Slidermin	= 8,	/* minimum thumb length so it stays grabbable */
};

typedef struct TkScroll TkScroll;
struct TkScroll
{
	int		activer;
	int		orient;		/* Horitontal or Vertical */
	int		dragpix;	/* Scroll delta in button drag */
	int		dragtop;
	int		dragbot;
	int		jump;		/* Jump scroll enable */
	int		flag;		/* Display flags */
	int		top;		/* Top fraction */
	int		bot;		/* Bottom fraction */
	int		a1;		/* Pixel top/left arrow1 */
	int		t1;		/* Pixel top/left trough */
	int		t2;		/* Pixel top/left lower trough */
	int		a2;		/* Pixel top/left arrow2 */
	char*		cmd;
};

enum {
	ActiveA1	= (1<<0),	/* Scrollbar control */
	ActiveA2	= (1<<1),
	ActiveB1	= (1<<2),
	ButtonA1	= (1<<3),
	ButtonA2	= (1<<4),
	ButtonB1	= (1<<5),
	Autorepeat = (1<<6)
};

static
TkOption opts[] =
{
	"activerelief",	OPTstab,	O(TkScroll, activer),	tkrelief,
	"command",	OPTtext,	O(TkScroll, cmd),	nil,
	"jump",	OPTstab,	O(TkScroll, jump),	tkbool,
	"orient",	OPTstab,	O(TkScroll, orient),	tkorient,
	nil
};

static
TkEbind b[] = 
{
	{TkLeave,		"%W activate {}"},
	{TkEnter,		"%W activate [%W identify %x %y]"},
	{TkMotion,		"%W activate [%W identify %x %y]"},
	{TkButton1P|TkMotion,	"%W tkScrollDrag %x %y"},
	{TkButton1P,		"%W tkScrolBut1P %x %y"},
	{TkButton1P|TkDouble,	"%W tkScrolBut1P %x %y"},
	{TkButton1R,	"%W tkScrolBut1R; %W activate [%W identify %x %y]"},
	{TkButton2P,		"%W tkScrolBut2P [%W fraction %x %y]"},
};

static char*
tkinitscroll(Tk *tk)
{
	int gap;
	TkScroll *tks;

	tks = TKobj(TkScroll, tk);
	
	gap = 2*tk->borderwidth;
	if(tks->orient == Tkvertical) {
		if(tk->req.width == 0)
			tk->req.width = Triangle + gap;
		if(tk->req.height == 0)	
			tk->req.height = 2*Triangle + gap + 6*Elembw;
	}
	else {
		if(tk->req.width == 0)
			tk->req.width = 2*Triangle + gap + 6*Elembw;
		if(tk->req.height == 0)	
			tk->req.height = Triangle + gap;
	}


	return tkbindings(tk->env->top, tk, b, nelem(b));
}

char*
tkscrollbar(TkTop *t, char *arg, char **ret)
{
	Tk *tk;
	char *e;
	TkName *names;
	TkScroll *tks;
	TkOptab tko[3];

	tk = tknewobj(t, TKscrollbar, sizeof(Tk)+sizeof(TkScroll));
	if(tk == nil)
		return TkNomem;

	tks = TKobj(TkScroll, tk);

	tk->relief = TKflat;
	tk->borderwidth = 1;
	tks->activer = TKraised;
	tks->orient = Tkvertical;

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = tks;
	tko[1].optab = opts;
	tko[2].ptr = nil;

	names = nil;
	e = tkparse(t, arg, tko, &names);
	if(e != nil) {
		tkfreeobj(tk);
		return e;
	}
	tksettransparent(tk, tkhasalpha(tk->env, TkCbackgnd));

	e = tkinitscroll(tk);
	if(e != nil) {
		tkfreeobj(tk);
		return e;
	}

	e = tkaddchild(t, tk, &names);
	tkfreename(names);
	if(e != nil) {
		tkfreeobj(tk);
		return e;
	}
	tk->name->link = nil;

	return tkvalue(ret, "%s", tk->name->name);
}

static char*
tkscrollcget(Tk *tk, char *arg, char **val)
{
	TkOptab tko[3];
	TkScroll *tks = TKobj(TkScroll, tk);

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = tks;
	tko[1].optab = opts;
	tko[2].ptr = nil;

	return tkgencget(tko, arg, val, tk->env->top);
}

void
tkfreescrlb(Tk *tk)
{
	TkScroll *tks = TKobj(TkScroll, tk);

	if(tks->cmd != nil)
		free(tks->cmd);
}

/*
 * Brutalism is 2D: the thumb is a flat filled rectangle, no bevel, no
 * arrows.  It sits on the flat trough (the toplevel background) and turns
 * accent while hovered or dragged.
 */
static void
drawslider(TkScroll *tks, Image *i, Rectangle r, TkEnv *e)
{
	int col;

	col = TkCdisablefgnd;			/* resting: a flat mid-grey thumb */
	if(tks->flag & (ActiveB1|ButtonB1))
		col = TkCselectbgnd;		/* hovered / dragged: accent */
	draw(i, r, tkgc(e, col), nil, ZP);
}

static void
tkvscroll(Tk *tk, TkScroll *tks, Image *i, Point size)
{
	TkEnv *e;
	Rectangle r;
	int bo, top, len, sl, sh;

	e = tk->env;
	bo = tk->borderwidth + Elembw;

	/* no arrows: the trough runs the full length of the bar */
	tks->a1 = bo;
	tks->a2 = size.y - bo;

	top = bo;
	len = size.y - 2*bo;
	if(len < 1)
		len = 1;

	sl = top + TKF2I(tks->top*len);			/* thumb top */
	sh = TKF2I((tks->bot - tks->top)*len);		/* thumb height */
	if(sh < Slidermin)
		sh = Slidermin;
	if(sl + sh > top + len)
		sl = top + len - sh;
	if(sl < top)
		sl = top;

	tks->t1 = sl - Elembw;
	tks->t2 = sl + sh + Elembw;

	r.min.x = tk->borderwidth;
	r.min.y = sl;
	r.max.x = size.x - tk->borderwidth;
	r.max.y = sl + sh;
	drawslider(tks, i, r, e);
}

static void
tkhscroll(Tk *tk, TkScroll *tks, Image *i, Point size)
{
	TkEnv *e;
	Rectangle r;
	int bo, left, len, sl, sw;

	e = tk->env;
	bo = tk->borderwidth + Elembw;

	tks->a1 = bo;
	tks->a2 = size.x - bo;

	left = bo;
	len = size.x - 2*bo;
	if(len < 1)
		len = 1;

	sl = left + TKF2I(tks->top*len);		/* thumb left */
	sw = TKF2I((tks->bot - tks->top)*len);		/* thumb width */
	if(sw < Slidermin)
		sw = Slidermin;
	if(sl + sw > left + len)
		sl = left + len - sw;
	if(sl < left)
		sl = left;

	tks->t1 = sl - Elembw;
	tks->t2 = sl + sw + Elembw;

	r.min.x = sl;
	r.min.y = tk->borderwidth;
	r.max.x = sl + sw;
	r.max.y = size.y - tk->borderwidth;
	drawslider(tks, i, r, e);
}

char*
tkdrawscrlb(Tk *tk, Point orig)
{
	Point p;
	TkEnv *e;
	Rectangle r;
	Image *i, *dst;
	TkScroll *tks = TKobj(TkScroll, tk);

	e = tk->env;

	dst = tkimageof(tk);
	if(dst == nil)
		return nil;

	r.min = ZP;
	r.max.x = tk->act.width + 2*tk->borderwidth;
	r.max.y = tk->act.height + 2*tk->borderwidth;

	i = tkitmp(e, r.max, TkCbackgnd);
	if(i == nil)
		return nil;

	if(tks->orient == Tkvertical)
		tkvscroll(tk, tks, i, r.max);
	else
		tkhscroll(tk, tks, i, r.max);

	tkdrawrelief(i, tk, ZP, TkCbackgnd, tk->relief);

	p.x = tk->act.x + orig.x;
	p.y = tk->act.y + orig.y;
	r = rectaddpt(r, p);
	draw(dst, r, i, nil, ZP);

	return nil;
}

/* Widget Commands (+ means implemented)	
	+activate
	+cget
	+configure
	+delta
	+fraction
	+get
	+identify
	+set
*/

static char*
tkscrollconf(Tk *tk, char *arg, char **val)
{
	char *e;
	TkGeom g;
	int bd;
	TkOptab tko[3];
	TkScroll *tks = TKobj(TkScroll, tk);

	tko[0].ptr = tk;
	tko[0].optab = tkgeneric;
	tko[1].ptr = tks;
	tko[1].optab = opts;
	tko[2].ptr = nil;

	if(*arg == '\0')
		return tkconflist(tko, val);

	g = tk->req;
	bd = tk->borderwidth;
	e = tkparse(tk->env->top, arg, tko, nil);
	tksettransparent(tk, tkhasalpha(tk->env, TkCbackgnd));
	tkgeomchg(tk, &g, bd);

	tk->dirty = tkrect(tk, 1);
	return e;
}

static char*
tkscrollactivate(Tk *tk, char *arg, char **val)
{
	int s, gotarg;
	char buf[Tkmaxitem];
	TkScroll *tks = TKobj(TkScroll, tk);

	USED(val);
	tkword(tk->env->top, arg, buf, buf+sizeof(buf), &gotarg);
	s = tks->flag;
	if (!gotarg) {
		char *a;
		if (s & ActiveA1)
			a = "arrow1";
		else if (s & ActiveA2)
			a = "arrow2";
		else if (s & ActiveB1)
			a = "slider";
		else
			a = "";
		return tkvalue(val, a);
	}
	tks->flag &= ~(ActiveA1 | ActiveA2 | ActiveB1);
	if(strcmp(buf, "arrow1") == 0)
		tks->flag |= ActiveA1;
	else
	if(strcmp(buf, "arrow2") == 0)
		tks->flag |= ActiveA2;
	else
	if(strcmp(buf, "slider") == 0)
		tks->flag |= ActiveB1;

	if(s ^ tks->flag)
		tk->dirty = tkrect(tk, 1);
	return nil;
}

static char*
tkscrollset(Tk *tk, char *arg, char **val)
{
	TkTop *t;
	char *e;
	TkScroll *tks = TKobj(TkScroll, tk);

	USED(val);
	t = tk->env->top;
	e = tkfracword(t, &arg, &tks->top, nil);
	if (e != nil)
		return e;
	e = tkfracword(t, &arg, &tks->bot, nil);
	if (e != nil)
		return e;
	if(tks->top < 0)
		tks->top = 0;
	if(tks->top > TKI2F(1))
		tks->top = TKI2F(1);
	if(tks->bot < 0)
		tks->bot = 0;
	if(tks->bot > TKI2F(1))
		tks->bot = TKI2F(1);

	tk->dirty = tkrect(tk, 1);
	return nil;
}

static char*
tkscrolldelta(Tk *tk, char *arg, char **val)
{
	int l, delta;
	char buf[Tkmaxitem];
	TkScroll *tks = TKobj(TkScroll, tk);

	arg = tkitem(buf, arg);
	if(tks->orient == Tkvertical)
		tkitem(buf, arg);
	if(*arg == '\0' || *buf == '\0')
		return TkBadvl;

	l = tks->a2-tks->a1-4*Elembw;
	delta = TKI2F(1);
	if(l != 0)
		delta = TKI2F(atoi(buf)) / l;
	tkfprint(buf, delta);

	return tkvalue(val, "%s", buf);	
}

static char*
tkscrollget(Tk *tk, char *arg, char **val)
{
	char *v, buf[Tkmaxitem];
	TkScroll *tks = TKobj(TkScroll, tk);

	USED(arg);
	v = tkfprint(buf, tks->top);
	*v++ = ' ';
	tkfprint(v, tks->bot);

	return tkvalue(val, "%s", buf);	
}

static char*
tkscrollidentify(Tk *tk, char *arg, char **val)
{
	int gotarg;
	TkTop *t;
	char *v, buf[Tkmaxitem];
	Point p;
	TkScroll *tks = TKobj(TkScroll, tk);

	t = tk->env->top;
	arg = tkword(t, arg, buf, buf+sizeof(buf), &gotarg);
	if (!gotarg)
		return TkBadvl;
	p.x = atoi(buf);
	tkword(t, arg, buf, buf+sizeof(buf), &gotarg);
	if (!gotarg)
		return TkBadvl;
	p.y = atoi(buf);
	if (!ptinrect(p, tkrect(tk, 0)))
		return nil;
	if (tks->orient == Tkvertical)
		p.x = p.y;
	p.x += tk->borderwidth;

	v = "";
	if(p.x <= tks->a1)
		v = "arrow1";
	if(p.x > tks->a1 && p.x <= tks->t1)
		v = "trough1";
	if(p.x > tks->t1 && p.x < tks->t2)
		v = "slider";
	if(p.x >= tks->t2 && p.x < tks->a2)
		v = "trough2";
	if(p.x >= tks->a2)
		v = "arrow2";
	return tkvalue(val, "%s", v);
}

static char*
tkscrollfraction(Tk *tk, char *arg, char **val)
{
	int len, frac, pos;
	char buf[Tkmaxitem];
	TkScroll *tks = TKobj(TkScroll, tk);

	arg = tkitem(buf, arg);
	if(tks->orient == Tkvertical)
		tkitem(buf, arg);
	if(*arg == '\0' || *buf == '\0')
		return TkBadvl;

	pos = atoi(buf);
	if(pos < tks->a1)
		pos = tks->a1;
	if(pos > tks->a2)
		pos = tks->a2;
	len = tks->a2 - tks->a1 - 4*Elembw;
	frac = TKI2F(1);
	if(len != 0)
		frac = TKI2F(pos-tks->a1)/len;
	tkfprint(buf, frac);
	return tkvalue(val, "%s", buf);
}

static char*
tkScrolBut1R(Tk *tk, char *arg, char **val)
{
	TkScroll *tks = TKobj(TkScroll, tk);

	USED(val);
	USED(arg);
	tkcancelrepeat(tk);
	tks->flag &= ~(ActiveA1|ActiveA2|ActiveB1|ButtonA1|ButtonA2|ButtonB1|Autorepeat);
	tk->dirty = tkrect(tk, 1);
	return nil;
}

/* tkScrolBut2P fraction */
static char*
tkScrolBut2P(Tk *tk, char *arg, char **val)
{
	TkTop *t;
	char *e, buf[Tkmaxitem], fracbuf[Tkmaxitem];
	TkScroll *tks = TKobj(TkScroll, tk);
	

	USED(val);
	t = tk->env->top;

	if(arg[0] == '\0')
		return TkBadvl;

	tkword(t, arg, fracbuf, fracbuf+sizeof(fracbuf), nil);

	e = nil;
	if(tks->cmd != nil) {
		snprint(buf, sizeof(buf), "%s moveto %s", tks->cmd, fracbuf);
		e = tkexec(t, buf, nil);
	}
	return e;
}

static void
sbrepeat(Tk *tk, void *v, int cancelled)
{
	char *e, buf[Tkmaxitem];
	TkScroll *tks = TKobj(TkScroll, tk);
	char *fmt = (char *)v;

	if (cancelled) {
		tks->flag &= ~Autorepeat;
		return;
	}
		
	if(tks->cmd != nil && fmt != nil) {
		snprint(buf, sizeof(buf), fmt, tks->cmd);
		e = tkexec(tk->env->top, buf, nil);
		if (e != nil) {
			tks->flag &= ~Autorepeat;
			tkcancelrepeat(tk);
		} else
			tkupdate(tk->env->top);
	}
}

/* tkScrolBut1P %x %y */
static char*
tkScrolBut1P(Tk *tk, char *arg, char **val)
{
	int pix;
	TkTop *t;
	char *e, *fmt, buf[Tkmaxitem];
	TkScroll *tks = TKobj(TkScroll, tk);

	USED(val);
	t = tk->env->top;

	if (tks->flag & Autorepeat)
		return nil;
	arg = tkword(t, arg, buf, buf+sizeof(buf), nil);
	if(tks->orient == Tkvertical)
		tkword(t, arg, buf, buf+sizeof(buf), nil);
	if(buf[0] == '\0')
		return TkBadvl;

	pix = atoi(buf);
	
	tks->dragpix = pix;
	tks->dragtop = tks->top;
	tks->dragbot = tks->bot;

	pix += tk->borderwidth;

	fmt = nil;
	e = nil;
	if(pix <= tks->a1) {
		fmt = "%s scroll -1 unit";
		tks->flag |= ButtonA1;
	}
	if(pix > tks->a1 && pix <= tks->t1)
		fmt = "%s scroll -1 page";
	if(pix > tks->t1 && pix < tks->t2)
		tks->flag |= ButtonB1;
	if(pix >= tks->t2 && pix < tks->a2)
		fmt = "%s scroll 1 page";
	if(pix >= tks->a2) {
		fmt = "%s scroll 1 unit";
		tks->flag |= ButtonA2;
	}
	if(tks->cmd != nil && fmt != nil) {
		snprint(buf, sizeof(buf), fmt, tks->cmd);
		e = tkexec(t, buf, nil);
		tks->flag |= Autorepeat;
		tkrepeat(tk, sbrepeat, fmt, TkRptpause, TkRptinterval);
	}
	tk->dirty = tkrect(tk, 1);
	return e;
}

/* tkScrolDrag %x %y */
static char*
tkScrollDrag(Tk *tk, char *arg, char **val)
{
	TkTop *t;
	int pix, delta;
	char frac[32], buf[Tkmaxitem];
	TkScroll *tks = TKobj(TkScroll, tk);

	USED(val);
	t = tk->env->top;

	if (tks->flag & Autorepeat)
		return nil;
	if((tks->flag & ButtonB1) == 0)
		return nil;

	arg = tkword(t, arg, buf, buf+sizeof(buf), nil);
	if(tks->orient == Tkvertical)
		tkword(t, arg, buf, buf+sizeof(buf), nil);
	if(buf[0] == '\0')
		return TkBadvl;

	pix = atoi(buf);

	delta = TKI2F(pix-tks->dragpix);
	if ( tks->a2 == tks->a1 )
		return TkBadvl;
	delta = delta/(tks->a2-tks->a1-4*Elembw);
	if(tks->jump == BoolT) {
		if(tks->dragtop+delta >= 0 &&
		   tks->dragbot+delta <= TKI2F(1)) {
			tks->top = tks->dragtop+delta;
			tks->bot = tks->dragbot+delta;
		}
		return nil;
	}
	if(tks->cmd != nil) {
		delta += tks->dragtop;
		if(delta < 0)
			delta = 0;
		if(delta > TKI2F(1))
			delta = TKI2F(1);
		tkfprint(frac, delta);
		snprint(buf, sizeof(buf), "%s moveto %s", tks->cmd, frac);
		return tkexec(t, buf, nil);
	}
	return nil;
}

TkCmdtab tkscrlbcmd[] =
{
	"activate",		tkscrollactivate,
	"cget",			tkscrollcget,
	"configure",		tkscrollconf,
	"delta",		tkscrolldelta,
	"fraction",		tkscrollfraction,
	"get",			tkscrollget,
	"identify",		tkscrollidentify,
	"set",			tkscrollset,
	"tkScrollDrag",		tkScrollDrag,
	"tkScrolBut1P",		tkScrolBut1P,
	"tkScrolBut1R",		tkScrolBut1R,
	"tkScrolBut2P",		tkScrolBut2P,
	nil
};

TkMethod scrollbarmethod = {
	"scrollbar",
	tkscrlbcmd,
	tkfreescrlb,
	tkdrawscrlb
};
