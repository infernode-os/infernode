implement WireFmt;

#
# wirefmt.b - Shared wire-format codec for the LLM-bridge TOOL: protocol.
#
# See wirefmt.m and docs/veltro-llm-bridge-bug-taxonomy.md. Pure string
# manipulation; no module dependencies beyond Sys (held only for symmetry
# with the rest of the lib — the codec functions themselves need nothing).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "wirefmt.m";

init()
{
	# No dependencies to load; present so callers can follow the usual
	# load/init convention.
	sys = load Sys Sys->PATH;
}

# Escape '\', newline and ':' so a field can sit inside the colon-delimited,
# newline-terminated TOOL: line without ambiguity. Backslash is handled by the
# same case arm as the others, so ordering cannot double-escape.
escapefield(s: string): string
{
	out := "";
	for(i := 0; i < len s; i++) {
		case s[i] {
		'\\' => out += "\\\\";
		'\n' => out += "\\n";
		':'  => out += "\\:";
		*    => out += s[i:i+1];
		}
	}
	return out;
}

# Exact inverse of escapefield. A lone trailing backslash, or a backslash
# before any other character, is preserved as-is (matching escapefield, which
# only ever emits the three escape sequences above).
unescapefield(s: string): string
{
	out := "";
	i := 0;
	while(i < len s) {
		if(s[i] == '\\' && i + 1 < len s) {
			case s[i+1] {
			'\\' => out += "\\"; i += 2;
			'n'  => out += "\n"; i += 2;
			':'  => out += ":";  i += 2;
			*    => out += s[i:i+1]; i++;   # lone backslash: keep, reprocess next
			}
		} else {
			out += s[i:i+1];
			i++;
		}
	}
	return out;
}

encodetool(id, name, args: string): string
{
	return "TOOL:" + escapefield(id) + ":" + escapefield(name) + ":" + escapefield(args);
}

# Index of the first UNescaped ':' at or after p, or -1 if none. A backslash
# escapes the following character, so "\:" is skipped (not a delimiter).
nextdelim(s: string, p: int): int
{
	i := p;
	while(i < len s) {
		if(s[i] == '\\')
			i += 2;            # skip the escaped char (or run past the end)
		else if(s[i] == ':')
			return i;
		else
			i++;
	}
	return -1;
}

parsetoolline(s: string): (string, string, string)
{
	c1 := nextdelim(s, 0);
	if(c1 < 0)
		return (unescapefield(s), "", "");
	id := unescapefield(s[0:c1]);

	c2 := nextdelim(s, c1 + 1);
	if(c2 < 0)
		return (id, unescapefield(s[c1+1:]), "");
	name := unescapefield(s[c1+1:c2]);
	args := unescapefield(s[c2+1:]);
	return (id, name, args);
}
