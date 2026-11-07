#
#	HID report descriptors (USB HID 1.11, 6.2.2), as much of them as a
#	mouse and a keyboard need: where in each input report the buttons,
#	X, Y and wheel are, and where a keyboard says which keys are down. A report-protocol device describes its own report
#	layout in its Report Map, so a reader that knows only the boot
#	layout (buttons, dx, dy) has to be given the map's meaning; this
#	parses the map once and turns each report into that boot layout,
#	so that what reads /dev/pointer never learns there was a map.
#

Hid: module
{
	PATH:	con "/dis/lib/hid.dis";

	init:	fn();

	# a field's place in a report: bit offset, bits per item, item count, signedness
	Field: adt {
		off:	int;
		size:	int;
		count:	int;
		signed:	int;
		min, max: int;		# logical range, for sign and scaling
	};

	# one input report a mouse application collection produces
	Report: adt {
		id:	int;		# 0 when the map uses no report IDs
		bits:	int;		# its length, without the ID byte
		buttons: ref Field;	# Button page usages, one bit each
		x:	ref Field;	# Generic Desktop X
		y:	ref Field;	# Generic Desktop Y
		wheel:	ref Field;	# Generic Desktop Wheel
		mouse:	fn(r: self ref Report, data: array of byte): array of byte;	# the boot layout: buttons, dx, dy, wheel
	};

	# the input reports of every Mouse (or Pointer) application
	# collection in the map, in order; nil if the map is malformed
	parse:	fn(map: array of byte): list of ref Report;
	# the report for an ID, or the only one when the map uses none
	find:	fn(l: list of ref Report, id: int): ref Report;

	# a run of Keyboard-page usages in a report: count fields of size
	# bits from bit off. A bitmap run (isarray 0) is one usage per field,
	# umin + i, down when its bit is set; an array run holds in each
	# field the index of a key that is down, usage umin + (value - lmin).
	Keyrun: adt {
		off:	int;
		size:	int;
		count:	int;
		umin:	int;
		lmin:	int;
		isarray:	int;
	};

	# one input report a Keyboard (or Keypad) application collection produces
	Keys: adt {
		id:	int;		# 0 when the map uses no report IDs
		bits:	int;		# its length, without the ID byte
		runs:	list of ref Keyrun;
		# the modifier byte in the boot layout (E0 bit 0 .. E7 bit 7),
		# and the other usages held, from one report without its ID byte
		held:	fn(k: self ref Keys, data: array of byte): (int, list of int);
	};

	# the keyboard input reports in the map, those with at least one
	# Keyboard-page field; nil if there are none or the map is malformed
	keyboard:	fn(map: array of byte): list of ref Keys;
	# the keyboard report for an ID
	findkeys:	fn(l: list of ref Keys, id: int): ref Keys;
};
