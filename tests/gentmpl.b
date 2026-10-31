# gentmpl - the type a module diswrite_test makes at run time must have
implement Gentmpl;
Gentmpl: module
{
	add: fn(a, b: int): int;
};
add(a, b: int): int
{
	return a + b;
}
