#
# Referstyle - a style of citation for refer(1)
#
# refer finds the works a document cites, in order, and a style sets
# them: a note citing a work, the first time and after, and its entry
# in the bibliography. What it gives is troff's text: \fI and \fP for
# italics, Unicode for quotation marks and dashes.
#
# A work's fields are named as BibTeX names them (title, journal,
# booktitle, publisher, year, volume, number, pages, edition, url,
# doi, ...), their values troff's text; names are split as BibTeX
# splits them.
#

Referstyle: module
{
	# a person's name: "von Last, Jr, First"
	Name: adt {
		first:	string;
		von:	string;
		last:	string;
		jr:	string;
	};

	Ref: adt {
		key:	string;			# the label cited by
		typ:	string;			# book, article, incollection, ...
		fields:	list of (string, string);
		author:	array of ref Name;
		editor:	array of ref Name;
		translator:	array of ref Name;
	};

	init:	fn(): string;

	# the text of a note citing r at loc (a page, a range, 1.1-5; nil
	# for none), the first time it is cited or after
	note:	fn(r: ref Ref, first: int, loc: string): string;

	# r's entry in the bibliography, and the key it is sorted by
	bib:	fn(r: ref Ref): string;
	sortkey:	fn(r: ref Ref): string;
};
