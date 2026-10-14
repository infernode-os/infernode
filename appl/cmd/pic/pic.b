implement Pic;

#line	2	"pic.y"
#
# pic - troff's preprocessor for pictures
#
# A translation of Plan 9's pic (as Neatroff uses it) into Limbo; for the
# same input it writes the same output, byte for byte. Its text is
# handled as bytes: each byte of the input is a character of the strings
# here (from 0 to 255), and each is written back as the byte it was.
# C's float is kept: what pic stores as a float is rounded to one.
#
# pic.b is made from pic.y by yacc(1): yacc -o pic.b pic.y
#
# Copyright (C) 2003, Lucent Technologies Inc. and others. All Rights
# Reserved. Distributed under the MIT license:
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
# OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "math.m";
	math: Math;

include "picdefs.b";

YYSTYPE: adt {
	i:	int;
	p:	string;
	o:	ref Obj;
	f:	real;
	st:	ref Sym;
};

YYLEX: adt {
	lval:	YYSTYPE;
	lex:	fn(l: self ref YYLEX): int;
	error:	fn(l: self ref YYLEX, msg: string);
};

y: YYSTYPE;
Pic: module {

	init:	fn(nil: ref Draw->Context, args: list of string);
BOX: con	1;
LINE: con	2;
ARROW: con	3;
CIRCLE: con	4;
ELLIPSE: con	5;
ARC: con	6;
SPLINE: con	7;
BLOCK: con	8;
TEXT: con	9;
TROFF: con	10;
MOVE: con	11;
BLOCKEND: con	12;
PLACE: con	13;
PRINT: con	57359;
RESET: con	57360;
THRU: con	57361;
UNTIL: con	57362;
FOR: con	57363;
IF: con	57364;
COPY: con	57365;
THENSTR: con	57366;
ELSESTR: con	57367;
DOSTR: con	57368;
PLACENAME: con	57369;
VARNAME: con	57370;
SPRINTF: con	57371;
DEFNAME: con	57372;
ATTR: con	57373;
TEXTATTR: con	57374;
LEFT: con	57375;
RIGHT: con	57376;
UP: con	57377;
DOWN: con	57378;
FROM: con	57379;
TO: con	57380;
AT: con	57381;
BY: con	57382;
WITH: con	57383;
HEAD: con	57384;
CW: con	57385;
CCW: con	57386;
THEN: con	57387;
HEIGHT: con	57388;
WIDTH: con	57389;
RADIUS: con	57390;
DIAMETER: con	57391;
LENGTH: con	57392;
SIZE: con	57393;
CORNER: con	57394;
HERE: con	57395;
LAST: con	57396;
NTH: con	57397;
SAME: con	57398;
BETWEEN: con	57399;
AND: con	57400;
EAST: con	57401;
WEST: con	57402;
NORTH: con	57403;
SOUTH: con	57404;
NE: con	57405;
NW: con	57406;
SE: con	57407;
SW: con	57408;
START: con	57409;
END: con	57410;
DOTX: con	57411;
DOTY: con	57412;
DOTHT: con	57413;
DOTWID: con	57414;
DOTRAD: con	57415;
NUMBER: con	57416;
LOG: con	57417;
EXP: con	57418;
SIN: con	57419;
COS: con	57420;
ATAN2: con	57421;
SQRT: con	57422;
RAND: con	57423;
MIN: con	57424;
MAX: con	57425;
INT: con	57426;
DIR: con	57427;
DOT: con	57428;
DASH: con	57429;
CHOP: con	57430;
FILL: con	57431;
NOEDGE: con	57432;
ST: con	57433;
OROR: con	57434;
ANDAND: con	57435;
GT: con	57436;
LT: con	57437;
LE: con	57438;
GE: con	57439;
EQ: con	57440;
NEQ: con	57441;
UMINUS: con	57442;
NOT: con	57443;

};
YYEOFCODE: con 1;
YYERRCODE: con 2;
YYMAXDEPTH: con 200;

#line	388	"pic.y"


