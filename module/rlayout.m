#
# Rlayout - Rich text layout engine for Xenith renderers
#
# Takes a document tree (list of DocNode) and renders it to a Draw->Image.
# Shared between markdown and HTML renderers. Uses Draw font measurement
# for line breaking and text() for rendering.
#

Rlayout: module {
	PATH: con "/dis/xenith/render/rlayout.dis";

	# Document node types
	Ntext,          # Inline text run
	Nbold,          # Bold text
	Nitalic,        # Italic text (underlined where the family has no italic)
	Ncode,          # Inline code (monospace)
	Nlink,          # Hyperlink (rendered as underlined text)
	Npara,          # Paragraph block
	Nheading,       # Heading block (level in aux)
	Ncodeblock,     # Code block (monospace, background)
	Nbullet,        # Bullet list item (nesting level in aux)
	Nnumber,        # Numbered list item (number in aux, nesting level in text)
	Nhrule,         # Horizontal rule
	Nblockquote,    # Block quote paragraph (depth of nesting in aux)
	Nnewline,       # Explicit line break
	Ntable,         # Table (rows in text, pipe-separated cells, aux=ncols)
	Nmermaid,       # Mermaid diagram (text= is raw mermaid syntax, rendered as image)
	Nstrike         # Struck-through text
		: con iota;

	# Document node: tree of content
	DocNode: adt {
		kind: int;            # Node type (Ntext, Nbold, etc.)
		text: string;         # Text content (for Ntext, Ncode, etc.)
		children: list of ref DocNode;  # Child nodes (for blocks)
		aux: int;             # Auxiliary data (heading level, list number)
	};

	# Layout configuration
	Style: adt {
		width: int;           # Available width in pixels
		margin: int;          # Left/right margin
		font: ref Draw->Font; # Base proportional font
		codefont: ref Draw->Font; # Monospace font
		fgcolor: ref Draw->Image; # Text color
		bgcolor: ref Draw->Image; # Background color
		linkcolor: ref Draw->Image; # Link color
		codebgcolor: ref Draw->Image; # Code block background
		h1scale: int;         # H1 size multiplier x100 (150 = 1.5x, via repeated text)
	};

	init: fn(d: ref Draw->Display);

	# Parse markdown text into a document tree.
	parsemd: fn(text: string): list of ref DocNode;

	# Render a document to an image.
	# Returns (image, total height used).
	render: fn(doc: list of ref DocNode, style: ref Style): (ref Draw->Image, int);

	# Parse markdown, with the line (from 0) each block starts on.
	parsemdlines: fn(text: string): (list of ref DocNode, array of int);

	# Render a document, with the y each block starts at: with
	# parsemdlines, a map between the text's lines and the image.
	renderat: fn(doc: list of ref DocNode, style: ref Style): (ref Draw->Image, array of int);

	# Extract plain text from a document tree (for AI/body buffer).
	totext: fn(doc: list of ref DocNode): string;
};
