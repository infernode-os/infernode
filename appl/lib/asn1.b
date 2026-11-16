implement ASN1;

include "sys.m";
	sys: Sys;

include "asn1.m";

# Masks
TAG_MASK : con 16r1F;
CONSTR_MASK : con 16r20;
CLASS_MASK : con 16rC0;

# Decoding errors
OK, ESHORT, ETOOBIG, EVALLEN, ECONSTR, EPRIM, EINVAL, EUNIMPL: con iota;
Maxdepth: con 32;

debug : con 0;

init()
{
	sys = load Sys Sys->PATH;
}

# Decode the whole array as the DER encoding of an ASN1 type.
# If there's an error, the return string will contain the error.
# Depending on the error, the returned elem may or may not
# be nil.
#
# The rules are DER's (X.690 10 and 11), not BER's: what is decoded
# here is certificates, CRLs, keys and signatures, which are DER
# (RFC 5280 4.1), and every reader of one must find the same thing in
# it.  A length or tag number not in its shortest form, an INTEGER
# with a byte it does not need, a constructed string, a BOOLEAN other
# than 00 or FF, unused bits that are not zero, an OID subidentifier
# with a leading 80, a string that is not its type's: each has one
# meaning to a lenient reader and none to a strict one, and was taken.
# Not checked, as they depend on the type and not on the encoding:
# DEFAULT values left out, the order of a SET OF's elements, a named
# bit list's trailing zero bits.
decode(a: array of byte) : (string, ref Elem)
{
	(ecode, i, elem) := ber_decode(a, 0, len a, 0);
	return (errstr(ecode, i, len a), elem);
}

# Like decode, but continue decoding after first element
# of array ends: the elements that fill the array, as the contents
# of a SEQUENCE under an implicit tag come.  (It asked for a sequence
# of indefinite length, and so for an end-of-contents mark that
# definite encodings do not have: it could not succeed.)
decode_seq(a: array of byte) : (string, list of ref Elem)
{
	(ecode, i, elist) := seq_decode(a, 0, len a, 1, 0);
	return (errstr(ecode, i, len a), elist);
}

# Decode the whole array as a DER encoding of an ASN1 value,
# (i.e., the part after the tag and length).
# Assume the value is encoded as universal tag "kind".
# The constr arg is 1 if the value is constructed, 0 if primitive.
# If there's an error, the return string will contain the error.
# Depending on the error, the returned value may or may not
# be nil.
decode_value(a: array of byte, kind, constr: int) : (string, ref Value)
{
	n := len a;
	(ecode, i, val) := value_decode(a, 0, n, n, kind, constr, 0);
	return (errstr(ecode, i, len a), val);
}

# The rest of the decoding routines take the array (a), the
# starting position (i), and the ending position +1 (n).
# They return (err code, new i, [... varies]).

# for debugging
ber_ind := "";
ber_ind_save := "";

# Decode an ASN1 (tag, length, value).
ber_decode(a: array of byte, i, n, depth: int) : (int, int, ref Elem)
{
	if(depth > Maxdepth)
		return (ETOOBIG, i, nil);
	if(debug) {
		ber_ind_save = ber_ind;
		ber_ind = ber_ind + "  ";
		sys->print("%sber_decode, byte %d\n", ber_ind, i);
	}
	err, length: int;
	tag : Tag;
	val : ref Value;
	elem : ref Elem = nil;
	(err, i, tag) = tag_decode(a, i, n);
	if(err == OK) {
		(err, i, length) = length_decode(a, i, n);
		if(err == OK) {
			if(debug)
				sys->print("%sgot tag %s, length %d, now at byte %d\n",
						ber_ind, tag.tostring(), length, i);
			if(tag.class == Universal)
				(err, i, val) = value_decode(a, i, n, length, tag.num, tag.constr, depth);
			else
				(err, i, val) = value_decode(a, i, n, length, OCTET_STRING, 0, depth);	# its bytes, whatever they hold
			if(val != nil)
				elem = ref Elem(tag, val);
		}
	}
	if(debug) {
		sys->print("%send ber_decode, byte %d\n", ber_ind, i);
		if(val != nil) {
			sys->print("%sdecode result:\n", ber_ind);
			print_elem(elem);
		}
		if(err != OK)
			sys->print("%serror: %s\n", ber_ind, errstr(err, i, i));
		ber_ind = ber_ind_save;
	}
	return (err, i, elem);
}

