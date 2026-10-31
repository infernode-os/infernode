implement Dictm;

# Oxford English Dictionary, second edition, in the tagged
# form Plan 9's dict reads (/lib/dict/oed2).  A port of
# Plan 9's /sys/src/cmd/dict/oed.c.

include "draw.m";
include "sys.m";
	sys: Sys;
	sprint: import sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "utils.m";
	utils: Utils;
	outrune, outrunes, outnl, Assoc, changett, outinhibit,
	lookassoc, liglookup, debug, err: import utils;
include "dictm.m";

bdict, bout: ref Iobuf;

init(b: Bufio, u: Utils, bd, bo: ref Iobuf)
{
	sys = load Sys Sys->PATH;
	bufio = b;
	bdict = bd;
	bout = bo;
	utils = u;
}

Buflen: con 1000;
Maxaux: con 5;

#  Runes for special purposes (0xe800-0xfdff is Private Use Area);
#  must agree with utils.b.
NONE: con 16re800;
TAGS, TAGE, SPCS, PAR, LIGS: con NONE+1+iota;
LACU, LGRV, LUML, LCED, LTIL, LBRV, LRNG, LDOT, LDTB, LFRN, LFRB, LOGO, LMAC,
LHCK, LASP, LLEN, LBRB, LIGE, MULTI: con LIGS+iota;
MAAS, MALN, MAND, MAOQ, MBRA, MDD, MDDD, MEAS, MELN, MEMM, MHAS, MHLN,
MIAS, MILN, MLCT, MLFF, MLFFI, MLFFL, MLFL, MLFI, MLLS, MLST, MOAS, MOLN, MOR,
MRAS, MRLN, MTT, MUAS, MULN, MWAS, MWLN, MOE, MES, MULTIE: con MULTI+iota;

multitab := array[] of {
	"ʽα", "ʼα", "and", "a/q", "<|", "..", "...", "ʽε", "ʼε", "——",
	"ʽη", "ʼη", "ʽι", "ʼι", "ct", "ff", "ffi", "ffl", "fl", "fi",
	"ɫɫ", "st", "ʽο", "ʼο", "or", "ʽρ", "ʼρ", "~~", "ʽυ", "ʼυ",
	"ʽω", "ʼω", "oe", "  ",
};

# Possible tags
A	# author in quote (small caps)
, B	# bold
, Ba	# author inside bib
, Bch	# builtup chem component
, Bib	# surrounds word 'in' for bibliographic ref
, Bl	# bold
, Bo	# bond over
, Bu	# bond under
, Cb	# ? block of stuff (indent)
, Cf	# cross ref to another entry (italics)
, Chem	# chemistry formula
, Co	# over (preceding sum, integral, etc.)
, Col	# column of table (aux just may be r)
, Cu	# under (preceding sum, integral, etc.)
, Dat	# date
, Db	# def block? indent
, Dn	# denominator of fraction
, E	# main entry
, Ed	# editor's comments (in [...])
, Etym	# etymology (in [...])
, Fq	# frequency count (superscript)
, Form	# formula
, Fr	# fraction (contains <nu>, then <dn>)
, Gk	# greek (transliteration)
, Gr	# grammar? (e.g., around 'pa.' in 'pa. pple.')
, Hg	# headword group
, Hm	# homonym (superscript)
, Hw	# headword (bold)
, I	# italics
, Il	# italic list?
, In	# inferior (subscript)
, L	# row of col of table
, La	# status or usage label (italic)
, Lc	# chapter/verse sort of thing for works
, N	# note (smaller type)
, Nu	# numerator of fraction
, Ov	# needs overline
, P	# paragraph (indent)
, Ph	# pronunciation (transliteration)
, Pi	# pile (frac without line)
, Pqp	# subblock of quote
, Pr	# pronunciation (in (...))
, Ps	# position (e.g., adv.) (italic)
, Pt	# part (in lc)
, Q	# quote in quote block
, Qd	# quote date (bold)
, Qig	# quote number (greek)
, Qla	# status or usage label in quote (italic)
, Qp	# quote block (small type, indent)
, Qsn	# quote number
, Qt	# quote words
, R	# roman type style
, Rx	# relative cross reference (e.g., next)
, S	# another form? (italic)
, S0	# sense (sometimes surrounds several sx's)
, S1	# sense (aux num: indented bold letter)
, S2	# sense (aux num: indented bold capital rom num)
, S3	# sense (aux num: indented number of asterisks)
, S4	# sense (aux num: indented bold number)
, S5	# sense (aux num: indented number of asterisks)
, S6	# subsense (aux num: bold letter)
, S7a	# subsense (aux num: letter)
, S7n	# subsense (aux num: roman numeral)
, Sc	# small caps
, Sgk	# subsense (aux num: transliterated greek)
, Sn	# sense of subdefinition (aux num: roman letter)
, Ss	# sans serif
, Ssb	# sans serif bold
, Ssi	# sans serif italic
, Su	# superior (superscript)
, Sub	# subdefinition
, Table	# table (aux cols=number of columns)
, Tt	# title? (italics)
, Vd	# numeric label for variant form
, Ve	# variant entry
, Vf	# variant form (light bold)
, Vfl	# list of vf's (starts with Also or Forms)
, W	# work (e.g., Beowulf) (italics)
, X	# cross reference to main word (small caps)
, Xd	# cross reference to quotation by date
, Xi	# internal cross reference ? (italic)
, Xid	# cross reference identifer, in quote ?
, Xs	# cross reference sense (lower number)
, Xr	# list of x's
, Ntag: con iota;

tagtab := array[] of {
	Assoc("a",	A),
	Assoc("b",	B),
	Assoc("ba",	Ba),
	Assoc("bch",	Bch),
	Assoc("bib",	Bib),
	Assoc("bl",	Bl),
	Assoc("bo",	Bo),
	Assoc("bu",	Bu),
	Assoc("cb",	Cb),
	Assoc("cf",	Cf),
	Assoc("chem",	Chem),
	Assoc("co",	Co),
	Assoc("col",	Col),
	Assoc("cu",	Cu),
	Assoc("dat",	Dat),
	Assoc("db",	Db),
	Assoc("dn",	Dn),
	Assoc("e",	E),
	Assoc("ed",	Ed),
	Assoc("et",	Etym),
	Assoc("etym",	Etym),
	Assoc("form",	Form),
	Assoc("fq",	Fq),
	Assoc("fr",	Fr),
	Assoc("frac",	Fr),
	Assoc("gk",	Gk),
	Assoc("gr",	Gr),
	Assoc("hg",	Hg),
	Assoc("hm",	Hm),
	Assoc("hw",	Hw),
	Assoc("i",	I),
	Assoc("il",	Il),
	Assoc("in",	In),
	Assoc("l",	L),
	Assoc("la",	La),
	Assoc("lc",	Lc),
	Assoc("n",	N),
	Assoc("nu",	Nu),
	Assoc("ov",	Ov),
	Assoc("p",	P),
	Assoc("ph",	Ph),
	Assoc("pi",	Pi),
	Assoc("pqp",	Pqp),
	Assoc("pr",	Pr),
	Assoc("ps",	Ps),
	Assoc("pt",	Pt),
	Assoc("q",	Q),
	Assoc("qd",	Qd),
	Assoc("qig",	Qig),
	Assoc("qla",	Qla),
	Assoc("qp",	Qp),
	Assoc("qsn",	Qsn),
	Assoc("qt",	Qt),
	Assoc("r",	R),
	Assoc("rx",	Rx),
	Assoc("s",	S),
	Assoc("s0",	S0),
	Assoc("s1",	S1),
	Assoc("s2",	S2),
	Assoc("s3",	S3),
	Assoc("s4",	S4),
	Assoc("s5",	S5),
	Assoc("s6",	S6),
	Assoc("s7a",	S7a),
	Assoc("s7n",	S7n),
	Assoc("sc",	Sc),
	Assoc("sgk",	Sgk),
	Assoc("sn",	Sn),
	Assoc("ss",	Ss),
	Assoc("ssb",	Ssb),
	Assoc("ssi",	Ssi),
	Assoc("su",	Su),
	Assoc("sub",	Sub),
	Assoc("table",	Table),
	Assoc("tt",	Tt),
	Assoc("vd",	Vd),
	Assoc("ve",	Ve),
	Assoc("vf",	Vf),
	Assoc("vfl",	Vfl),
	Assoc("w",	W),
	Assoc("x",	X),
	Assoc("xd",	Xd),
	Assoc("xi",	Xi),
	Assoc("xid",	Xid),
	Assoc("xr",	Xr),
	Assoc("xs",	Xs),
};

