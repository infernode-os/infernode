implement Pdfenc;

#
# The encodings are PDF 32000-1 Annex D (WinAnsi with its undefined
# codes as bullet, as the Annex says); the glyph names Adobe's AGLFN
# and the Symbol and ZapfDingbats names with Unicode's mappings for
# those fonts (ZDINGBAT.TXT).  The tables are strings, split the first
# time they are asked for.
#

include "sys.m";
	sys: Sys;

include "pdfenc.m";

encs: array of array of string;
names: array of list of (string, int);
NHASH: con 512;

encoding(name: string): array of string
{
	i: int;
	case name {
	"StandardEncoding" =>	i = 0;
	"WinAnsiEncoding" =>	i = 1;
	"MacRomanEncoding" =>	i = 2;
	"Symbol" =>	i = 3;
	"ZapfDingbats" =>	i = 4;
	* =>	return nil;
	}
	if(encs == nil)
		encs = array[5] of array of string;
	if(encs[i] == nil){
		s := array[] of {Stdenc, Winenc, Macenc, Symenc, Dbtenc};
		encs[i] = split(s[i]);
	}
	return encs[i];
}

split(s: string): array of string
{
	e := array[256] of string;
	c := 0;
	for(i := 0; i < len s && c < 256; ){
		for(j := i; j < len s && s[j] != ' '; j++)
			;
		if(s[i:j] != ".")
			e[c] = s[i:j];
		c++;
		i = j + 1;
	}
	return e;
}

unicode(name: string): int
{
	if(name == nil)
		return -1;
	if(len name == 7 && name[0:3] == "uni")
		return hex(name[3:]);
	if(len name >= 5 && len name <= 7 && name[0] == 'u')
		return hex(name[1:]);
	if(names == nil)
		loadnames();
	for(l := names[hash(name)]; l != nil; l = tl l){
		(n, u) := hd l;
		if(n == name)
			return u;
	}
	# a name with a suffix: "a.sc", "f_i" (taken as its first part)
	for(i := 1; i < len name; i++)
		if(name[i] == '.' || name[i] == '_')
			return unicode(name[0:i]);
	return -1;
}

hex(s: string): int
{
	v := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= '0' && c <= '9')
			v = v*16 + c - '0';
		else if(c >= 'A' && c <= 'F')
			v = v*16 + c - 'A' + 10;
		else if(c >= 'a' && c <= 'f')
			v = v*16 + c - 'a' + 10;
		else
			return -1;
	}
	return v;
}

hash(s: string): int
{
	h := 0;
	for(i := 0; i < len s; i++)
		h = h*31 + s[i];
	return (h & 16r7FFFFFFF) % NHASH;
}

loadnames()
{
	names = array[NHASH] of list of (string, int);
	s := Glyphnames;
	for(i := 0; i < len s; ){
		for(j := i; j < len s && s[j] != ' '; j++)
			;
		for(k := j + 1; k < len s && s[k] != ' '; k++)
			;
		if(k > len s)
			k = len s;
		n := s[i:j];
		h := hash(n);
		names[h] = (n, hex(s[j+1:k])) :: names[h];
		i = k + 1;
	}
}

Stdenc: con
	". . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . space " +
	"exclam quotedbl numbersign dollar percent ampersand quoteright " +
	"parenleft parenright asterisk plus comma hyphen period slash zero one " +
	"two three four five six seven eight nine colon semicolon less equal " +
	"greater question at A B C D E F G H I J K L M N O P Q R S T U V W X Y " +
	"Z bracketleft backslash bracketright asciicircum underscore quoteleft " +
	"a b c d e f g h i j k l m n o p q r s t u v w x y z braceleft bar " +
	"braceright asciitilde . . . . . . . . . . . . . . . . . . . . . . . . " +
	". . . . . . . . . . exclamdown cent sterling fraction yen florin " +
	"section currency quotesingle quotedblleft guillemotleft guilsinglleft " +
	"guilsinglright fi fl . endash dagger daggerdbl periodcentered . " +
	"paragraph bullet quotesinglbase quotedblbase quotedblright " +
	"guillemotright ellipsis perthousand . questiondown . grave acute " +
	"circumflex tilde macron breve dotaccent dieresis . ring cedilla . " +
	"hungarumlaut ogonek caron emdash . . . . . . . . . . . . . . . . AE . " +
	"ordfeminine . . . . Lslash Oslash OE ordmasculine . . . . . ae . . . " +
	"dotlessi . . lslash oslash oe germandbls . . . .";