# Decode a tag field.  As well as Tag, return an int that
# is 1 if the type is constructed, 0 if not.
tag_decode(a: array of byte, i, n: int) : (int, int, Tag)
{
	err := OK;
	class, num, constr: int;
	if(n-i >= 2) {
		v := int a[i++];
		class = v & CLASS_MASK;
		if(v & CONSTR_MASK)
			constr = 1;
		else
			constr = 0;
		num = v & TAG_MASK;
		if(num == TAG_MASK) {
			# long tag number: only for 31 and above, in the
			# fewest bytes (X.690 8.1.2.4)
			if(i < n && a[i] == byte 16r80)
				err = EINVAL;
			else
				(err, i, num) = uint7_decode(a, i, n);
			if(err == OK && num < TAG_MASK)
				err = EINVAL;
		}
	}
	else
		err = ESHORT;
	return (err, i, Tag(class, num, constr));
}

# Decode a length field.  Assume it fits in a Limbo int.
# The indefinite form (16r80) is refused: DER has none (X.690 10.1),
# and what is decoded here is certificates, keys and signatures.  It
# was read as a long form of no bytes, a length of 0, so that
# 30 80 00 00 was an empty SEQUENCE and two bytes left over.
length_decode(a: array of byte, i, n: int) : (int, int, int)
{
	err := OK;
	num := 0;
	if(i < n) {
		v := int a[i++];
		if(v == 16r80)
			err = EINVAL;
		else if(v & 16r80) {
			# the long form, in the fewest bytes (X.690 10.1): no
			# leading zero byte, and not for a length the short
			# form holds
			if(i < n && a[i] == byte 0)
				return (EINVAL, i, 0);
			(err, i, num) = int_decode(a, i, n, v&16r7F, 1);
			if(err == OK && num < 16r80)
				err = EINVAL;
		}
		else
			num = v;
	}
	else
		err = ESHORT;
	return (err, i, num);
}

