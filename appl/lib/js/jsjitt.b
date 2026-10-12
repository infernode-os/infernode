implement Jitcode;

#
# jsjitt - a module of the type the engine's compiled functions are
# (jsjit.m), compiled by limbo so that jsjit.b can read from it the
# signature a module it makes must have.  It is never run.
#

include "jsjit.m";

run(st: ref Jitst, pc: int): int
{
	st.vs[st.base] = st.consts[0];
	return pc;
}
