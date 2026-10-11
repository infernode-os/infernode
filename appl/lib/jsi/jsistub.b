#
# jsistub.b - what is not written yet: typed arrays, explicit resource
# management, modules.  Each says so when it is reached.
#

disposeinit()
{
}

natdispose(nil: int, nil: ref Obj, nil: V, nil: array of V, nil: ref Obj): V
{
	throwtype("explicit resource management is not supported yet");
	return undef;
}

usingadd(nil: V, nil: int)
{
	throwtype("using declarations are not supported yet");
}