include "picl.b";
include "picmain.b";
include "picgen.b";
include "picprint.b";
yyexca := array[] of {-1, 0,
	1, 2,
	-2, 0,
-1, 1,
	1, -1,
	-2, 0,
-1, 206,
	95, 0,
	96, 0,
	97, 0,
	98, 0,
	99, 0,
	100, 0,
	-2, 159,
-1, 213,
	95, 0,
	96, 0,
	97, 0,
	98, 0,
	99, 0,
	100, 0,
	-2, 158,
-1, 214,
	95, 0,
	96, 0,
	97, 0,
	98, 0,
	99, 0,
	100, 0,
	-2, 160,
-1, 215,
	95, 0,
	96, 0,
	97, 0,
	98, 0,
	99, 0,
	100, 0,
	-2, 161,
-1, 216,
	95, 0,
	96, 0,
	97, 0,
	98, 0,
	99, 0,
	100, 0,
	-2, 162,
-1, 217,
	95, 0,
	96, 0,
	97, 0,
	98, 0,
	99, 0,
	100, 0,
	-2, 163,
-1, 264,
	69, 112,
	70, 112,
	71, 112,
	72, 112,
	73, 112,
	-2, 85,
-1, 270,
	95, 0,
	96, 0,
	97, 0,
	98, 0,
	99, 0,
	100, 0,
	-2, 159,
};
YYNPROD: con 178;
YYPRIVATE: con 57344;
yytoknames: array of string;
yystates: array of string;
yydebug: con 0;
YYLAST:	con 1654;
yyact := array[] of {
 173, 334, 139,  32,  53,  68, 312, 242, 124, 125,
 137,  42, 115, 197, 116, 117, 118, 119, 110, 111,
 112, 113, 114,  95, 227, 122, 162, 320,  81,  43,
 274, 137,  92, 319,  51, 299, 273, 161, 137, 160,
 159, 105, 158, 157, 156, 155, 154, 153,  98, 127,
 128, 131, 109, 298, 246, 235, 152, 149, 233,  40,
 112, 113, 114, 122,  51, 122,  41,  72,  40, 194,
 102, 164, 166, 138, 130, 110, 111, 112, 113, 114,
 129,  83, 122, 169, 190,  73,  74,  75,  76,  77,
  78,  79,  80, 276, 246, 200, 110, 111, 112, 113,
 114, 138, 126, 122, 124, 125, 107,  38, 204, 206,
 105, 208, 209, 210, 211, 212, 213, 214, 215, 216,
 217, 218, 219, 220, 195, 221, 224, 132, 133, 134,
 135, 136,  51,  51, 124, 125, 124, 125, 205, 207,
 198, 199,  34, 316, 275, 321, 168,  85, 223, 226,
 234, 124, 125,  44, 236, 237, 238, 239, 240, 241,
 203, 243, 244, 245, 232, 167, 170, 247, 249, 228,
 124, 125,  86, 252,  93, 253, 105, 105, 105, 105,
 105,  96,  97, 123, 261, 262, 263, 265, 335, 336,
 337, 338,  81, 124, 125, 267, 268, 192, 270,  51,
  51,  51,  51,  51, 251, 254, 255, 256, 257, 260,
 121, 120, 115, 197, 116, 117, 118, 119, 110, 111,
 112, 113, 114, 278,  90, 122, 280,  86, 311, 282,
 287, 193, 191, 283, 229, 132, 133, 134, 135, 136,
  71, 201, 142, 146, 147, 143, 144, 145, 148, 250,
 285,  35, 281, 300,  66,  67,  69, 284,  87,  88,
 287, 288,  35, 164, 166, 269,   2,   4,  36, 230,
  37, 285, 286,  39, 163, 305, 105, 105, 308,  36,
 310, 196, 188,  24, 171,  24, 266, 149,  84,  24,
 230, 231, 151,  82, 313,  70, 314, 315,   1,  51,
  51,  69, 165, 317, 318, 306, 307,  37, 100,  24,
 322,   5, 323, 142, 146, 147, 143, 144, 145, 148,
 248, 331,  24,  24,  26,   6,  12,  13,  14, 304,
  89, 339,  91,   0, 301, 340,   0,   0,   0,   0,
 341, 271, 272,  16,  20,  21,  17,  18,  19,  22,
  37,  35,  25,  23,  52,  46,  10,  11,   0,   0,
  30,  31,  29, 141,   0,  24, 103,  46,  36, 202,
   0,   0,   0,   0,   0,   0,   0,   0,   0,  66,
  67,  69,  54,   0,  24,   0,   0,   0,   0,   0,
   0,  66,  67,  69,  54,   0,   0,   0,   0,   0,
   0,  45,  56,  57,  58,  59,  60,  61,  62,  64,
  63,  65,   0,  45,  56,  57,  58,  59,  60,  61,
  62,  64,  63,  65,   9,   0,   0,   0,  49,  48,
 101,   0, 303,   0,  55,   0,   0,   0,   0,   0,
  49,  48,  35,  94,   0,   0,  55,   0,   0,   0,
   0,  27,   0,  33,   0,  50,   0,  52,  46,  36,
   0, 172, 181,   0,   0,   0,   0, 175, 176, 177,
 178, 179, 182,   0, 142, 146, 147, 143, 144, 145,
 148, 150,  66,  67,  69,  54, 180, 121, 120, 115,
 197, 116, 117, 118, 119, 110, 111, 112, 113, 114,
   0,   0, 122,   0,  45,  56,  57,  58,  59,  60,
  61,  62,  64,  63,  65, 174, 183, 184, 185, 186,
 187,   0,   0,  35, 151,   0,   0,   0,   0,   0,
   0,  49,  48,   0,  35,   0,   0,  55,  52,  46,
  36,   0,   0,   0,   0,   0,  94,   0,   0,  52,
  46,  36,   0,   0,   0,   0,   0,   0,   0,   0,
   0,   0,   0,  66,  67,  69,  54,   0,   0,   0,
   0,   0,   0,   0,  66,  67,  69,  54,   0,   0,
   0,   0,   0,   0,   0,  45,  56,  57,  58,  59,
  60,  61,  62,  64,  63,  65,  45,  56,  57,  58,
  59,  60,  61,  62,  64,  63,  65,  52,  46,   0,
   0,   0,  49,  48,   0,   0,   0,   0,  55,  52,
  46,   0,   0,  49,  48,   0,   0,  94,   0,  55,
   0,   0, 258,  67,  69,  54,   0,   0,  50,   0,
   0,   0,   0,   0,  66,  67,  69,  54,   0,   0,
   0,   0,   0,   0,  45,  56,  57,  58,  59,  60,
  61,  62,  64,  63,  65,   0,  45,  56,  57,  58,
  59,  60,  61,  62,  64,  63,  65, 264,  46,   0,
   0,  49,  48,   0,   0,   0,   0,  55,  52,  46,
   0,   0,   0,  49,  48, 259,  50,   0,   0,  55,
   0,   0,  66,  67,  69,  54,   0,   0,  50,   0,
   0,   0,   0,  66,  67,  69,  54,   0,   0,   0,
   0,   0,   0,   0,  45,  56,  57,  58,  59,  60,
  61,  62,  64,  63,  65,  45,  56,  57,  58,  59,
  60,  61,  62,  64,  63,  65,  52,  46,   0,   0,
   0,  49,  48,   0,   0,   0,   0,  55,   0,   0,
   0,   0,  49,  48,   0,   0,  94,   0,  55,   0,
   0,  66,  67,  69,  54,   0,   0, 225, 120, 115,
 197, 116, 117, 118, 119, 110, 111, 112, 113, 114,
   0,   0, 122,  45,  56,  57,  58,  59,  60,  61,
  62,  64,  63,  65,   0,  16,  20,  21,  17,  18,
  19,  22,   0,  35,  25,  23,   0,   0,  10,  11,
  49,  48,  30,  31,  29,   0,  55,   0,   7,  28,
  36,   0,   0,   0,   0, 222,  16,  20,  21,  17,
  18,  19,  22,   0,  35,  25,  23,   0,   0,  10,
  11,   0,   0,  30,  31,  29,   0,   0,   0,   7,
  28,  36,   3,   0,  16,  20,  21,  17,  18,  19,
  22,   0,  35,  25,  23,   0,   0,  10,  11,   0,
   0,  30,  31,  29,   0,   0,   9,   7,  28,  36,
   0,   0,  15,   0,   0, 121, 120, 115, 197, 116,
 117, 118, 119, 110, 111, 112, 113, 114,   0,   0,
 122,   0,   0,  27, 189,  33,   0,   9,   0, 333,
   0,   0,   0,  15, 121, 120, 115, 197, 116, 117,
 118, 119, 110, 111, 112, 113, 114,   0,   0, 122,
   0,  99, 109,   0,  27,   9,  33,   0, 332,   0,
   0,  15,  16,  20,  21,  17,  18,  19,  22,   0,
  35,  25,  23,   0,   0,  10,  11,   0,   0,  30,
  31,  29,  27,   0,  33,   7,  28,  36, 121, 120,
 115, 108, 116, 117, 118, 119, 110, 111, 112, 113,
 114,   0,   0, 122,   0,   0, 107,   0,   0,   0,
   0,   0, 229, 121, 120, 115, 197, 116, 117, 118,
 119, 110, 111, 112, 113, 114,   0,   0, 122,   0,
   0, 309,   0,   0,   0,   0,   0, 229,   0,   0,
   0,   0,   0,   9,   0,   0,   0,   0,   0,  15,
 121, 120, 115, 197, 116, 117, 118, 119, 110, 111,
 112, 113, 114,   0,   0, 122,   0,   0,   0,   0,
  27,   0,  33,   0, 326, 121, 120, 115, 197, 116,
 117, 118, 119, 110, 111, 112, 113, 114,   0,   0,
 122, 142, 146, 147, 143, 144, 145, 148, 140, 325,
 121, 120, 115, 197, 116, 117, 118, 119, 110, 111,
 112, 113, 114,   0,   0, 122,   0,   0,   0,   0,
   0,   0,   0,   0, 324, 121, 120, 115, 197, 116,
 117, 118, 119, 110, 111, 112, 113, 114,   0,   0,
 122, 141,   0,   0,   0,   0,   0,   0,   0, 297,
 121, 120, 115, 197, 116, 117, 118, 119, 110, 111,
 112, 113, 114,   0,   0, 122,   0,   0,   0,   0,
   0,   0,   0,   0, 294, 121, 120, 115, 197, 116,
 117, 118, 119, 110, 111, 112, 113, 114,   0,   0,
 122,   0,   0,   0,   0,   0,   0,   0,   0, 292,
 121, 120, 115, 197, 116, 117, 118, 119, 110, 111,
 112, 113, 114,   0,   0, 122,   0,   0,   0,   0,
   0,   0,   0,   0, 291, 121, 120, 115, 197, 116,
 117, 118, 119, 110, 111, 112, 113, 114,   0,   0,
 122,   0,   0,   0,   0,   0,   0,   0,   0, 290,
 121, 120, 115, 197, 116, 117, 118, 119, 110, 111,
 112, 113, 114,   0, 109, 122,   0,   0,   0,   0,
   0,   0,   0,   0, 289, 121, 120, 115, 197, 116,
 117, 118, 119, 110, 111, 112, 113, 114, 109,   0,
 122,   0,   0,   0,   0,   0,   0,   0, 106, 229,
 121, 120, 115, 108, 116, 117, 118, 119, 110, 111,
 112, 113, 114,   0,   0, 122,   0,   0, 107,   0,
   0,   0,   0,   0, 121, 120, 115, 108, 116, 117,
 118, 119, 110, 111, 112, 113, 114,   0,   0, 122,
   0,   0, 107, 121, 120, 115, 197, 116, 117, 118,
 119, 110, 111, 112, 113, 114,   0,   0, 122,   0,
   0, 296, 121, 120, 115, 197, 116, 117, 118, 119,
 110, 111, 112, 113, 114,   0,   0, 122,   0,   0,
 295, 121, 120, 115, 197, 116, 117, 118, 119, 110,
 111, 112, 113, 114,   0,   0, 122, 343,   0, 293,
 121, 120, 115, 197, 116, 117, 118, 119, 110, 111,
 112, 113, 114, 342,   0, 122,   0,   0, 279, 121,
 120, 115, 197, 116, 117, 118, 119, 110, 111, 112,
 113, 114, 330,   0, 122,   0,   0, 277,   0,   0,
   0,   0,   0,   0,   0,   0, 329,   0, 328,   0,
   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
   0,   0, 327,   0, 121, 120, 115, 197, 116, 117,
 118, 119, 110, 111, 112, 113, 114, 302,   0, 122,
 121, 120, 115, 197, 116, 117, 118, 119, 110, 111,
 112, 113, 114,   0,   0, 122,   0,   0,   0, 121,
 120, 115, 197, 116, 117, 118, 119, 110, 111, 112,
 113, 114,   0,   0, 122, 121, 120, 115, 197, 116,
 117, 118, 119, 110, 111, 112, 113, 114,   0,   0,
 122,   0, 121, 120, 115, 197, 116, 117, 118, 119,
 110, 111, 112, 113, 114,   0,   0, 122, 121, 120,
 115, 197, 116, 117, 118, 119, 110, 111, 112, 113,
 114,  47,   8, 122,   8,   0,   0,   0,   8,   0,
   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
   0,   0,   0,   0,   0,   0,   0,   0,   8,   0,
   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
   0,   8, 104,   0,   0,   0,   0,   0,   0,   0,
   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
   0,   0,   0,   0,   8,   0,   0,   0,   0,   0,
   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
   0,   0,   0,   8,
};
yypact := array[] of {
 860,-1000, 948,-1000,-1000,  16, 948, -51, -25,-1000,
 522, 212,-1000,-1000,-1000,-1000,-1000,-1000,-1000,-1000,
-1000,-1000,-1000,-1000, 250,-1000, 948,-1000, -11, 239,
 196, 511, 149,-1000, 150,-1000, -68,-1000,-1000, 832,
 339,-1000,1197,  92,  11,-1000, -11,-1000, 327, 327,
 592, 166, -14,1077, 470, 327, -69, -70, -71, -72,
 -73, -74, -76, -77, -79, -90, 247,-1000, 113,-1000,
  55,-1000, 430, 430, 430, 430, 430, 430, 430, 430,
 430, 149, 801, 327, 239,-1000,-1000, 167, 250,  32,
-1000, 257,1445,  41, 327, 166,-1000,-1000, 250,-1000,
-1000, 948,  69, -42, -25,1221,-1000, 327, 592, 592,
 327, 327, 327, 327, 327, 327, 327, 327, 327, 327,
 327, 327, 327,-1000, 719, 661,-1000, -45, -45, -93,
  58, 885,-1000,-1000,-1000,-1000,-1000,-1000, 263, 112,
 -57,-1000,-1000,-1000,-1000,-1000,-1000,-1000,-1000,  98,
 -60,-1000, -45, 327, 327, 327, 327, 327, 327,-110,
 327, 327, 327, -61, 309, 238,-1000,-1000,-1000,-1000,
 176,-1000, 327,1445, 327, 592, 592, 592, 592, 580,
-1000,-1000,-1000, 327, 327, 650, 327,-1000, 250,-1000,
1445,-1000,-1000,-1000, 327, 327, 240, 327, 250, 250,
1172, -81,-1000,-1000,1445,  33,  -5,  35, -43, -43,
 -45, -45, -45, -26, -26, -26, -26, -26, -83, 684,
 -45,1316, 327, 166,1297, 327, 166,-1000, 202,-1000,
-1000,-1000,-1000, 244,-1000, 233,1147,1122,1097,1072,
1278,1047,-1000,1259,1240,1022, 242,-1000, -62,-1000,
 -80,-1000,1445,1445,   3,   3,   3,   3, 247, 226,
   3,1445,1445,1445, -14,1445,-1000,1429, 394,-1000,
 -26,-1000,-1000,-1000, 327, 592, 592, 327, 910, 327,
 117,-111, -21, 309, 238,-1000,-1000,-1000,-1000,-1000,
-1000,-1000,-1000, 327,-1000, 327, 327,-1000, 223, 203,
  91, 430, 327, 327, -84,1445,  50,   3,1445, 327,
1445, 327,-1000, 997, 972, 947,-1000,1412,1396,-1000,
 327,-1000, 831, 802,-1000,-1000,-1000,  87,-1000,  87,
-1000,1445,-1000,-1000, 327,-1000,-1000,-1000,-1000, 327,
1377,1361,-1000,-1000,
};
yypgo := array[] of {
   0,   0, 332,1551, 330, 142,   1, 329, 328, 327,
 326, 325, 267, 266,  29, 324, 311,  23,   5, 282,
   3,   4,   2, 298, 295, 288, 147,  67, 286, 284,
};
yyr1 := array[] of {
   0,  23,  23,  23,  13,  13,  12,  12,  12,  12,
  12,  12,  12,  12,  12,  12,  12,  12,  12,  12,
  12,  24,  24,  24,  24,   3,  10,  25,  25,  26,
  26,  26,   9,   9,   9,   9,   8,   8,   2,   2,
   2,   4,   6,   6,   6,   6,   6,  11,  16,  16,
  16,  16,  16,  16,  16,  16,  16,  16,  28,  16,
  15,  27,  27,  29,  29,  29,  29,  29,  29,  29,
  29,  29,  29,  29,  29,  29,  29,  29,  29,  29,
  29,  29,  29,  29,  29,  29,  29,  29,  29,  29,
  19,  19,  20,  20,  20,   5,   5,   5,   7,   7,
  14,  14,  14,  14,  14,  14,  14,  14,  14,  14,
  14,  14,  17,  17,  17,  17,  17,  17,  17,  17,
  17,  17,  17,  17,  17,  18,  18,  18,  21,  21,
  21,  22,  22,  22,  22,  22,  22,  22,  22,   1,
   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,
   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,
   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,
   1,   1,   1,   1,   1,   1,   1,   1,
};
yyr2 := array[] of {
   0,   1,   0,   1,   1,   2,   2,   3,   3,   4,
   4,   2,   1,   3,   3,   3,   3,   1,   1,   1,
   1,   0,   1,   2,   3,   3,   2,   1,   2,   1,
   2,   2,  10,   7,  10,   7,   4,   3,   1,   3,
   3,   1,   1,   1,   1,   1,   0,   1,   2,   2,
   2,   2,   2,   2,   2,   2,   2,   1,   0,   5,
   1,   2,   0,   2,   1,   1,   2,   1,   2,   2,
   2,   2,   2,   3,   4,   2,   1,   1,   1,   2,
   1,   2,   1,   2,   1,   2,   2,   1,   1,   1,
   1,   2,   1,   2,   2,   1,   4,   6,   1,   3,
   1,   3,   3,   5,   5,   7,   7,   3,   3,   5,
   6,   5,   1,   2,   2,   1,   2,   3,   3,   2,
   3,   3,   1,   2,   2,   4,   4,   3,   2,   2,
   1,   1,   1,   1,   1,   1,   1,   1,   1,   1,
   1,   1,   3,   3,   3,   3,   3,   2,   2,   3,
   2,   2,   2,   2,   2,   3,   4,   4,   3,   3,
   3,   3,   3,   3,   3,   3,   2,   4,   4,   3,
   4,   4,   6,   4,   3,   6,   6,   4,
};
yychk := array[] of {
-1000, -23, -13,   2, -12, -16, -11,  27,  -3,  85,
  17,  18, -10,  -9,  -8,  91,   4,   7,   8,   9,
   5,   6,  10,  14, -19,  13, -15, 112,  28,  23,
  21,  22, -20, 114,  -5,  12,  29, -12,  91, -13,
 110,  91,  -1, -14,  -5,  74,  28,  -3, 102, 101,
 116, -17,  27, -21,  55, 107,  75,  76,  77,  78,
  79,  80,  81,  83,  82,  84,  52,  53, -18,  54,
 -24,  28, -27, -27, -27, -27, -27, -27, -27, -27,
 -27, -20, -13,  92, -25, -26,  -5,  19,  20,  -4,
  28,  -2,  -1,  -5, 116, -17,  32,  32, 116, 109,
 -12,  91, -14,  27,  -3,  -1,  91, 111,  96,  57,
 101, 102, 103, 104, 105,  95,  97,  98,  99, 100,
  94,  93, 108,  91, 101, 102,  91,  -1,  -1, -14,
 -17,  -1,  69,  70,  71,  72,  73,  52, 115, -22,
  11,  54,   4,   7,   8,   9,   5,   6,  10, -22,
  11,  54,  -1, 116, 116, 116, 116, 116, 116, 116,
 116, 116, 116,  27, -21,  55, -18,  52,  91,  28,
 111, -29,  31,  -1,  85,  37,  38,  39,  40,  41,
  56,  32,  42,  86,  87,  88,  89,  90, -19, 113,
  -1, -26,  30,  -5,  37,  92,  24,  96,  99, 100,
  -1,  -5, -12,  91,  -1, -14,  -1, -14,  -1,  -1,
  -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,
  -1,  -1, 116, -17,  -1, 116, -17, 117, 111, 117,
  27,  28,  52, 115,  52, 115,  -1,  -1,  -1,  -1,
  -1,  -1, 117,  -1,  -1,  -1, 115, -22,  11, -22,
  11,  28,  -1,  -1, -14, -14, -14, -14,  52, 115,
 -14,  -1,  -1,  -1,  27,  -1, -28,  -1,  -1,  25,
  -1,  -5,  -5, 117, 111, 111,  58, 111,  -1, 111,
  -1, -17,  27, -21,  55,  27,  28,  27,  28, 117,
 117, 117, 117, 111, 117, 111, 111, 117, 115, 115,
  27, -27,  38,  38,  -7,  -1, -14, -14,  -1, 111,
  -1, 111, 117,  -1,  -1,  -1,  52,  -1,  -1, 117,
 111,  95,  -1,  -1, 117, 117, 117,  40,  26,  40,
  26,  -1, 117, 117,  -6, 101, 102, 103, 104,  -6,
  -1,  -1,  26,  26,
};
yydef := array[] of {
  -2,  -2,   1,   3,   4,   0,   0,   0,   0,  12,
   0,  21,  17,  18,  19,  20,  62,  62,  62,  62,
  62,  62,  62,  62,  62,  57,   0,  47,   0,   0,
   0,   0,  90,  60,  92,  95,   0,   5,   6,   0,
   0,  11,   0,   0,   0, 139, 140, 141,   0,   0,
   0, 100, 112,   0,   0,   0,   0,   0,   0,   0,
   0,   0,   0,   0,   0,   0,   0, 115, 122, 130,
   0,  22,  48,  49,  50,  51,  52,  53,  54,  55,
  56,  91,   0,   0,  26,  27,  29,   0,   0,   0,
  41,   0,  38,   0,   0,   0,  94,  93,   0,   7,
   8,  20,   0, 112, 141,   0,  13,   0,   0,   0,
   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
   0,   0,   0,  14,   0,   0,  15, 147, 148,   0,
 100,   0, 150, 151, 152, 153, 154, 113,   0, 116,
 138, 128, 131, 132, 133, 134, 135, 136, 137, 119,
 138, 129, 166,   0,   0,   0,   0,   0,   0,   0,
   0,   0,   0, 114,   0,   0, 124, 123,  16,  23,
   0,  61,  64,  65,  67,   0,   0,   0,   0,   0,
  76,  77,  78,  80,  82,  84,  87,  88,  89,  58,
  25,  28,  30,  31,   0,   0,  37,   0,   0,   0,
   0,   0,   9,  10, 102,   0,  -2,   0, 142, 143,
 144, 145, 146,  -2,  -2,  -2,  -2,  -2, 164, 165,
 169,   0,   0, 107,   0,   0, 108, 101,   0, 149,
 127, 155, 117,   0, 120,   0,   0,   0,   0,   0,
   0,   0, 174,   0,   0,   0,   0, 118, 138, 121,
 138,  24,  63,  66,  68,  69,  70,  71,  72,   0,
  75,  79,  81,  83,  -2,  86,  62,   0,   0,  36,
  -2,  39,  40,  96,   0,   0,   0,   0,   0,   0,
   0,   0, 112,   0,   0, 125, 156, 126, 157, 167,
 168, 170, 171,   0, 173,   0,   0, 177,   0,   0,
  73,  59,   0,   0,   0,  98,   0, 111, 103,   0,
 104,   0, 109,   0,   0,   0,  74,   0,   0,  97,
   0, 110,   0,   0, 172, 175, 176,  46,  33,  46,
  35,  99, 105, 106,   0,  42,  43,  44,  45,   0,
   0,   0,  32,  34,
};
yytok1 := array[] of {
   1,   4,   5,   6,   7,   8,   9,  10,  11,  12,
  13,  14,  15,  16,   3,   3,   3,   3,   3,   3,
   3,   3,   3,   3,   3,   3,   3,   3,   3,   3,
   3,   3,   3,   3,   3,   3,   3, 105,   3,   3,
 116, 117, 103, 101, 111, 102, 115, 104,   3,   3,
   3,   3,   3,   3,   3,   3,   3,   3, 110,   3,
   3,  92,   3,   3,   3,   3,   3,   3,   3,   3,
   3,   3,   3,   3,   3,   3,   3,   3,   3,   3,
   3,   3,   3,   3,   3,   3,   3,   3,   3,   3,
   3, 114,   3, 113, 108,   3,   3,   3,   3,   3,
   3,   3,   3,   3,   3,   3,   3,   3,   3,   3,
   3,   3,   3,   3,   3,   3,   3,   3,   3,   3,
   3,   3,   3, 112,   3, 109,
};
yytok2 := array[] of {
   2,   3,   0,   0,   0,   0,   0,   0,   0,   0,
   0,   0,   0,   0,   0,  17,  18,  19,  20,  21,
  22,  23,  24,  25,  26,  27,  28,  29,  30,  31,
  32,  33,  34,  35,  36,  37,  38,  39,  40,  41,
  42,  43,  44,  45,  46,  47,  48,  49,  50,  51,
  52,  53,  54,  55,  56,  57,  58,  59,  60,  61,
  62,  63,  64,  65,  66,  67,  68,  69,  70,  71,
  72,  73,  74,  75,  76,  77,  78,  79,  80,  81,
  82,  83,  84,  85,  86,  87,  88,  89,  90,  91,
  93,  94,  95,  96,  97,  98,  99, 100, 106, 107,
};
yytok3 := array[] of {
   0
};

