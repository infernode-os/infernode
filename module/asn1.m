ASN1: module {
	PATH: con "/dis/lib/asn1.dis";

	# Tag classes
	Universal : con 0;
	Application : con 16r40;
	Context : con 16r80;
	Private : con 16rC0;

	# Universal tags
	BOOLEAN : con 1;
	INTEGER : con 2;
	BIT_STRING : con 3;
	OCTET_STRING : con 4;
	NULL : con 5;
	OBJECT_ID: con 6;
	ObjectDescriptor : con 7;
	EXTERNAL : con 8;
	REAL : con 9;
	ENUMERATED : con 10;
	EMBEDDED_PDV : con 11;
	UTF8String : con 12;
	SEQUENCE : con 16;		# also SEQUENCE OF
	SET : con 17;			# also SET  OF
	NumericString : con 18;
	PrintableString : con 19;
	TeletexString : con 20;
	VideotexString : con 21;
	IA5String : con 22;
	UTCTime : con 23;
	GeneralizedTime : con 24;
	GraphicString : con 25;
	VisibleString : con 26;
	GeneralString : con 27;
	UniversalString : con 28;
	BMPString : con 30;

	Elem: adt {
		tag: Tag;
		val: ref Value;

		is_seq: fn(e: self ref Elem) : (int, list of ref Elem);
		is_set: fn(e: self ref Elem) : (int, list of ref Elem);
		is_int: fn(e: self ref Elem) : (int, int);
		is_bigint: fn(e: self ref Elem) : (int, array of byte);
		is_bitstring: fn(e: self ref Elem) : (int, int, array of byte);
		is_octetstring: fn(e: self ref Elem) : (int, array of byte);
		is_oid: fn(e: self ref Elem) : (int, ref Oid);
		is_string: fn(e: self ref Elem) : (int, string);
		is_time: fn(e: self ref Elem) : (int, string);
		tostring: fn(e: self ref Elem) : string;
	};

	Tag: adt {
		class: int;
		num: int;
		constr: int;

		tostring: fn(t: self Tag) : string;
	};

	Value: adt {
		pick {
			Bool or Int =>
				# Bool: 0 for FALSE, 16rFF for TRUE
				v: int;
			Octets or BigInt or Real or Other =>
				# BigInt: integer too big for limbo int
				# Real: we don't care to decode these
				#    since they are hardly ever used
				bytes: array of byte;
			BitString =>
				# pack into bytes, with perhaps some
				# unused bits in last byte
				unusedbits: int;
				bits: array of byte;
			Null =>
				dummy: int;
			ObjId =>
				id: ref Oid;
			String =>
				# the text, decoded as its type has it
				# (tag.num says which)
				s: string;
			Seq or Set =>
				l: list of ref Elem;
		}

		tostring : fn(v: self ref Value) : string;
	};

	Oid: adt {
		nums: array of int;

		tostring: fn(o: self ref Oid) : string;
	};

	init: fn();
	# DER (X.690 10, 11): definite lengths and tag numbers in their
	# shortest form, INTEGERs in the fewest bytes, BOOLEANs 00 or FF,
	# strings primitive and in their type's characters, a BIT
	# STRING's unused bits zero.  Whatever the bytes, the answer is
	# an element or an error: no exception.
	decode: fn(a: array of byte) : (string, ref Elem);
	# the elements that fill a (a SEQUENCE's contents)
	decode_seq: fn(a: array of byte) : (string, list of ref Elem);
	decode_value: fn(a: array of byte, kind, constr: int) : (string, ref Value);
	oid_lookup: fn(o: ref Oid, tab: array of Oid) : int;
	print_elem: fn(e: ref Elem);
};
