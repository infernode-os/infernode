implement Llmsrv;

#
# llmsrv - LLM Filesystem Service
#
# Plan 9-style Styx server exposing LLM access as a filesystem
# with clone-based multiplexing for concurrent sessions.
#
# Filesystem layout:
#   /mnt/llm/
#       new              read: allocates session N, returns "N\n"
#       N/               per-session directory
#           ask          rw: write prompt, read response (blocks until done)
#           stream       r:  blocking reads return chunks during generation
#           model        rw: model name (aliases: haiku/sonnet/opus)
#           temperature  rw: float 0.0-2.0
#           system       rw: system prompt
#           thinking     rw: "disabled" / "max" / integer
#           prefill      rw: assistant response prefill
#           tools        w:  write JSON tool definitions
#           context      r:  JSON conversation history
#           compact      rw: write to trigger compaction
#           ctl          w:  "reset" or "close"
#           usage        r:  "estimated_tokens/context_limit\n"
#
# Usage:
#   llmsrv                                    # mount at /mnt/llm (Anthropic API)
#   llmsrv -b openai -u http://host:11434/v1  # Ollama backend
#   llmsrv -m /mnt/llm                        # custom mount point
#   llmsrv -D                                 # debug tracing
#
# Example session:
#   id=`{cat /mnt/llm/new}
#   echo 'What is 2+2?' > /mnt/llm/$id/ask
#   cat /mnt/llm/$id/ask
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;

include "draw.m";

include "arg.m";

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

include "styxservers.m";
	styxservers: Styxservers;
	Fid, Styxserver, Navigator, Navop: import styxservers;
	Enotfound, Eperm, Ebadarg: import styxservers;

include "string.m";
	str: String;

include "json.m";
	json: JSON;
	JValue: import json;

include "bufio.m";
	bufio: Bufio;

include "factotum.m";
	factotum: Factotum;

include "llmclient.m";
	llmclient: Llmclient;
	LlmMessage, ToolDef, ToolResult, AskRequest, AskResponse: import llmclient;

Llmsrv: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
};

# File types (low byte of qid path)
Qroot:    con 0;
Qnew:     con 1;
# Per-session files start at 16
Qsessdir: con 16;
Qask:     con 17;
Qstream:  con 18;
Qmodel:   con 19;
Qtemp:    con 20;
Qsystem:  con 21;
Qthinking:con 22;
Qprefill: con 23;
Qtools:   con 24;
Qcontext: con 25;
Qcompact: con 26;
Qctl:     con 27;
Qusage:   con 28;
Qmaxtokens: con 29;
Qreasoning: con 30;  # per-session reasoning_effort override:
                     # ""|"low"|"medium"|"high". Defaults to the
                     # daemon-wide value set via -r at launch.
                     # Per-session override exists because models
                     # like devstral don't support reasoning_effort
                     # and Ollama 500s if it's set; a session that
                     # overrides its model to a non-reasoning model
                     # must also clear reasoning. (See
                     # /tool/limbo flow for canonical use.)
Qmodels:  con 31;    # top-level, read-only — backend's available models

NSESSFILES: con 13;  # number of files per session dir

# Session state
LlmSession: adt {
	id:             int;
	name:           string;  # unguessable capability token (INFR-321). The
	                         # session's directory name in the namespace is
	                         # this token, returned to its creator by reading
	                         # /new. Root readdir does not list sessions and
	                         # walk resolves only by exact token match, so a
	                         # client cannot enumerate or guess another
	                         # client's session. The numeric id stays the
	                         # internal array/QID key only.
	messages:       list of ref LlmMessage;
	lastresponse:   string;
	totaltokens:    int;

	# Per-session settings
	model:          string;
	temperature:    real;
	maxtokens:      int;     # generation cap; 0 = backend default
	systemprompt:   string;
	thinkingtokens: int;
	reasoningeffort: string; # "" | "low" | "medium" | "high"
	prefill:        string;
	tools:          list of ref ToolDef;
	autocompact:    int;     # auto-compact high-water mark in estimated
	                         # tokens; 0 = disabled (client owns its own
	                         # compaction policy). Defaults to the daemon
	                         # -c value. See rungeneration (INFR-223).

	# Streaming state
	streamch:       chan of string;  # nil when idle
	donech:         chan of int;     # signaled when gen completes
	genactive:      int;            # 1 during generation
	pendingwrite:   array of byte;   # /ask prompt reassembled across write-fragments,
	                                 # consumed (-> generation) on the next read

	# Session lifecycle
	closed:         int;
	refs:           int;
};

stderr: ref Sys->FD;
user: string;
vers: int;

# Session pool
sessions: array of ref LlmSession;
nsessions: int;
nextsid: int;

MAXSESSIONS: con 128;
MAXPROMPT: con 1048576;
MAXSYSTEM: con 262144;
MAXTOOLS: con 1048576;
MAXPREFILL: con 65536;
MAXSETTING: con 4096;

# Backend configuration
backend: string;      # "api" or "openai"
apikey: string;
apiurl: string;       # Anthropic: hostname; OpenAI: base URL
defaultmodel: string;
autocompactdefault: int;   # default session auto-compact high-water mark
                           # (estimated tokens); -c flag, 0 = disabled.
defaultreasoning: string;  # ""|"low"|"medium"|"high" — set via -r flag at
                           # daemon launch. Threaded into AskRequest so
                           # gpt-oss-style reasoning models default to a
                           # sensible effort. InferNode MODEL-EVAL recommends
                           # "low" for tool-driven scenarios (~15× faster than
                           # default medium with no quality loss on dispatch).

# Completion notification for async ask reads
# When ask read arrives during generation, we spawn a goroutine
# that waits on donech then replies.

usage()
{
	sys->fprint(stderr, "Usage: llmsrv [-D] [-m mountpt] [-b api|openai] [-u url] [-M model] [-r low|medium|high] [-c autocompact-tokens]\n");
	raise "fail:usage";
}

