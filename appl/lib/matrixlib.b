implement MatrixLib;

#
# matrixlib - Matrix composition parsing and manipulation
#
# Pure logic shared by the Matrix runtime (appl/wm/matrix.b) and
# its tests: parses the plain-text composition format into the ADTs
# declared in matrixlib.m.  No I/O and no Draw context — callers
# hand in text and get a tree or a diagnostic back.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Rect: import draw;

include "string.m";
	str: String;

include "matrix.m";

include "matrixlib.m";

init()
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
}

parsecomposition(text: string): (ref Composition, string)
{
	c := ref Composition;
	c.text = text;
	c.name = "";
	c.layout = nil;
	c.assigns = nil;
	c.services = nil;
	c.watches = nil;

	# Leaf name → LayoutNode map (for resolving nested splits)
	leafnames: list of (string, ref LayoutNode);

	lines := splitlines(text);

	for(; lines != nil; lines = tl lines) {
		line := hd lines;
		line = trim(line);
		if(len line == 0)
			continue;

		# Comment
		if(line[0] == '#') {
			if(c.name == "" && len line > 2)
				c.name = trim(line[2:]);
			continue;
		}

		(nil, toks) := sys->tokenize(line, " \t");
		if(toks == nil)
			continue;
		first := hd toks;
		rest := tl toks;

		# "layout hsplit|vsplit N M" — root split
		if(first == "layout") {
			if(c.layout != nil)
				return (nil, "duplicate layout declaration");
			if(len rest < 3)
				return (nil, "layout needs: hsplit|vsplit ratio1 ratio2");
			orient := parseorient(hd rest);
			if(orient < 0)
				return (nil, "layout: expected hsplit or vsplit");
			rest = tl rest;
			(r1, r1err) := parseint(hd rest);
			if(r1err != nil)
				return (nil, "layout: bad ratio1");
			rest = tl rest;
			(r2, r2err) := parseint(hd rest);
			if(r2err != nil)
				return (nil, "layout: bad ratio2");

			(n1, n2) := childnames("", orient);
			leaf1 := ref LayoutNode.Leaf(n1, "", "", nil, Rect((0,0),(0,0)));
			leaf2 := ref LayoutNode.Leaf(n2, "", "", nil, Rect((0,0),(0,0)));
			c.layout = ref LayoutNode.Split(
				orient, r1, r2, leaf1, leaf2,
				Rect((0,0),(0,0)));
			leafnames = (n1, leaf1) :: (n2, leaf2) :: nil;
			continue;
		}

		# "service name mount"
		if(first == "service") {
			if(len rest < 2)
				return (nil, "service needs: name mount");
			sname := hd rest;
			smount := hd tl rest;
			se := ref ServiceEntry(sname, smount, "", nil, 0);
			c.services = se :: c.services;
			continue;
		}

		# Region split: "left vsplit N M" or "right hsplit N M"
		# Region assign: "left/top module-name /mount/path"
		if(len rest >= 3) {
			# Is the second token an orientation?
			orient := parseorient(hd rest);
			if(orient >= 0) {
				# Region split
				rest = tl rest;
				(r1, r1e) := parseint(hd rest);
				if(r1e != nil)
					return (nil, first + ": bad ratio1");
				rest = tl rest;
				(r2, r2e) := parseint(hd rest);
				if(r2e != nil)
					return (nil, first + ": bad ratio2");

				# Find the leaf with this name
				found := 0;
				for(ln := leafnames; ln != nil; ln = tl ln) {
					(lname, nil) := hd ln;
					if(lname == first) {
						# Check depth
						if(depth(first) >= MAX_DEPTH - 1)
							return (nil, first + ": max layout depth exceeded");

						(n1, n2) := childnames(first, orient);
						leaf1 := ref LayoutNode.Leaf(n1, "", "", nil, Rect((0,0),(0,0)));
						leaf2 := ref LayoutNode.Leaf(n2, "", "", nil, Rect((0,0),(0,0)));
						split := ref LayoutNode.Split(
							orient, r1, r2, leaf1, leaf2,
							Rect((0,0),(0,0)));

						# Replace the leaf in its parent
						replaceleaf(c.layout, lname, split);

						# Update leaf names: remove old, add new
						newnames: list of (string, ref LayoutNode);
						for(ln2 := leafnames; ln2 != nil; ln2 = tl ln2)
							if((hd ln2).t0 != first)
								newnames = hd ln2 :: newnames;
						leafnames = (n1, leaf1) :: (n2, leaf2) :: newnames;
						found = 1;
						break;
					}
				}
				if(!found)
					return (nil, first + ": unknown region for split");
				continue;
			}
		}

		# Module assignment: "region modname mount"
		if(len rest >= 2) {
			modname := hd rest;
			mount := hd tl rest;
			ma := ref ModuleAssign(first, modname, mount);
			c.assigns = ma :: c.assigns;
			continue;
		}

		return (nil, "unrecognized line: " + line);
	}

	# Apply module assignments to layout leaves
	for(al := c.assigns; al != nil; al = tl al) {
		a := hd al;
		if(c.layout != nil) {
			if(!assignleaf(c.layout, a.region, a.modname, a.mount))
				return (nil, a.region + ": region not found in layout");
		}
	}

	return (c, nil);
}