spectab := array[] of {
	Assoc("3on4",	16rbe),
	Assoc("Aacu",	16rc1),
	Assoc("Aang",	16rc5),
	Assoc("Abarab",	16r100),
	Assoc("Acirc",	16rc2),
	Assoc("Ae",	16rc6),
	Assoc("Agrave",	16rc0),
	Assoc("Alpha",	16r391),
	Assoc("Amac",	16r100),
	Assoc("Asg",	16r1b7),	# Unicyle. Cf "Sake"
	Assoc("Auml",	16rc4),
	Assoc("Beta",	16r392),
	Assoc("Cced",	16rc7),
	Assoc("Chacek",	16r10c),
	Assoc("Chi",	16r3a7),
	Assoc("Chirho",	16r2627),	# Chi Rho U+2627
	Assoc("Csigma",	16r3da),
	Assoc("Delta",	16r394),
	Assoc("Eacu",	16rc9),
	Assoc("Ecirc",	16rca),
	Assoc("Edh",	16rd0),
	Assoc("Epsilon",	16r395),
	Assoc("Eta",	16r397),
	Assoc("Gamma",	16r393),
	Assoc("Iacu",	16rcd),
	Assoc("Icirc",	16rce),
	Assoc("Imac",	16r12a),
	Assoc("Integ",	16r222b),
	Assoc("Iota",	16r399),
	Assoc("Kappa",	16r39a),
	Assoc("Koppa",	16r3de),
	Assoc("Lambda",	16r39b),
	Assoc("Lbar",	16r141),
	Assoc("Mu",	16r39c),
	Assoc("Naira",	16r4e),	# should have bar through
	Assoc("Nplus",	16r4e),	# should have plus above
	Assoc("Ntilde",	16rd1),
	Assoc("Nu",	16r39d),
	Assoc("Oacu",	16rd3),
	Assoc("Obar",	16rd8),
	Assoc("Ocirc",	16rd4),
	Assoc("Oe",	16r152),
	Assoc("Omega",	16r3a9),
	Assoc("Omicron",	16r39f),
	Assoc("Ouml",	16rd6),
	Assoc("Phi",	16r3a6),
	Assoc("Pi",	16r3a0),
	Assoc("Psi",	16r3a8),
	Assoc("Rho",	16r3a1),
	Assoc("Sacu",	16r15a),
	Assoc("Sigma",	16r3a3),
	Assoc("Summ",	16r2211),
	Assoc("Tau",	16r3a4),
	Assoc("Th",	16rde),
	Assoc("Theta",	16r398),
	Assoc("Tse",	16r426),
	Assoc("Uacu",	16rda),
	Assoc("Ucirc",	16rdb),
	Assoc("Upsilon",	16r3a5),
	Assoc("Uuml",	16rdc),
	Assoc("Wyn",	16r1bf),	# wynn U+01BF
	Assoc("Xi",	16r39e),
	Assoc("Ygh",	16r1b7),	# Yogh	U+01B7
	Assoc("Zeta",	16r396),
	Assoc("Zh",	16r1b7),	# looks like Yogh. Cf "Sake"
	Assoc("a",	16r61),	# ante
	Assoc("aacu",	16re1),
	Assoc("aang",	16re5),
	Assoc("aasper",	MAAS),
	Assoc("abreve",	16r103),
	Assoc("acirc",	16re2),
	Assoc("acu",	LACU),
	Assoc("ae",	16re6),
	Assoc("agrave",	16re0),
	Assoc("ahook",	16r105),
	Assoc("alenis",	MALN),
	Assoc("alpha",	16r3b1),
	Assoc("amac",	16r101),
	Assoc("amp",	16r26),
	Assoc("and",	MAND),
	Assoc("ang",	LRNG),
	Assoc("angle",	16r2220),
	Assoc("ankh",	16r2625),	# ankh U+2625
	Assoc("ante",	16r61),	# before (year)
	Assoc("aonq",	MAOQ),
	Assoc("appreq",	16r2243),
	Assoc("aquar",	16r2652),
	Assoc("arDadfull",	16r636),	# Dad U+0636
	Assoc("arHa",	16r62d),	# haa U+062D
	Assoc("arTa",	16r62a),	# taa U+062A
	Assoc("arain",	16r639),	# ain U+0639
	Assoc("arainfull",	16r639),	# ain U+0639
	Assoc("aralif",	16r627),	# alef U+0627
	Assoc("arba",	16r628),	# baa U+0628
	Assoc("arha",	16r647),	# ha U+0647
	Assoc("aries",	16r2648),
	Assoc("arnun",	16r646),	# noon U+0646
	Assoc("arnunfull",	16r646),	# noon U+0646
	Assoc("arpa",	16r647),	# ha U+0647
	Assoc("arqoph",	16r642),	# qaf U+0642
	Assoc("arshinfull",	16r634),	# sheen U+0634
	Assoc("arta",	16r62a),	# taa U+062A
	Assoc("artafull",	16r62a),	# taa U+062A
	Assoc("artha",	16r62b),	# thaa U+062B
	Assoc("arwaw",	16r648),	# waw U+0648
	Assoc("arya",	16r64a),	# ya U+064A
	Assoc("aryafull",	16r64a),	# ya U+064A
	Assoc("arzero",	16r660),	# indic zero U+0660
	Assoc("asg",	16r292),	# unicycle character. Cf "hallow"
	Assoc("asper",	LASP),
	Assoc("assert",	16r22a2),
	Assoc("astm",	16r2042),	# asterism: should be upside down
	Assoc("at",	16r40),
	Assoc("atilde",	16re3),
	Assoc("auml",	16re4),
	Assoc("ayin",	16r639),	# arabic ain U+0639
	Assoc("b1",	16r2d),	# single bond
	Assoc("b2",	16r3d),	# double bond
	Assoc("b3",	16r2261),	# triple bond
	Assoc("bbar",	16r180),	# b with bar U+0180
	Assoc("beta",	16r3b2),
	Assoc("bigobl",	16r2f),
	Assoc("blC",	16r43),	# should be black letter
	Assoc("blJ",	16r4a),	# should be black letter
	Assoc("blU",	16r55),	# should be black letter
	Assoc("blb",	16r62),	# should be black letter
	Assoc("blozenge",	16r25ca),	# U+25CA; should be black
	Assoc("bly",	16r79),	# should be black letter
	Assoc("bra",	MBRA),
	Assoc("brbl",	LBRB),
	Assoc("breve",	LBRV),
	Assoc("bslash",	'\\'),
	Assoc("bsquare",	16r25a0),	# black square U+25A0
	Assoc("btril",	16r25c0),	# U+25C0
	Assoc("btrir",	16r25b6),	# U+25B6
	Assoc("c",	16r63),	# circa
	Assoc("cab",	16r232a),
	Assoc("cacu",	16r107),
	Assoc("canc",	16r264b),
	Assoc("capr",	16r2651),
	Assoc("caret",	16r5e),
	Assoc("cb",	16r7d),
	Assoc("cbigb",	16r7d),
	Assoc("cbigpren",	16r29),
	Assoc("cbigsb",	16r5d),
	Assoc("cced",	16re7),
	Assoc("cdil",	LCED),
	Assoc("cdsb",	16r301b),	# ]] U+301b
	Assoc("cent",	16ra2),
	Assoc("chacek",	16r10d),
	Assoc("chi",	16r3c7),
	Assoc("circ",	LRNG),
	Assoc("circa",	16r63),	# about (year)
	Assoc("circbl",	16r325),	# ring below accent U+0325
	Assoc("circle",	16r25cb),	# U+25CB
	Assoc("circledot",	16r2299),
	Assoc("click",	16r296),
	Assoc("club",	16r2663),
	Assoc("comtime",	16r43),
	Assoc("conj",	16r260c),
	Assoc("cprt",	16ra9),
	Assoc("cq",	'\''),
	Assoc("cqq",	16r201d),
	Assoc("cross",	16r2720),	# maltese cross U+2720
	Assoc("crotchet",	16r2669),
	Assoc("csb",	16r5d),
	Assoc("ctilde",	16r63),	# +tilde
	Assoc("ctlig",	MLCT),
	Assoc("cyra",	16r430),
	Assoc("cyre",	16r435),
	Assoc("cyrhard",	16r44a),
	Assoc("cyrjat",	16r463),
	Assoc("cyrm",	16r43c),
	Assoc("cyrn",	16r43d),
	Assoc("cyrr",	16r440),
	Assoc("cyrsoft",	16r44c),
	Assoc("cyrt",	16r442),
	Assoc("cyry",	16r44b),
	Assoc("dag",	16r2020),
	Assoc("dbar",	16r111),
	Assoc("dblar",	16r21cb),
	Assoc("dblgt",	16r226b),
	Assoc("dbllt",	16r226a),
	Assoc("dced",	16r64),	# +cedilla
	Assoc("dd",	MDD),
	Assoc("ddag",	16r2021),
	Assoc("ddd",	MDDD),
	Assoc("decr",	16r2193),
	Assoc("deg",	16rb0),
	Assoc("dele",	16r64),	# should be dele
	Assoc("delta",	16r3b4),
	Assoc("descnode",	16r260b),	# descending node U+260B
	Assoc("diamond",	16r2662),
	Assoc("digamma",	16r3dd),
	Assoc("div",	16rf7),
	Assoc("dlessi",	16r131),
	Assoc("dlessj1",	16r6a),	# should be dotless
	Assoc("dlessj2",	16r6a),	# should be dotless
	Assoc("dlessj3",	16r6a),	# should be dotless
	Assoc("dollar",	16r24),
	Assoc("dotab",	LDOT),
	Assoc("dotbl",	LDTB),
	Assoc("drachm",	16r292),
	Assoc("dubh",	16r2d),
	Assoc("eacu",	16re9),
	Assoc("earth",	16r2641),
	Assoc("easper",	MEAS),
	Assoc("ebreve",	16r115),
	Assoc("ecirc",	16rea),
	Assoc("edh",	16rf0),
	Assoc("egrave",	16re8),
	Assoc("ehacek",	16r11b),
	Assoc("ehook",	16r119),
	Assoc("elem",	16r220a),
	Assoc("elenis",	MELN),
	Assoc("em",	16r2014),
	Assoc("emac",	16r113),
	Assoc("emem",	MEMM),
	Assoc("en",	16r2013),
	Assoc("epsilon",	16r3b5),
	Assoc("equil",	16r21cb),
	Assoc("ergo",	16r2234),
	Assoc("es",	MES),
	Assoc("eszett",	16rdf),
	Assoc("eta",	16r3b7),
	Assoc("eth",	16rf0),
	Assoc("euml",	16reb),
	Assoc("expon",	16r2191),
	Assoc("fact",	16r21),
	Assoc("fata",	16r251),
	Assoc("fatpara",	16rb6),	# should have fatter, filled in bowl
	Assoc("female",	16r2640),
	Assoc("ffilig",	MLFFI),
	Assoc("fflig",	MLFF),
	Assoc("ffllig",	MLFFL),
	Assoc("filig",	MLFI),
	Assoc("flat",	16r266d),
	Assoc("fllig",	MLFL),
	Assoc("frE",	16r45),	# should be curly
	Assoc("frL",	'L'),	# should be curly
	Assoc("frR",	16r52),	# should be curly
	Assoc("frakB",	16r42),	# should have fraktur style
	Assoc("frakG",	16r47),
	Assoc("frakH",	16r48),
	Assoc("frakI",	16r49),
	Assoc("frakM",	16r4d),
	Assoc("frakU",	16r55),
	Assoc("frakX",	16r58),
	Assoc("frakY",	16r59),
	Assoc("frakh",	16r68),
	Assoc("frbl",	LFRB),
	Assoc("frown",	LFRN),
	Assoc("fs",	16r20),
	Assoc("fsigma",	16r3c2),
	Assoc("gAacu",	16rc1),	# should be Α+acute
	Assoc("gaacu",	16r3b1),	# +acute
	Assoc("gabreve",	16r3b1),	# +breve
	Assoc("gafrown",	16r3b1),	# +frown
	Assoc("gagrave",	16r3b1),	# +grave
	Assoc("gamac",	16r3b1),	# +macron
	Assoc("gamma",	16r3b3),
	Assoc("gauml",	16r3b1),	# +umlaut
	Assoc("ge",	16r2267),
	Assoc("geacu",	16r3b5),	# +acute
	Assoc("gegrave",	16r3b5),	# +grave
	Assoc("ghacu",	16r3b7),	# +acute
	Assoc("ghfrown",	16r3b7),	# +frown
	Assoc("ghgrave",	16r3b7),	# +grave
	Assoc("ghmac",	16r3b7),	# +macron
	Assoc("giacu",	16r3b9),	# +acute
	Assoc("gibreve",	16r3b9),	# +breve
	Assoc("gifrown",	16r3b9),	# +frown
	Assoc("gigrave",	16r3b9),	# +grave
	Assoc("gimac",	16r3b9),	# +macron
	Assoc("giuml",	16r3b9),	# +umlaut
	Assoc("glagjat",	16r467),
	Assoc("glots",	16r2c0),
	Assoc("goacu",	16r3bf),	# +acute
	Assoc("gobreve",	16r3bf),	# +breve
	Assoc("grave",	LGRV),
	Assoc("gt",	16r3e),
	Assoc("guacu",	16r3c5),	# +acute
	Assoc("gufrown",	16r3c5),	# +frown
	Assoc("gugrave",	16r3c5),	# +grave
	Assoc("gumac",	16r3c5),	# +macron
	Assoc("guuml",	16r3c5),	# +umlaut
	Assoc("gwacu",	16r3c9),	# +acute
	Assoc("gwfrown",	16r3c9),	# +frown
	Assoc("gwgrave",	16r3c9),	# +grave
	Assoc("hacek",	LHCK),
	Assoc("halft",	16r2308),
	Assoc("hash",	16r23),
	Assoc("hasper",	MHAS),
	Assoc("hatpath",	16r5b2),	# hataf patah U+05B2
	Assoc("hatqam",	16r5b3),	# hataf qamats U+05B3
	Assoc("hatseg",	16r5b1),	# hataf segol U+05B1
	Assoc("hbar",	16r127),
	Assoc("heart",	16r2661),
	Assoc("hebaleph",	16r5d0),	# aleph U+05D0
	Assoc("hebayin",	16r5e2),	# ayin U+05E2
	Assoc("hebbet",	16r5d1),	# bet U+05D1
	Assoc("hebbeth",	16r5d1),	# bet U+05D1
	Assoc("hebcheth",	16r5d7),	# bet U+05D7
	Assoc("hebdaleth",	16r5d3),	# dalet U+05D3
	Assoc("hebgimel",	16r5d2),	# gimel U+05D2
	Assoc("hebhe",	16r5d4),	# he U+05D4
	Assoc("hebkaph",	16r5db),	# kaf U+05DB
	Assoc("heblamed",	16r5dc),	# lamed U+05DC
	Assoc("hebmem",	16r5de),	# mem U+05DE
	Assoc("hebnun",	16r5e0),	# nun U+05E0
	Assoc("hebnunfin",	16r5df),	# final nun U+05DF
	Assoc("hebpe",	16r5e4),	# pe U+05E4
	Assoc("hebpedag",	16r5e3),	# final pe? U+05E3
	Assoc("hebqoph",	16r5e7),	# qof U+05E7
	Assoc("hebresh",	16r5e8),	# resh U+05E8
	Assoc("hebshin",	16r5e9),	# shin U+05E9
	Assoc("hebtav",	16r5ea),	# tav U+05EA
	Assoc("hebtsade",	16r5e6),	# tsadi U+05E6
	Assoc("hebwaw",	16r5d5),	# vav? U+05D5
	Assoc("hebyod",	16r5d9),	# yod U+05D9
	Assoc("hebzayin",	16r5d6),	# zayin U+05D6
	Assoc("hgz",	16r292),	# ??? Cf "alet"
	Assoc("hireq",	16r5b4),	# U+05B4
	Assoc("hlenis",	MHLN),
	Assoc("hook",	LOGO),
	Assoc("horizE",	16r45),	# should be on side
	Assoc("horizP",	16r50),	# should be on side
	Assoc("horizS",	16r223d),
	Assoc("horizT",	16r22a3),
	Assoc("horizb",	16r7b),	# should be underbrace
	Assoc("ia",	16r3b1),
	Assoc("iacu",	16red),
	Assoc("iasper",	MIAS),
	Assoc("ib",	16r3b2),
	Assoc("ibar",	16r268),
	Assoc("ibreve",	16r12d),
	Assoc("icirc",	16ree),
	Assoc("id",	16r3b4),
	Assoc("ident",	16r2261),
	Assoc("ie",	16r3b5),
	Assoc("ifilig",	MLFI),
	Assoc("ifflig",	MLFF),
	Assoc("ig",	16r3b3),
	Assoc("igrave",	16rec),
	Assoc("ih",	16r3b7),
	Assoc("ii",	16r3b9),
	Assoc("ik",	16r3ba),
	Assoc("ilenis",	MILN),
	Assoc("imac",	16r12b),
	Assoc("implies",	16r21d2),
	Assoc("index",	16r261e),
	Assoc("infin",	16r221e),
	Assoc("integ",	16r222b),
	Assoc("intsec",	16r2229),
	Assoc("invpri",	16r2cf),
	Assoc("iota",	16r3b9),
	Assoc("iq",	16r3c8),
	Assoc("istlig",	MLST),
	Assoc("isub",	16r3f5),	# iota below accent
	Assoc("iuml",	16ref),
	Assoc("iz",	16r3b6),
	Assoc("jup",	16r2643),
	Assoc("kappa",	16r3ba),
	Assoc("koppa",	16r3df),
	Assoc("lambda",	16r3bb),
	Assoc("lar",	16r2190),
	Assoc("lbar",	16r142),
	Assoc("le",	16r2266),
	Assoc("lenis",	LLEN),
	Assoc("leo",	16r264c),
	Assoc("lhalfbr",	16r2308),
	Assoc("lhshoe",	16r2283),
	Assoc("libra",	16r264e),
	Assoc("llswing",	MLLS),
	Assoc("lm",	16r2d0),
	Assoc("logicand",	16r2227),
	Assoc("logicor",	16r2228),
	Assoc("longs",	16r283),
	Assoc("lrar",	16r2194),
	Assoc("lt",	16r3c),
	Assoc("ltappr",	16r227e),
	Assoc("ltflat",	16r2220),
	Assoc("lumlbl",	16r6c),	# +umlaut below
	Assoc("mac",	LMAC),
	Assoc("male",	16r2642),
	Assoc("mc",	16r63),	# should be raised
	Assoc("merc",	16r263f),	# mercury U+263F
	Assoc("min",	16r2212),
	Assoc("moonfq",	16r263d),	# first quarter moon U+263D
	Assoc("moonlq",	16r263e),	# last quarter moon U+263E
	Assoc("msylab",	16r6d),	# +sylab (ˌ)
	Assoc("mu",	16r3bc),
	Assoc("nacu",	16r144),
	Assoc("natural",	16r266e),
	Assoc("neq",	16r2260),
	Assoc("nfacu",	16r2032),
	Assoc("nfasper",	16r2bd),
	Assoc("nfbreve",	16r2d8),
	Assoc("nfced",	16rb8),
	Assoc("nfcirc",	16r2c6),
	Assoc("nffrown",	16r2322),
	Assoc("nfgra",	16r2cb),
	Assoc("nfhacek",	16r2c7),
	Assoc("nfmac",	16raf),
	Assoc("nftilde",	16r2dc),
	Assoc("nfuml",	16ra8),
	Assoc("ng",	16r14b),
	Assoc("not",	16rac),
	Assoc("notelem",	16r2209),
	Assoc("ntilde",	16rf1),
	Assoc("nu",	16r3bd),
	Assoc("oab",	16r2329),
	Assoc("oacu",	16rf3),
	Assoc("oasper",	MOAS),
	Assoc("ob",	16r7b),
	Assoc("obar",	16rf8),
	Assoc("obigb",	16r7b),	# should be big
	Assoc("obigpren",	16r28),
	Assoc("obigsb",	16r5b),	# should be big
	Assoc("obreve",	16r14f),
	Assoc("ocirc",	16rf4),
	Assoc("odsb",	16r301a),	# [[ U+301A
	Assoc("oe",	16r153),
	Assoc("oeamp",	16r26),
	Assoc("ograve",	16rf2),
	Assoc("ohook",	16r6f),	# +hook
	Assoc("olenis",	MOLN),
	Assoc("omac",	16r14d),
	Assoc("omega",	16r3c9),
	Assoc("omicron",	16r3bf),
	Assoc("ope",	16r25b),
	Assoc("opp",	16r260d),
	Assoc("oq",	16r60),
	Assoc("oqq",	16r201c),
	Assoc("or",	MOR),
	Assoc("osb",	16r5b),
	Assoc("otilde",	16rf5),
	Assoc("ouml",	16rf6),
	Assoc("ounce",	16r2125),	# ounce U+2125
	Assoc("ovparen",	16r2322),	# should be sideways (
	Assoc("p",	16r2032),
	Assoc("pa",	16r2202),
	Assoc("page",	16r50),
	Assoc("pall",	16r28e),
	Assoc("paln",	16r272),
	Assoc("par",	PAR),
	Assoc("para",	16rb6),
	Assoc("pbar",	16r70),	# +bar
	Assoc("per",	16r2118),	# per U+2118
	Assoc("phi",	16r3c6),
	Assoc("phi2",	16r3d5),
	Assoc("pi",	16r3c0),
	Assoc("pisces",	16r2653),
	Assoc("planck",	16r127),
	Assoc("plantinJ",	16r4a),	# should be script
	Assoc("pm",	16rb1),
	Assoc("pmil",	16r2030),
	Assoc("pp",	16r2033),
	Assoc("ppp",	16r2034),
	Assoc("prop",	16r221d),
	Assoc("psi",	16r3c8),
	Assoc("pstlg",	16ra3),
	Assoc("q",	16r3f),	# should be raised
	Assoc("qamets",	16r5b3),	# U+05B3
	Assoc("quaver",	16r266a),
	Assoc("rar",	16r2192),
	Assoc("rasper",	MRAS),
	Assoc("rdot",	16rb7),
	Assoc("recipe",	16r211e),	# U+211E
	Assoc("reg",	16rae),
	Assoc("revC",	16r186),	# open O U+0186
	Assoc("reva",	16r252),
	Assoc("revc",	16r254),
	Assoc("revope",	16r25c),
	Assoc("revr",	16r279),
	Assoc("revsc",	16r2d2),	# upside-down semicolon
	Assoc("revv",	16r28c),
	Assoc("rfa",	16r6f),	# +hook (Cf "goal")
	Assoc("rhacek",	16r159),
	Assoc("rhalfbr",	16r2309),
	Assoc("rho",	16r3c1),
	Assoc("rhshoe",	16r2282),
	Assoc("rlenis",	MRLN),
	Assoc("rsylab",	16r72),	# +sylab
	Assoc("runash",	16r46),	# should be runic 'ash'
	Assoc("rvow",	16r2d4),
	Assoc("sacu",	16r15b),
	Assoc("sagit",	16r2650),
	Assoc("sampi",	16r3e1),
	Assoc("saturn",	16r2644),
	Assoc("sced",	16r15f),
	Assoc("schwa",	16r259),
	Assoc("scorpio",	16r264f),
	Assoc("scrA",	16r41),	# should be script
	Assoc("scrC",	16r43),
	Assoc("scrE",	16r45),
	Assoc("scrF",	16r46),
	Assoc("scrI",	16r49),
	Assoc("scrJ",	16r4a),
	Assoc("scrL",	'L'),
	Assoc("scrO",	16r4f),
	Assoc("scrP",	16r50),
	Assoc("scrQ",	16r51),
	Assoc("scrS",	16r53),
	Assoc("scrT",	16r54),
	Assoc("scrb",	16r62),
	Assoc("scrd",	16r64),
	Assoc("scrh",	16r68),
	Assoc("scrl",	16r6c),
	Assoc("scruple",	16r2108),	# U+2108
	Assoc("sdd",	16r2d0),
	Assoc("sect",	16ra7),
	Assoc("semE",	16r2203),
	Assoc("sh",	16r283),
	Assoc("shacek",	16r161),
	Assoc("sharp",	16r266f),
	Assoc("sheva",	16r5b0),	# U+05B0
	Assoc("shti",	16r26a),
	Assoc("shtsyll",	16r222a),
	Assoc("shtu",	16r28a),
	Assoc("sidetri",	16r22b2),
	Assoc("sigma",	16r3c3),
	Assoc("since",	16r2235),
	Assoc("slge",	16r2265),	# should have slanted line under
	Assoc("slle",	16r2264),	# should have slanted line under
	Assoc("sm",	16r2c8),
	Assoc("smm",	16r2cc),
	Assoc("spade",	16r2660),
	Assoc("sqrt",	16r221a),
	Assoc("square",	16r25a1),	# U+25A1
	Assoc("ssChi",	16r3a7),	# should be sans serif
	Assoc("ssIota",	16r399),
	Assoc("ssOmicron",	16r39f),
	Assoc("ssPi",	16r3a0),
	Assoc("ssRho",	16r3a1),
	Assoc("ssSigma",	16r3a3),
	Assoc("ssTau",	16r3a4),
	Assoc("star",	16r2a),
	Assoc("stlig",	MLST),
	Assoc("sup2",	16r2072),
	Assoc("supgt",	16r2c3),
	Assoc("suplt",	16r2c2),
	Assoc("sur",	16r2b3),
	Assoc("swing",	16r223c),
	Assoc("tau",	16r3c4),
	Assoc("taur",	16r2649),
	Assoc("th",	16rfe),
	Assoc("thbar",	16rfe),	# +bar
	Assoc("theta",	16r3b8),
	Assoc("thinqm",	16r3f),	# should be thinner
	Assoc("tilde",	LTIL),
	Assoc("times",	16rd7),
	Assoc("tri",	16r2206),
	Assoc("trli",	16r2016),
	Assoc("ts",	16r2009),
	Assoc("uacu",	16rfa),
	Assoc("uasper",	MUAS),
	Assoc("ubar",	16r75),	# +bar
	Assoc("ubreve",	16r16d),
	Assoc("ucirc",	16rfb),
	Assoc("udA",	16r2200),
	Assoc("udT",	16r22a5),
	Assoc("uda",	16r250),
	Assoc("udh",	16r265),
	Assoc("udqm",	16rbf),
	Assoc("udpsi",	16r22d4),
	Assoc("udtr",	16r2207),
	Assoc("ugrave",	16rf9),
	Assoc("ulenis",	MULN),
	Assoc("umac",	16r16b),
	Assoc("uml",	LUML),
	Assoc("undl",	16r2cd),	# underline accent
	Assoc("union",	16r222a),
	Assoc("upsilon",	16r3c5),
	Assoc("uuml",	16rfc),
	Assoc("vavpath",	16r5d5),	# vav U+05D5 (+patah)
	Assoc("vavsheva",	16r5d5),	# vav U+05D5 (+sheva)
	Assoc("vb",	16r7c),
	Assoc("vddd",	16r22ee),
	Assoc("versicle2",	16r2123),	# U+2123
	Assoc("vinc",	16raf),
	Assoc("virgo",	16r264d),
	Assoc("vpal",	16r25f),
	Assoc("vvf",	16r263),
	Assoc("wasper",	MWAS),
	Assoc("wavyeq",	16r2248),
	Assoc("wlenis",	MWLN),
	Assoc("wyn",	16r1bf),	# wynn U+01BF
	Assoc("xi",	16r3be),
	Assoc("yacu",	16rfd),
	Assoc("ycirc",	16r177),
	Assoc("ygh",	16r292),
	Assoc("ymac",	16r79),	# +macron
	Assoc("yuml",	16rff),
	Assoc("zced",	16r7a),	# +cedilla
	Assoc("zeta",	16r3b6),
	Assoc("zh",	16r292),
	Assoc("zhacek",	16r17e),
};