Winenc: con
	". . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . space " +
	"exclam quotedbl numbersign dollar percent ampersand quotesingle " +
	"parenleft parenright asterisk plus comma hyphen period slash zero one " +
	"two three four five six seven eight nine colon semicolon less equal " +
	"greater question at A B C D E F G H I J K L M N O P Q R S T U V W X Y " +
	"Z bracketleft backslash bracketright asciicircum underscore grave a b " +
	"c d e f g h i j k l m n o p q r s t u v w x y z braceleft bar " +
	"braceright asciitilde bullet Euro bullet quotesinglbase florin " +
	"quotedblbase ellipsis dagger daggerdbl circumflex perthousand Scaron " +
	"guilsinglleft OE bullet Zcaron bullet bullet quoteleft quoteright " +
	"quotedblleft quotedblright bullet endash emdash tilde trademark scaron " +
	"guilsinglright oe bullet zcaron Ydieresis space exclamdown cent " +
	"sterling currency yen brokenbar section dieresis copyright ordfeminine " +
	"guillemotleft logicalnot hyphen registered macron degree plusminus " +
	"uni00B2 uni00B3 acute mu paragraph periodcentered cedilla uni00B9 " +
	"ordmasculine guillemotright onequarter onehalf threequarters " +
	"questiondown Agrave Aacute Acircumflex Atilde Adieresis Aring AE " +
	"Ccedilla Egrave Eacute Ecircumflex Edieresis Igrave Iacute Icircumflex " +
	"Idieresis Eth Ntilde Ograve Oacute Ocircumflex Otilde Odieresis " +
	"multiply Oslash Ugrave Uacute Ucircumflex Udieresis Yacute Thorn " +
	"germandbls agrave aacute acircumflex atilde adieresis aring ae " +
	"ccedilla egrave eacute ecircumflex edieresis igrave iacute icircumflex " +
	"idieresis eth ntilde ograve oacute ocircumflex otilde odieresis divide " +
	"oslash ugrave uacute ucircumflex udieresis yacute thorn ydieresis";

Macenc: con
	". . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . space " +
	"exclam quotedbl numbersign dollar percent ampersand quotesingle " +
	"parenleft parenright asterisk plus comma hyphen period slash zero one " +
	"two three four five six seven eight nine colon semicolon less equal " +
	"greater question at A B C D E F G H I J K L M N O P Q R S T U V W X Y " +
	"Z bracketleft backslash bracketright asciicircum underscore grave a b " +
	"c d e f g h i j k l m n o p q r s t u v w x y z braceleft bar " +
	"braceright asciitilde . Adieresis Aring Ccedilla Eacute Ntilde " +
	"Odieresis Udieresis aacute agrave acircumflex adieresis atilde aring " +
	"ccedilla eacute egrave ecircumflex edieresis iacute igrave icircumflex " +
	"idieresis ntilde oacute ograve ocircumflex odieresis otilde uacute " +
	"ugrave ucircumflex udieresis dagger degree cent sterling section " +
	"bullet paragraph germandbls registered copyright trademark acute " +
	"dieresis notequal AE Oslash infinity plusminus lessequal greaterequal " +
	"yen mu partialdiff summation product pi integral ordfeminine " +
	"ordmasculine Omega ae oslash questiondown exclamdown logicalnot " +
	"radical florin approxequal Delta guillemotleft guillemotright ellipsis " +
	"nbspace Agrave Atilde Otilde OE oe endash emdash quotedblleft " +
	"quotedblright quoteleft quoteright divide lozenge ydieresis Ydieresis " +
	"fraction currency guilsinglleft guilsinglright fi fl daggerdbl " +
	"periodcentered quotesinglbase quotedblbase perthousand Acircumflex " +
	"Ecircumflex Aacute Edieresis Egrave Iacute Icircumflex Idieresis " +
	"Igrave Oacute Ocircumflex apple Ograve Uacute Ucircumflex Ugrave " +
	"dotlessi circumflex tilde macron breve dotaccent ring cedilla " +
	"hungarumlaut ogonek caron";

