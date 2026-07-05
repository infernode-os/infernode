# Native (Dis) sam engine — the "host" half of the sam split.
# Spawned in-process by samstub over a byte pipe; speaks the Plan 9
# sam terminal protocol (see samstub.m) to the samterm front end.
# Replaces the historical `#C exec "sam -R"` bridge to a host binary.

Samengine: module
{
	PATH:	con "/dis/wm/samengine.dis";

	# run the engine loop, reading T* / writing H* messages on `io`.
	run:	fn(io: ref Sys->FD, args: list of string);
};
