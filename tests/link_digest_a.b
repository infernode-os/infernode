implement LinkDigestA;

#
# What tests/link_digest_test.b loads: two functions that return what
# they are given.  twin's type is one of a pair the test declares, the
# two folding to the same 32-bit signature.
#

LinkDigestA: module
{
	twin:	fn(a: big, p0: big, p1: int, p2: big, p3: big, p4: int, p5: real, p6: int, p7: real, p8: real, p9: big, p10: int): int;
	plain:	fn(x: int): int;
};

twin(a: big, nil: big, nil: int, nil: big, nil: big, nil: int, nil: real, nil: int, nil: real, nil: real, nil: big, nil: int): int
{
	return int a;
}

plain(x: int): int
{
	return x+1;
}
