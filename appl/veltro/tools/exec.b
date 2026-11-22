implement ToolExec;

#
# exec - Execute shell command tool for Veltro agent
#
# Runs a shell command and returns output.
# Commands are executed via Inferno's sh(1).
#
# IMPORTANT: Inferno shell syntax differs from POSIX/bash:
#   - Use SINGLE quotes for strings: echo 'hello world'
#   - Double quotes do NOT work like bash
#   - One command a call: ; | & && || and substitutions are refused
#
# Usage:
#   Exec <command>
#
# Examples:
#   Exec cat /dev/sysname
#   Exec ls /appl
#   Exec echo 'hello world'
#   Exec wc -l /appl/cmd/cat.b
#
# Note: Double-quoted strings are auto-converted to single quotes.
# Security note: Commands run with agent's namespace/capabilities.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "sh.m";
	sh: Sh;

include "../tool.m";

ToolExec: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

# Limits
DEFAULT_TIMEOUT: con 30000;  # 30 seconds; 5 cut off a build half way
MAX_TIMEOUT: con 120000;     # 120 seconds, under the harness's bound on a call
MAX_OUTPUT: con 16384;       # 16KB max output kept
HEAD_OUTPUT: con 4096;       # of it, from the start; the rest is the end

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	sh = load Sh Sh->PATH;
	# sh.dis may not be visible at init() time if tools9p's namespace
	# restriction hasn't yet bound sh.dis (exec not in the caps.tools
	# passed to restrictns, or called before restriction applies).
	# exec() will retry the load lazily when actually invoked.
	return nil;
}

name(): string
{
	return "exec";
}

doc(): string
{
	return "Exec - Run a program in the Inferno namespace\n\n" +
		"GUI/WM programs (wm/clock, /dis/wm/clock, /dis/wm/clock.dis) are\n" +
		"not run by Exec: use the launch tool, which puts them in the\n" +
		"presentation zone (e.g. 'launch clock'). Exec refuses them with an\n" +
		"error naming the launch call to make.\n\n" +
		"For non-GUI programs:\n" +
		"  Exec /dis/bind.dis -a /mnt/foo /n/bar\n" +
		"  Exec /dis/veltro/tools/someprogram.dis args\n\n" +
		"The namespace is restricted: standard Unix commands (echo, cat, ls)\n" +
		"are NOT available. Use the dedicated tools instead:\n" +
		"  read/write/edit  - file I/O\n" +
		"  list             - directory listing\n" +
		"  find/search/grep - search\n\n" +
		"IMPORTANT: Inferno shell syntax, not POSIX:\n" +
		"  - One command a call: a command with ; | & && || $name or a\n" +
		"    `{} ${} <{} >{} substitution is refused, not run in part\n" +
		"  - Single quotes for strings\n\n" +
		"Returns program output: all of it, or, when it is long, its start\n" +
		"and its end (where errors are), and how much was left out.\n" +
		"Default timeout: 30 seconds; -t <seconds> before the command sets\n" +
		"another (at most 120).";
}

