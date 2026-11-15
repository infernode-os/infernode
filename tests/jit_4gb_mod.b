implement Jit4gbMod;

# The module tests/jit_4gb.b calls: see tests/host/jit_4gb_test.sh.

Jit4gbMod: module
{
	f:	fn(x: int): int;
};

f(x: int): int
{
	return x + 1;
}
