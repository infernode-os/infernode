implement QualificationProbe;

include "sys.m";
	sys: Sys;

include "draw.m";

QualificationProbe: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	sys->print("INFR434_PROBE_OK\n");
}
