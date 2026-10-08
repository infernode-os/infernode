implement Titlebar;
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Point, Rect: import draw;
include "tk.m";
	tk: Tk;
include "titlebar.m";

# There is no title bar.  The window's frame is tkclient's: a solid
# border in the theme's windowborder (wmlib->Border wide), whose presses
# tkclient turns into the "size" and "move" requests sent on this
# module's channel.  What is left here is that channel and the title,
# kept in an unpacked .Wm_t.title (task lists ask for it, and some apps
# configure .Wm_t).
title_cfg := array[] of {
	"frame .Wm_t",
	"label .Wm_t.title -anchor w",
};

init()
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
}

new(top: ref Tk->Toplevel, buts: int): chan of string
{
	ctl := chan of string;
	tk->namechan(top, ctl, "wm_title");

	if(buts & Plain)
		return ctl;

	for(i := 0; i < len title_cfg; i++)
		cmd(top, title_cfg[i]);

	return ctl;
}

title(top: ref Tk->Toplevel): string
{
	if(tk->cmd(top, "winfo class .Wm_t.title")[0] != '!')
		return cmd(top, ".Wm_t.title cget -text");
	return nil;
}
	
settitle(top: ref Tk->Toplevel, t: string): string
{
	s := title(top);
	tk->cmd(top, ".Wm_t.title configure -text '" + t);
	return s;
}

sendctl(top: ref Tk->Toplevel, c: string)
{
	cmd(top, "send wm_title " + c);
}

minsize(top: ref Tk->Toplevel): Point
{
	r := tk->rect(top, ".", Tk->Border);
	r.min.x = r.max.x;
	r.max.y = r.min.y;
	return r.size();
}

cmd(top: ref Tk->Toplevel, s: string): string
{
	e := tk->cmd(top, s);
	if (e != nil && e[0] == '!')
		sys->fprint(sys->fildes(2), "wmclient: tk error %s on '%s'\n", e, s);
	return e;
}