nomod(s: string)
{
	sys->fprint(stderr, "llmsrv: can't load %s: %r\n", s);
	raise "fail:load";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	sys->pctl(Sys->FORKFD|Sys->NEWPGRP, nil);
	stderr = sys->fildes(2);

	styx = load Styx Styx->PATH;
	if(styx == nil) nomod(Styx->PATH);
	styx->init();

	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil) nomod(Styxservers->PATH);
	styxservers->init(styx);

	str = load String String->PATH;
	if(str == nil) nomod(String->PATH);

	bufio = load Bufio Bufio->PATH;
	if(bufio == nil) nomod(Bufio->PATH);

	json = load JSON JSON->PATH;
	if(json == nil) nomod(JSON->PATH);
	json->init(bufio);

	llmclient = load Llmclient Llmclient->PATH;
	if(llmclient == nil) nomod(Llmclient->PATH);
	llmclient->init();

	factotum = load Factotum Factotum->PATH;
	if(factotum != nil)
		factotum->init();

	arg := load Arg Arg->PATH;
	if(arg == nil) nomod(Arg->PATH);
	arg->init(args);

	mountpt := "/mnt/llm";
	backend = "api";
	apiurl = "";
	apikey = "";
	defaultmodel = "claude-sonnet-4-5-20250929";
	defaultreasoning = "";
	autocompactdefault = DEFAULTAUTOCOMPACT;

	while((o := arg->opt()) != 0)
		case o {
		'D' => styxservers->traceset(1);
		'm' => mountpt = arg->earg();
		'b' => backend = arg->earg();
		'u' => apiurl = arg->earg();
		'M' => defaultmodel = arg->earg();
		'r' => defaultreasoning = arg->earg();
		'c' => autocompactdefault = strtoint(arg->earg());
		* =>   usage();
		}
	if(autocompactdefault < 0)
		autocompactdefault = 0;
	arg = nil;

	# Factotum is preferred. Environment fallback supports direct headless
	# daemon startup where no interactive factotum/secstore unlock is possible;
	# agent namespaces never inherit these environment variables.
	if(apikey == "" && backend == "api") {
		apikey = getfactotumkey("anthropic");
		if(apikey == "")
			apikey = readenv("ANTHROPIC_API_KEY");
		if(apikey == "") {
			sys->fprint(stderr, "llmsrv: no API key in factotum or ANTHROPIC_API_KEY\n");
			raise "fail:apikey";
		}
	}
	if(apikey == "" && backend == "openai") {
		apikey = getfactotumkey("openai");
		if(apikey == "")
			apikey = readenv("OPENAI_API_KEY");
	}

	# Initialize pools
	sessions = array[16] of ref LlmSession;
	nsessions = 0;
	nextsid = 0;
	vers = 0;

	sys->pctl(Sys->FORKFD, nil);

	user = rf("/dev/user");
	if(user == nil)
		user = "inferno";

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0) {
		sys->fprint(stderr, "llmsrv: can't create pipe: %r\n");
		raise "fail:pipe";
	}

	navops := chan of ref Navop;
	spawn navigator(navops);

	(tchan, srv) := Styxserver.new(fds[0], Navigator.new(navops), big Qroot);
	srv.msize = 65536 + Styx->IOHDRSZ;
	fds[0] = nil;

	pidc := chan of int;
	spawn serveloop(tchan, srv, pidc, navops);
	<-pidc;

	ensuredir(mountpt);

	if(sys->mount(fds[1], nil, mountpt, Sys->MREPL|Sys->MCREATE, nil) < 0) {
		sys->fprint(stderr, "llmsrv: mount failed: %r\n");
		raise "fail:mount";
	}
}

# --- QID encoding ---

MKPATH(id, filetype: int): big
{
	return big ((id << 8) | filetype);
}

SESSID(path: big): int
{
	return (int path >> 8) & 16rFFFFFF;
}

FTYPE(path: big): int
{
	return int path & 16rFF;
}

# --- Session management ---

