implement JitSmallHelper;

# Loaded by jit_small_test.b: a module of a few instructions, well under
# the 128 that comp-amd64.c's compile() used to refuse.  Keep it small;
# the test checks that it still is.

JitSmallHelper: module
{
	PATH:	con "/dis/tests/jit_small_helper.dis";
	add:	fn(a, b: int): int;
};

add(a, b: int): int
{
	return a + b;
}