Symenc: con
	". . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . space " +
	"exclam universal numbersign existential percent ampersand suchthat " +
	"parenleft parenright asteriskmath plus comma minus period slash zero " +
	"one two three four five six seven eight nine colon semicolon less " +
	"equal greater question congruent Alpha Beta Chi Delta Epsilon Phi " +
	"Gamma Eta Iota theta1 Kappa Lambda Mu Nu Omicron Pi Theta Rho Sigma " +
	"Tau Upsilon sigma1 Omega Xi Psi Zeta bracketleft therefore " +
	"bracketright perpendicular underscore radicalex alpha beta chi delta " +
	"epsilon phi gamma eta iota phi1 kappa lambda mu nu omicron pi theta " +
	"rho sigma tau upsilon omega1 omega xi psi zeta braceleft bar " +
	"braceright similar . . . . . . . . . . . . . . . . . . . . . . . . . . " +
	". . . . . . . Euro Upsilon1 minute lessequal fraction infinity florin " +
	"club diamond heart spade arrowboth arrowleft arrowup arrowright " +
	"arrowdown degree plusminus second greaterequal multiply proportional " +
	"partialdiff bullet divide notequal equivalence approxequal ellipsis " +
	"arrowvertex arrowhorizex carriagereturn aleph Ifraktur Rfraktur " +
	"weierstrass circlemultiply circleplus emptyset intersection union " +
	"propersuperset reflexsuperset notsubset propersubset reflexsubset " +
	"element notelement angle gradient registerserif copyrightserif " +
	"trademarkserif product radical dotmath logicalnot logicaland logicalor " +
	"arrowdblboth arrowdblleft arrowdblup arrowdblright arrowdbldown " +
	"lozenge angleleft registersans copyrightsans trademarksans summation " +
	"parenlefttp parenleftex parenleftbt bracketlefttp bracketleftex " +
	"bracketleftbt bracelefttp braceleftmid braceleftbt braceex . " +
	"angleright integral integraltp integralex integralbt parenrighttp " +
	"parenrightex parenrightbt bracketrighttp bracketrightex bracketrightbt " +
	"bracerighttp bracerightmid bracerightbt .";

Dbtenc: con
	". . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . space " +
	"a1 a2 a202 a3 a4 a5 a119 a118 a117 a11 a12 a13 a14 a15 a16 a105 a17 " +
	"a18 a19 a20 a21 a22 a23 a24 a25 a26 a27 a28 a6 a7 a8 a9 a10 a29 a30 " +
	"a31 a32 a33 a34 a35 a36 a37 a38 a39 a40 a41 a42 a43 a44 a45 a46 a47 " +
	"a48 a49 a50 a51 a52 a53 a54 a55 a56 a57 a58 a59 a60 a61 a62 a63 a64 " +
	"a65 a66 a67 a68 a69 a70 a71 a72 a73 a74 a203 a75 a204 a76 a77 a78 a79 " +
	"a81 a82 a83 a84 a97 a98 a99 a100 . . . . . . . . . . . . . . . . . . . " +
	". . . . . . . . . . . . . . . a101 a102 a103 a104 a106 a107 a108 a112 " +
	"a111 a110 a109 a120 a121 a122 a123 a124 a125 a126 a127 a128 a129 a130 " +
	"a131 a132 a133 a134 a135 a136 a137 a138 a139 a140 a141 a142 a143 a144 " +
	"a145 a146 a147 a148 a149 a150 a151 a152 a153 a154 a155 a156 a157 a158 " +
	"a159 a160 a161 a163 a164 a196 a165 a192 a166 a167 a168 a169 a170 a171 " +
	"a172 a173 a162 a174 a175 a176 a177 a178 a179 a193 a180 a199 a181 a200 " +
	"a182 . a201 a183 a184 a197 a185 a194 a198 a186 a195 a187 a188 a189 " +
	"a190 a191 .";