schema(): string
{
	return "{" +
		"\"name\":\"exec\"," +
		"\"description\":\"Run a program inside the Inferno namespace via the shell. Inferno rc-style syntax; one command a call (no ; | & && || or $ and `{} substitution: such a command is refused). GUI/wm apps are not run here \\u2014 use the launch tool for the presentation zone.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"command\":{\"type\":\"string\",\"description\":\"Full command line, e.g. '/dis/bind.dis -a /mnt/foo /n/bar'.\"}," +
				"\"timeout\":{\"type\":\"string\",\"description\":\"Seconds to let it run. Optional; default 30, at most 120.\"}" +
			"}," +
			"\"required\":[\"command\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(sys == nil)
		init();

	if(sh == nil) {
		sh = load Sh Sh->PATH;
		if(sh == nil)
			return "error: cannot load shell module (exec requires sh.dis; pass 'exec' to tools9p)";
	}

	# Parse command
	cmd := args;

	# Strip leading/trailing whitespace
	while(len cmd > 0 && (cmd[0] == ' ' || cmd[0] == '\t'))
		cmd = cmd[1:];

	# -t <seconds>: how long it may run
	timeoutms := DEFAULT_TIMEOUT;
	if(len cmd > 3 && cmd[0:3] == "-t ") {
		i := 3;
		while(i < len cmd && cmd[i] == ' ')
			i++;
		# (A count of 0, or one large enough to wrap to it or below,
		# left "-t" in the command, which the shell then looked for.)
		secs := 0;
		digits := 0;
		for(; i < len cmd && cmd[i] >= '0' && cmd[i] <= '9'; i++) {
			if(secs <= MAX_TIMEOUT)
				secs = secs * 10 + cmd[i] - '0';
			digits++;
		}
		if(digits == 0 || secs == 0 || (i < len cmd && cmd[i] != ' ' && cmd[i] != '\t'))
			return sys->sprint("error: -t takes a number of seconds, 1 to %d, then the command", MAX_TIMEOUT / 1000);
		timeoutms = secs * 1000;
		if(secs > MAX_TIMEOUT / 1000)
			timeoutms = MAX_TIMEOUT;
		while(i < len cmd && (cmd[i] == ' ' || cmd[i] == '\t'))
			i++;
		cmd = cmd[i:];
	}
	while(len cmd > 0 && (cmd[len cmd - 1] == ' ' || cmd[len cmd - 1] == '\t' || cmd[len cmd - 1] == '\n'))
		cmd = cmd[0:len cmd - 1];

	# Handle quoted command (strip outer quotes if present)
	if(len cmd >= 2) {
		if((cmd[0] == '"' && cmd[len cmd - 1] == '"') ||
		   (cmd[0] == '\'' && cmd[len cmd - 1] == '\''))
			cmd = cmd[1:len cmd - 1];
	}

	# Strip trailing & — model sometimes appends it for "background" but
	# exec handles GUI launch asynchronously; & breaks firstword detection
	while(len cmd > 0 && cmd[len cmd - 1] == '&')
		cmd = cmd[0:len cmd - 1];
	while(len cmd > 0 && (cmd[len cmd - 1] == ' ' || cmd[len cmd - 1] == '\t'))
		cmd = cmd[0:len cmd - 1];

	if(cmd == "")
		return "error: usage: Exec <command>";

	# One command, with no substitution.  The name space is the boundary;
	# this keeps a call to what its one line says.  These were taken out
	# of the command and the rest run: "a ; b" ran a with b as an
	# argument, "echo $x" ran echo, and nothing said so.
	if((what := refused(cmd)) != nil)
		return "error: exec runs one command and no substitution: " + what +
			" is not taken (make a call for each command; nothing was run)";

	# Convert double quotes to single quotes for Inferno shell compatibility
	# Inferno's sh uses single quotes for literal strings, not double quotes
	cmd = convertquotes(cmd);

	# GUI programs in /dis/wm/ are refused with a pointer to launch.
	# Detects /dis/wm/ programs three ways:
	#   1. Full .dis path:  exec /dis/wm/clock.dis
	#   2. Absolute no-ext: exec /dis/wm/clock    → tries /dis/wm/clock.dis
	#   3. Short name:      exec wm/clock          → tries /dis/wm/clock.dis
	# Only /dis/wm/* programs are refused; CLI tools fall through.
	if(len cmd > 0) {
		firstword := cmd;
		for(i := 0; i < len firstword; i++) {
			if(firstword[i] == ' ' || firstword[i] == '\t') {
				firstword = firstword[0:i];
				break;
			}
		}
		dispath := "";
		if(len firstword > 4 && firstword[len firstword - 4:] == ".dis") {
			# Already has .dis extension
			dispath = firstword;
		} else if(len firstword > 0 && firstword[0] == '/') {
			# Absolute path without .dis extension — try appending .dis
			trypath := firstword + ".dis";
			(pok, nil) := sys->stat(trypath);
			if(pok >= 0)
				dispath = trypath;
		} else {
			# Short/relative name — try /dis/<firstword>.dis
			trypath := "/dis/" + firstword + ".dis";
			(pok, nil) := sys->stat(trypath);
			if(pok >= 0)
				dispath = trypath;
		}
		# Xenith is a full-environment GUI app; exec cannot target the
		# presentation zone for it and it would try to take over the display.
		# Force the agent to use the 'launch' tool instead.
		if(dispath != "" && len dispath >= 10 &&
		   dispath[len dispath - 10:] == "xenith.dis") {
			return "error: use 'launch xenith' — exec cannot target the presentation zone for xenith";
		}
		# /dis/wm/* apps are wmclient GUI programs: they belong in the
		# presentation zone, which only the launch tool reaches (through
		# /mnt/ui's presentation/ctl).  exec has no display to give them.
		# It used to drop the path in /n/pres-launch or
		# /tmp/veltro/pres-launch for lucifer to poll, but nothing has read
		# either since lucifer's unified tab model (48174e2fb), so exec
		# reported a launch that never happened.
		if(len dispath > 8 && dispath[0:8] == "/dis/wm/") {
			appname := dispath[8:len dispath - 4];
			return "error: use 'launch " + appname + "' — exec cannot open GUI apps; launch puts them in the presentation zone";
		}
	}

	# The command, its pipe, its wait file and its process control are
	# all opened by a process with a file descriptor group of its own.
	# Every tool call of a tool server shares one group, and the command
	# was given that group's descriptors 0, 1 and 2: whatever any call
	# had open there at that moment (another call's directory, a pipe of
	# its copy-on-write mount, a process control file).
	answer := chan[1] of string;
	spawn supervise(cmd, timeoutms, answer);
	return <-answer;
}

