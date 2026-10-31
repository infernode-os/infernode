implement Themefs;

#
# themefs - serve the theme's current and event (lucitheme(2)'s serve)
# in this name space, so a write of /lib/lucifer/theme/current reaches
# every program watching it.  The profile runs it once a session.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "lucitheme.m";

Themefs: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme == nil) {
		sys->fprint(sys->fildes(2), "themefs: cannot load %s: %r\n", Lucitheme->PATH);
		raise "fail:load";
	}
	if((err := lucitheme->serve()) != nil) {
		sys->fprint(sys->fildes(2), "themefs: %s\n", err);
		raise "fail:serve";
	}
}
