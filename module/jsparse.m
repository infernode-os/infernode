#
# jsparse.m - JavaScript's syntax (ECMAScript 2025 §13-16), parsed to
# a tree.
#
# The tree follows ESTree (as Acorn, Babel and most tools have it), so
# that what the compiler and the early-error checks walk is a familiar
# shape.  Positions are character offsets into the source.
#
Jsparse: module
{
	PATH:	con "/dis/lib/js/jsparse.dis";

	# Func flags
	Fgen, Fasync, Farrow, Fexpr, Fdecl, Fmethod, Fstrict, Fsimple: con 1 << iota;
	# Var kinds
	Kvar, Klet, Kconst: con iota;
	# Prop and Method kinds
	Pinit, Pget, Pset, Pmethod, Pctor, Pfield, Pblock: con iota;
	# Import specifier kinds
	Idefault, Inamespace, Inamed: con iota;

	Node: adt {
		pos, end:	int;
		pick {
		Program =>
			body:	array of ref Node;
			ismod, strict:	int;
		Expr =>
			e:	ref Node;
			directive:	string;	# a directive prologue's string, raw, or nil
		Block =>
			body:	array of ref Node;
		Empty =>
		Debugger =>
		With =>
			obj, body:	ref Node;
		Return =>
			arg:	ref Node;
		Labeled =>
			label:	string;
			body:	ref Node;
		Break =>
			label:	string;
		Continue =>
			label:	string;
		If =>
			test, cons, els:	ref Node;
		Switch =>
			disc:	ref Node;
			cases:	array of ref Node;
		Case =>
			test:	ref Node;		# nil: default
			body:	array of ref Node;
		Throw =>
			arg:	ref Node;
		Try =>
			block, param, handler, final:	ref Node;	# handler nil: no catch; param nil: catch without a binding
		While =>
			test, body:	ref Node;
		DoWhile =>
			body, test:	ref Node;
		For =>
			init, test, update, body:	ref Node;
		ForIn =>
			left, right, body:	ref Node;
		ForOf =>
			left, right, body:	ref Node;
			await:	int;
		Var =>
			kind:	int;
			decls:	array of ref Node;
		Decl =>
			id, init:	ref Node;
		Func =>
			id:	ref Node;
			params:	array of ref Node;
			body:	array of ref Node;	# an arrow's expression body: one Return
			flags:	int;
		Class =>
			id, super:	ref Node;
			body:	array of ref Node;	# Methods
			decl:	int;
		Method =>
			key, value:	ref Node;	# value: a Func, a field's initialiser, a static block's Block
			kind, computed, static:	int;
		Import =>
			specs:	array of ref Node;
			source:	string;
		ImportSpec =>
			kind:	int;
			imported, local:	string;
		Export =>
			decl:	ref Node;		# a declaration, or default's expression
			specs:	array of ref Node;
			source:	string;		# from "..."
			default, all:	int;
			allas:	string;		# export * as name from
		ExportSpec =>
			local, exported:	string;

		Ident =>
			name:	string;
		Private =>
			name:	string;
		Num =>
			n:	real;
		BigInt =>
			digits:	string;
		Str =>
			s:	string;
		Regex =>
			pattern, flags:	string;
		Bool =>
			v:	int;
		Null =>
		This =>
		Super =>
		Template =>
			quasis:	array of string;	# cooked; nil where an escape was not valid (a tagged template's)
			raws:	array of string;
			exprs:	array of ref Node;
			bad:	int;
		Tagged =>
			tag, quasi:	ref Node;
		Array =>
			elems:	array of ref Node;	# nil: a hole
		Object =>
			props:	array of ref Node;
		Prop =>
			key, value:	ref Node;
			kind, computed, shorthand:	int;
		Spread =>
			arg:	ref Node;
		Unary =>
			op:	string;
			arg:	ref Node;
		Update =>
			op:	string;
			prefix:	int;
			arg:	ref Node;
		Binary =>
			op:	string;
			l, r:	ref Node;
		Logical =>
			op:	string;
			l, r:	ref Node;
		Assign =>
			op:	string;
			target, value:	ref Node;
		Cond =>
			test, cons, els:	ref Node;
		Call =>
			callee:	ref Node;
			args:	array of ref Node;
			optional:	int;
		New =>
			callee:	ref Node;
			args:	array of ref Node;
		Member =>
			obj, prop:	ref Node;
			computed, optional:	int;
		Chain =>
			e:	ref Node;
		Seq =>
			exprs:	array of ref Node;
		Yield =>
			arg:	ref Node;
			delegate:	int;
		Await =>
			arg:	ref Node;
		Meta =>
			meta, prop:	string;	# new.target, import.meta
		ImportCall =>
			source, options:	ref Node;
		Paren =>
			e:	ref Node;		# kept so that (a) = 1 and ((a)) => are told apart

		ArrayPat =>
			elems:	array of ref Node;
		ObjectPat =>
			props:	array of ref Node;	# Props whose values are patterns; a Rest last
		AssignPat =>
			target, dflt:	ref Node;
		Rest =>
			arg:	ref Node;
		}
	};

	init:	fn();
	# the program in src: (tree, nil), or (nil, "line:col: message")
	parse:	fn(src: string, ismod, strict: int): (ref Node, string);
};
