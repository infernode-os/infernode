#
# PDF - Native PDF parsing and rendering
#
# Parses PDF files and renders pages to Draw images using
# Inferno's graphics primitives.  No host-side dependencies.
#

PDF: module {
	PATH: con "/dis/lib/pdf.dis";

	init:  fn(d: ref Draw->Display): string;
	open:  fn(data: array of byte, password: string): (ref Doc, string);

	Doc: adt {
		idx:         int;  # opaque handle
		close:       fn(d: self ref Doc);
		pagecount:   fn(d: self ref Doc): int;
		pagesize:    fn(d: self ref Doc, page: int): (real, real);
		renderpage:  fn(d: self ref Doc, page: int, dpi: int): (ref Draw->Image, string);
		extracttext: fn(d: self ref Doc, page: int): string;
		extractall:  fn(d: self ref Doc): string;
		dumppage:    fn(d: self ref Doc, page: int): string;
		# the words on a page, each with its box at 72 dpi from the
		# page's top left (where the page's text is drawn)
		words:       fn(d: self ref Doc, page: int): list of (string, Draw->Rect);
	};
};