Glyphnames: con
	"A 41 AE c6 AEacute 1fc Aacute c1 Abreve 102 Acircumflex c2 Adieresis " +
	"c4 Agrave c0 Alpha 391 Alphatonos 386 Amacron 100 Aogonek 104 Aring c5 " +
	"Aringacute 1fa Atilde c3 B 42 Beta 392 C 43 Cacute 106 Ccaron 10c " +
	"Ccedilla c7 Ccircumflex 108 Cdotaccent 10a Chi 3a7 D 44 Dcaron 10e " +
	"Dcroat 110 Delta 394 E 45 Eacute c9 Ebreve 114 Ecaron 11a Ecircumflex " +
	"ca Edieresis cb Edotaccent 116 Egrave c8 Emacron 112 Eng 14a Eogonek " +
	"118 Epsilon 395 Epsilontonos 388 Eta 397 Etatonos 389 Eth d0 Euro 20ac " +
	"F 46 G 47 Gamma 393 Gbreve 11e Gcaron 1e6 Gcircumflex 11c Gdotaccent " +
	"120 H 48 H18533 25cf H18543 25aa H18551 25ab H22073 25a1 Hbar 126 " +
	"Hcircumflex 124 I 49 IJ 132 Iacute cd Ibreve 12c Icircumflex ce " +
	"Idieresis cf Idotaccent 130 Ifraktur 2111 Igrave cc Imacron 12a " +
	"Iogonek 12e Iota 399 Iotadieresis 3aa Iotatonos 38a Itilde 128 J 4a " +
	"Jcircumflex 134 K 4b Kappa 39a L 4c Lacute 139 Lambda 39b Lcaron 13d " +
	"Ldot 13f Lslash 141 M 4d Mu 39c N 4e Nacute 143 Ncaron 147 Ntilde d1 " +
	"Nu 39d O 4f OE 152 Oacute d3 Obreve 14e Ocircumflex d4 Odieresis d6 " +
	"Ograve d2 Ohm 2126 Ohorn 1a0 Ohungarumlaut 150 Omacron 14c Omega 3a9 " +
	"Omegatonos 38f Omicron 39f Omicrontonos 38c Oslash d8 Oslashacute 1fe " +
	"Otilde d5 P 50 Phi 3a6 Pi 3a0 Psi 3a8 Q 51 R 52 Racute 154 Rcaron 158 " +
	"Rfraktur 211c Rho 3a1 S 53 SF010000 250c SF020000 2514 SF030000 2510 " +
	"SF040000 2518 SF050000 253c SF060000 252c SF070000 2534 SF080000 251c " +
	"SF090000 2524 SF100000 2500 SF110000 2502 SF190000 2561 SF200000 2562 " +
	"SF210000 2556 SF220000 2555 SF230000 2563 SF240000 2551 SF250000 2557 " +
	"SF260000 255d SF270000 255c SF280000 255b SF360000 255e SF370000 255f " +
	"SF380000 255a SF390000 2554 SF400000 2569 SF410000 2566 SF420000 2560 " +
	"SF430000 2550 SF440000 256c SF450000 2567 SF460000 2568 SF470000 2564 " +
	"SF480000 2565 SF490000 2559 SF500000 2558 SF510000 2552 SF520000 2553 " +
	"SF530000 256b SF540000 256a Sacute 15a Scaron 160 Scedilla 15e " +
	"Scircumflex 15c Sigma 3a3 T 54 Tau 3a4 Tbar 166 Tcaron 164 Theta 398 " +
	"Thorn de U 55 Uacute da Ubreve 16c Ucircumflex db Udieresis dc Ugrave " +
	"d9 Uhorn 1af Uhungarumlaut 170 Umacron 16a Uogonek 172 Upsilon 3a5 " +
	"Upsilon1 3d2 Upsilondieresis 3ab Upsilontonos 38e Uring 16e Utilde 168 " +
	"V 56 W 57 Wacute 1e82 Wcircumflex 174 Wdieresis 1e84 Wgrave 1e80 X 58 " +
	"Xi 39e Y 59 Yacute dd Ycircumflex 176 Ydieresis 178 Ygrave 1ef2 Z 5a " +
	"Zacute 179 Zcaron 17d Zdotaccent 17b Zeta 396 a 61 a1 2701 a10 2721 " +
	"a100 275e a101 2761 a102 2762 a103 2763 a104 2764 a105 2710 a106 2765 " +
	"a107 2766 a108 2767 a109 2660 a11 261b a110 2665 a111 2666 a112 2663 " +
	"a117 2709 a118 2708 a119 2707 a12 261e a120 2460 a121 2461 a122 2462 " +
	"a123 2463 a124 2464 a125 2465 a126 2466 a127 2467 a128 2468 a129 2469 " +
	"a13 270c a130 2776 a131 2777 a132 2778 a133 2779 a134 277a a135 277b " +
	"a136 277c a137 277d a138 277e a139 277f a14 270d a140 2780 a141 2781 " +
	"a142 2782 a143 2783 a144 2784 a145 2785 a146 2786 a147 2787 a148 2788 " +
	"a149 2789 a15 270e a150 278a a151 278b a152 278c a153 278d a154 278e " +
	"a155 278f a156 2790 a157 2791 a158 2792 a159 2793 a16 270f a160 2794 " +
	"a161 2192 a162 27a3 a163 2194 a164 2195 a165 2799 a166 279b a167 279c " +
	"a168 279d a169 279e a17 2711 a170 279f a171 27a0 a172 27a1 a173 27a2 " +
	"a174 27a4 a175 27a5 a176 27a6 a177 27a7 a178 27a8 a179 27a9 a18 2712 " +
	"a180 27ab a181 27ad a182 27af a183 27b2 a184 27b3 a185 27b5 a186 27b8 " +
	"a187 27ba a188 27bb a189 27bc a19 2713 a190 27bd a191 27be a192 279a " +
	"a193 27aa a194 27b6 a195 27b9 a196 2798 a197 27b4 a198 27b7 a199 27ac " +
	"a2 2702 a20 2714 a200 27ae a201 27b1 a202 2703 a203 2750 a204 2752 a21 " +
	"2715 a22 2716 a23 2717 a24 2718 a25 2719 a26 271a a27 271b a28 271c " +
	"a29 2722 a3 2704 a30 2723 a31 2724 a32 2725 a33 2726 a34 2727 a35 2605 " +
	"a36 2729 a37 272a a38 272b a39 272c a4 260e a40 272d a41 272e a42 272f " +
	"a43 2730 a44 2731 a45 2732 a46 2733 a47 2734 a48 2735 a49 2736 a5 2706 " +
	"a50 2737 a51 2738 a52 2739 a53 273a a54 273b a55 273c a56 273d a57 " +
	"273e a58 273f a59 2740 a6 271d a60 2741 a61 2742 a62 2743 a63 2744 a64 " +
	"2745 a65 2746 a66 2747 a67 2748 a68 2749 a69 274a a7 271e a70 274b a71 " +
	"25cf a72 274d a73 25a0 a74 274f a75 2751 a76 25b2 a77 25bc a78 25c6 " +
	"a79 2756 a8 271f a81 25d7 a82 2758 a83 2759 a84 275a a9 2720 a97 275b " +
	"a98 275c a99 275d aacute e1 abreve 103 acircumflex e2 acute b4 " +
	"acutecomb 301 adieresis e4 ae e6 aeacute 1fd agrave e0 aleph 2135 " +
	"alpha 3b1 alphatonos 3ac amacron 101 ampersand 26 angle 2220 angleleft " +
	"2329 angleright 232a anoteleia 387 aogonek 105 apple f8ff approxequal " +
	"2248 aring e5 aringacute 1fb arrowboth 2194 arrowdblboth 21d4 " +
	"arrowdbldown 21d3 arrowdblleft 21d0 arrowdblright 21d2 arrowdblup 21d1 " +
	"arrowdown 2193 arrowhorizex 23af arrowleft 2190 arrowright 2192 " +
	"arrowup 2191 arrowupdn 2195 arrowupdnbse 21a8 arrowvertex 23d0 " +
	"asciicircum 5e asciitilde 7e asterisk 2a asteriskmath 2217 at 40 " +
	"atilde e3 b 62 backslash 5c bar 7c beta 3b2 block 2588 braceex 23aa " +
	"braceleft 7b braceleftbt 23a9 braceleftmid 23a8 bracelefttp 23a7 " +
	"braceright 7d bracerightbt 23ad bracerightmid 23ac bracerighttp 23ab " +
	"bracketleft 5b bracketleftbt 23a3 bracketleftex 23a2 bracketlefttp " +
	"23a1 bracketright 5d bracketrightbt 23a6 bracketrightex 23a5 " +
	"bracketrighttp 23a4 breve 2d8 brokenbar a6 bullet 2022 c 63 cacute 107 " +
	"caron 2c7 carriagereturn 21b5 ccaron 10d ccedilla e7 ccircumflex 109 " +
	"cdotaccent 10b cedilla b8 cent a2 chi 3c7 circle 25cb circlemultiply " +
	"2297 circleplus 2295 circumflex 2c6 club 2663 colon 3a colonmonetary " +
	"20a1 comma 2c congruent 2245 copyright a9 copyrightsans a9 " +
	"copyrightserif a9 currency a4 d 64 dagger 2020 daggerdbl 2021 dcaron " +
	"10f dcroat 111 degree b0 delta 3b4 diamond 2666 dieresis a8 " +
	"dieresistonos 385 divide f7 dkshade 2593 dnblock 2584 dollar 24 dong " +
	"20ab dotaccent 2d9 dotbelowcomb 323 dotlessi 131 dotlessj 237 dotmath " +
	"22c5 e 65 eacute e9 ebreve 115 ecaron 11b ecircumflex ea edieresis eb " +
	"edotaccent 117 egrave e8 eight 38 element 2208 ellipsis 2026 emacron " +
	"113 emdash 2014 emptyset 2205 endash 2013 eng 14b eogonek 119 epsilon " +
	"3b5 epsilontonos 3ad equal 3d equivalence 2261 estimated 212e eta 3b7 " +
	"etatonos 3ae eth f0 exclam 21 exclamdbl 203c exclamdown a1 existential " +
	"2203 f 66 female 2640 ff fb00 ffi fb03 ffl fb04 fi fb01 figuredash " +
	"2012 filledbox 25a0 filledrect 25ac five 35 fiveeighths 215d fl fb02 " +
	"florin 192 four 34 fraction 2044 franc 20a3 g 67 gamma 3b3 gbreve 11f " +
	"gcaron 1e7 gcircumflex 11d gdotaccent 121 germandbls df gradient 2207 " +
	"grave 60 gravecomb 300 greater 3e greaterequal 2265 guillemotleft ab " +
	"guillemotright bb guilsinglleft 2039 guilsinglright 203a h 68 hbar 127 " +
	"hcircumflex 125 heart 2665 hookabovecomb 309 house 2302 hungarumlaut " +
	"2dd hyphen 2d i 69 iacute ed ibreve 12d icircumflex ee idieresis ef " +
	"igrave ec ij 133 imacron 12b infinity 221e integral 222b integralbt " +
	"2321 integralex 23ae integraltp 2320 intersection 2229 invbullet 25d8 " +
	"invcircle 25d9 invsmileface 263b iogonek 12f iota 3b9 iotadieresis 3ca " +
	"iotadieresistonos 390 iotatonos 3af itilde 129 j 6a jcircumflex 135 k " +
	"6b kappa 3ba kgreenlandic 138 l 6c lacute 13a lambda 3bb lcaron 13e " +
	"ldot 140 less 3c lessequal 2264 lfblock 258c lira 20a4 logicaland 2227 " +
	"logicalnot ac logicalor 2228 longs 17f lozenge 25ca lslash 142 ltshade " +
	"2591 m 6d macron af male 2642 middot b7 minus 2212 minute 2032 mu 3bc " +
	"mu1 b5 multiply d7 musicalnote 266a musicalnotedbl 266b n 6e nacute " +
	"144 napostrophe 149 nbspace a0 ncaron 148 nine 39 notelement 2209 " +
	"notequal 2260 notsubset 2284 ntilde f1 nu 3bd numbersign 23 o 6f " +
	"oacute f3 obreve 14f ocircumflex f4 odieresis f6 oe 153 ogonek 2db " +
	"ograve f2 ohorn 1a1 ohungarumlaut 151 omacron 14d omega 3c9 omega1 3d6 " +
	"omegatonos 3ce omicron 3bf omicrontonos 3cc one 31 onedotenleader 2024 " +
	"oneeighth 215b onehalf bd onequarter bc onesuperior b9 onethird 2153 " +
	"openbullet 25e6 ordfeminine aa ordmasculine ba orthogonal 221f oslash " +
	"f8 oslashacute 1ff otilde f5 overscore af p 70 paragraph b6 parenleft " +
	"28 parenleftbt 239d parenleftex 239c parenlefttp 239b parenright 29 " +
	"parenrightbt 23a0 parenrightex 239f parenrighttp 239e partialdiff 2202 " +
	"percent 25 period 2e periodcentered b7 perpendicular 22a5 perthousand " +
	"2030 peseta 20a7 phi 3c6 phi1 3d5 pi 3c0 plus 2b plusminus b1 " +
	"prescription 211e product 220f propersubset 2282 propersuperset 2283 " +
	"proportional 221d psi 3c8 q 71 question 3f questiondown bf quotedbl 22 " +
	"quotedblbase 201e quotedblleft 201c quotedblright 201d quoteleft 2018 " +
	"quotereversed 201b quoteright 2019 quotesinglbase 201a quotesingle 27 " +
	"r 72 racute 155 radical 221a radicalex f8e5 rcaron 159 reflexsubset " +
	"2286 reflexsuperset 2287 registered ae registersans ae registerserif " +
	"ae revlogicalnot 2310 rho 3c1 ring 2da rtblock 2590 s 73 sacute 15b " +
	"scaron 161 scedilla 15f scircumflex 15d second 2033 section a7 " +
	"semicolon 3b seven 37 seveneighths 215e sfthyphen ad shade 2592 sigma " +
	"3c3 sigma1 3c2 similar 223c six 36 slash 2f smileface 263a space 20 " +
	"spade 2660 sterling a3 suchthat 220b summation 2211 sun 263c t 74 tau " +
	"3c4 tbar 167 tcaron 165 therefore 2234 theta 3b8 theta1 3d1 thorn fe " +
	"three 33 threeeighths 215c threequarters be threesuperior b3 tilde 2dc " +
	"tildecomb 303 tonos 384 trademark 2122 trademarksans 2122 " +
	"trademarkserif 2122 triagdn 25bc triaglf 25c4 triagrt 25ba triagup " +
	"25b2 two 32 twodotenleader 2025 twosuperior b2 twothirds 2154 u 75 " +
	"uacute fa ubreve 16d ucircumflex fb udieresis fc ugrave f9 uhorn 1b0 " +
	"uhungarumlaut 171 umacron 16b underscore 5f underscoredbl 2017 union " +
	"222a universal 2200 uogonek 173 upblock 2580 upsilon 3c5 " +
	"upsilondieresis 3cb upsilondieresistonos 3b0 upsilontonos 3cd uring " +
	"16f utilde 169 v 76 w 77 wacute 1e83 wcircumflex 175 wdieresis 1e85 " +
	"weierstrass 2118 wgrave 1e81 x 78 xi 3be y 79 yacute fd ycircumflex " +
	"177 ydieresis ff yen a5 ygrave 1ef3 z 7a zacute 17a zcaron 17e " +
	"zdotaccent 17c zero 30 zeta 3b6";