# Generate an unguessable 128-bit capability token (32 hex chars) from the
# kernel CSPRNG. Returns nil if /dev/random is unavailable, in which case we
# refuse to mint a session rather than fall back to a guessable name (INFR-321).
gentoken(): string
{
	fd := sys->open("/dev/random", Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[16] of byte;
	if(sys->readn(fd, buf, len buf) != len buf)
		return nil;
	tok := "";
	for(i := 0; i < len buf; i++)
		tok += sys->sprint("%.2x", int buf[i]);
	return tok;
}

findsessionbyname(name: string): ref LlmSession
{
	if(name == "")
		return nil;
	for(i := 0; i < nsessions; i++)
		if(sessions[i].name == name)
			return sessions[i];
	return nil;
}

newsession(): ref LlmSession
{
	if(nsessions >= MAXSESSIONS)
		return nil;
	tok := gentoken();
	if(tok == nil)
		return nil;
	id := nextsid++;
	s := ref LlmSession(
		id,
		tok,           # name: capability token
		nil,           # messages
		"",            # lastresponse
		0,             # totaltokens
		defaultmodel,  # model
		0.7,           # temperature
		1024,          # maxtokens (per-session; previously hardcoded 4096
		               # in llmclient.b, now overridable via /mnt/llm/$id/maxtokens)
		"",            # systemprompt
		0,             # thinkingtokens
		defaultreasoning, # reasoningeffort — daemon default; per-session
		                  # writable via /mnt/llm/$id/reasoning. Sessions
		                  # that override model to a non-reasoning model
		                  # MUST also clear this or Ollama 500s.
		"",            # prefill
		nil,           # tools
		autocompactdefault, # autocompact high-water mark (daemon -c default)
		nil,           # streamch
		nil,           # donech
		0,             # genactive
		nil,           # pendingwrite
		0,             # closed
		1              # refs (starts at 1)
	);

	if(nsessions >= len sessions) {
		ns := array[len sessions * 2] of ref LlmSession;
		ns[0:] = sessions[0:nsessions];
		sessions = ns;
	}
	sessions[nsessions++] = s;
	vers++;
	return s;
}

findsession(id: int): ref LlmSession
{
	for(i := 0; i < nsessions; i++)
		if(sessions[i].id == id)
			return sessions[i];
	return nil;
}

freesession(id: int)
{
	for(i := 0; i < nsessions; i++) {
		if(sessions[i].id == id) {
			sessions[i:] = sessions[i+1:nsessions];
			nsessions--;
			sessions[nsessions] = nil;
			vers++;
			return;
		}
	}
}

resetsession(sess: ref LlmSession)
{
	sess.messages = nil;
	sess.lastresponse = "";
	sess.totaltokens = 0;
}

closesession(sess: ref LlmSession)
{
	sess.closed = 1;
	freesession(sess.id);
}

# --- Model aliases ---

resolvemodel(name: string): string
{
	lname := str->tolower(name);
	case lname {
	"haiku" =>  return "claude-haiku-4-5-20251001";
	"sonnet" => return "claude-sonnet-4-5-20250929";
	"opus" =>   return "claude-opus-4-5-20251101";
	}
	return name;
}

# --- Token estimation ---

estimatedtokens(sess: ref LlmSession): int
{
	total := 0;
	for(ml := sess.messages; ml != nil; ml = tl ml) {
		m := hd ml;
		total += len m.content / 4;
	}
	return total;
}

CONTEXTLIMIT: con 200000;

# Default auto-compact high-water mark (estimated tokens) for new sessions,
# overridable per-daemon with -c and per-session via `ctl autocompact <n>`.
# 150000 ≈ 75% of CONTEXTLIMIT, matching veltro's COMPACT_THRESHOLD. This is
# a server-side safety net (INFR-223) so long-lived clients that don't drive
# /compact themselves (nerva, repl, sub-agents) can't grow context unbounded.
# Clients that own their own compaction policy set the session value to 0.
DEFAULTAUTOCOMPACT: con 150000;

# --- Backend call ---

callbackend(req: ref AskRequest): (ref AskResponse, string)
{
	if(backend == "openai")
		return llmclient->askopenai(apiurl, apikey, req);
	return llmclient->askanthropic(apikey, apiurl, req);
}

# Top-level /mnt/llm/models read: the backend's available models, one id
# per line. OpenAI backends are queried live (GET /v1/models); the
# Anthropic backend has no models endpoint, so report the known aliases.
availablemodels(): (string, string)
{
	if(backend == "openai")
		return llmclient->listmodels(apiurl, apikey);
	return ("claude-opus-4-5-20251101\nclaude-sonnet-4-5-20250929\nclaude-haiku-4-5-20251001\n", nil);
}

# --- Error classification ---

iscontentfiltererror(err: string): int
{
	return hasprefix(err, "content filtering") || contains(err, "content filtering policy");
}

istooluseerror(err: string): int
{
	return contains(err, "tool_use") && contains(err, "tool_result");
}

# --- Serve loop ---

serveloop(tchan: chan of ref Tmsg, srv: ref Styxserver,
	pidc: chan of int, navops: chan of ref Navop)
{
	pidc <-= sys->pctl(Sys->FORKNS|Sys->NEWFD, 1::2::srv.fd.fd::nil);

Serve:
	while((gm := <-tchan) != nil) {
		pick m := gm {
		Readerror =>
			sys->fprint(stderr, "llmsrv: fatal read error: %s\n", m.error);
			break Serve;

		Open =>
			c := srv.getfid(m.fid);
			if(c == nil) {
				srv.open(m);
				break;
			}

			mode := styxservers->openmode(m.mode);
			if(mode < 0) {
				srv.reply(ref Rmsg.Error(m.tag, Ebadarg));
				break;
			}

			qid := Qid(c.path, 0, c.qtype);
			c.open(mode, qid);
			c.data = nil;	# fresh write-reassembly buffer for this open
			srv.reply(ref Rmsg.Open(m.tag, qid, srv.iounit()));

		Read =>
			(c, err) := srv.canread(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}

			if(c.qtype & Sys->QTDIR) {
				srv.read(m);
				break;
			}

			ft := FTYPE(c.path);
			sid := SESSID(c.path);

			case ft {
			Qnew =>
				sess := newsession();
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, "cannot allocate session"));
					break;
				}
				# Return the capability token, not the numeric id: it is the
				# only handle by which the creator can reach this session.
				data := array of byte (sess.name + "\n");
				srv.reply(styxservers->readbytes(m, data));

			Qmodels =>
				(mtext, merr) := availablemodels();
				if(merr != nil) {
					srv.reply(ref Rmsg.Error(m.tag, merr));
					break;
				}
				srv.reply(styxservers->readbytes(m, array of byte mtext));

			Qask =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				# Write->read transition: a fully-written prompt is pending
				# -> finalize it and start generation here (the /ask fid is a
				# persistent ORDWR fd, never clunked between turns).
				triggerpending(sess);
				if(sess.genactive) {
					# Block until generation completes, then reply
					spawn asyncaskread(srv, m, sess);
				} else {
					content := sess.lastresponse;
					if(content != "" && content[len content - 1] != '\n')
						content += "\n";
					srv.reply(styxservers->readbytes(m, array of byte content));
				}

			Qstream =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				# Same write->read transition trigger as Qask, so the
				# streaming interface (write /ask, read /stream) still works.
				triggerpending(sess);
				# Spawn async reader that blocks on stream channel
				spawn asyncstreamread(srv, m, sess);

			Qmodel =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				srv.reply(styxservers->readbytes(m, array of byte (sess.model + "\n")));

			Qtemp =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				srv.reply(styxservers->readbytes(m, array of byte sys->sprint("%.2f\n", sess.temperature)));

			Qsystem =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				content := sess.systemprompt;
				if(content != "" && content[len content - 1] != '\n')
					content += "\n";
				srv.reply(styxservers->readbytes(m, array of byte content));

			Qthinking =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				content: string;
				if(sess.thinkingtokens < 0)
					content = "max\n";
				else if(sess.thinkingtokens == 0)
					content = "disabled\n";
				else
					content = string sess.thinkingtokens + "\n";
				srv.reply(styxservers->readbytes(m, array of byte content));

			Qprefill =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				content := sess.prefill;
				if(content != "" && content[len content - 1] != '\n')
					content += "\n";
				srv.reply(styxservers->readbytes(m, array of byte content));

			Qcontext =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				content := llmclient->messagesjson(sess.messages) + "\n";
				srv.reply(styxservers->readbytes(m, array of byte content));

			Qcompact =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				srv.reply(styxservers->readbytes(m, array of byte "write to compact conversation\n"));

			Qctl =>
				# Write-only file
				srv.reply(styxservers->readbytes(m, nil));

			Qusage =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				estimated := estimatedtokens(sess);
				content := sys->sprint("%d/%d\n", estimated, CONTEXTLIMIT);
				srv.reply(styxservers->readbytes(m, array of byte content));

			Qmaxtokens =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				srv.reply(styxservers->readbytes(m, array of byte sys->sprint("%d\n", sess.maxtokens)));

			Qreasoning =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				val := sess.reasoningeffort;
				if(val == "")
					val = "(default)";
				srv.reply(styxservers->readbytes(m, array of byte (val + "\n")));

			Qtools =>
				# Write-only
				srv.reply(styxservers->readbytes(m, nil));

			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			}

		Write =>
			(c, merr) := srv.canwrite(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, merr));
				break;
			}

			ft := FTYPE(c.path);
			sid := SESSID(c.path);

			case ft {
			Qask =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				if(sess.closed) {
					srv.reply(ref Rmsg.Error(m.tag, Eperm));
					break;
				}
				# Accumulate the prompt across mnt write-fragments. The mnt
				# device splits one client write() into multiple <=iounit
				# Twrites; generation is deferred to the following read so the
				# whole prompt is assembled first (see triggerpending).
				(nb, aerr) := appendbyteslimit(sess.pendingwrite, m.data, MAXPROMPT);
				if(aerr != nil) {
					sess.pendingwrite = nil;
					srv.reply(ref Rmsg.Error(m.tag, aerr));
					break;
				}
				sess.pendingwrite = nb;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));

			Qmodel =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				if(len m.data > MAXSETTING) {
					srv.reply(ref Rmsg.Error(m.tag, "model setting too large"));
					break;
				}
				model := resolvemodel(strip(string m.data));
				if(model != "")
					sess.model = model;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));

			Qtemp =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				if(len m.data > MAXSETTING) {
					srv.reply(ref Rmsg.Error(m.tag, "temperature setting too large"));
					break;
				}
				tstr := strip(string m.data);
				temp := parsefloat(tstr);
				if(temp < 0.0 || temp > 2.0) {
					srv.reply(ref Rmsg.Error(m.tag, "temperature must be between 0.0 and 2.0"));
					break;
				}
				sess.temperature = temp;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));

			Qsystem =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				# Accumulate across write-fragments; committed on clunk.
				(nb, aerr) := appendbyteslimit(c.data, m.data, MAXSYSTEM);
				if(aerr != nil) {
					c.data = nil;
					srv.reply(ref Rmsg.Error(m.tag, aerr));
					break;
				}
				c.data = nb;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));

			Qthinking =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				if(len m.data > MAXSETTING) {
					srv.reply(ref Rmsg.Error(m.tag, "thinking setting too large"));
					break;
				}
				value := strip(string m.data);
				case value {
				"max" or "-1" =>
					sess.thinkingtokens = -1;
				"disabled" or "off" or "0" =>
					sess.thinkingtokens = 0;
				* =>
					n := strtoint(value);
					if(n < 0) {
						srv.reply(ref Rmsg.Error(m.tag, "invalid thinking budget"));
						break;
					}
					sess.thinkingtokens = n;
				}
				srv.reply(ref Rmsg.Write(m.tag, len m.data));

			Qprefill =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				# Don't strip — prefill may have intentional trailing space
				# But remove trailing newline since shell adds it
				if(len m.data > MAXPREFILL) {
					srv.reply(ref Rmsg.Error(m.tag, "prefill too large"));
					break;
				}
				pf := string m.data;
				if(len pf > 0 && pf[len pf - 1] == '\n')
					pf = pf[:len pf - 1];
				sess.prefill = pf;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));

			Qmaxtokens =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				if(len m.data > MAXSETTING) {
					srv.reply(ref Rmsg.Error(m.tag, "maxtokens setting too large"));
					break;
				}
				value := strip(string m.data);
				n := strtoint(value);
				# 0 means "use backend default"; negative is invalid;
				# upper bound matches the highest sane LLM context cap.
				if(n < 0 || n > 65536) {
					srv.reply(ref Rmsg.Error(m.tag, "maxtokens must be 0..65536"));
					break;
				}
				sess.maxtokens = n;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));

			Qreasoning =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				if(len m.data > MAXSETTING) {
					srv.reply(ref Rmsg.Error(m.tag, "reasoning setting too large"));
					break;
				}
				value := strip(string m.data);
				# Empty string clears (== use no reasoning_effort, e.g.
				# for sessions that override their model to a non-reasoning
				# backend). Otherwise must be one of low/medium/high.
				if(value != "" && value != "low" && value != "medium" && value != "high") {
					srv.reply(ref Rmsg.Error(m.tag, "reasoning must be ''|low|medium|high"));
					break;
				}
				sess.reasoningeffort = value;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));

			Qtools =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				# Accumulate the tool-defs JSON across write-fragments; parsed
				# and committed on clunk (see finalizewrite). The whole array
				# may exceed one iounit, so it cannot be parsed per-write.
				(nb, aerr) := appendbyteslimit(c.data, m.data, MAXTOOLS);
				if(aerr != nil) {
					c.data = nil;
					srv.reply(ref Rmsg.Error(m.tag, aerr));
					break;
				}
				c.data = nb;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));

			Qcompact =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				spawn asynccompact(srv, m.tag, len m.data, sess);

			Qctl =>
				sess := findsession(sid);
				if(sess == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				cmd := strip(string m.data);
				case cmd {
				"reset" =>
					resetsession(sess);
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
				"close" =>
					closesession(sess);
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
				* =>
					# autocompact <n>: per-session auto-compact high-water
					# mark in estimated tokens; 0 disables (caller owns its
					# own compaction policy). See rungeneration (INFR-223).
					if(hasprefix(cmd, "autocompact")) {
						n := strtoint(strip(cmd[len "autocompact":]));
						if(n < 0)
							srv.reply(ref Rmsg.Error(m.tag, "autocompact needs a non-negative integer (0 disables)"));
						else {
							sess.autocompact = n;
							srv.reply(ref Rmsg.Write(m.tag, len m.data));
						}
					} else
						srv.reply(ref Rmsg.Error(m.tag, "unknown command: " + cmd));
				}

			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			}

		Clunk =>
			finalizewrite(srv, m.fid);
			srv.clunk(m);

		Remove =>
			srv.remove(m);

		Attach =>
			# Robustness (INFR-349): every export connection to /mnt/llm is
			# multiplexed by the kernel mnt device through this one styx link,
			# and the mnt device never reuses a fid number it still considers
			# live. So an attach for a fid we already hold can only be a stale
			# orphan left behind when a client disconnected abruptly (emu
			# kill -9, dropped TCP) before its fids were clunked. Reap it here
			# so the new attach succeeds immediately, instead of replying
			# "fid already in use" until TCP keepalive eventually tears down
			# the dead export connection (the observed minutes-long stall).
			reapstale(srv, m.fid);
			srv.attach(m);

		Walk =>
			# Same orphan-reuse reasoning as Attach: a Twalk that clones onto
			# a newfid we still hold is a recycled-after-disconnect number, so
			# reap the stale entry rather than fail the clone with Einuse
			# (surfaces to the client as "clone failed"/"mount rpc error").
			# A same-fid walk (newfid == fid) allocates nothing — leave it be.
			if(m.newfid != m.fid)
				reapstale(srv, m.newfid);
			srv.walk(m);

		* =>
			srv.default(gm);
		}
	}
	navops <-= nil;
}

