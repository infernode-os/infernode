implement Troff;

#
# troff - typesetter
#
# A translation into Limbo of Ali Gholami Rudi's Neatroff
# (https://github.com/aligrudi/neatroff), file by file, so that
# its parts can be followed against the original: in.b is in.c,
# cp.b is cp.c, and so on.  Its output, troff's device-independent
# page description, is byte for byte what Neatroff writes for the
# same input and fonts; tests/host/troff_test.sh keeps it so.
#
# Copyright (C) 2012-2025 Ali Gholami Rudi <ali at rudi dot ir>
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "daytime.m";
	daytime: Daytime;

Troff: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

# where the device descriptions and macro packages live
FDIR:	con "/lib/troff";
MDIR:	con "/lib/tmac";

# array limits, as Neatroff's
NFILES:		con 16;		# input files
NFONTS:		con 32;		# mounted fonts
NFONTSPCL:	con 4;		# font specials
GNLEN:		con 32;		# glyph name length
NMLEN:		con 128;	# macro, register or environment name length
NREGS:		con 8192;	# mapped names
NARGS:		con 32;		# macro arguments
NPREV:		con 16;		# environment stack depth
NTRAPS:		con 1024;	# traps per page
NIES:		con 128;	# nested .ie
NTABS:		con 32;		# tab stops
NCMAPS:		con 512;	# .tr translations
NSSTR:		con 32;		# nested sstr_push()
NFIELDS:	con 32;		# fields
NCHARS:		con 32;		# characters for .eos, .hydash, .hystop
MAXFRAC:	con 100000;	# the largest fraction
NCDEFS:		con 128;	# .char definitions
NHYPHS:		con 16384;	# hyphenation patterns and words
NHYPHSWORD:	con 32;		# hyphenations per word
NHCODES:	con 512;	# .hcode characters
WORDLEN:	con 256;	# word length
NFEATS:		con 128;	# features per font
NSCRPS:		con 64;		# scripts per font
NLANGS:		con 64;		# languages per font

# escape sequences with quoted (\X'ccc') and unquoted (\Xc \X(cc \X[ccc]) arguments
ESC_Q:	con "bCDhHjlLNoRSvwxXZ?";
ESC_P:	con "*fgkmns";

c_ni:	con 4;		# non-interpreted copy-mode escape
c_bp:	con "\\:";	# zero-width word break point
c_nb:	con "\\~";	# stretchable no-break space

# internal requests
TR_DIVBEG:	con "\u0007<";	# a diversion begins
TR_DIVEND:	con "\u0007>";	# a diversion ends
TR_DIVVS:	con "\u0007V";	# the value of \n(.v inside a diversion
TR_POPREN:	con "\u0007P";	# leave render_rec()

# hyphenation flags
HY_LAST:	con 16r02;	# do not hyphenate last lines
HY_FINAL2:	con 16r04;	# do not hyphenate the final two characters
HY_FIRST2:	con 16r08;	# do not hyphenate the first two characters

# adjustment flags
AD_C:	con 16r001;	# centre
AD_L:	con 16r002;	# left
AD_R:	con 16r004;	# right
AD_X:	con 16r007;	# mask for AD_C, AD_L and AD_R
AD_B:	con 16r010;	# both margins
AD_P:	con 16r020;	# whole paragraphs
AD_K:	con 16r040;	# keshideh
AD_Q:	con 16r080;	# the alternative filling algorithm
AD_LN:	con 16r100;	# left in no-fill mode
AD_RN:	con 16r200;	# right in no-fill mode
AD_CN:	con 16r400;	# centre in no-fill mode
AD_XN:	con 16r700;	# mask for AD_CN, AD_LN and AD_RN

# the sources characters are read from (Neatroff's next()/back() pairs)
S_CP, S_CPNONI, S_SSTR, S_REN: con iota;

# special characters
c_ec := '\\';		# escape character
c_cc := '.';		# control character
c_c2 := '\'';		# no-break control character
c_pc := "%";		# page number character

stderr: ref Sys->FD;
bout: ref Iobuf;