supervise(cmd: string, timeoutms: int, answer: chan of string)
{
	{
		answer <-= capture(cmd, timeoutms);
	} exception e {
	"*" =>
		answer <-= "error: exec: " + e;
	}
}

capture(cmd: string, timeoutms: int): string
{
	# Nothing of the caller's, and /dev/null as 0, 1 and 2 for as long as
	# this process lives: the command keeps 0, and nothing opened below
	# is taken for a standard descriptor.
	if(sys->pctl(Sys->NEWFD, nil) < 0)
		return sys->sprint("error: cannot isolate descriptors: %r");
	std := array[3] of ref Sys->FD;
	for(n := 0; n < len std; n++) {
		std[n] = sys->open("/dev/null", Sys->ORDWR);
		if(std[n] == nil || std[n].fd != n)
			return sys->sprint("error: cannot open /dev/null for the command: %r");
	}

	# Create pipe for capturing output
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		return sys->sprint("error: cannot create pipe: %r");

	# Spawn command execution
	# Buffered capacity 1: goroutines can complete their send and exit
	# even after the alt has moved on, preventing indefinite blocking.
	result := chan[1] of string;
	ctlch := chan[1] of ref Sys->FD;
	release := chan[1] of int;
	spawn runcommand(cmd, fds[1], result, ctlch, release);
	fds[1] = nil;

	# Hold an already-open capability to the worker's process control. The
	# leader remains alive until cleanup, so descendants cannot make the group
	# unnameable by letting the leader exit first.
	groupctl := <-ctlch;

	# Read output with timeout
	output := "";
	done := 0;

	timeout := chan[1] of int;
	spawn timer(timeout, timeoutms);

	reader := chan[1] of string;
	quit := chan[1] of int;
	spawn readoutput(fds[0], reader, quit);

	# A long output is kept as its start and its end, and the command
	# runs to its finish: cut off at the cap, a build or a test run was
	# killed half way, and its errors, at the end, were lost.
	omitted := 0;
	while(!done) {
		alt {
		s := <-reader =>
			if(s == nil) {
				done = 1;
			} else {
				output += s;
				if(len output > 2 * MAX_OUTPUT) {
					drop := len output - (MAX_OUTPUT - HEAD_OUTPUT);
					omitted += drop - HEAD_OUTPUT;
					output = output[0:HEAD_OUTPUT] + output[drop:];
				}
			}
		<-timeout =>
			output += sys->sprint("\n... (timeout after %d seconds)", timeoutms / 1000);
			done = 1;
		}
	}
	if(len output > MAX_OUTPUT) {
		drop := len output - (MAX_OUTPUT - HEAD_OUTPUT);
		omitted += drop - HEAD_OUTPUT;
		output = output[0:HEAD_OUTPUT] + output[drop:];
	}
	if(omitted > 0)
		output = output[0:HEAD_OUTPUT] +
			sys->sprint("\n... [%d bytes of output left out] ...\n", omitted) +
			output[HEAD_OUTPUT:];

	# Tell the reader nobody is listening.  A command still printing at
	# the timeout left it blocked for good in a send on a full channel,
	# with the pipe: one process and one pipe a timed-out call.
	quit <-= 1;
	fds[0] = nil;

	# Collect the command's exit status.  If it has not finished on its own
	# it is still running after we stopped reading (timeout or output cap):
	# leaving it alive orphans a process outside this tool's accounting.
	# Two abandoned limbo.dis compiles left this way are what faulted the
	# emulator in the escape campaign (INFR-421).  Kill the worker's whole
	# descendant process tree so a command cannot escape cleanup with NEWPGRP;
	# a killed group leader
	# will not report back, so do not block waiting for it.
	err := "";
	finished := 0;
	alt {
	e := <-result =>
		err = e;
		finished = 1;
	* =>
		;
	}
	killed := killtree(groupctl);
	# A leader that could not be killed waited for ever to be: let it go.
	if(!killed)
		release <-= 1;
	if(!finished) {
		if(killed)
			output += "\n... (command still running at return; process tree terminated)";
		else
			output += "\n... (command still running at return; process tree could not be terminated)";
	}

	if(output == "" && err != "")
		return "error: " + err;

	if(err != "")
		output += "\n(exit: " + err + ")";

	if(output == "")
		return "(no output)";

	return output;
}

