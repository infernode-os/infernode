#
# dom.m - the document tree.
#
# A document is an array of nodes linked by integer indices: parent,
# first and last child, next and previous sibling.  Index 0 is "none";
# the document node is index 1.  No node points at another with a
# ref, so the tree has no cycles and a walk is index arithmetic.
#
# Elements known to the HTML parser get a small-integer tag (Tdiv, ...);
# every element also keeps its lower-case name, so unknown and custom
# elements (<my-widget>) work the same way, only compared as strings.
#
# Everything that changes the tree goes through the Doc methods below.
# The parser uses nothing else, so the same interface is the DOM's
# write side for a script engine.  Each change bumps Doc.gen.
#
Dom: module
{
	PATH:	con "/dis/lib/web/dom.dis";

	# node kinds
	Document, Doctype, Element, Text, Comment: con 1+iota;

	# namespaces
	HTML, SVG, MathML: con iota;

	# the attribute marking a popover its invoker has opened (:popover-open):
	# a NUL begins it, which no attribute from markup can (the parser
	# makes NUL U+FFFD)
	POPOPEN: con "\u0000popover-open";

	# tags known to the parser; the order matches tagnames in dom.b
	Tnone, Ta, Tabbr, Taddress, Tapplet, Tarea, Tarticle, Taside, Taudio,
	Tb, Tbase, Tbasefont, Tbdi, Tbdo, Tbgsound, Tbig, Tblockquote, Tbody,
	Tbr, Tbutton, Tcanvas, Tcaption, Tcenter, Tcite, Tcode, Tcol, Tcolgroup,
	Tdata, Tdatalist, Tdd, Tdel, Tdetails, Tdfn, Tdialog, Tdir, Tdiv, Tdl,
	Tdt, Tem, Tembed, Tfieldset, Tfigcaption, Tfigure, Tfont, Tfooter,
	Tform, Tframe, Tframeset, Th1, Th2, Th3, Th4, Th5, Th6, Thead, Theader,
	Thgroup, Thr, Thtml, Ti, Tiframe, Timage, Timg, Tinput, Tins, Tkbd,
	Tkeygen, Tlabel, Tlegend, Tli, Tlink, Tlisting, Tmain, Tmap, Tmark,
	Tmarquee, Tmenu, Tmeta, Tmeter, Tnav, Tnobr, Tnoembed, Tnoframes,
	Tnoscript, Tobject, Tol, Toptgroup, Toption, Toutput, Tp, Tparam,
	Tpicture, Tplaintext, Tpre, Tprogress, Tq, Trb, Trp, Trt, Trtc, Truby,
	Ts, Tsamp, Tscript, Tsearch, Tsection, Tselect, Tslot, Tsmall, Tsource,
	Tspan, Tstrike, Tstrong, Tstyle, Tsub, Tsummary, Tsup, Ttable, Ttbody,
	Ttd, Ttemplate, Ttextarea, Ttfoot, Tth, Tthead, Ttime, Ttitle, Ttr,
	Ttrack, Ttt, Tu, Tul, Tvar, Tvideo, Twbr, Txmp, Tsvg, Tmath, Tdesc,
	TforeignObject, Tmi, Tmo, Tmn, Tms, Tmtext, Tannotation_xml,
	Ntags: con iota;

	Node: adt {
		kind:	int;
		tag:	int;		# Tnone if not a known HTML tag
		ns:	int;
		name:	string;		# element: lower-case name (as written, for SVG);
					# doctype: its name
		parent, first, last, next, prev:	int;
		attrs:	list of (string, string);	# in source order
		text:	string;		# Text, Comment; doctype public id
	};

	Doc: adt {
		nodes:	array of ref Node;
		n:	int;		# nodes[1:n] are allocated
		gen:	int;		# bumped by every change
		quirks:	int;		# document is in quirks mode
		url:	string;		# document address, for resolving references
		xml:	int;		# parsed as XML (attribute values match case-sensitively)
		charset:	string;		# the encoding it was decoded from (its stylesheets' default)
		lang:	string;		# the document's language, from <meta http-equiv=content-language>, for :lang()
		shadows:	list of (int, int);	# (host, shadow root): the root a node of kind Document

		new:	fn(url: string): ref Doc;
		create:	fn(d: self ref Doc, kind: int, name: string, ns: int): int;
		append:	fn(d: self ref Doc, parent, child: int);
		insert:	fn(d: self ref Doc, parent, child, before: int);	# before 0 = append
		remove:	fn(d: self ref Doc, child: int);		# detach from parent
		setattr:	fn(d: self ref Doc, n: int, name, val: string);
		delattr:	fn(d: self ref Doc, n: int, name: string);
		settext:	fn(d: self ref Doc, n: int, s: string);
		attachshadow:	fn(d: self ref Doc, host, root: int);

		attr:	fn(d: self ref Doc, n: int, name: string): string;	# "" if absent or empty: see hasattr
		hasattr:	fn(d: self ref Doc, n: int, name: string): int;
		root:	fn(d: self ref Doc): int;	# the html element
		find:	fn(d: self ref Doc, from, tag: int): int;	# first descendant with tag
		textof:	fn(d: self ref Doc, n: int): string;	# concatenated descendant text
		dump:	fn(d: self ref Doc): string;	# html5lib-test tree format
	};

	# The flat tree (DOM §4.2.2), as style and layout see a document with
	# shadow roots: a host's children are its shadow root's, a slot's are
	# the light children assigned to it (or its own, if none are), and a
	# host's light children no slot takes are not in it.  Selectors still
	# match the document's own tree; scope says which tree a node is in.
	Flat: adt {
		parent, first, next:	array of int;	# by node; 0 none
		scope:	array of int;	# the root of a node's tree: 1, or its shadow root
		roots:	list of (int, int);	# (host, root), as Doc.shadows
	};
	flat:	fn(d: ref Doc): ref Flat;	# nil if the document has no shadow roots
	within:	fn(d: ref Doc, n, top: int): int;	# the node after n in tree order, inside top; 0 at its end

	atom:	fn(name: string): int;		# lower-case name -> tag, or Tnone
	tagname:	fn(tag: int): string;
};
