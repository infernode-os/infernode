#
#	HID report descriptors (USB HID 1.11, 6.2.2), as much of them as a
#	mouse needs: where in each input report the buttons, X, Y and
#	wheel are. A report-protocol device describes its own report
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
};