normtab := array[128] of {
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	16r20,	16r21,	16r22,	16r23,	16r24,	16r25,	SPCS,	'\'',
	16r28,	16r29,	16r2a,	16r2b,	16r2c,	16r2d,	16r2e,	16r2f,
	16r30,	16r31,	16r32,	16r33,	16r34,	16r35,	16r36,	16r37,
	16r38,	16r39,	16r3a,	16r3b,	TAGS,	16r3d,	TAGE,	16r3f,
	16r40,	16r41,	16r42,	16r43,	16r44,	16r45,	16r46,	16r47,
	16r48,	16r49,	16r4a,	16r4b,	'L',	16r4d,	16r4e,	16r4f,
	16r50,	16r51,	16r52,	16r53,	16r54,	16r55,	16r56,	16r57,
	16r58,	16r59,	16r5a,	16r5b,	'\\',	16r5d,	16r5e,	16r5f,
	16r60,	16r61,	16r62,	16r63,	16r64,	16r65,	16r66,	16r67,
	16r68,	16r69,	16r6a,	16r6b,	16r6c,	16r6d,	16r6e,	16r6f,
	16r70,	16r71,	16r72,	16r73,	16r74,	16r75,	16r76,	16r77,
	16r78,	16r79,	16r7a,	16r7b,	16r7c,	16r7d,	16r7e,	NONE,
};

