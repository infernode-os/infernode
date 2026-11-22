Styxpersist: module {
	PATH: con "/dis/lib/styxpersist.dis";
	init: fn(clientfd: ref Sys->FD): (chan of chan of ref Sys->FD, string);
};
