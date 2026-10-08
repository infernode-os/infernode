implement XenithFrameTest;

#
# Xenith's frame: the tests are in tests/xenith_framesuite.b, which is
# the frame's Graph (its drawing) as well as the suite, and so has to
# implement Graph alone; see the comment at its top. This is the
# command the test runner finds: it loads the suite and runs it.
#

include "sys.m";
	sys: Sys;

include "draw.m";

# Xenith's module interfaces, as appl/xenith/common.m includes them,
# so that Graph's init matches the suite's
include "bufio.m";
include "plumbmsg.m";
include "workdir.m";
include "styx.m";
include "../appl/xenith/xenith.m";
include "../appl/xenith/dat.m";
include "../appl/xenith/gui.m";
include "../appl/xenith/graph.m";
include "../appl/xenith/frame.m";
include "../appl/xenith/util.m";
include "../appl/xenith/regx.m";
include "../appl/xenith/text.m";
include "../appl/xenith/file.m";
include "../appl/xenith/wind.m";
include "../appl/xenith/row.m";
include "../appl/xenith/col.m";
include "../appl/xenith/buff.m";
include "../appl/xenith/disk.m";
include "../appl/xenith/xfid.m";
include "../appl/xenith/exec.m";
include "../appl/xenith/look.m";
include "../appl/xenith/time.m";
include "../appl/xenith/scrl.m";
include "../appl/xenith/fsys.m";
include "../appl/xenith/edit.m";
include "../appl/xenith/elog.m";
include "../appl/xenith/ecmd.m";
include "../appl/xenith/styxaux.m";
include "../appl/xenith/imgload.m";
include "renderer.m";
include "../appl/xenith/render.m";
include "formatter.m";
include "../appl/xenith/format.m";
include "../appl/xenith/asyncio.m";

XenithFrameTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	suite := load Graph "/tests/xenith_framesuite.dis";
	if(suite == nil)
		suite = load Graph "/dis/tests/xenith_framesuite.dis";
	if(suite == nil){
		sys->fprint(sys->fildes(2), "xenith_frame_test: cannot load the suite: %r\n");
		raise "fail:cannot load tests/xenith_framesuite.dis";
	}
	suite->init(nil);
}