transplant(old, new: ref Composition)
{
	if(old == nil || new == nil)
		return;
	if(old.layout != nil && new.layout != nil)
		transplantleaves(old.layout, new.layout);
	for(nl := new.services; nl != nil; nl = tl nl) {
		ns := hd nl;
		for(ol := old.services; ol != nil; ol = tl ol) {
			os := hd ol;
			if(os.mod != nil && os.name == ns.name && os.mount == ns.mount) {
				ns.mod = os.mod;
				ns.outdir = os.outdir;
				ns.pid = os.pid;
				os.mod = nil;
				os.pid = 0;
				break;
			}
		}
	}
}

# Walk the new layout's leaves; adopt the old module when the same
# region name carries the same module against the same mount.
# Region-name-first matching prevents two regions running the same
# module from cross-stealing each other's instance.
transplantleaves(oldroot, node: ref LayoutNode)
{
	pick n := node {
	Split =>
		transplantleaves(oldroot, n.child1);
		transplantleaves(oldroot, n.child2);
	Leaf =>
		if(n.modname == "")
			return;
		o := findleaf(oldroot, n.name);
		if(o != nil && o.mod != nil &&
		   o.modname == n.modname && o.mount == n.mount) {
			n.mod = o.mod;
			o.mod = nil;
		}
	}
}

findleaf(node: ref LayoutNode, name: string): ref LayoutNode.Leaf
{
	if(node == nil)
		return nil;
	pick n := node {
	Split =>
		l := findleaf(n.child1, name);
		if(l != nil)
			return l;
		return findleaf(n.child2, name);
	Leaf =>
		if(n.name == name)
			return n;
	}
	return nil;
}

# Parse "hsplit" or "vsplit"
parseorient(s: string): int
{
	if(s == "hsplit")
		return HSPLIT;
	if(s == "vsplit")
		return VSPLIT;
	return -1;
}

# Parse integer
parseint(s: string): (int, string)
{
	(v, rest) := str->toint(s, 10);
	if(rest != nil && rest != "")
		return (0, "not an integer");
	return (v, nil);
}

# Compute child names for a split
childnames(parent: string, orient: int): (string, string)
{
	prefix := "";
	if(parent != "")
		prefix = parent + "/";
	if(orient == HSPLIT)
		return (prefix + "left", prefix + "right");
	return (prefix + "top", prefix + "bottom");
}

# Count slashes to determine depth
depth(name: string): int
{
	d := 0;
	for(i := 0; i < len name; i++)
		if(name[i] == '/')
			d++;
	return d;
}

# Replace a named leaf in the layout tree with a new node
replaceleaf(node: ref LayoutNode, name: string, replacement: ref LayoutNode): int
{
	pick n := node {
	Split =>
		pick c1 := n.child1 {
		Leaf =>
			if(c1.name == name) {
				n.child1 = replacement;
				return 1;
			}
		Split =>
			if(replaceleaf(n.child1, name, replacement))
				return 1;
		}
		pick c2 := n.child2 {
		Leaf =>
			if(c2.name == name) {
				n.child2 = replacement;
				return 1;
			}
		Split =>
			if(replaceleaf(n.child2, name, replacement))
				return 1;
		}
	Leaf =>
		;  # can't recurse into a leaf
	}
	return 0;
}

# Assign a module to a named leaf
assignleaf(node: ref LayoutNode, name, modname, mount: string): int
{
	pick n := node {
	Split =>
		if(assignleaf(n.child1, name, modname, mount))
			return 1;
		return assignleaf(n.child2, name, modname, mount);
	Leaf =>
		if(n.name == name) {
			n.modname = modname;
			n.mount = mount;
			return 1;
		}
	}
	return 0;
}

# ── String utilities ────────────────────────────────────────

splitlines(s: string): list of string
{
	lines: list of string;
	start := 0;
	for(i := 0; i < len s; i++) {
		if(s[i] == '\n') {
			lines = s[start:i] :: lines;
			start = i + 1;
		}
	}
	if(start < len s)
		lines = s[start:] :: lines;

	# Reverse
	rev: list of string;
	for(; lines != nil; lines = tl lines)
		rev = hd lines :: rev;
	return rev;
}

trim(s: string): string
{
	start := 0;
	end := len s;
	while(start < end && (s[start] == ' ' || s[start] == '\t'))
		start++;
	while(end > start && (s[end-1] == ' ' || s[end-1] == '\t'))
		end--;
	if(start == 0 && end == len s)
		return s;
	return s[start:end];
}