# built-in number registers: the ".x" ones are their character
R_a:	con 'a';
R_cp:	con 'C';
R_d:	con 'd';
R_f:	con 'f';
R_h:	con 'h';
R_i:	con 'i';
R_I:	con 'I';
R_j:	con 'j';
R_l:	con 'l';
R_L:	con 'L';
R_n:	con 'n';
R_m:	con 'm';
R_o:	con 'o';
R_p:	con 'p';
R_s:	con 's';
R_u:	con 'u';
R_v:	con 'v';
R_PG:	con '%';	# the number of ejected pages

# and the rest are mapped by regsinit()
R_it, R_itn, R_lsn, R_nI, R_nm, R_nM, R_nn, R_nS, R_mc, R_mcn,
R_ct, R_td, R_cd, R_dl, R_dn, R_ln, R_nl, R_sb, R_st, R_pg,
R_lb, R_ce, R_f0, R_lg, R_hy, R_hycost, R_hycost2, R_hycost3, R_hlm, R_i0,
R_ti, R_kn, R_tI, R_I0, R_l0, R_L0, R_m0, R_mk, R_na, R_ns,
R_o0, R_pmll, R_pmllcost, R_ss, R_sss, R_ssh, R_s0, R_sv, R_lt, R_lt0,
R_v0, R_llx, R_lly, R_urx, R_ury, R_mtp, R_mtes, R_mtek, R_mtep, R_wo: int;

regsinit()
{
	R_it = map(".it");
	R_itn = map(".itn");
	R_lsn = map("lsn");
	R_nI = map(".nI");
	R_nm = map(".nm");
	R_nM = map(".nM");
	R_nn = map(".nn");
	R_nS = map(".nS");
	R_mc = map(".mc");
	R_mcn = map(".mcn");
	R_ct = map("ct");
	R_td = map(".td");
	R_cd = map(".cd");
	R_dl = map("dl");
	R_dn = map("dn");
	R_ln = map("ln");
	R_nl = map("nl");
	R_sb = map("sb");
	R_st = map("st");
	R_pg = map("%");
	R_lb = map(".b0");
	R_ce = map(".ce");
	R_f0 = map(".f0");
	R_lg = map(".lg");
	R_hy = map(".hy");
	R_hycost = map(".hycost");
	R_hycost2 = map(".hycost2");
	R_hycost3 = map(".hycost3");
	R_hlm = map(".hlm");
	R_i0 = map(".i0");
	R_ti = map(".ti");
	R_kn = map(".kn");
	R_tI = map(".tI");
	R_I0 = map(".I0");
	R_l0 = map(".l0");
	R_L0 = map(".L0");
	R_m0 = map(".m0");
	R_mk = map(".mk");
	R_na = map(".na");
	R_ns = map(".ns");
	R_o0 = map(".o0");
	R_pmll = map(".pmll");
	R_pmllcost = map(".pmllcost");
	R_ss = map(".ss");
	R_sss = map(".sss");
	R_ssh = map(".ssh");
	R_s0 = map(".s0");
	R_sv = map(".sv");
	R_lt = map(".lt");
	R_lt0 = map(".lt0");
	R_v0 = map(".v0");
	R_llx = map("bbllx");
	R_lly = map("bblly");
	R_urx = map("bburx");
	R_ury = map("bbury");
	R_mtp = map(".mtp");
	R_mtes = map(".mtes");
	R_mtek = map(".mtek");
	R_mtep = map(".mtep");
	R_wo = map(".wo");
}

# scales
SC_IN(): int
{
	return dev_res;
}

SC_PT(): int
{
	return dev_res / 72;
}

SC_EM(): int
{
	return nr(R_s) * dev_res / 72;
}

include "util.b";
include "dict.b";
include "map.b";
include "clr.b";
include "eval.b";
include "reg.b";
include "in.b";
include "cp.b";
include "char.b";
include "dev.b";
include "font.b";
include "wb.b";
include "fmt.b";
include "ren.b";
include "draw.b";
include "tr.b";
include "out.b";
include "hyph.b";
include "hyen.b";
include "dir.b";