# Run command in a separate thread with isolated fd group.
# NEWFD prevents dup from affecting other goroutines' stdout/stderr.
runcommand(cmd: string, outfd: ref Sys->FD, result: chan of string, ctlch: chan of ref Sys->FD, release: chan of int)
{
	# Become a process-group leader so the parent can kill this command and
	# everything it spawns as one unit if it overruns its deadline (INFR-421).
	# NEWPGRP returns this proc's pid, which is also the new group id.
	pid := sys->pctl(Sys->NEWPGRP, nil);
	ctl := sys->open("#p/" + string pid + "/ctl", Sys->OWRITE);
	ctlch <-= ctl;
	if(ctl == nil) {
		result <-= sys->sprint("cannot open private process control: %r");
		return;
	}
	ctl = nil;

	# Open this worker's wait channel before NODEVS. The shell normally reaches
	# it through #p or ambient /prog; retaining this one FD lets the namespace
	# hide every process directory, including writable sibling ctl files.
	waitfd := sys->open("#p/" + string pid + "/wait", Sys->OREAD);
	if(waitfd == nil) {
		result <-= sys->sprint("cannot open private wait channel: %r");
		return;
	}
	# The command's descriptors: 0 is the /dev/null capture() opened, 1
	# and 2 are the pipe, and the wait file is the only other.  (0, 1 and
	# 2 were kept from the group all tool calls share.)
	ofd := outfd.fd;
	if(sys->pctl(Sys->NEWFD, 0 :: ofd :: waitfd.fd :: nil) < 0) {
		result <-= sys->sprint("cannot isolate descriptors: %r");
		return;
	}
	if(sys->pctl(Sys->NODEVS, nil) < 0) {
		result <-= sys->sprint("cannot disable device attachment: %r");
		return;
	}

	# Redirect stdout/stderr to pipe; a command with no way to say
	# anything is not run
	if(sys->dup(ofd, 1) != 1 || sys->dup(ofd, 2) != 2) {
		result <-= sys->sprint("cannot set up the command's output: %r");
		return;
	}
	outfd = nil;
	# and not the pipe a third time, under the number it was made with
	if(sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: waitfd.fd :: nil) < 0) {
		result <-= sys->sprint("cannot isolate descriptors: %r");
		return;
	}

	err := sh->systemfd(nil, cmd, waitfd);
	result <-= err;

	# Keep the leader alive until the parent has reaped the whole tree. Drop
	# every descriptor first so the output reader reaches EOF.
	waitfd = nil;
	sys->pctl(Sys->NEWFD, nil);
	<-release;
}