phtab := array[128] of {
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	16r20,	16r21,	16r2c8,	16r23,	16r24,	16r2cc,	16re6,	'\'',
	16r28,	16r29,	16r2a,	16r2b,	16r2c,	16r2d,	16r2e,	16r2f,
	16r30,	16r31,	16r32,	16r25c,	16r34,	16r35,	16r36,	16r37,
	16r38,	16rf8,	16r2d0,	16r3b,	TAGS,	16r3d,	TAGE,	16r3f,
	16r259,	16r251,	16r42,	16r43,	16rf0,	16r25b,	16r46,	16r47,
	16r48,	16r26a,	16r4a,	16r4b,	'L',	16r4d,	16r14b,	16r254,
	16r50,	16r252,	16r52,	16r283,	16r3b8,	16r28a,	16r28c,	16r57,
	16r58,	16r59,	16r292,	16r5b,	'\\',	16r5d,	16r5e,	16r5f,
	16r60,	16r61,	16r62,	16r63,	16r64,	16r65,	16r66,	16r67,
	16r68,	16r69,	16r6a,	16r6b,	16r6c,	16r6d,	16r6e,	16r6f,
	16r70,	16r71,	16r72,	16r73,	16r74,	16r75,	16r76,	16r77,
	16r78,	16r79,	16r7a,	16r7b,	16r7c,	16r7d,	16r7e,	NONE,
};