usage := "usage: troff [options] input\n\n" +
	"options:\n" +
	"  -mx   \tinclude macro x\n" +
	"  -rx=y \tset number register x to y\n" +
	"  -dx=y \tdefine string register x as y\n" +
	"  -C    \tenable compatibility mode\n" +
	"  -Tdev \tset output device\n" +
	"  -Fdir \tset font directory (" + FDIR + ")\n" +
	"  -Mdir \tset macro directory (" + MDIR + ")\n";

# parse the argument of -r and -d
cmddef(arg: string): (int, string)
{
	eq := strchr(arg, '=');
	if(eq >= 0){
		n := eq;
		if(n > NMLEN - 1)
			n = NMLEN - 1;
		return (map(arg[0:n]), arg[eq+1:]);
	}
	if(arg == nil)
		return (map(""), "");
	return (map(arg[0:1]), arg[1:]);
}

readable(path: string): int
{
	fd := sys->open(path, Sys->OREAD);
	return fd != nil;
}

# find the macro package named by -m
cmdmac(dir, arg: string): int
{
	path := dir + "/" + arg + ".tmac";
	if(!readable(path))
		path = dir + "/tmac." + arg;
	if(!readable(path))
		path = dir + "/" + arg;
	if(!readable(path))
		return 1;
	in_queue(path);
	return 0;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	{
		troff(args);
	} exception e {
	"fail:*" =>
		if(bout != nil)
			bout.flush();
		raise e;
	"*" =>
		# where C would crash: said, and failed (a Broken program keeps emu alive)
		if(bout != nil)
			bout.flush();
		sys->fprint(stderr, "troff: %s\n", e);
		raise "fail:" + e;
	}
}

troff(args: list of string)
{
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil){
		sys->fprint(stderr, "troff: cannot load %s: %r\n", Bufio->PATH);
		raise "fail:load";
	}
	daytime = load Daytime Daytime->PATH;
	esc_arg = cset("CDfhmsvXx<>");
	esc_p = cset(ESC_P);
	esc_q = cset(ESC_Q);
	esc_ren = cset(" bCcDdefHhjkLlmNoprSsuvXxZz0^|!{}&/,<>");
	bout = bufio->fopen(sys->fildes(1), Bufio->OWRITE);
	fdir := FDIR;
	mdir := MDIR;
	dev := "utf";
	nreginit();
	regsinit();
	if(args != nil)
		args = tl args;
	for(; args != nil; args = tl args){
		a := hd args;
		if(len a < 2 || a[0] != '-')
			break;
		val := a[2:];
		case a[1] {
		'C' =>
			nrset(R_cp, 1);
		'm' =>
			if(strchr(val, '/') >= 0 || (cmdmac(mdir, val) && cmdmac(".", val)))
				in_queue(val);
		'r' or 'd' or 'F' or 'M' or 'T' =>
			if(val == nil && tl args != nil){
				args = tl args;
				val = hd args;
			}
			case a[1] {
			'r' =>
				(reg, def) := cmddef(val);
				nrset(reg, eval_re(def, nr(reg), 'u'));
			'd' =>
				(reg, def) := cmddef(val);
				str_set(reg, def);
			'F' =>
				fdir = val;
			'M' =>
				mdir = val;
			'T' =>
				dev = val;
			}
		* =>
			sys->fprint(stderr, "%s", usage);
			raise "fail:usage";
		}
	}
	if(dev_open(fdir, dev)){
		bout.flush();
		sys->fprint(stderr, "troff: cannot open device %s\n", dev);
		raise "fail:device";
	}
	hyph_init();
	env_init();
	tr_init();
	if(args == nil)
		in_queue(nil);	# standard input
	for(; args != nil; args = tl args)
		if(hd args == "-")
			in_queue(nil);
		else
			in_queue(hd args);
	out(sys->sprint("s%d\n", nr(R_s)));
	out(sys->sprint("f%d\n", nr(R_f)));
	ret := render();
	out(sys->sprint("V%d\n", nr(R_p)));
	dev_close();
	bout.flush();
	if(ret)
		raise "fail:aborted";
}
