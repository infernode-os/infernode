implement Dat;

include "common.m";

sys : Sys;
xenith : Xenith;
utils : Utils;

# lc, uc : chan of ref Lock;

init(mods : ref Dat->Mods)
{
	sys = mods.sys;
	xenith = mods.xenith;
	utils = mods.utils;

	Scrollwid = 12;
	Scrollgap = 4;
	Border = 2;
	Mincolwid = 80;
	mouse = ref Draw->Pointer;
	mouse.buttons = mouse.msec = 0;
	mouse.xy = (0, 0);
	# lc = chan of ref Lock;
	# uc = chan of ref Lock;
	# spawn lockmgr();
}

# lockmgr()
# {
# 	l : ref Lock;
# 
# 	xenith->lockpid = sys->pctl(0, nil);
# 	for (;;) {
# 		alt {
# 			l = <- lc =>
# 				if (l.cnt++ == 0)
# 					l.chann <-= 1;
# 			l = <- uc =>
# 				if (--l.cnt > 0)
# 					l.chann <-= 1;
# 		}
# 	}
# }

Lock.init() : ref Lock
{
	return ref Lock(0, chan[1] of int);
	# return ref Lock(0, chan of int);
}

Lock.lock(l : self ref Lock)
{
	l.cnt++;
	l.chann <-= 0;
	# lc <-= l;
	# <- l.chann;
}

Lock.unlock(l : self ref Lock)
{
	<-l.chann;
	l.cnt--;
	# uc <-= l;
}

Lock.locked(l : self ref Lock) : int
{
	return l.cnt > 0;
}

Ref.init() : ref Ref
{
	r := ref Ref;
	r.l = Lock.init();
	r.cnt = 0;
	return r;
}

Ref.inc(r : self ref Ref) : int
{
	r.l.lock();
	i := r.cnt;
	r.cnt++;
	r.l.unlock();
	return i;
}

Ref.dec(r : self ref Ref) : int
{
	r.l.lock();
	r.cnt--;
	i := r.cnt;
	r.l.unlock();
	return i;
}

Ref.refx(r : self ref Ref) : int
{
	return r.cnt;
}

Reffont.get(p, q, r : int, b : string) : ref Reffont
{
	return xenith->get(p, q, r, b);
}

Reffont.close(r : self ref Reffont)
{
	return xenith->close(r);
}