grtab := array[128] of {
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	16r20,	16r21,	16r22,	16r23,	16r24,	16r25,	SPCS,	'\'',
	16r28,	16r29,	16r2a,	16r2b,	16r2c,	16r2d,	16r2e,	16r2f,
	16r30,	16r31,	16r32,	16r33,	16r34,	16r35,	16r36,	16r37,
	16r38,	16r39,	16r3a,	16r3b,	TAGS,	16r3d,	TAGE,	16r3f,
	16r40,	16r391,	16r392,	16r39e,	16r394,	16r395,	16r3a6,	16r393,
	16r397,	16r399,	16r3da,	16r39a,	16r39b,	16r39c,	16r39d,	16r39f,
	16r3a0,	16r398,	16r3a1,	16r3a3,	16r3a4,	16r3a5,	16r56,	16r3a9,
	16r3a7,	16r3a8,	16r396,	16r5b,	'\\',	16r5d,	16r5e,	16r5f,
	16r60,	16r3b1,	16r3b2,	16r3be,	16r3b4,	16r3b5,	16r3c6,	16r3b3,
	16r3b7,	16r3b9,	16r3c2,	16r3ba,	16r3bb,	16r3bc,	16r3bd,	16r3bf,
	16r3c0,	16r3b8,	16r3c1,	16r3c3,	16r3c4,	16r3c5,	16r76,	16r3c9,
	16r3c7,	16r3c8,	16r3b6,	16r7b,	16r7c,	16r7d,	16r7e,	NONE,
};

