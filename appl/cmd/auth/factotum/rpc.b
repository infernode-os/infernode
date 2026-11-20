implement Rpcio;

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "arg.m";

Rpcio: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

usage()
{
	sys->fprint(sys->fildes(2), "usage: rpc\n");
	raise "fail:usage";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		cantload(Bufio->PATH);

	file := "/mnt/factotum/rpc";
	if(len args > 1)
		file = hd tl args;
	rfd := sys->open(file, Sys->ORDWR);
	if(rfd == nil){
		sys->fprint(sys->fildes(2), "rpc: can't open %s: %r\n", file);
		raise "fail:load";
	}
	f := bufio->fopen(sys->fildes(0), Sys->OREAD);
	for(;;){
		sys->print("> ");
		s := f.gets('\n');
		if(s == nil)
			break;
		# a last line with no newline lost its last character
		if(s[len s-1] == '\n')
			s = s[0:len s-1];
		# nothing to send: an empty write printed whatever error
		# string was left from before
		if(s == nil)
			continue;
		rpc(rfd, s);
	}
}

cantload(s: string)
{
	sys->fprint(sys->fildes(2), "csquery: can't load %s: %r\n", s);
	raise "fail:load";
}

rpc(f: ref Sys->FD, addr: string)
{
	b := array of byte addr;
	if(sys->write(f, b, len b) > 0){
		sys->seek(f, big 0, Sys->SEEKSTART);
		buf := array[4096+3] of byte;
		if((n := sys->read(f, buf, len buf)) > 0)
			sys->print("%s\n", string buf[0:n]);
		# factotum cuts a reply of text to the reader's buffer
		# without a word: say that this one may not be whole
		if(n == len buf)
			sys->print("!reply filled the %d bytes read: it may be cut short\n", len buf);
		if(n >= 0)
			return;
	}
	sys->print("!%r\n");
}