# Kill through the ctl opened before the worker dropped device attachment.
killtree(ctl: ref Sys->FD): int
{
	if(ctl == nil)
		return 0;
	msg := array of byte "killtree";
	return sys->write(ctl, msg, len msg) == len msg;
}

# Timer thread
timer(ch: chan of int, ms: int)
{
	sys->sleep(ms);
	ch <-= 1;
}

# Read output from fd
readoutput(fd: ref Sys->FD, ch: chan of string, quit: chan of int)
{
	buf := array[4096] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		s: string;
		if(n > 0)
			s = string buf[0:n];
		alt {
		ch <-= s =>
			if(n <= 0)
				return;
		<-quit =>
			return;
		}
	}
}

# Convert double quotes to single quotes for Inferno shell compatibility
# Handles: echo "hello world" -> echo 'hello world'
# Also handles escaped quotes and nested cases
convertquotes(s: string): string
{
	result := "";
	i := 0;

	while(i < len s) {
		if(s[i] == '"') {
			# Found double quote - convert to single quote
			# But first check if it's escaped
			if(i > 0 && s[i-1] == '\\') {
				# Escaped quote - keep as literal (remove backslash, keep quote)
				result = result[0:len result - 1] + "'";
				i++;
				continue;
			}

			# Start of double-quoted string - find matching close
			result[len result] = '\'';
			i++;

			# Copy contents until closing double quote
			while(i < len s && s[i] != '"') {
				# Handle single quotes inside - they need escaping in sh
				if(s[i] == '\'') {
					# End single quote, add escaped quote, restart single quote
					result += "'\\''";
				} else {
					result[len result] = s[i];
				}
				i++;
			}

			# Add closing single quote
			if(i < len s && s[i] == '"') {
				result[len result] = '\'';
				i++;
			}
		} else {
			result[len result] = s[i];
			i++;
		}
	}

	return result;
}

# What in a command exec does not take, or nil.
#
# Inferno shell metacharacters (from sh(1) man page):
#   # ; & | ^ $ ` ' { } ( ) < > " =
#
# Command substitution forms in Inferno sh:
#   `{cmd}   — backtick with braces (output split by $ifs)
#   "{cmd}   — double-quote with brace (output as single string)
#   ${name}  — substitution builtin invocation
#   $var     — variable expansion
#   <{cmd}   — process substitution (read end)
#   >{cmd}   — process substitution (write end)
#
# Note: Inferno does NOT support bash's $() syntax or bare backticks.
# Chaining and backgrounding (; | &) are not taken either, so that a call
# is one command that ends with the call.  Quotes are not looked at: a
# quoted ; is refused too, which costs an argument now and then and
# leaves no quoting rule to get wrong.
refused(s: string): string
{
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == '`')
			return "a ` substitution";
		if(c == '$')
			return "a $ variable or substitution";
		if(c == ';')
			return "';' (a second command)";
		if(c == '|')
			return "'|' (a pipe)";
		if(c == '&')
			return "'&'";
		if(c == '\n' || c == '\r')
			return "a second line";
		if((c == '"' || c == '<' || c == '>') && i + 1 < len s && s[i+1] == '{')
			return s[i:i+2] + "} (a substitution)";
	}
	return nil;
}