subtab := array[128] of {
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	16r20,	16r21,	16r22,	16r23,	16r24,	16r25,	SPCS,	'\'',
	16r208d,	16r208e,	16r2a,	16r208a,	16r2c,	16r208b,	16r2e,	16r2f,
	16r2080,	16r2081,	16r2082,	16r2083,	16r2084,	16r2085,	16r2086,	16r2087,
	16r2088,	16r2089,	16r3a,	16r3b,	TAGS,	16r208c,	TAGE,	16r3f,
	16r40,	16r41,	16r42,	16r43,	16r44,	16r45,	16r46,	16r47,
	16r48,	16r49,	16r4a,	16r4b,	'L',	16r4d,	16r4e,	16r4f,
	16r50,	16r51,	16r52,	16r53,	16r54,	16r55,	16r56,	16r57,
	16r58,	16r59,	16r5a,	16r5b,	'\\',	16r5d,	16r5e,	16r5f,
	16r60,	16r61,	16r62,	16r63,	16r64,	16r65,	16r66,	16r67,
	16r68,	16r69,	16r6a,	16r6b,	16r6c,	16r6d,	16r6e,	16r6f,
	16r70,	16r71,	16r72,	16r73,	16r74,	16r75,	16r76,	16r77,
	16r78,	16r79,	16r7a,	16r7b,	16r7c,	16r7d,	16r7e,	NONE,
};