# Decode a value according to the encoding of the Universal
# type with number "kind" and constructed/primitive according
# to "constr", with given length (may be -1, for "indefinite").
value_decode(a: array of byte, i, n, length, kind, constr, depth: int) : (int, int, ref Value)
{
	err := OK;
	val : ref Value;
	va : array of byte;
	# the bytes that are there, counted without adding: a length near
	# the largest int made i+length negative, and the value was then
	# sliced or allocated at that size (an exception in whoever was
	# decoding a peer's certificate)
	if(length < 0 || length > n - i)
		err = EVALLEN;
	if(err != OK)
		return (err, i, nil);
	case kind {
	0 =>
		# end-of-contents: there are no indefinite lengths to end
		err = EINVAL;
	BOOLEAN =>
		if(constr)
			err = ECONSTR;
		else if(length != 1)
			err = EVALLEN;
		else {
			# the value's own byte (it was the buffer's first: a
			# certificate begins 16r30, so every BOOLEAN in one
			# was true, cA FALSE and critical FALSE included).
			# 0 is false and 16rFF true (X.690 11.1); BER's
			# any-other-byte for true is refused.
			if(a[i] != byte 0 && a[i] != byte 16rFF)
				err = EINVAL;
			else {
				val = ref Value.Bool(int a[i]);
				i++;
			}
		}
	INTEGER or ENUMERATED =>
		if(constr)
			err = ECONSTR;
		else if(length == 0)
			# an INTEGER has at least one byte (X.690 8.3.1)
			err = EVALLEN;
		else if(length > 1 && (a[i] == byte 0 && (int a[i+1] & 16r80) == 0
				|| a[i] == byte 16rFF && (int a[i+1] & 16r80) != 0))
			# and no more than it needs (8.3.2): 00 7F and FF 80
			# are 7F and 80 written long
			err = EINVAL;
		else if(length <= 4) {
			num : int;
			(err, i, num) = int_decode(a, i, i+length, length, 0);
			if(err == OK)
				val = ref Value.Int(num);
		}
		else {
			va = array[length] of byte;
			va[0:] = a[i:i+length];
			val = ref Value.BigInt(va);
			i += length;
		}
	BIT_STRING =>
		# primitive (X.690 10.2); a first byte that counts the unused
		# bits of the last, which are zero (11.2.1); with no bits,
		# that byte alone and zero
		if(constr)
			err = ECONSTR;
		else if(length < 1 || int a[i] > 7 || length == 1 && a[i] != byte 0)
			err = EINVAL;
		else if(length > 16r0FFFFFFF)
			err = ETOOBIG;
		else {
			bitsunused := int a[i];
			if(length > 1 && (int a[i+length-1] & ((1 << bitsunused) - 1)) != 0)
				err = EINVAL;
			else {
				va = array[length-1] of byte;
				va[0:] = a[i+1:i+length];
				if(length == 1)
					va = nil;
				val = ref Value.BitString(bitsunused, va);
				i += length;
			}
		}
	OCTET_STRING or ObjectDescriptor =>
		(err, i, va) = octet_decode(a, i, length, constr);
		if(err == OK)
			val = ref Value.Octets(va);
	NULL =>
		if(constr)
			err = ECONSTR;
		else if(length != 0)
			err = EVALLEN;
		else
			val = ref Value.Null;
	OBJECT_ID =>
		if(constr)
			err = ECONSTR;
		else if (length == 0)
			err = EVALLEN;
		else {
			subids : list of int = nil;
			iend := i+length;
			while(i < iend) {
				x : int;
				# a subidentifier in the fewest bytes (X.690 8.19.2)
				if(a[i] == byte 16r80) {
					err = EINVAL;
					break;
				}
				(err, i, x) = uint7_decode(a, i, iend);
				if(err != OK)
					break;
				subids = x :: subids;
			}
			if(err == OK) {
				if(i != iend)
					err = EVALLEN;
				else {
					m := len subids;
					ia := array[m+1] of int;
					while(subids != nil) {
						y := hd subids;
						subids = tl subids;
						if(m == 1) {
							# the first two arcs are one number,
							# 40*X+Y with X at most 2 (X.690
							# 8.19.4): under arc 2, Y is whatever
							# is left (2.999 was read as 26.39)
							if(y >= 80) {
								ia[0] = 2;
								ia[1] = y - 80;
							} else {
								ia[1] = y % 40;
								ia[0] = y / 40;
							}
						}
						else
							ia[m--] = y;
					}
					val = ref Value.ObjId(ref Oid(ia));
				}
			}
		}
	EXTERNAL or EMBEDDED_PDV =>
		# TODO: parse this internally
		va = array[length] of byte;
		va[0:] = a[i:i+length];
		val = ref Value.Other(va);
		i += length;
	REAL =>
		# let the appl decode, with math module
		if(constr)
			err = ECONSTR;
		else {
			va = array[length] of byte;
			va[0:] = a[i:i+length];
			val = ref Value.Real(va);
			i += length;
		}
	SEQUENCE or SET=>
		vl : list of ref Elem;
		(err, i, vl) = seq_decode(a, i, length, constr, depth+1);
		if(err == OK) {
			if(kind == SEQUENCE)
				val = ref Value.Seq(vl);
			else
				val = ref Value.Set(vl);
		}
	UTF8String or NumericString or PrintableString or TeletexString
	or VideotexString or IA5String or UTCTime
	or GeneralizedTime or GraphicString or VisibleString
	or GeneralString or UniversalString or BMPString =>
		(err, i, va) = octet_decode(a, i, length, constr);
		if(err == OK) {
			str: string;
			(err, str) = strdecode(va, kind);
			if(err == OK)
				val = ref Value.String(str);
		}

	* =>
		va = array[length] of byte;
		va[0:] = a[i:i+length];
		val = ref Value.Other(va);
		i += length;
	}
	return (err, i, val);
}

# Decode an int in format where count bytes are
# concatenated to form value.
# Although ASN1 allows any size integer, we return
# an error if the result doesn't fit in a Limbo int.
# If unsigned is not set, make sure to propagate sign bit.
int_decode(a: array of byte, i, n, count, unsigned: int) : (int, int, int)
{
	err := OK;
	num := 0;
	if(n-i >= count) {
		if((count > 4) || (unsigned && count == 4 && (int a[i] & 16r80)))
			err = ETOOBIG;
		else {
			if(!unsigned && count > 0 && count < 4 && (int a[i] & 16r80))
				num = -1;		# all bits set
			for(j := 0; j < count; j++) {
				v := int a[i++];
				num = (num << 8) | v;
			}
		}
	}
	else
		err = ESHORT;
	return (err, i, num);
}

