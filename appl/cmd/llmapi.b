implement Llmapi;

#
# llmapi [-ns] [-b anthropic|openai] [-u url] [-m model] [-t maxtokens] [system]
# - put the text on standard input to a model's API, with the
# instructions in the file system, and print its answer.  No service
# runs: the call is made from here.  The key is factotum's
# (proto=pass service=anthropic, or service=openai), or failing that
# $ANTHROPIC_API_KEY or $OPENAI_API_KEY; an OpenAI-compatible server
# on this machine (-u http://localhost:11434/v1) needs none.  With -n,
# only the model's name is printed; with -s, only the settings the call
# is made with, as attr=value words (temperature=default maxtokens=8192
# thinking=off), for a record of it.  ask(1) is what tools call; it
# calls this when $llm names an API.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "factotum.m";
	factotum: Factotum;
include "llmclient.m";
	llmclient: Llmclient;
	AskRequest: import llmclient;

Llmapi: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Defanthropic: con "claude-sonnet-5-5";
Maxtokens: con 8192;

stderr: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	if(arg == nil || bufio == nil)
		fail(sys->sprint("cannot load: %r"));
	arg->init(args);
	arg->setusage("llmapi [-ns] [-b anthropic|openai] [-u url] [-m model] [-t maxtokens] [system]");
	backend := "anthropic";
	url := "";
	model := "";
	nameonly := 0;
	settings := 0;
	maxtokens := Maxtokens;
	while((o := arg->opt()) != 0)
		case o {
		'b' =>	backend = arg->earg();
		'u' =>	url = arg->earg();
		'm' =>	model = arg->earg();
		't' =>	maxtokens = int arg->earg();
		'n' =>	nameonly = 1;
		's' =>	settings = 1;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args > 1 || (backend != "anthropic" && backend != "openai"))
		arg->usage();
	if(backend == "openai" && url == "")
		fail("an OpenAI-compatible API needs its address: -u http://host:port/v1");
	if(model == "" && backend == "anthropic")
		model = Defanthropic;
	# what the request below is made with: the provider's own
	# temperature, no thinking
	if(settings) {
		sys->print("temperature=default maxtokens=%d thinking=off\n", maxtokens);
		return;
	}
	key := factotumkey(backend);
	if(key == "" && backend == "anthropic")
		key = env("ANTHROPIC_API_KEY");
	else if(key == "")
		key = env("OPENAI_API_KEY");
	if(key == "" && backend == "anthropic")
		fail("no key: add one to factotum (proto=pass service=anthropic !password=...), set ANTHROPIC_API_KEY, or set llm");
	if(nameonly) {
		if(model == "")
			model = "the default model at " + url;
		sys->print("%s\n", model);
		return;
	}
	system := "";
	if(args != nil) {
		system = readfile(hd args);
		if(system == nil)
			fail(sys->sprint("cannot read %s: %r", hd args));
	}
	prompt := readall(sys->fildes(0));
	if(prompt == "")
		fail("nothing to ask: the question is read from standard input");

	llmclient = load Llmclient Llmclient->PATH;
	if(llmclient == nil)
		fail(sys->sprint("cannot load %s: %r", Llmclient->PATH));
	llmclient->init();
	req := ref AskRequest(nil, prompt, model, -1.0, maxtokens, system,
		0, "", "", nil, nil, nil);
	resp: ref Llmclient->AskResponse;
	err: string;
	if(backend == "openai")
		(resp, err) = llmclient->askopenai(url, key, req);
	else
		(resp, err) = llmclient->askanthropic(key, url, req);
	if(err != nil)
		fail(err);
	text := llmclient->extracttextcontent(resp.response);
	if(text != "" && text[len text - 1] != '\n')
		text += "\n";
	b := array of byte text;
	if(sys->write(sys->fildes(1), b, len b) != len b)
		fail(sys->sprint("write: %r"));
}

factotumkey(backend: string): string
{
	(ok, nil) := sys->stat("/mnt/factotum/rpc");
	if(ok < 0)
		return "";
	factotum = load Factotum Factotum->PATH;
	if(factotum == nil)
		return "";
	factotum->init();
	(nil, password) := factotum->getuserpasswd("proto=pass service=" + backend);
	if(password == nil)
		sys->fprint(stderr, "llmapi: factotum: %r\n");
	return password;
}

env(name: string): string
{
	s := readfile("/env/" + name);
	while(s != "" && (s[len s - 1] == '\n' || s[len s - 1] == 0 || s[len s - 1] == ' '))
		s = s[0:len s - 1];
	return s;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	return readall(fd);
}

readall(fd: ref Sys->FD): string
{
	io := bufio->fopen(fd, Bufio->OREAD);
	if(io == nil)
		return "";
	s := "";
	while((c := io.getc()) >= 0)
		s[len s] = c;
	return s;
}

fail(s: string)
{
	sys->fprint(stderr, "llmapi: %s\n", s);
	raise "fail:" + s;
}