# Reap a stale fid before an attach/walk reuses its number (INFR-349). A
# collision can only be an orphan from an abruptly-disconnected client (see
# the Attach case for why), so dropping it from the fid table is always safe:
# per-session state lives in the `sessions` array keyed by SESSID, not on the
# Fid, so nothing is lost. Any async reader that already captured this Fid ref
# keeps its copy — delfid only unlinks the hash entry.
reapstale(srv: ref Styxserver, fid: int)
{
	c := srv.getfid(fid);
	if(c != nil) {
		finalizewrite(srv, fid);  # drop any half-written reassembly buffer
		srv.delfid(c);
	}
}

# --- Async generation goroutine ---

# Append a write-fragment to a reassembly buffer, returning the grown buffer.
# The mnt device fragments one client write() into multiple <=iounit Twrites
# delivered in order; appending in arrival order faithfully reconstructs the
# document. We deliberately do NOT index by absolute offset: the persistent
# ORDWR /ask fid's write offset climbs across turns (queryllmfd never seeks 0),
# which would make absolute-offset placement grow without bound.
appendbyteslimit(buf, data: array of byte, limit: int): (array of byte, string)
{
	if(data == nil || len data == 0)
		return (buf, nil);
	blen := 0;
	if(buf != nil)
		blen = len buf;
	if(blen + len data > limit)
		return (nil, sys->sprint("write too large: limit %d bytes", limit));
	if(buf == nil) {
		nb := array[len data] of byte;
		nb[0:] = data;
		return (nb, nil);
	}
	nb := array[len buf + len data] of byte;
	nb[0:] = buf;
	nb[len buf:] = data;
	return (nb, nil);
}