suptab := array[128] of {
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,	NONE,
	16r20,	16r21,	16r22,	16r23,	16r24,	16r25,	SPCS,	'\'',
	16r207d,	16r207e,	16r2a,	16r207a,	16r2c,	16r207b,	16r2e,	16r2f,
	16r2070,	16r2071,	16r2072,	16r2073,	16r2074,	16r2075,	16r2076,	16r2077,
	16r2078,	16r2079,	16r3a,	16r3b,	TAGS,	16r207c,	TAGE,	16r3f,
	16r40,	16r41,	16r42,	16r43,	16r44,	16r45,	16r46,	16r47,
	16r48,	16r49,	16r4a,	16r4b,	'L',	16r4d,	16r4e,	16r4f,
	16r50,	16r51,	16r52,	16r53,	16r54,	16r55,	16r56,	16r57,
	16r58,	16r59,	16r5a,	16r5b,	'\\',	16r5d,	16r5e,	16r5f,
	16r60,	16r61,	16r62,	16r63,	16r64,	16r65,	16r66,	16r67,
	16r68,	16r69,	16r6a,	16r6b,	16r6c,	16r6d,	16r6e,	16r6f,
	16r70,	16r71,	16r72,	16r73,	16r74,	16r75,	16r76,	16r77,
	16r78,	16r79,	16r7a,	16r7b,	16r7c,	16r7d,	16r7e,	NONE,
};

prkey :=
	"KEY TO THE PRONUNCIATION\n" +
	"\n" +
	"I. CONSONANTS\n" +
	"b, d, f, k, l, m, n, p, t, v, z: usual English values\n" +
	"\n" +
	"g as in go (gəʊ)\n" +
	"h  ...  ho! (həʊ)\n" +
	"r  ...  run (rʌn), terrier (ˈtɛriə(r))\n" +
	"(r)...  her (hɜː(r))\n" +
	"s  ...  see (siː), success (səkˈsɜs)\n" +
	"w  ...  wear (wɛə(r))\n" +
	"hw ...  when (hwɛn)\n" +
	"j  ...  yes (jɛs)\n" +
	"θ  ...  thin (θin), bath (bɑːθ)\n" +
	"ð  ...  then (ðɛn), bathe (beɪð)\n" +
	"ʃ  ...  shop (ʃɒp), dish (dɪʃ)\n" +
	"tʃ ...  chop (tʃɒp), ditch (dɪtʃ)\n" +
	"ʒ  ...  vision (ˈvɪʒən), déjeuner (deʒøne)\n" +
	"dʒ ...  judge (dʒʌdʒ)\n" +
	"ŋ  ...  singing (ˈsɪŋɪŋ), think (θiŋk)\n" +
	"ŋg ...  finger (ˈfiŋgə(r))\n" +
	"\n" +
	"Foreign\n" +
	"ʎ as in It. seraglio (serˈraʎo)\n" +
	"ɲ  ...  Fr. cognac (kɔɲak)\n" +
	"x  ...  Ger. ach (ax), Sc. loch (lɒx)\n" +
	"ç  ...  Ger. ich (ɪç), Sc. nicht (nɪçt)\n" +
	"ɣ  ...  North Ger. sagen (ˈzaːɣən)\n" +
	"c  ...  Afrikaans baardmannetjie (ˈbaːrtmanəci)\n" +
	"ɥ  ...  Fr. cuisine (kɥizin)\n" +
	"\n" +
	"II. VOWELS AND DIPTHONGS\n" +
	"\n" +
	"Short\n" +
	"ɪ as in pit (pɪt), -ness (-nɪs)\n" +
	"ɛ  ...  pet (pɛt), Fr. sept (sɛt)\n" +
	"æ  ...  pat (pæt)\n" +
	"ʌ  ...  putt (pʌt)\n" +
	"ɒ  ...  pot (pɒt)\n" +
	"ʊ  ...  put (pʊt)\n" +
	"ə  ...  another (əˈnʌðə(r))\n" +
	"(ə)...  beaten (ˈbiːt(ə)n)\n" +
	"i  ...  Fr. si (si)\n" +
	"e  ...  Fr. bébé (bebe)\n" +
	"a  ...  Fr. mari (mari)\n" +
	"ɑ  ...  Fr. bâtiment (bɑtimã)\n" +
	"ɔ  ...  Fr. homme (ɔm)\n" +
	"o  ...  Fr. eau (o)\n" +
	"ø  ...  Fr. peu (pø)\n" +
	"œ  ...  Fr. boeuf (bœf), coeur (kœr)\n" +
	"u  ...  Fr. douce (dus)\n" +
	"ʏ  ...  Ger. Müller (ˈmʏlər)\n" +
	"y  ...  Fr. du (dy)\n" +
	"\n" +
	"Long\n" +
	"iː as in bean (biːn)\n" +
	"ɑː ...  barn (bɑːn)\n" +
	"ɔː ...  born (bɔːn)\n" +
	"uː ...  boon (buːn)\n" +
	"ɜː ...  burn (bɜːn)\n" +
	"eː ...  Ger. Schnee (ʃneː)\n" +
	"ɛː ...  Ger. Fähre (ˈfɛːrə)\n" +
	"aː ...  Ger. Tag (taːk)\n" +
	"oː ...  Ger. Sohn (zoːn)\n" +
	"øː ...  Ger. Goethe (gøːtə)\n" +
	"yː ...  Ger. grün (gryːn)\n" +
	"\n" +
	"Nasal\n" +
	"ɛ˜, æ˜ as in Fr. fin (fɛ˜, fæ˜)\n" +
	"ã  ...  Fr. franc (frã)\n" +
	"ɔ˜ ...  Fr. bon (bɔ˜n)\n" +
	"œ˜ ...  Fr. un (œ˜)\n" +
	"\n" +
	"Dipthongs, etc.\n" +
	"eɪ as in bay (beɪ)\n" +
	"aɪ ...  buy (baɪ)\n" +
	"ɔɪ ...  boy (bɔɪ)\n" +
	"əʊ ...  no (nəʊ)\n" +
	"aʊ ...  now (naʊ)\n" +
	"ɪə ...  peer (pɪə(r))\n" +
	"ɛə ...  pair (pɛə(r))\n" +
	"ʊə ...  tour (tʊə(r))\n" +
	"ɔə ...  boar (bɔə(r))\n" +
	"\n" +
	"III. STRESS\n" +
	"\n" +
	"Main stress: ˈ preceding stressed syllable\n" +
	"Secondary stress: ˌ preceding stressed syllable\n" +
	"\n" +
	"E.g.: pronunciation (prəˌnʌnsɪˈeɪʃ(ə)n)\n";

#  Possible tag auxiliary info
Cols	#  number of columns in a table
, Num	#  letter or number, for a sense
, St	#  status (e.g., obs)
, Naux: con iota;

auxtab := array[] of {
	Assoc("cols",	Cols),
	Assoc("num",	Num),
	Assoc("st",	St),
};

tagstarts: int;
tag: string;
naux: int;
auxname := array[Maxaux] of string;
auxval := array[Maxaux] of string;
spec: string;
auxstate := array[Naux] of string;	#  vals for most recent tag
curentry: Entry;

#  The entry is 7-bit text; walk it by index rather than
#  re-slicing a string, which would copy on every character
#  of entries that run to hundreds of kilobytes.
buf: array of byte;
pos: int;

outchar(c: int)
{
	outrune(c);
}

outchars(s: string)
{
	for(i := 0; i < len s; i++)
		outrune(s[i]);
}