YYSys: module
{
	FD: adt
	{
		fd:	int;
	};
	fildes:		fn(fd: int): ref FD;
	fprint:		fn(fd: ref FD, s: string, *): int;
};

yysys: YYSys;
yystderr: ref YYSys->FD;

YYFLAG: con -1000;

# parser for yacc output

yytokname(yyc: int): string
{
	if(yyc > 0 && yyc <= len yytoknames && yytoknames[yyc-1] != nil)
		return yytoknames[yyc-1];
	return "<"+string yyc+">";
}

yystatname(yys: int): string
{
	if(yys >= 0 && yys < len yystates && yystates[yys] != nil)
		return yystates[yys];
	return "<"+string yys+">\n";
}

yylex1(yylex: ref YYLEX): int
{
	c : int;
	yychar := yylex.lex();
	if(yychar <= 0)
		c = yytok1[0];
	else if(yychar < len yytok1)
		c = yytok1[yychar];
	else if(yychar >= YYPRIVATE && yychar < YYPRIVATE+len yytok2)
		c = yytok2[yychar-YYPRIVATE];
	else{
		n := len yytok3;
		c = 0;
		for(i := 0; i < n; i+=2) {
			if(yytok3[i+0] == yychar) {
				c = yytok3[i+1];
				break;
			}
		}
		if(c == 0)
			c = yytok2[1];	# unknown char
	}
	if(yydebug >= 3)
		yysys->fprint(yystderr, "lex %.4ux %s\n", yychar, yytokname(c));
	return c;
}