# Start a generation turn if a fully-written prompt is pending and none is
# running. The trigger is the write->read transition (first read after the
# prompt writes), since the /ask fid is never clunked between turns.
triggerpending(sess: ref LlmSession)
{
	if(sess.pendingwrite == nil || sess.genactive)
		return;
	prompt := strip(string sess.pendingwrite);
	sess.pendingwrite = nil;
	if(prompt == "")
		return;
	# Allocate channels before spawning, then run generation async.
	sess.streamch = chan[256] of string;
	sess.donech = chan of int;
	sess.genactive = 1;
	spawn rungeneration(sess, prompt);
}

# Commit a reassembled /tools or /system document on clunk. Tool-defs validity
# cannot be known until the whole array is assembled, so parse errors surface
# in the server log here rather than as a write error (the write already
# succeeded chunk-by-chunk). This is also the natural point for a future
# content-hash + parsed-tooldef cache (INFR-214 follow-up).
finalizewrite(srv: ref Styxserver, fid: int)
{
	c := srv.getfid(fid);
	if(c == nil || c.data == nil)
		return;
	sess := findsession(SESSID(c.path));
	if(sess == nil) {
		c.data = nil;
		return;
	}
	content := strip(string c.data);
	c.data = nil;
	case FTYPE(c.path) {
	Qtools =>
		if(content == "") {
			sess.tools = nil;
			return;
		}
		(tools, terr) := parsetooldefs(content);
		if(terr != nil) {
			sys->fprint(stderr, "llmsrv: tools parse on clunk: %s\n", terr);
			return;
		}
		sess.tools = tools;
	Qsystem =>
		sess.systemprompt = content;
	}
}

# Run one generation turn. Caller (triggerpending) has set genactive/streamch/
# donech and the triggering write was already replied to.
rungeneration(sess: ref LlmSession, prompt: string)
{
	# Check for TOOL_RESULTS
	if(hasprefix(prompt, "TOOL_RESULTS\n") || hasprefix(prompt, "TOOL_RESULTS\r\n")) {
		(results, perr) := llmclient->parsetoolresults(prompt);
		if(perr != nil) {
			sess.lastresponse = "Error: " + perr;
			endgeneration(sess);
			return;
		}
		askwithtoolresults(sess, results);
	} else {
		# Normal prompt
		askprompt(sess, prompt);
	}

	maybeautocompact(sess);
	endgeneration(sess);
}

# Server-side automatic compaction (INFR-223). Runs at the end of a turn, in
# the generation proc, while genactive==1 still blocks any new turn from
# starting (triggerpending) — so it cannot race a concurrent generation
# rewriting sess.messages. This is the safety net that makes every client safe
# by default: clients that don't poll /usage and drive /compact themselves
# (nerva, repl, sub-agents) are still bounded. Clients that own their own
# compaction policy disable it per-session with `ctl autocompact 0`; the
# explicit /compact write keeps working regardless. The crossing turn pays one
# extra summarization round-trip before its reply is released — acceptable
# since the high-water mark is reached rarely.
maybeautocompact(sess: ref LlmSession)
{
	before := estimatedtokens(sess);
	if(sess.autocompact <= 0 || before < sess.autocompact)
		return;
	err := compactnow(sess);
	if(err != nil)
		sys->fprint(stderr, "llmsrv: auto-compact (session %d) failed: %s\n", sess.id, err);
	else
		sys->fprint(stderr, "llmsrv: auto-compacted session %d (~%d -> ~%d tokens, threshold %d)\n",
			sess.id, before, estimatedtokens(sess), sess.autocompact);
}