# Decode an unsigned int in format where each
# byte except last has high bit set, and remaining
# seven bits of each byte are concatenated to form value.
# Although ASN1 allows any size integer, we return
# an error if the result doesn't fit in a Limbo int.
uint7_decode(a: array of byte, i, n: int) : (int, int, int)
{
	err := OK;
	num := 0;
	more := 1;
	while(more && i < n) {
		v := int a[i++];
		if(num & 16r7F000000) {
			err = ETOOBIG;
			break;
		}
		num <<= 7;
		more = v & 16r80;
		num |= (v & 16r7F);
	}
	if(more && err == OK)
		err = ESHORT;
	return (err, i, num);
}

# The bytes of an OCTET STRING or of a string type: primitive, as DER
# has them (X.690 10.2).  The caller has checked that length bytes are
# there.
octet_decode(a: array of byte, i, length, constr: int) : (int, int, array of byte)
{
	if(constr)
		return (ECONSTR, i, nil);
	va := array[length] of byte;
	va[0:] = a[i:i+length];
	return (OK, i+length, va);
}

# The text of a string type's bytes.  Each type has its own characters
# (X.680 41): they were all taken for UTF-8, so a BMPString read as
# its bytes with a NUL before each letter and a TeletexString's
# accented letters as U+FFFD, and two names that differ only in how
# they are written could not be told to be the same or different.
#	UTF8String: UTF-8, and nothing that is not (an overlong form,
#		half a rune)
#	NumericString, PrintableString, IA5String, VisibleString, and
#		the two times: ASCII (their own subsets of it are not
#		enforced: CAs have put '@' and '*' in PrintableStrings)
#	BMPString: UCS-2, big-endian, no surrogates
#	UniversalString: UCS-4, big-endian
#	TeletexString, VideotexString, GraphicString, GeneralString:
#		taken as Latin-1, as every other reader of certificates
#		takes them (T.61's own escapes are not used in practice)
# A NUL is a character like another here; a name with one is refused
# by whoever reads names (x509).
strdecode(va: array of byte, kind: int): (int, string)
{
	s: string;
	n := len va;
	case kind {
	UTF8String =>
		s = string va;
		back := array of byte s;
		if(len back != n)
			return (EINVAL, nil);
		for(i := 0; i < n; i++)
			if(back[i] != va[i])
				return (EINVAL, nil);
	TeletexString or VideotexString or GraphicString or GeneralString =>
		s = "";
		for(i := 0; i < n; i++)
			s[i] = int va[i];
	BMPString =>
		if(n % 2 != 0)
			return (EINVAL, nil);
		s = "";
		for(i := 0; i < n; i += 2) {
			r := (int va[i] << 8) | int va[i+1];
			if(r >= 16rD800 && r <= 16rDFFF)
				return (EINVAL, nil);
			s[i/2] = r;
		}
	UniversalString =>
		if(n % 4 != 0)
			return (EINVAL, nil);
		s = "";
		for(i := 0; i < n; i += 4) {
			if(va[i] != byte 0 || int va[i+1] > 16r10)
				return (EINVAL, nil);
			r := (int va[i+1] << 16) | (int va[i+2] << 8) | int va[i+3];
			if(r >= 16rD800 && r <= 16rDFFF)
				return (EINVAL, nil);
			s[i/4] = r;
		}
	* =>
		s = "";
		for(i := 0; i < n; i++) {
			if(int va[i] >= 16r80)
				return (EINVAL, nil);
			s[i] = int va[i];
		}
	}
	return (OK, s);
}

# Decode a sequence or set: the elements that fill length bytes,
# which the caller has checked are there.
seq_decode(a : array of byte, i, length, constr, depth: int) : (int, int, list of ref Elem)
{
	if(!constr)
		return (EPRIM, i, nil);
	err := OK;
	lve : list of ref Elem = nil;
	elem : ref Elem;
	iend := i+length;
	while(i < iend) {
		(err, i, elem) = ber_decode(a, i, iend, depth);
		if(err != OK)
			return (err, i, nil);
		lve = elem :: lve;
	}
	ans : list of ref Elem = nil;
	# reverse back to original order
	for(; lve != nil; lve = tl lve)
		ans = hd lve :: ans;
	return (err, i, ans);
}