YYS: adt
{
	yyv: YYSTYPE;
	yys: int;
};

yyparse(yylex: ref YYLEX): int
{
	if(yydebug >= 1 && yysys == nil) {
		yysys = load YYSys "$Sys";
		yystderr = yysys->fildes(2);
	}

	yys := array[YYMAXDEPTH] of YYS;

	yyval: YYSTYPE;
	yystate := 0;
	yychar := -1;
	yynerrs := 0;		# number of errors
	yyerrflag := 0;		# error recovery flag
	yyp := -1;
	yyn := 0;

yystack:
	for(;;){
		# put a state and value onto the stack
		if(yydebug >= 4)
			yysys->fprint(yystderr, "char %s in %s", yytokname(yychar), yystatname(yystate));

		yyp++;
		if(yyp >= len yys)
			yys = (array[len yys * 2] of YYS)[0:] = yys;
		yys[yyp].yys = yystate;
		yys[yyp].yyv = yyval;

		for(;;){
			yyn = yypact[yystate];
			if(yyn > YYFLAG) {	# simple state
				if(yychar < 0)
					yychar = yylex1(yylex);
				yyn += yychar;
				if(yyn >= 0 && yyn < YYLAST) {
					yyn = yyact[yyn];
					if(yychk[yyn] == yychar) { # valid shift
						yychar = -1;
						yyp++;
						if(yyp >= len yys)
							yys = (array[len yys * 2] of YYS)[0:] = yys;
						yystate = yyn;
						yys[yyp].yys = yystate;
						yys[yyp].yyv = yylex.lval;
						if(yyerrflag > 0)
							yyerrflag--;
						if(yydebug >= 4)
							yysys->fprint(yystderr, "char %s in %s", yytokname(yychar), yystatname(yystate));
						continue;
					}
				}
			}
		
			# default state action
			yyn = yydef[yystate];
			if(yyn == -2) {
				if(yychar < 0)
					yychar = yylex1(yylex);
		
				# look through exception table
				for(yyxi:=0;; yyxi+=2)
					if(yyexca[yyxi] == -1 && yyexca[yyxi+1] == yystate)
						break;
				for(yyxi += 2;; yyxi += 2) {
					yyn = yyexca[yyxi];
					if(yyn < 0 || yyn == yychar)
						break;
				}
				yyn = yyexca[yyxi+1];
				if(yyn < 0){
					yyn = 0;
					break yystack;
				}
			}

			if(yyn != 0)
				break;

			# error ... attempt to resume parsing
			if(yyerrflag == 0) { # brand new error
				yylex.error("syntax error");
				yynerrs++;
				if(yydebug >= 1) {
					yysys->fprint(yystderr, "%s", yystatname(yystate));
					yysys->fprint(yystderr, "saw %s\n", yytokname(yychar));
				}
			}

			if(yyerrflag != 3) { # incompletely recovered error ... try again
				yyerrflag = 3;
	
				# find a state where "error" is a legal shift action
				while(yyp >= 0) {
					yyn = yypact[yys[yyp].yys] + YYERRCODE;
					if(yyn >= 0 && yyn < YYLAST) {
						yystate = yyact[yyn];  # simulate a shift of "error"
						if(yychk[yystate] == YYERRCODE)
							continue yystack;
					}
	
					# the current yyp has no shift onn "error", pop stack
					if(yydebug >= 2)
						yysys->fprint(yystderr, "error recovery pops state %d, uncovers %d\n",
							yys[yyp].yys, yys[yyp-1].yys );
					yyp--;
				}
				# there is no state on the stack with an error shift ... abort
				yyn = 1;
				break yystack;
			}

			# no shift yet; clobber input char
			if(yydebug >= 2)
				yysys->fprint(yystderr, "error recovery discards %s\n", yytokname(yychar));
			if(yychar == YYEOFCODE) {
				yyn = 1;
				break yystack;
			}
			yychar = -1;
			# try again in the same state
		}
	
		# reduction by production yyn
		if(yydebug >= 2)
			yysys->fprint(yystderr, "reduce %d in:\n\t%s", yyn, yystatname(yystate));
	
		yypt := yyp;
		yyp -= yyr2[yyn];
		# $$ is $1 until an action says otherwise, as in C's yacc
		yyval = yys[yyp+1].yyv;
		yym := yyn;
	
		# consult goto table to find next state
		yyn = yyr1[yyn];
		yyg := yypgo[yyn];
		yyj := yyg + yys[yyp].yys + 1;
	
		if(yyj >= YYLAST || yychk[yystate=yyact[yyj]] != -yyn)
			yystate = yyact[yyg];
		case yym {
			
3=>
#line	126	"pic.y"
{ error("syntax error"); }
4=>
yyval.o = yys[yyp+1].yyv.o;
5=>
yyval.o = yys[yyp+1].yyv.o;
6=>
#line	135	"pic.y"
{ codegen = 1; makeiattr(0, 0); }
7=>
#line	136	"pic.y"
{ rightthing(yys[yypt-2].yyv.o, '}'); yyval.o = yys[yypt-1].yyv.o; }
8=>
#line	137	"pic.y"
{ y.o=yys[yypt-0].yyv.o; makevar(yys[yypt-2].yyv.p,PLACENAME,y); yyval.o = yys[yypt-0].yyv.o; }
9=>
#line	138	"pic.y"
{ y.o=yys[yypt-0].yyv.o; makevar(yys[yypt-3].yyv.p,PLACENAME,y); yyval.o = yys[yypt-0].yyv.o; }
10=>
#line	139	"pic.y"
{ y.o=yys[yypt-1].yyv.o; makevar(yys[yypt-3].yyv.p,PLACENAME,y); yyval.o = yys[yypt-1].yyv.o; }
11=>
#line	140	"pic.y"
{ y.f = yys[yypt-1].yyv.f; yyval.o = y.o; yyval.o = makenode(PLACE, 0); }
12=>
#line	141	"pic.y"
{ setdir(yys[yypt-0].yyv.i); yyval.o = makenode(PLACE, 0); }
13=>
#line	142	"pic.y"
{ printexpr(yys[yypt-1].yyv.f); yyval.o = makenode(PLACE, 0); }
14=>
#line	143	"pic.y"
{ printpos(yys[yypt-1].yyv.o); yyval.o = makenode(PLACE, 0); }
15=>
#line	144	"pic.y"
{ out(yys[yypt-1].yyv.p + "\n"); yyval.o = makenode(PLACE, 0); }
16=>
#line	145	"pic.y"
{ resetvar(); makeiattr(0, 0); yyval.o = makenode(PLACE, 0); }
17=>
yyval.o = yys[yyp+1].yyv.o;
18=>
yyval.o = yys[yyp+1].yyv.o;
19=>
yyval.o = yys[yyp+1].yyv.o;
20=>
yyval.o = yys[yyp+1].yyv.o;
22=>
#line	154	"pic.y"
{ makevattr(yys[yypt-0].yyv.p); }
23=>
#line	155	"pic.y"
{ makevattr(yys[yypt-0].yyv.p); }
24=>
#line	156	"pic.y"
{ makevattr(yys[yypt-0].yyv.p); }
25=>
#line	160	"pic.y"
{ yyval.f=y.f=yys[yypt-0].yyv.f; makevar(yys[yypt-2].yyv.p,VARNAME,y); checkscale(yys[yypt-2].yyv.p); }
26=>
#line	164	"pic.y"
{ copy(); }
29=>
#line	171	"pic.y"
{ copyfile(yys[yypt-0].yyv.p); }
30=>
#line	172	"pic.y"
{ copydef(yys[yypt-0].yyv.st); }
31=>
#line	173	"pic.y"
{ copyuntil(yys[yypt-0].yyv.p); }
32=>
#line	178	"pic.y"
{ forloop(yys[yypt-8].yyv.p, yys[yypt-6].yyv.f, yys[yypt-4].yyv.f, yys[yypt-2].yyv.i, yys[yypt-1].yyv.f, yys[yypt-0].yyv.p); }
33=>
#line	180	"pic.y"
{ forloop(yys[yypt-5].yyv.p, yys[yypt-3].yyv.f, yys[yypt-1].yyv.f, '+', 1.0, yys[yypt-0].yyv.p); }
34=>
#line	182	"pic.y"
{ forloop(yys[yypt-8].yyv.p, yys[yypt-6].yyv.f, yys[yypt-4].yyv.f, yys[yypt-2].yyv.i, yys[yypt-1].yyv.f, yys[yypt-0].yyv.p); }
35=>
#line	184	"pic.y"
{ forloop(yys[yypt-5].yyv.p, yys[yypt-3].yyv.f, yys[yypt-1].yyv.f, '+', 1.0, yys[yypt-0].yyv.p); }
36=>
#line	188	"pic.y"
{ ifstat(yys[yypt-2].yyv.f, yys[yypt-1].yyv.p, yys[yypt-0].yyv.p); }
37=>
#line	189	"pic.y"
{ ifstat(yys[yypt-1].yyv.f, yys[yypt-0].yyv.p, NULLP); }
38=>
yyval.f = yys[yyp+1].yyv.f;
39=>
#line	193	"pic.y"
{ yyval.f = real (yys[yypt-2].yyv.p == yys[yypt-0].yyv.p); }
40=>
#line	194	"pic.y"
{ yyval.f = real (yys[yypt-2].yyv.p != yys[yypt-0].yyv.p); }
41=>
#line	198	"pic.y"
{ y.f = 0.0; makevar(yys[yypt-0].yyv.p, VARNAME, y); }
42=>
#line	201	"pic.y"
{ yyval.i = '+'; }
43=>
#line	202	"pic.y"
{ yyval.i = '-'; }
44=>
#line	203	"pic.y"
{ yyval.i = '*'; }
45=>
#line	204	"pic.y"
{ yyval.i = '/'; }
46=>
#line	205	"pic.y"
{ yyval.i = ' '; }
47=>
#line	210	"pic.y"
{ yyval.o = leftthing('{'); }
48=>
#line	214	"pic.y"
{ yyval.o = boxgen(); }
49=>
#line	215	"pic.y"
{ yyval.o = circgen(yys[yypt-1].yyv.i); }
50=>
#line	216	"pic.y"
{ yyval.o = circgen(yys[yypt-1].yyv.i); }
51=>
#line	217	"pic.y"
{ yyval.o = arcgen(yys[yypt-1].yyv.i); }
52=>
#line	218	"pic.y"
{ yyval.o = linegen(yys[yypt-1].yyv.i); }
53=>
#line	219	"pic.y"
{ yyval.o = linegen(yys[yypt-1].yyv.i); }
54=>
#line	220	"pic.y"
{ yyval.o = linegen(yys[yypt-1].yyv.i); }
55=>
#line	221	"pic.y"
{ yyval.o = movegen(); }
56=>
#line	222	"pic.y"
{ yyval.o = textgen(); }
57=>
#line	223	"pic.y"
{ yyval.o = troffgen(yys[yypt-0].yyv.p); }
58=>
#line	224	"pic.y"
{ yyval.o=rightthing(yys[yypt-2].yyv.o,']'); }
59=>
#line	225	"pic.y"
{ yyval.o = blockgen(yys[yypt-4].yyv.o, yys[yypt-1].yyv.o); }
60=>
#line	229	"pic.y"
{ yyval.o = leftthing('['); }
63=>
#line	238	"pic.y"
{ makefattr(yys[yypt-1].yyv.i, !DEFAULT, yys[yypt-0].yyv.f); }
64=>
#line	239	"pic.y"
{ makefattr(yys[yypt-0].yyv.i, DEFAULT, 0.0); }
65=>
#line	240	"pic.y"
{ makefattr(curdir(), !DEFAULT, yys[yypt-0].yyv.f); }
66=>
#line	241	"pic.y"
{ makefattr(yys[yypt-1].yyv.i, !DEFAULT, yys[yypt-0].yyv.f); }
67=>
#line	242	"pic.y"
{ makefattr(yys[yypt-0].yyv.i, DEFAULT, 0.0); }
68=>
#line	243	"pic.y"
{ makeoattr(yys[yypt-1].yyv.i, yys[yypt-0].yyv.o); }
69=>
#line	244	"pic.y"
{ makeoattr(yys[yypt-1].yyv.i, yys[yypt-0].yyv.o); }
70=>
#line	245	"pic.y"
{ makeoattr(yys[yypt-1].yyv.i, yys[yypt-0].yyv.o); }
71=>
#line	246	"pic.y"
{ makeoattr(yys[yypt-1].yyv.i, yys[yypt-0].yyv.o); }
72=>
#line	247	"pic.y"
{ makeiattr(WITH, yys[yypt-0].yyv.i); }
73=>
#line	248	"pic.y"
{ makeoattr(PLACE, getblock(getlast(1,BLOCK), yys[yypt-0].yyv.p)); }
74=>
#line	250	"pic.y"
{ makeoattr(PLACE, getpos(getblock(getlast(1,BLOCK), yys[yypt-1].yyv.p), yys[yypt-0].yyv.i)); }
75=>
#line	251	"pic.y"
{ makeoattr(PLACE, yys[yypt-0].yyv.o); }
76=>
#line	252	"pic.y"
{ makeiattr(SAME, yys[yypt-0].yyv.i); }
77=>
#line	253	"pic.y"
{ maketattr(yys[yypt-0].yyv.i, NULLP); }
78=>
#line	254	"pic.y"
{ makeiattr(HEAD, yys[yypt-0].yyv.i); }
79=>
#line	255	"pic.y"
{ makefattr(DOT, !DEFAULT, yys[yypt-0].yyv.f); }
80=>
#line	256	"pic.y"
{ makefattr(DOT, DEFAULT, 0.0); }
81=>
#line	257	"pic.y"
{ makefattr(DASH, !DEFAULT, yys[yypt-0].yyv.f); }
82=>
#line	258	"pic.y"
{ makefattr(DASH, DEFAULT, 0.0); }
83=>
#line	259	"pic.y"
{ makefattr(CHOP, !DEFAULT, yys[yypt-0].yyv.f); }
84=>
#line	260	"pic.y"
{ makefattr(CHOP, DEFAULT, 0.0); }
85=>
#line	261	"pic.y"
{ makeattr(CHOP, PLACENAME, getvar(yys[yypt-0].yyv.p)); }
86=>
#line	262	"pic.y"
{ makefattr(FILL, !DEFAULT, yys[yypt-0].yyv.f); }
87=>
#line	263	"pic.y"
{ makefattr(FILL, DEFAULT, 0.0); }
88=>
#line	264	"pic.y"
{ makeiattr(NOEDGE, 0); }
90=>
yyval.i = yys[yyp+1].yyv.i;
91=>
yyval.i = yys[yyp+1].yyv.i;
92=>
#line	273	"pic.y"
{ maketattr(CENTER, yys[yypt-0].yyv.p); }
93=>
#line	274	"pic.y"
{ maketattr(yys[yypt-0].yyv.i, yys[yypt-1].yyv.p); }
94=>
#line	275	"pic.y"
{ addtattr(yys[yypt-0].yyv.i); }
95=>
yyval.p = yys[yyp+1].yyv.p;
96=>
#line	279	"pic.y"
{ yyval.p = sprintgen(yys[yypt-1].yyv.p); }
97=>
#line	280	"pic.y"
{ yyval.p = sprintgen(yys[yypt-3].yyv.p); }
98=>
#line	284	"pic.y"
{ exprsave(yys[yypt-0].yyv.f); yyval.i = 0; }
99=>
#line	285	"pic.y"
{ exprsave(yys[yypt-0].yyv.f); }
100=>
yyval.o = yys[yyp+1].yyv.o;
101=>
#line	290	"pic.y"
{ yyval.o = yys[yypt-1].yyv.o; }
102=>
#line	291	"pic.y"
{ yyval.o = makepos(yys[yypt-2].yyv.f, yys[yypt-0].yyv.f); }
103=>
#line	292	"pic.y"
{ yyval.o = fixpos(yys[yypt-4].yyv.o, yys[yypt-2].yyv.f, yys[yypt-0].yyv.f); }
104=>
#line	293	"pic.y"
{ yyval.o = fixpos(yys[yypt-4].yyv.o, -yys[yypt-2].yyv.f, -yys[yypt-0].yyv.f); }
105=>
#line	294	"pic.y"
{ yyval.o = fixpos(yys[yypt-6].yyv.o, yys[yypt-3].yyv.f, yys[yypt-1].yyv.f); }
106=>
#line	295	"pic.y"
{ yyval.o = fixpos(yys[yypt-6].yyv.o, -yys[yypt-3].yyv.f, -yys[yypt-1].yyv.f); }
107=>
#line	296	"pic.y"
{ yyval.o = addpos(yys[yypt-2].yyv.o, yys[yypt-0].yyv.o); }
108=>
#line	297	"pic.y"
{ yyval.o = subpos(yys[yypt-2].yyv.o, yys[yypt-0].yyv.o); }
109=>
#line	298	"pic.y"
{ yyval.o = makepos(getcomp(yys[yypt-3].yyv.o,DOTX), getcomp(yys[yypt-1].yyv.o,DOTY)); }
110=>
#line	299	"pic.y"
{ yyval.o = makebetween(yys[yypt-5].yyv.f, yys[yypt-3].yyv.o, yys[yypt-1].yyv.o); }
111=>
#line	300	"pic.y"
{ yyval.o = makebetween(yys[yypt-4].yyv.f, yys[yypt-2].yyv.o, yys[yypt-0].yyv.o); }
112=>
#line	304	"pic.y"
{ y = getvar(yys[yypt-0].yyv.p); yyval.o = y.o; if(yyval.o == nil) fatal("null object"); }
113=>
#line	305	"pic.y"
{ y = getvar(yys[yypt-1].yyv.p); yyval.o = getpos(y.o, yys[yypt-0].yyv.i); }
114=>
#line	306	"pic.y"
{ y = getvar(yys[yypt-0].yyv.p); yyval.o = getpos(y.o, yys[yypt-1].yyv.i); }
115=>
#line	307	"pic.y"
{ yyval.o = gethere(); }
116=>
#line	308	"pic.y"
{ yyval.o = getlast(yys[yypt-1].yyv.i, yys[yypt-0].yyv.i); }
117=>
#line	309	"pic.y"
{ yyval.o = getpos(getlast(yys[yypt-2].yyv.i, yys[yypt-1].yyv.i), yys[yypt-0].yyv.i); }
118=>
#line	310	"pic.y"
{ yyval.o = getpos(getlast(yys[yypt-1].yyv.i, yys[yypt-0].yyv.i), yys[yypt-2].yyv.i); }
119=>
#line	311	"pic.y"
{ yyval.o = getfirst(yys[yypt-1].yyv.i, yys[yypt-0].yyv.i); }
120=>
#line	312	"pic.y"
{ yyval.o = getpos(getfirst(yys[yypt-2].yyv.i, yys[yypt-1].yyv.i), yys[yypt-0].yyv.i); }
121=>
#line	313	"pic.y"
{ yyval.o = getpos(getfirst(yys[yypt-1].yyv.i, yys[yypt-0].yyv.i), yys[yypt-2].yyv.i); }
122=>
yyval.o = yys[yyp+1].yyv.o;
123=>
#line	315	"pic.y"
{ yyval.o = getpos(yys[yypt-1].yyv.o, yys[yypt-0].yyv.i); }
124=>
#line	316	"pic.y"
{ yyval.o = getpos(yys[yypt-0].yyv.o, yys[yypt-1].yyv.i); }
125=>
#line	320	"pic.y"
{ yyval.o = getblock(getlast(yys[yypt-3].yyv.i,yys[yypt-2].yyv.i), yys[yypt-0].yyv.p); }
126=>
#line	321	"pic.y"
{ yyval.o = getblock(getfirst(yys[yypt-3].yyv.i,yys[yypt-2].yyv.i), yys[yypt-0].yyv.p); }
127=>
#line	322	"pic.y"
{ y = getvar(yys[yypt-2].yyv.p); yyval.o = getblock(y.o, yys[yypt-0].yyv.p); }
128=>
#line	326	"pic.y"
{ yyval.i = yys[yypt-1].yyv.i + 1; }
129=>
#line	327	"pic.y"
{ yyval.i = yys[yypt-1].yyv.i; }
130=>
#line	328	"pic.y"
{ yyval.i = 1; }
131=>
yyval.i = yys[yyp+1].yyv.i;
132=>
yyval.i = yys[yyp+1].yyv.i;
133=>
yyval.i = yys[yyp+1].yyv.i;
134=>
yyval.i = yys[yyp+1].yyv.i;
135=>
yyval.i = yys[yyp+1].yyv.i;
136=>
yyval.i = yys[yyp+1].yyv.i;
137=>
yyval.i = yys[yyp+1].yyv.i;
138=>
yyval.i = yys[yyp+1].yyv.i;
139=>
yyval.f = yys[yyp+1].yyv.f;
140=>
#line	344	"pic.y"
{ yyval.f = getfval(yys[yypt-0].yyv.p); }
141=>
yyval.f = yys[yyp+1].yyv.f;
142=>
#line	346	"pic.y"
{ yyval.f = yys[yypt-2].yyv.f + yys[yypt-0].yyv.f; }
143=>
#line	347	"pic.y"
{ yyval.f = yys[yypt-2].yyv.f - yys[yypt-0].yyv.f; }
144=>
#line	348	"pic.y"
{ yyval.f = yys[yypt-2].yyv.f * yys[yypt-0].yyv.f; }
145=>
#line	349	"pic.y"
{ if (yys[yypt-0].yyv.f == 0.0) {
					error("division by 0"); yys[yypt-0].yyv.f = 1.0; }
				  yyval.f = yys[yypt-2].yyv.f / yys[yypt-0].yyv.f; }
146=>
#line	352	"pic.y"
{ if (clong(yys[yypt-0].yyv.f) == big 0) {
					error("mod division by 0"); yys[yypt-0].yyv.f = 1.0; }
				  yyval.f = real (clong(yys[yypt-2].yyv.f) % clong(yys[yypt-0].yyv.f)); }
147=>
#line	355	"pic.y"
{ yyval.f = -yys[yypt-0].yyv.f; }
148=>
#line	356	"pic.y"
{ yyval.f = yys[yypt-0].yyv.f; }
149=>
#line	357	"pic.y"
{ yyval.f = yys[yypt-1].yyv.f; }
150=>
#line	358	"pic.y"
{ yyval.f = getcomp(yys[yypt-1].yyv.o, yys[yypt-0].yyv.i); }
151=>
#line	359	"pic.y"
{ yyval.f = getcomp(yys[yypt-1].yyv.o, yys[yypt-0].yyv.i); }
152=>
#line	360	"pic.y"
{ yyval.f = getcomp(yys[yypt-1].yyv.o, yys[yypt-0].yyv.i); }
153=>
#line	361	"pic.y"
{ yyval.f = getcomp(yys[yypt-1].yyv.o, yys[yypt-0].yyv.i); }
154=>
#line	362	"pic.y"
{ yyval.f = getcomp(yys[yypt-1].yyv.o, yys[yypt-0].yyv.i); }
155=>
#line	363	"pic.y"
{ y = getvar(yys[yypt-2].yyv.p); yyval.f = getblkvar(y.o, yys[yypt-0].yyv.p); }
156=>
#line	364	"pic.y"
{ yyval.f = getblkvar(getlast(yys[yypt-3].yyv.i,yys[yypt-2].yyv.i), yys[yypt-0].yyv.p); }
157=>
#line	365	"pic.y"
{ yyval.f = getblkvar(getfirst(yys[yypt-3].yyv.i,yys[yypt-2].yyv.i), yys[yypt-0].yyv.p); }
158=>
#line	366	"pic.y"
{ yyval.f = real (yys[yypt-2].yyv.f > yys[yypt-0].yyv.f); }
159=>
#line	367	"pic.y"
{ yyval.f = real (yys[yypt-2].yyv.f < yys[yypt-0].yyv.f); }
160=>
#line	368	"pic.y"
{ yyval.f = real (yys[yypt-2].yyv.f <= yys[yypt-0].yyv.f); }
161=>
#line	369	"pic.y"
{ yyval.f = real (yys[yypt-2].yyv.f >= yys[yypt-0].yyv.f); }
162=>
#line	370	"pic.y"
{ yyval.f = real (yys[yypt-2].yyv.f == yys[yypt-0].yyv.f); }
163=>
#line	371	"pic.y"
{ yyval.f = real (yys[yypt-2].yyv.f != yys[yypt-0].yyv.f); }
164=>
#line	372	"pic.y"
{ yyval.f = real (yys[yypt-2].yyv.f != 0.0 && yys[yypt-0].yyv.f != 0.0); }
165=>
#line	373	"pic.y"
{ yyval.f = real (yys[yypt-2].yyv.f != 0.0 || yys[yypt-0].yyv.f != 0.0); }
166=>
#line	374	"pic.y"
{ yyval.f = real (yys[yypt-0].yyv.f == 0.0); }
167=>
#line	375	"pic.y"
{ yyval.f = errcheck(math->log10(yys[yypt-1].yyv.f), "log"); }
168=>
#line	376	"pic.y"
{ yyval.f = errcheck(math->exp(yys[yypt-1].yyv.f * math->log(10.0)), "exp"); }
169=>
#line	377	"pic.y"
{ yyval.f = errcheck(math->pow(yys[yypt-2].yyv.f, yys[yypt-0].yyv.f), nil); }
170=>
#line	378	"pic.y"
{ yyval.f = math->sin(yys[yypt-1].yyv.f); }
171=>
#line	379	"pic.y"
{ yyval.f = math->cos(yys[yypt-1].yyv.f); }
172=>
#line	380	"pic.y"
{ yyval.f = math->atan2(yys[yypt-3].yyv.f, yys[yypt-1].yyv.f); }
173=>
#line	381	"pic.y"
{ yyval.f = errcheck(math->sqrt(yys[yypt-1].yyv.f), "sqrt"); }
174=>
#line	382	"pic.y"
{ yyval.f = f32(real crand()) / 32767.0; }
175=>
#line	383	"pic.y"
{ if(yys[yypt-3].yyv.f >= yys[yypt-1].yyv.f) yyval.f = yys[yypt-3].yyv.f; else yyval.f = yys[yypt-1].yyv.f; }
176=>
#line	384	"pic.y"
{ if(yys[yypt-3].yyv.f <= yys[yypt-1].yyv.f) yyval.f = yys[yypt-3].yyv.f; else yyval.f = yys[yypt-1].yyv.f; }
177=>
#line	385	"pic.y"
{ yyval.f = real clong(yys[yypt-1].yyv.f); }
		}
	}

	return yyn;
}