askprompt(sess: ref LlmSession, prompt: string)
{
	req := ref AskRequest(
		sess.messages,    # messages
		prompt,           # prompt
		sess.model,       # model
		sess.temperature, # temperature
		sess.maxtokens,   # maxtokens
		sess.systemprompt,# systemprompt
		sess.thinkingtokens, # thinkingtokens
		sess.reasoningeffort, # per-session override (defaults to daemon -r)
		sess.prefill,     # prefill
		sess.tools,       # tooldefs
		nil,              # toolresults
		sess.streamch     # streamch
	);

	(resp, err) := callbackend(req);
	if(err != nil) {
		# Error recovery
		if(iscontentfiltererror(err) || istooluseerror(err)) {
			# Reset and retry
			sess.messages = nil;
			req.messages = nil;
			(resp, err) = callbackend(req);
			if(err != nil) {
				sess.lastresponse = "Error: " + err;
				return;
			}
		} else {
			sess.lastresponse = "Error: " + err;
			return;
		}
	}

	# Update session state
	textcontent := llmclient->extracttextcontent(resp.response);
	sess.messages = addmessage(sess.messages, "user", prompt, "");
	sess.messages = addmessage(sess.messages, "assistant", textcontent, resp.structuredjson);
	sess.totaltokens += resp.tokens;
	sess.lastresponse = resp.response;
}

askwithtoolresults(sess: ref LlmSession, results: list of ref ToolResult)
{
	# Copy message list for the request (matches Go pattern: req gets snapshot
	# without tool_result; session gets tool_result immediately to prevent
	# orphaned tool_use if the API call fails).
	history := copymessages(sess.messages);

	req := ref AskRequest(
		history,          # messages (snapshot WITHOUT tool_result)
		"",               # prompt (empty for tool results)
		sess.model,       # model
		sess.temperature, # temperature
		sess.maxtokens,   # maxtokens
		sess.systemprompt,# systemprompt
		sess.thinkingtokens, # thinkingtokens
		defaultreasoning, # reasoningeffort
		"",               # prefill (empty mid-tool-loop)
		sess.tools,       # tooldefs
		results,          # toolresults
		sess.streamch     # streamch
	);

	# Record tool results in history BEFORE API call so history stays valid
	# even if the call fails. An orphaned tool_use assistant message (no
	# following tool_result) causes every subsequent Ask to fail.
	toolresultstext := "tool results submitted";
	toolresultsjson := buildtoolresultsjson(results);
	sess.messages = addmessage(sess.messages, "user", toolresultstext, toolresultsjson);

	(resp, err) := callbackend(req);

	if(err != nil) {
		if(iscontentfiltererror(err)) {
			sess.messages = nil;
			synthetic := "STOP:end_turn\nContent filtering policy blocked a tool result. Session history reset.";
			sess.lastresponse = synthetic;
			return;
		}
		# Add synthetic assistant error to keep role alternation valid
		errmsg := "Error: " + err;
		sess.messages = addmessage(sess.messages, "assistant", errmsg, "");
		sess.lastresponse = errmsg;
		return;
	}

	textcontent := llmclient->extracttextcontent(resp.response);
	sess.messages = addmessage(sess.messages, "assistant", textcontent, resp.structuredjson);
	sess.totaltokens += resp.tokens;
	sess.lastresponse = resp.response;
}

endgeneration(sess: ref LlmSession)
{
	ch := sess.streamch;
	done := sess.donech;
	# Do NOT nil streamch — leave closed channel readable for late readers
	sess.donech = nil;
	sess.genactive = 0;
	if(ch != nil) {
		# Close the channel by sending a nil sentinel
		# In Limbo, we can't close channels, so we send empty string as EOF marker
		# Actually, Limbo channels can't be "closed" like Go.
		# Convention: send nil/empty as EOF marker, then nil the channel after done signal
		alt {
			ch <-= "" => ;
			* => ;
		}
	}
	if(done != nil)
		done <-= 0;
}

# --- Async blocking reads ---

asyncaskread(srv: ref Styxserver, m: ref Tmsg.Read, sess: ref LlmSession)
{
	# Block until generation completes
	donech := sess.donech;
	if(donech != nil)
		<-donech;

	content := sess.lastresponse;
	if(content != "" && content[len content - 1] != '\n')
		content += "\n";

	srv.reply(styxservers->readbytes(m, array of byte content));
}

asyncstreamread(srv: ref Styxserver, m: ref Tmsg.Read, sess: ref LlmSession)
{
	ch := sess.streamch;
	if(ch == nil) {
		# No active generation — EOF
		srv.reply(styxservers->readbytes(m, nil));
		return;
	}

	chunk := <-ch;
	if(chunk == nil || chunk == "") {
		# Channel "closed" (EOF sentinel)
		srv.reply(styxservers->readbytes(m, nil));
		return;
	}

	srv.reply(styxservers->readbytes(m, array of byte chunk));
}

# --- Compaction ---

# Summarize the session history in place, replacing it with a compact summary.
# Synchronous and self-contained so both the manual /compact path
# (asynccompact) and the server-side automatic trigger (maybeautocompact) share
# one implementation. Returns "" on success or when there is too little history
# to bother (< 4 messages); otherwise an error string. Callers are responsible
# for serializing against generation, since this rewrites sess.messages: the
# auto path runs inside the generation proc; the manual path rejects writes
# while a turn is in flight (see asynccompact).
compactnow(sess: ref LlmSession): string
{
	# Count messages
	nmsg := 0;
	for(ml := sess.messages; ml != nil; ml = tl ml)
		nmsg++;

	if(nmsg < 4)
		return "";

	# Build conversation text for summarization
	convtext := "";
	for(ml = sess.messages; ml != nil; ml = tl ml) {
		m := hd ml;
		if(m.role == "system")
			continue;
		convtext += m.role + ": " + m.content + "\n\n";
	}

	req := ref AskRequest(
		nil,       # messages
		"Summarize this conversation concisely, preserving key facts, decisions, file paths, code snippets, and all context needed to continue the work:\n\n" + convtext,
		sess.model,
		0.3,       # low temperature for summarization
		2048,      # maxtokens (compact: longer than chat default for summary breathing room)
		"",        # no system prompt
		0,         # no thinking
		sess.reasoningeffort, # per-session override
		"",        # no prefill
		nil,       # no tools
		nil,       # no tool results
		nil        # no streaming
	);

	(resp, err) := callbackend(req);
	if(err != nil)
		return err;

	# Replace history with compact summary
	sess.messages = nil;
	sess.messages = addmessage(sess.messages, "user",
		"Context from earlier in this session:\n" + resp.response, "");
	sess.messages = addmessage(sess.messages, "assistant",
		"Understood. I have the context from our previous work and will continue from there.", "");
	sess.totaltokens = resp.tokens;

	return "";
}