intarr_eq(a: array of int, b: array of int) : int
{
	alen := len a;
	if(alen != len b)
		return 0;
	for(i := 0; i < alen; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

# Look for o in tab; if found, return index, else return -1.
oid_lookup(o: ref Oid, tab: array of Oid) : int
{
	for(i := 0; i < len tab; i++)
		if(intarr_eq(o.nums, tab[i].nums))
			return i;
	return -1;
}

# If e is a SEQUENCE, return (1, e's element list)
# else return (error, nil).
Elem.is_seq(e: self ref Elem) : (int, list of ref Elem)
{
	if(e.tag.class == Universal && e.tag.num == SEQUENCE) {
		pick v := e.val {
		Seq =>
			return (1, v.l);
		}
	}
	return (0, nil);
}

# If e is a SET, return (1, e's element list)
# else return (error, nil).
Elem.is_set(e: self ref Elem) : (int, list of ref Elem)
{
	if(e.tag.class == Universal && e.tag.num == SET) {
		pick v := e.val {
		Set =>
			return (1, v.l);
		}
	}
	return (0, nil);
}

# If e is an INTEGER that fits in a limbo int, return (1, val)
# else return (0, 0l).
Elem.is_int(e: self ref Elem) : (int, int)
{
	if(e.tag.class == Universal && (e.tag.num == INTEGER || e.tag.num == BOOLEAN)) {
		pick v := e.val {
		Bool or
		Int =>
			return (1, v.v);
		}
	}
	return (0, 0);
}

# If e is an INTEGER, return (1, bytes): its contents as DER has them,
# two's complement in the fewest bytes, so that a first byte with its
# top bit set says a negative number whatever the length.  (One that
# fits an int came back as the int's bytes less leading zeros: 128 as
# 80, which is also -128's.)
Elem.is_bigint(e: self ref Elem) : (int, array of byte)
{
	if(e.tag.class == Universal && e.tag.num == INTEGER) {
		pick v := e.val {
		BigInt =>
			return (1, v.bytes);
		Int =>
			x := v.v;
			a := array[5] of byte;
			a[0] = byte 0;
			if(x < 0)
				a[0] = byte 16rFF;
			for(i := 0; i < 4; i++)
				a[i+1] = byte ((x >> (8*(3-i))) & 16rFF);
			for(j := 0; j < 4; j++)
				if(!(a[j] == byte 0 && (int a[j+1] & 16r80) == 0
				  || a[j] == byte 16rFF && (int a[j+1] & 16r80) != 0))
					break;
			return (1, a[j:]);
		}
	}
	return (0, nil);
}

# If e is a bitstring, return (1, unused bits, bytes containing bit string),
# else return (0, nil)
Elem.is_bitstring(e: self ref Elem) : (int, int, array of byte)
{
	if(e.tag.class == Universal && e.tag.num == BIT_STRING) {
		pick v := e.val {
		BitString =>
			return (1, v.unusedbits, v.bits);
		}
	}
	return (0, 0, nil);
}

# If e is an octetstring, return (1, bytes),
# else return (0, nil)
Elem.is_octetstring(e: self ref Elem) : (int, array of byte)
{
	if(e.tag.class == Universal && e.tag.num == OCTET_STRING) {
		pick v := e.val {
		Octets =>
			return (1, v.bytes);
		}
	}
	return (0, nil);
}

# If e is an object id, return (1, ref Oid),
# else return (0, nil)
Elem.is_oid(e: self  ref Elem) : (int, ref Oid)
{
	if(e.tag.class == Universal && e.tag.num == OBJECT_ID) {
		pick v := e.val {
		ObjId =>
			return (1, v.id);
		}
	}
	return (0, nil);
}

# If e is some kind of string (excluding times), return (1, string),
# else return (0, "")
Elem.is_string(e: self ref Elem) : (int, string)
{
	if(e.tag.class == Universal) {
		case e.tag.num {
		UTF8String or NumericString or PrintableString or TeletexString
		or VideotexString or IA5String or GraphicString
		or VisibleString or GeneralString or UniversalString
		or BMPString =>
		pick v := e.val {
			String =>
				return (1, v.s);
			}
		}
	}
	return (0, nil);
}

# If e is some kind of time, return (1, string),
# else return (0, "")
Elem.is_time(e: self ref Elem) : (int, string)
{
	if(e.tag.class == Universal
	   && (e.tag.num == UTCTime || e.tag.num == GeneralizedTime)) {
		pick v := e.val {
		String =>
			return (1, v.s);
		}
	}
	return (0, nil);
}

# Return printable error string for code ecode.
# i is position where error is first noted.
# n is the end of the passed data: if i!=n then
# we didn't use all the data and an error should
# be returned about that.
errstr(ecode, i, n: int) : string
{
	if(ecode == OK && i == n)
		return "";
	err := "DER decode: ";
	case ecode {
		OK =>
			err += "extra data after the value";
		ESHORT =>
			err += "need more data";
		ETOOBIG =>
			err += "value exceeds implementation limit";
		EVALLEN =>
			err += "value has wrong length";
		ECONSTR =>
			err += "value is constructed, should be primitive";
		EPRIM =>
			err += "value is primitive";
		EINVAL =>
			err += "value encoding invalid";
		* =>
			err += "unknown error " + string ecode;
	}
	err += " at byte " + string i;
	return err;
}

# Printing functions, for debugging

Tag.tostring(t: self Tag) : string
{
	ans := "";
	snum := string t.num;
	if(t.class == Universal) {
		case t.num {
		BOOLEAN => ans = "BOOLEAN";
		INTEGER => ans = "INTEGER";
		BIT_STRING => ans = "BIT STRING";
		OCTET_STRING => ans = "OCTET STRING";
		NULL => ans = "NULL";
		OBJECT_ID => ans = "OBJECT IDENTIFER";
		ObjectDescriptor => ans = "OBJECT_DES";
		EXTERNAL => ans = "EXTERNAL";
		REAL => ans = "REAL";
		ENUMERATED => ans = "ENUMERATED";
		EMBEDDED_PDV => ans = "EMBEDDED PDV";
		UTF8String => ans = "UTF8String";
		SEQUENCE => ans = "SEQUENCE";
		SET => ans = "SET";
		NumericString => ans = "NumericString";
		PrintableString => ans = "PrintableString";
		TeletexString => ans = "TeletexString";
		VideotexString => ans = "VideotexString";
		IA5String => ans = "IA5String";
		UTCTime => ans = "UTCTime";
		GeneralizedTime => ans = "GeneralizedTime";
		GraphicString => ans = "GraphicString";
		VisibleString => ans = "VisibleString";
		GeneralString => ans = "GeneralString";
		UniversalString => ans = "UniversalString";
		BMPString => ans = "BMPString";
		* => ans = "UNIVERSAL " + snum;
		}
	}
	else {
		case t.class {
		Application =>
			ans = "APPLICATION " + snum;
		Context =>
			ans = "CONTEXT "+ snum;
		Private =>
			ans = "PRIVATE " + snum;
		}
	}
	return ans;
}

Elem.tostring(e: self ref Elem) : string
{
	return estring(e, "");
}

Value.tostring(v: self ref Value) : string
{
	return vstring(v, "");
}

estring(e: ref Elem, indent: string) : string
{
	return indent + e.tag.tostring() + " " + vstring(e.val, indent);
}

vstring(val: ref Value, indent: string) : string
{
	ans := "";
	pick v := val {
		Bool or Int =>
			ans += string v.v;
		Octets or BigInt or Real or Other =>
			ans += bastring(v.bytes, indent + "\t");
		BitString =>
			ans += " bits (unused " +string v.unusedbits + ")" +  bastring(v.bits, indent + "\t");
		Null =>
			;
		ObjId =>
			ans += v.id.tostring();
		String =>
			ans += "\"" + v.s + "\"";
		Seq or Set =>
			ans += "{\n";
			newindent := indent + "\t";
			l := v.l;
			while(l != nil) {
				if(ans[len ans-1] != '\n')
					ans[len ans] = '\n';
				ans += estring(hd l, newindent);
				l = tl l;
			}
			if(ans[len ans-1] != '\n')
				ans[len ans] = '\n';
			ans += indent + "}";
	}
	return ans;
}

bastring(a: array of byte, indent: string) : string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	ans := indent;
	nlindent := "\n" + indent;
	for(i := 0; i < len a; i++) {
		if(i < len a - 1 && i%10 == 0)
			ans += nlindent ;
		ans += sys->sprint("%2x ", int a[i]);
	}
	return ans;
}

Oid.tostring(o: self ref Oid) : string
{
	ans := "";
	for(i := 0; i < len o.nums; i++) {
		ans += string o.nums[i];
		if(i < len o.nums - 1)
			ans[len ans] = '.';
	}
	return ans;
}

print_elem(e: ref Elem)
{
	s := e.tostring();
	a := array of byte s;
	sys->write(sys->fildes(1), a, len a);
	sys->print("\n");
}
