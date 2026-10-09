implement Tiny;

# tiny - the size of module a JavaScript function compiles to: one
# function, a few dozen instructions.  loadtest loads a thousand copies.

include "sys.m";

Tiny: module
{
	f:	fn(a, b: real): real;
};

f(a, b: real): real
{
	x := a;
	for(i := 0; i < 8; i++)
		x = x * 1.5 + b - real i;
	if(x > 1000.0)
		x = x / 3.0;
	return x + a * b;
}