# Manual /compact trigger. Compaction rewrites sess.messages, which the
# generation proc actively appends to, so reject while a turn is in flight
# (serialize per session, INFR-223) rather than race it. Clients drive
# /compact between turns (e.g. veltro's checkandcompact, after queryllmfd
# returns), so this guard does not impede normal use.
asynccompact(srv: ref Styxserver, tag: int, count: int, sess: ref LlmSession)
{
	if(sess.genactive) {
		srv.reply(ref Rmsg.Error(tag, "compact: generation in progress, retry"));
		return;
	}

	err := compactnow(sess);
	if(err != nil) {
		srv.reply(ref Rmsg.Error(tag, "compact: " + err));
		return;
	}

	srv.reply(ref Rmsg.Write(tag, count));
}

# --- Tool definition parsing ---

parsetooldefs(content: string): (list of ref ToolDef, string)
{
	bio := bufio->aopen(array of byte content);
	if(bio == nil)
		return (nil, "cannot create buffer");
	(jv, jerr) := json->readjson(bio);
	if(jerr != nil)
		return (nil, "invalid JSON: " + jerr);

	tools: list of ref ToolDef;
	pick a := jv {
	Array =>
		for(i := len a.a - 1; i >= 0; i--) {
			td := a.a[i];
			name := "";
			desc := "";
			schema := "{}";
			nv := td.get("name");
			if(nv != nil) pick n := nv { String => name = n.s; }
			dv := td.get("description");
			if(dv != nil) pick d := dv { String => desc = d.s; }
			# Accept either "parameters" (OpenAI shape, per INFR-126) or
			# "input_schema" (legacy Anthropic shape). Prefer "parameters"
			# when both are present.
			sv := td.get("parameters");
			if(sv == nil)
				sv = td.get("input_schema");
			if(sv != nil)
				schema = sv.text();
			tools = ref ToolDef(name, desc, schema) :: tools;
		}
	* =>
		return (nil, "expected JSON array");
	}
	return (tools, nil);
}

# --- Tool results JSON builder ---

buildtoolresultsjson(results: list of ref ToolResult): string
{
	s := "[";
	first := 1;
	for(; results != nil; results = tl results) {
		r := hd results;
		if(!first)
			s += ",";
		first = 0;
		s += "{\"type\":\"tool_result\",\"tool_use_id\":" +
			jquote(r.tooluseid) +
			",\"content\":" + jquote(r.content) + "}";
	}
	s += "]";
	return s;
}

# --- Directory generation ---

dir(qid: Sys->Qid, name: string, length: big, perm: int): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.qid = qid;
	if(qid.qtype & Sys->QTDIR)
		perm |= Sys->DMDIR;
	d.mode = perm;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.length = length;
	return d;
}

dirgen(p: big): (ref Sys->Dir, string)
{
	ft := FTYPE(p);
	sid := SESSID(p);

	case ft {
	Qroot =>
		return (dir(Qid(p, vers, Sys->QTDIR), "/", big 0, 8r755), nil);
	Qnew =>
		return (dir(Qid(p, vers, Sys->QTFILE), "new", big 0, 8r444), nil);
	Qmodels =>
		return (dir(Qid(p, vers, Sys->QTFILE), "models", big 0, 8r444), nil);
	Qsessdir =>
		# Present the session's capability token as its directory name, not
		# the numeric id, so a stat never discloses a guessable id (INFR-321).
		nm := string sid;
		s := findsession(sid);
		if(s != nil)
			nm = s.name;
		return (dir(Qid(p, vers, Sys->QTDIR), nm, big 0, 8r755), nil);
	Qask =>
		return (dir(Qid(p, vers, Sys->QTFILE), "ask", big 0, 8r666), nil);
	Qstream =>
		return (dir(Qid(p, vers, Sys->QTFILE), "stream", big 0, 8r444), nil);
	Qmodel =>
		return (dir(Qid(p, vers, Sys->QTFILE), "model", big 0, 8r666), nil);
	Qtemp =>
		return (dir(Qid(p, vers, Sys->QTFILE), "temperature", big 0, 8r666), nil);
	Qsystem =>
		return (dir(Qid(p, vers, Sys->QTFILE), "system", big 0, 8r666), nil);
	Qthinking =>
		return (dir(Qid(p, vers, Sys->QTFILE), "thinking", big 0, 8r666), nil);
	Qprefill =>
		return (dir(Qid(p, vers, Sys->QTFILE), "prefill", big 0, 8r666), nil);
	Qtools =>
		return (dir(Qid(p, vers, Sys->QTFILE), "tools", big 0, 8r222), nil);
	Qcontext =>
		return (dir(Qid(p, vers, Sys->QTFILE), "context", big 0, 8r444), nil);
	Qcompact =>
		return (dir(Qid(p, vers, Sys->QTFILE), "compact", big 0, 8r644), nil);
	Qctl =>
		return (dir(Qid(p, vers, Sys->QTFILE), "ctl", big 0, 8r222), nil);
	Qusage =>
		return (dir(Qid(p, vers, Sys->QTFILE), "usage", big 0, 8r444), nil);
	Qmaxtokens =>
		return (dir(Qid(p, vers, Sys->QTFILE), "maxtokens", big 0, 8r666), nil);
	Qreasoning =>
		return (dir(Qid(p, vers, Sys->QTFILE), "reasoning", big 0, 8r666), nil);
	}

	return (nil, Enotfound);
}

