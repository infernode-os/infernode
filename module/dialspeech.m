#
# dialspeech.m — what was said to a telephone, as a number to dial
#
# Speech recognised (speech9p's hear) is read as a phone's voice
# dialling reads it: a number said as digits ("five five five one two",
# "oh", "double two", "nine eleven", "eight hundred", "star", "pound",
# "plus") or written as one ("555-1234", "+1 (555) 123-4567"), or a
# name to find in the address book (/phone/contacts, "name\tkind\t
# number" a line), with the kind of number wanted ("at work",
# "Sarah's mobile", "on her cell").  A leading "call" or "dial" says to
# place the call; without it the number is only put on the keypad.
#
Dialspeech: module
{
	PATH:	con "/dis/lib/dialspeech.dis";

	# what was said
	Nothing, Number, Name: con iota;

	Said: adt {
		what:	int;		# Nothing, Number or Name
		call:	int;		# began with call, dial, phone or ring
		number:	string;	# Number: the digits, * # and a leading +
		name:	string;	# Name: as said, lower case
		kind:	string;	# Name: mobile, work, home or main; nil for any
	};

	init:	fn();

	# The words heard, read.
	parse:	fn(text: string): ref Said;

	# The address book's entry for a name said: its number, the
	# contact's name and the number's kind as the book has them; or
	# nil and why not (no such name, two people answer to it, that
	# kind of number not there; or, for a book with no one in it, its
	# own "# ..." line: permission denied, not wired).  A name said
	# whole beats a word of one (mom, Mom); with no kind said, a
	# mobile is taken first.
	lookup:	fn(contacts: string, name, kind: string): (string, string, string, string);
};
