implement ExecReapSleeper;

# Fixture for tests/host/exec_reap_test.sh: a command that outlives the exec
# tool's deadline without leaving its process group.

include "sys.m";
	sys: Sys;
include "draw.m";

ExecReapSleeper: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	sys->sleep(60 * 1000);
}