# --- Navigator ---

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil) {
		pick n := m {
		Stat =>
			n.reply <-= dirgen(n.path);

		Walk =>
			ft := FTYPE(n.path);
			sid := SESSID(n.path);

			case ft {
			Qroot =>
				case n.name {
				".." =>
					;  # stay at root
				"new" =>
					n.path = MKPATH(0, Qnew);
				"models" =>
					n.path = MKPATH(0, Qmodels);
				* =>
					# Resolve a session only by exact capability-token
					# match (INFR-321). Numeric ids are no longer walkable,
					# so a client cannot reach a session it did not create.
					sess := findsessionbyname(n.name);
					if(sess != nil)
						n.path = MKPATH(sess.id, Qsessdir);
					else {
						n.reply <-= (nil, Enotfound);
						continue;
					}
				}
				n.reply <-= dirgen(n.path);

			Qsessdir =>
				case n.name {
				".." =>
					n.path = big Qroot;
				"ask" =>
					n.path = MKPATH(sid, Qask);
				"stream" =>
					n.path = MKPATH(sid, Qstream);
				"model" =>
					n.path = MKPATH(sid, Qmodel);
				"temperature" =>
					n.path = MKPATH(sid, Qtemp);
				"system" =>
					n.path = MKPATH(sid, Qsystem);
				"thinking" =>
					n.path = MKPATH(sid, Qthinking);
				"prefill" =>
					n.path = MKPATH(sid, Qprefill);
				"tools" =>
					n.path = MKPATH(sid, Qtools);
				"context" =>
					n.path = MKPATH(sid, Qcontext);
				"compact" =>
					n.path = MKPATH(sid, Qcompact);
				"ctl" =>
					n.path = MKPATH(sid, Qctl);
				"usage" =>
					n.path = MKPATH(sid, Qusage);
				"maxtokens" =>
					n.path = MKPATH(sid, Qmaxtokens);
				"reasoning" =>
					n.path = MKPATH(sid, Qreasoning);
				* =>
					n.reply <-= (nil, Enotfound);
					continue;
				}
				n.reply <-= dirgen(n.path);

			* =>
				# Files are not directories
				case n.name {
				".." =>
					if(ft >= Qsessdir)
						n.path = MKPATH(sid, Qsessdir);
					else
						n.path = big Qroot;
					n.reply <-= dirgen(n.path);
				* =>
					n.reply <-= (nil, "not a directory");
				}
			}

		Readdir =>
			ft := FTYPE(m.path);

			case ft {
			Qroot =>
				# Root: new + models only. Session directories are
				# deliberately NOT listed (INFR-321): they are reachable
				# only via their unguessable capability token, so a client
				# cannot enumerate sessions it does not own.
				entries: list of big;
				entries = MKPATH(0, Qnew) :: entries;
				entries = MKPATH(0, Qmodels) :: entries;

				# Reverse to preserve order
				rev: list of big;
				for(; entries != nil; entries = tl entries)
					rev = hd entries :: rev;
				entries = rev;

				i := 0;
				for(e := entries; e != nil; e = tl e) {
					if(i >= n.offset && n.count > 0) {
						n.reply <-= dirgen(hd e);
						n.count--;
					}
					i++;
				}
				n.reply <-= (nil, nil);

			Qsessdir =>
				sid := SESSID(m.path);
				files := array[] of {
					MKPATH(sid, Qask),
					MKPATH(sid, Qstream),
					MKPATH(sid, Qmodel),
					MKPATH(sid, Qtemp),
					MKPATH(sid, Qsystem),
					MKPATH(sid, Qthinking),
					MKPATH(sid, Qprefill),
					MKPATH(sid, Qtools),
					MKPATH(sid, Qcontext),
					MKPATH(sid, Qcompact),
					MKPATH(sid, Qctl),
					MKPATH(sid, Qusage),
					MKPATH(sid, Qmaxtokens),
					MKPATH(sid, Qreasoning),
				};
				i := n.offset;
				for(; i < len files && n.count > 0; i++) {
					n.reply <-= dirgen(files[i]);
					n.count--;
				}
				n.reply <-= (nil, nil);

			* =>
				n.reply <-= (nil, "not a directory");
			}
		}
	}
}

# --- Message list helpers ---

copymessages(msgs: list of ref LlmMessage): list of ref LlmMessage
{
	# Create a shallow copy of the message list (new cons cells, same LlmMessage refs).
	# This ensures addmessage on the original doesn't affect the copy.
	rev: list of ref LlmMessage;
	for(ml := msgs; ml != nil; ml = tl ml)
		rev = hd ml :: rev;
	result: list of ref LlmMessage;
	for(; rev != nil; rev = tl rev)
		result = hd rev :: result;
	return result;
}

addmessage(msgs: list of ref LlmMessage, role, content, sc: string): list of ref LlmMessage
{
	# Append to end by reversing, prepending, reversing
	rev: list of ref LlmMessage;
	for(ml := msgs; ml != nil; ml = tl ml)
		rev = hd ml :: rev;
	rev = ref LlmMessage(role, content, sc) :: rev;
	result: list of ref LlmMessage;
	for(; rev != nil; rev = tl rev)
		result = hd rev :: result;
	return result;
}

# --- Helpers ---

ensuredir(path: string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd != nil)
		return;

	for(i := len path - 1; i > 0; i--) {
		if(path[i] == '/') {
			ensuredir(path[0:i]);
			break;
		}
	}

	fd = sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
	if(fd == nil)
		sys->fprint(stderr, "llmsrv: cannot create directory %s: %r\n", path);
}

rf(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[Sys->NAMEMAX] of byte;
	n := sys->read(fd, b, len b);
	if(n < 0)
		return nil;
	return string b[0:n];
}

getfactotumkey(service: string): string
{
	if(factotum == nil)
		return "";
	(nil, password) := factotum->getuserpasswd(
		"proto=pass service=" + service);
	return password;
}

readenv(name: string): string
{
	s := rf("/env/" + name);
	if(s != nil)
		s = strip(s);
	return s;
}

strtoint(s: string): int
{
	n := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c < '0' || c > '9')
			return -1;
		n = n * 10 + (c - '0');
	}
	if(len s == 0)
		return -1;
	return n;
}

parsefloat(s: string): real
{
	# Simple float parser for "N.NN" format
	neg := 0;
	i := 0;
	if(i < len s && s[i] == '-') {
		neg = 1;
		i++;
	}
	whole := 0.0;
	for(; i < len s && s[i] >= '0' && s[i] <= '9'; i++)
		whole = whole * 10.0 + real(s[i] - '0');

	frac := 0.0;
	if(i < len s && s[i] == '.') {
		i++;
		div := 10.0;
		for(; i < len s && s[i] >= '0' && s[i] <= '9'; i++) {
			frac += real(s[i] - '0') / div;
			div *= 10.0;
		}
	}
	result := whole + frac;
	if(neg)
		result = -result;
	return result;
}

hasprefix(s, prefix: string): int
{
	return len s >= len prefix && s[0:len prefix] == prefix;
}

contains(s, sub: string): int
{
	if(len sub > len s)
		return 0;
	for(i := 0; i <= len s - len sub; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

strip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n' || s[j-1] == '\r'))
		j--;
	if(i >= j)
		return "";
	return s[i:j];
}

jquote(s: string): string
{
	return "\"" + llmclient->jsonescapestr(s) + "\"";
}