# 
#  cmd is one of:
#     'p': normal print
#     'h': just print headwords
#     'r': print raw
# 
printentry(e: Entry, cmd: int)
{
	t, a, i: int;
	r, rprev, rlig: int;

	buf = e.start;
	pos = 0;
	transtab := normtab;
	rprev = NONE;
	changett(nil, nil, 0);
	curentry = e;
	if(cmd == 'h')
		outinhibit = 1;
	while(pos < len buf){
		if(cmd == 'r'){
			outchar(int buf[pos++]);
			continue;
		}
		r = transtab[int buf[pos++] & 16r7F];
		if(r < NONE){
			#  Emit the rune, but buffer in case of ligature
			if(rprev != NONE)
				outrune(rprev);
			rprev = r;
		}else if(r == SPCS){
			#  Start of special character name
			getspec();
			r = lookassoc(spectab, len spectab, spec);
			if(r == -1){
				if(debug)
					err(sprint("spec %bd %d %s", e.doff, len buf, spec));
				r = 16rfffd;
			}
			if(r >= LIGS && r < LIGE){
				#  handle possible ligature
				rlig = liglookup(r, rprev);
				if(rlig != NONE)
					rprev = rlig;	#  overwrite rprev
				else{
					#  could print accent, but let's not
					if(rprev != NONE)
						outrune(rprev);
					rprev = NONE;
				}
			}else if(r >= MULTI && r < MULTIE){
				if(rprev != NONE){
					outrune(rprev);
					rprev = NONE;
				}
				outrunes(multitab[r-MULTI]);
			}else if(r == PAR){
				if(rprev != NONE){
					outrune(rprev);
					rprev = NONE;
				}
				outnl(1);
			}else{
				if(rprev != NONE)
					outrune(rprev);
				rprev = r;
			}
		}else if(r == TAGS){
			#  Start of tag name
			if(rprev != NONE){
				outrune(rprev);
				rprev = NONE;
			}
			gettag();
			t = lookassoc(tagtab, len tagtab, tag);
			if(t == -1){
				if(debug)
					err(sprint("tag %bd %d %s", e.doff, len buf, tag));
				continue;
			}
			for(i = 0; i < Naux; i++)
				auxstate[i] = nil;
			for(i = 0; i < naux; i++){
				a = lookassoc(auxtab, len auxtab, auxname[i]);
				if(a == -1){
					if(debug)
						err(sprint("aux %bd %d %s", e.doff, len buf, auxname[i]));
				}else
					auxstate[a] = auxval[i];
			}
			case t {
			E or Ve =>
				outnl(0);
				if(tagstarts)
					dostatus();
			Ed or Etym =>
				if(tagstarts)
					outchar('[');
				else
					outchar(']');
			Pr =>
				if(tagstarts)
					outchar('(');
				else
					outchar(')');
			In =>
				transtab = changett(transtab, subtab, tagstarts);
			Hm or Su or Fq =>
				transtab = changett(transtab, suptab, tagstarts);
			Gk =>
				transtab = changett(transtab, grtab, tagstarts);
			Ph =>
				transtab = changett(transtab, phtab, tagstarts);
			Hw =>
				if(cmd == 'h'){
					if(!tagstarts)
						outchar(' ');
					outinhibit = !tagstarts;
				}
			S0 or S1 or S2 or S3 or S4 or S5 or S6 or S7a or S7n or Sn or Sgk =>
				if(tagstarts){
					outnl(2);
					dostatus();
					num := auxstate[Num];
					if(num != nil){
						if(t == S3 || t == S5){
							for(i = int num; i > 0; i--)
								outchar('*');
							outchars("  ");
						}else if(t == S7a || t == S7n || t == Sn){
							outchar('(');
							outchars(num);
							outchars(") ");
						}else if(t == Sgk){
							i = grtab[num[0] & 16r7F];
							if(i != NONE)
								outrune(i);
							outchars(".  ");
						}else{
							outchars(num);
							outchars(".  ");
						}
					}
				}
			Cb or Db or Qp or P =>
				if(tagstarts)
					outnl(1);
			Table =>
				#  Todo: gather columns, justify them, etc.
				#  For now, just let columns come out as rows
				if(!tagstarts)
					outnl(0);
			Col =>
				if(tagstarts)
					outnl(0);
			Dn =>
				if(tagstarts)
					outchar('/');
			}
		}
	}
	if(cmd == 'h'){
		outinhibit = 0;
		outnl(0);
	}
	buf = nil;
}

# 
#  Return offset into bdict where next oed entry after fromoff starts.
#  Oed entries start with <e>, <ve>, <e st=...>, or <ve st=...>
# 
nextoff(fromoff: big): big
{
	c: int;

	if(bdict.seek(fromoff, 0) < big 0)
		return big -1;
	n := 0;
	for(;;){
		c = bdict.getb();
		if(c < 0)
			break;
		if(c == '<'){
			c = bdict.getb();
			if(c == 'e'){
				c = bdict.getb();
				if(c == '>' || c == ' ')
					n = 3;
			}else if(c == 'v' && bdict.getb() == 'e'){
				c = bdict.getb();
				if(c == '>' || c == ' ')
					n = 4;
			}
			if(n)
				break;
		}
	}
	return bdict.offset() - big n;
}

printkey()
{
	bout.puts(prkey);
}

# 
#  pos is just after a '&'.  Accumulate the special name,
#  continuing until the next '.', in spec; leave pos after the '.'.
# 
getspec()
{
	s := "";
	for(i := 1; i < Buflen && pos < len buf; i++){
		c := int buf[pos++];
		if(c == '.')
			break;
		s[len s] = c;
	}
	spec = s;
}

# 
#  pos is just after '<'.  Expect
#   [/][^ >]+( [^>=]+=[^ >]+)*>
#       tag   auxname auxval
#  Accumulate the tag and its auxiliary information in
#  tag, auxname and auxval; set tagstarts and naux.
#  Leave pos after the final '>'.
# 
gettag()
{
	if(pos >= len buf){
		tag = "";
		naux = 0;
		return;
	}
	s := "";
	c := int buf[pos++];
	if(c == '/')
		tagstarts = 0;
	else{
		tagstarts = 1;
		s[len s] = c;
	}
	naux = 0;
	field := 0;	# 0 tag, 1 auxname[naux-1], 2 auxval[naux-1]
	for(i := 1; i < Buflen && pos < len buf; i++){
		c = int buf[pos++];
		if(c == '>')
			break;
		if(c == ' '){
			store(field, s);
			s = "";
			if(naux < Maxaux)
				naux++;
			auxval[naux-1] = nil;
			field = 1;
		}else if(naux && c == '='){
			store(field, s);
			s = "";
			field = 2;
		}else
			s[len s] = c;
	}
	store(field, s);
}

store(field: int, s: string)
{
	case field {
	0 =>	tag = s;
	1 =>	auxname[naux-1] = s;
	2 =>	auxval[naux-1] = s;
	}
}

dostatus()
{
	s := auxstate[St];
	if(s == nil)
		return;
	case s {
	"obs" =>
		outrune(16r2020);
	"ali" =>
		outrune(16r2016);
	"err" or "spu" =>
		outrune(16rb6);
	"xref" =>
		;
	* =>
		if(debug)
			err(sprint("status %bd %d %s", curentry.doff, len buf, s));
	}
}

mkindex()
{
}
