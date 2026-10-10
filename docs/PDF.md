# PDF Module

InferNode includes a native PDF parser and renderer written entirely in Limbo.
It can open PDF files, extract text, and render pages to Draw images — all
within the Inferno environment with no external dependencies (aside from an
optional host-side `pdftoppm` fallback in the Xenith integration).

The implementation spans three modules with no external dependencies:

- **`pdf.b`** (6,900 lines) — PDF parser, content stream interpreter, page
  renderer, text extractor, encryption/decryption
- **`outlinefont.b`** (4,200 lines) — CFF/Type 2, TrueType and Type 1 font
  parsers, charstring interpreters, glyph rasterizer
- **`pdfenc.b`** (380 lines) — the PDF encodings and glyph names, loaded
  when a document has a simple font

## API

### PDF Module

```
include "pdf.m";
    pdf: PDF;
    Doc: import pdf;

pdf = load PDF PDF->PATH;
pdf->init(display);

(doc, err) := pdf->open(data, nil);       # nil = try empty password
if(doc == nil)
    sys->fprint(stderr, "open: %s\n", err);

n := doc.pagecount();
(w, h) := doc.pagesize(1);            # points (1/72 inch)
(img, err) := doc.renderpage(1, 72);   # render at 72 DPI
err = doc.paint(1, 1.5, dst);          # onto dst at 1.5 pixels to the point
text := doc.extracttext(1);            # page 1 text
words := doc.words(1);                 # its words, each with its box
alltext := doc.extractall();           # all pages

doc.close();                           # release resources
```

**`Doc` methods:**

| Method | Description |
|--------|-------------|
| `close()` | Release internal state (xref, object graph, raw data). Callers should always close when done. Methods on a closed Doc return zero/nil safely. |
| `pagecount()` | Number of pages in the document. |
| `pagesize(page)` | Width and height in PDF points (72 points = 1 inch). Pages are 1-indexed. |
| `renderpage(page, dpi)` | Render a page to a `Draw->Image` (RGB24). DPI controls resolution: 72 for screen, 150+ for print. Returns `(nil, error)` on failure. |
| `paint(page, zoom, dst)` | Draw a page onto `dst` (white first), its top left at `dst.r.min`, at `zoom` pixels to the point: no image of its own, and any zoom, not a whole number of dots to the inch. Xenith's view paints its page images so. |
| `words(page)` | The words on a page, each with its box at 72 dpi from the page's top left, measured by the widths the renderer advances by. |
| `extracttext(page)` | Extract Unicode text from a single page via content stream analysis and ToUnicode CMap mapping. |
| `extractall()` | Concatenate text from all pages. |
| `dumppage(page)` | Dump page object tree for debugging. |

### OutlineFont Module

```
include "outlinefont.m";
    outlinefont: OutlineFont;

outlinefont = load OutlineFont OutlineFont->PATH;
outlinefont->init(display);

(face, err) := outlinefont->open(fontdata, "cff");   # or "ttf", "t1"

gid := face.chartogid(charcode);       # encoding lookup
gid = face.namedgid("Aacute");         # by glyph name (CFF, Type 1)
adv := face.drawglyph(gid, 12.0, dst, point, src);   # render at 12pt
face.drawglyphm(gid, m, dst, x, y, src);  # through a 2x2 matrix, at a real origin
w := face.glyphwidth(gid, 12.0);       # advance width in pixels
(h, asc, desc) := face.metrics(12.0);  # scaled metrics
face.close();                          # release it
```

`drawglyphm` draws a glyph slanted, stretched or turned as itself: the
glyph's point (u, v), in font units with y up, lands at
(x + m[0]u + m[2]v, y + m[1]u + m[3]v). Its origin is placed to a
quarter of a pixel; upright text sits on a whole pixel row, its tops and
bottoms fitted to rows. Rasterised glyphs are cached by face, glyph,
matrix and phase, the cache bounded by its pixels (3 MB) as well as its
entries.

## What It Supports

### PDF Structure
- Cross-reference tables (traditional and fallback keyword scan)
- Incremental updates (`/Prev` trailer chaining)
- Indirect object references with generation numbers
- Page tree traversal with cycle detection (depth limit 64)

### Content Streams
- Path construction: `m`, `l`, `c`, `v`, `y`, `h`, `re`
- Path painting: `f`, `f*`, `S`, `s`, `B`, `B*`, `b`, `b*`, `n`
- Clipping: `W`, `W*`
- Text: `BT`/`ET`, `Tf`, `Tm`, `Td`, `TD`, `T*`, `Tj`, `TJ`, `'`, `"`
- Color: `g`, `G`, `rg`, `RG`, `k`, `K`, `cs`, `CS`, `sc`, `SC`, `scn`, `SCN`
- Graphics state: `q`, `Q`, `cm`, `gs`, `w`, `J`, `j`, `M`, `d`
- XObjects: `Do` (Form XObjects and Image XObjects)
- Inline images: `BI`/`ID`/`EI`

### Color Spaces
- DeviceRGB, DeviceGray, DeviceCMYK (converted to RGB)
- Indexed (palette lookup)
- CalRGB (treated as sRGB)

### Fonts

Every glyph is drawn from its outline, through the text rendering
matrix, anti-aliased at the image's resolution, and placed by the PDF's
own widths. No bitmap fonts are used.

- **Embedded**: Type 1 (FontFile: PFA, PFB, eexec, Subrs, flex, seac),
  CFF / Type1C and CID-keyed CFF (FontFile3), OpenType (FontFile3
  /OpenType), TrueType (FontFile2).
- **Not embedded**: a face of the font's kind with the same metrics —
  TeX Gyre Termes, Heros and Cursor for Times, Helvetica and Courier
  (regular, bold, italic, bold italic), chosen by the font's name and
  its descriptor's flags; DejaVu Sans for Symbol, ZapfDingbats and
  characters the others lack. A face is narrowed to the PDF's widths
  when the font it stands for is narrower.
- **Simple fonts' glyphs** by the spec's rules: Encoding, BaseEncoding
  and Differences by glyph name (Type 1, CFF); through Unicode, or the
  font's own cmap when symbolic (TrueType); else the font's built-in
  encoding.
- **CID fonts**: Identity and embedded CMaps (codespace ranges of one
  to four bytes, cidrange, cidchar), CIDToGIDMap, W and DW.
- **Type 3** glyphs run their content streams through the font matrix.
- **Text state**: Tc, Tw, Tz, TL, Ts, Tr (fill, stroke, invisible),
  fill opacity, the clip; `Q` restores the font and text state.
- ToUnicode CMaps (bfchar, bfrange) and, without one, the encoding's
  glyph names, for text extraction and `words`.
- Fonts are made once a document, by object, and their programs parsed
  when a glyph is first drawn.

### Encryption
- Standard security handler (RC4 and AES password-based decryption)
- V=1 (RC4, 40-bit key), V=2 (RC4, 128-bit key), V=4 (AES-128), V=5 (AES-256)
- Automatic empty-password trial (most encrypted PDFs use permissions-only encryption)
- User password authentication; owner password not needed for decryption
- Crypt filters: V2 (RC4), AESV2 (AES-128), AESV3 (AES-256)
- Object stream (ObjStm) decryption at the container level
- `open(data, "secret")` to supply a password; `open(data, nil)` tries empty

### Filters / Decompression
- A stream goes through every filter it names, in order, each with its
  DecodeParms
- FlateDecode (zlib) and LZWDecode (EarlyChange), each with PNG
  predictors (None, Sub, Up, Average, Paeth) or the TIFF predictor
- ASCII85Decode, ASCIIHexDecode, RunLengthDecode
- DCTDecode / JPEGDecode (via Inferno's `readjpg`)

### Rendering Features
- Affine transforms (CTM composition)
- Fill and stroke with configurable colors and opacity
- Even-odd and winding number fill rules
- Clipping paths (computed as GREY8 masks)
- Soft masks (SMask from ExtGState) for non-binary transparency
- Fill and stroke opacity (`ca`, `CA` from ExtGState)
- Gradient shading (axial and radial)
- Text at any angle, slant or stretch, each glyph rasterised through its
  matrix
- Image XObjects (JPEG, raw RGB/Gray, with color space conversion)
- Form XObjects (nested content streams with independent resources)

## Known Limitations

### Not Implemented
- **Certificate-based encryption** — PDFs using `/Filter/Adobe.PubSec`
  (public-key / certificate encryption) are not supported. These are rare
  outside enterprise document management systems.
- **Blend modes** — `ColorBurn`, `ColorDodge`, `Overlay`, `Multiply`, etc.
  are parsed from ExtGState but rendered as normal (opaque compositing).
  Visual fidelity is reduced for PDFs that rely on blend effects.
- **CCITTFax filter** — streams using it are silently skipped (blank areas).
- **Text and clipping** — text is clipped to the clip path's bounds:
  exactly for a rectangle (the usual clip), to its bounding box for
  another shape. Text render modes 4 to 7 (adding glyphs to the clip
  path) draw as their filling modes; the clip they would make is not
  made.
- **Annotations and forms** — AcroForm fields, widget annotations, and
  digital signatures are ignored.
- **JavaScript and actions** — no execution environment for embedded scripts.
- **Linearized PDF** — the linearization hint tables are not used; parsing
  starts from `startxref` like a non-linearized file.
- **JBIG2 image filter** — not supported (rare outside scanned documents).

### Practical Limits
- Images with raw decompressed size > 128 MB are skipped to prevent heap
  exhaustion.
- Default heap pool is 256 MB (`-pheap=256M`). Very large PDFs with many
  high-resolution images may need `-pheap=512M` or larger.
- Glyphs are filled by the draw device (`Image.fillpath`, non-zero
  winding), once per face, glyph, size and quarter-pixel phase.

## Conformance Testing

### Test Corpus

The test suite covers 10,302 PDFs drawn from 8 open-source repositories.
These are fetched once by `tests/host/fetch-test-pdfs.sh` (~2 GB on disk):

| Suite | Source | PDFs | Focus |
|-------|--------|------|-------|
| pdf-differences | [PDF Association](https://github.com/pdf-association/pdf-differences) | 34 | Interop edge cases: blend modes, fonts, clipping, dashing |
| poppler-test | [Poppler](https://gitlab.freedesktop.org/poppler/test) | 80 | Rendering correctness (has reference PNGs) |
| bfo-pdfa | [BFO](https://github.com/bfocom/pdfa-testsuite) | 33 | PDF/A-2 conformance, accessibility |
| pdftest | [PDFTest](https://github.com/sambitdash/PDFTest) | 58 | Reader capabilities, fonts, encryption |
| cabinet-of-horrors | [Open Preserve](https://github.com/openpreserve/format-corpus) | 24 | Degenerate streams, malformed structure |
| itext-pdfs | [iText](https://github.com/itext/itext-java) | 6,269 | Layout, forms, signing, PDF/A, PDF/UA, barcodes |
| pdfjs-pdfs | [Mozilla pdf.js](https://github.com/mozilla/pdf.js) | 897 | Mozilla's PDF viewer test corpus |
| verapdf-corpus | [veraPDF](https://github.com/veraPDF/veraPDF-corpus) | 2,907 | PDF/A validation, ISO 32000 compliance |

### Running Tests

```sh
# One-time: fetch all test suites
sh tests/host/fetch-test-pdfs.sh

# Full conformance run (runs each suite in its own emu process)
sh tests/host/run-pdf-conformance.sh

# Single suite
./emu/MacOSX/o.emu -r. -pheap=1024M \
    /tests/pdf_conformance_test.dis -suite pdfjs-pdfs

# Verbose (prints per-PDF status)
./emu/MacOSX/o.emu -r. -pheap=1024M \
    /tests/pdf_conformance_test.dis -v -suite cabinet-of-horrors
```

### Test Methodology

For each PDF, the conformance test:

1. Reads the file into a byte array
2. Calls `pdf->open(data, nil)` — parses xref, trailer, object graph; tries empty password for encrypted PDFs
3. Calls `doc.pagecount()` — fails if 0 (encrypted or unparseable)
4. Calls `doc.renderpage(1, 72)` — renders page 1 at screen resolution
5. Samples the rendered image on a 4x4 grid for non-white pixels
6. Calls `doc.extracttext(1)` — extracts text via content stream + CMap
7. Classifies result: **PASS** (rendered with content), **WARN** (rendered
   but blank), or **FAIL** (error during any step)
8. Calls `doc.close()` — releases document state

Each suite runs in a separate `emu` process with a 1 GB heap. The itext
suite (6,269 PDFs) is further batched into groups of 1,000 to stay within
memory limits. Results are written to `usr/inferno/test-pdfs/results.txt`.

### Current Results (February 2026)

```
Total:  10,302 PDFs
PASS:    9,762 (94.8%)
FAIL:      540 (5.2%)
```

**Failure breakdown:**

| Count | Category | Notes |
|------:|----------|-------|
| 206 | Password required | Encrypted PDFs requiring a non-empty password |
| 200 | Out of memory | Large images exceeding 1 GB heap (mostly itext GetImageBytesTest) |
| 46 | 0 pages | Unsupported structure or corrupted page tree |
| 45 | Unsupported encryption | Certificate-based (Adobe.PubSec) or misspelled filter |
| 14 | Corrupt xref | Fuzzed or intentionally corrupted files |
| 8 | Not a PDF | Test files that aren't actually PDFs |
| 8 | No startxref | Genuinely broken — no cross-reference table at all |
| 6 | Unsupported V=6 | Encryption revision 6 (extended AES-256) not yet implemented |
| 4 | Cannot parse Encrypt | Malformed or unusual encryption dictionaries |
| 2 | Empty file | Zero-byte test files |
| 1 | Other | Edge cases |

All 540 failures are clean error returns — no crashes, no hangs, no
undefined behavior.

**Encryption impact:** With encryption support, 51 previously-failing PDFs
(those with empty/permissions-only passwords) now open correctly. The raw
pass count decreased from 10,123 to 9,762 because 261 encrypted PDFs that
previously produced **garbled output** are now correctly **rejected** with
meaningful error messages ("password required", "unsupported filter").
This is the correct behavior — silent garbled rendering is worse than an
explicit error.

### What the Tests Do NOT Cover

- **Visual correctness** — the test checks that *something* rendered (non-white
  pixels exist), not that the output matches a reference image. A page could
  render with wrong colors or missing elements and still pass. For that,
  `tests/pdfrender` renders a page to an image file with its time and the
  memory it used, to compare with a reference renderer (Poppler's
  `pdftoppm`), and `tests/pdftext_test.b` checks text against known
  metrics and ink positions.
- **Multi-page rendering** — only page 1 is rendered. Bugs that appear on
  later pages (different fonts, images, structure) are not caught.
- **Text extraction accuracy** — the test checks that `extracttext` does not
  crash, but does not verify the extracted text against ground truth.
- **Performance** — no timing benchmarks. Some PDFs with thousands of path
  segments render slowly but correctly.

## Architecture Notes

### Document Lifecycle

`pdf->open()` parses the entire PDF into memory: the raw byte array, the
cross-reference table, and the trailer object graph are stored in a
module-global `doctab` array indexed by `Doc.idx`. The refcount GC handles
object lifetimes, but without `doc.close()` the entire document stays live
for the lifetime of the process.

Always call `doc.close()` when done — it nils the `doctab` slot, allowing
the GC to free the raw data, xref, and object graph immediately.

### Font Caching

A document's fonts are made once, by object number, when a page first
names them; a font's program is parsed when its first glyph is drawn
or measured, and closed with the document (`Doc.close`). The substitute
faces are opened once a process, when first wanted, and shared. The
rasterizer caches GREY8 masks by face, glyph, matrix and quarter-pixel
phase, up to 8192 glyphs or 3 MB of pixels.

### Coordinate System

PDF uses a bottom-left origin with y-axis pointing up. The renderer
constructs a CTM that maps PDF coordinates to pixel coordinates (top-left
origin, y-down). The page's `MediaBox` (or `CropBox`) defines the visible
area. All rendering operations go through the CTM, so rotated pages and
non-standard coordinate systems work correctly.

### Error Recovery

The parser is designed to handle malformed PDFs gracefully:

- **Invalid startxref offset**: falls back to scanning backward for the
  `xref` keyword
- **Fuzzed xref entries**: validates object numbers and counts against file
  size
- **Circular page trees**: depth limit of 64 prevents infinite recursion
- **Corrupt fonts**: bounds-checks array indices in hmtx, cmap, and glyph
  tables
- **Decompression errors**: caught and reported without crashing

## Reproducing the Conformance Tests

The test PDFs are **not** included in the InferNode distribution — they are
fetched from upstream open-source repositories on demand. The full corpus is
~1.8 GB on disk (10,302 files). To reproduce:

```sh
# 1. Set up build environment
export ROOT=$PWD
export PATH=$PWD/MacOSX/arm64/bin:$PATH

# 2. Build the PDF module and test programs
cd appl/lib && mk install
cd ../../tests && mk install

# 3. Fetch all 8 test suites (one-time, requires git, ~1.8 GB)
sh tests/host/fetch-test-pdfs.sh

# 4. Run the full conformance suite
sh tests/host/run-pdf-conformance.sh

# 5. Inspect results
cat usr/inferno/test-pdfs/results.txt | grep '^FAIL'
```

The fetch script clones each repository with `--depth 1` (shallow) and uses
sparse checkout where possible to minimize download size. It is idempotent —
running it again skips already-cloned suites.

Test PDFs are stored under `usr/inferno/test-pdfs/` which is in `.gitignore`.
Results are written to `usr/inferno/test-pdfs/results.txt` (one line per PDF).

## Code Size

| File | Lines | Role |
|------|------:|------|
| `appl/lib/pdf.b` | 6,923 | PDF parser, renderer, text extractor, encryption |
| `appl/lib/outlinefont.b` | 4,202 | CFF, TrueType and Type 1 font parsers, rasterizer |
| `appl/lib/pdfenc.b` | 378 | Encodings and glyph names |
| `tests/pdf_conformance_test.b` | 598 | Conformance test harness |
| `tests/pdf_test.b` | 629 | Unit tests |
| `tests/pdftext_test.b` | 363 | Text: metrics, encodings, filters, Type 1, Type 3 |
| `tests/pdfrender.b` | 129 | A page to an image file, timed |
| `tests/host/fetch-test-pdfs.sh` | 135 | Corpus fetch script |
| `tests/host/run-pdf-conformance.sh` | 58 | Test orchestrator |
| `module/outlinefont.m` | 104 | Font module interface |
| `module/pdf.m` | 30 | PDF module interface |
| `module/pdfenc.m` | 23 | Encodings interface |
| **Total** | **13,572** | |

The core implementation is **11,503 lines** of Limbo (pdf.b, outlinefont.b,
pdfenc.b). With tests, interfaces and shell scripts the full PDF subsystem
is **13,572 lines**. The substitute faces (`fonts/texgyre`) are 1.4 MB.

## Files

| File | Description |
|------|-------------|
| `module/pdf.m` | Public API interface |
| `module/outlinefont.m` | Font module interface |
| `module/pdfenc.m` | Encodings interface |
| `appl/lib/pdf.b` | PDF implementation |
| `appl/lib/outlinefont.b` | Font implementation |
| `appl/lib/pdfenc.b` | Encodings and glyph names |
| `fonts/texgyre/` | Substitute faces for fonts not embedded (GUST Font License) |
| `dis/lib/pdf.dis` | Compiled PDF module |
| `dis/lib/outlinefont.dis` | Compiled font module |
| `tests/pdftext_test.b` | Text rendering and measuring tests |
| `tests/pdfrender.b` | A page to an image file, with its time and memory |
| `tests/pdf_conformance_test.b` | Conformance test (discovery-based) |
| `tests/pdf_test.b` | Unit tests (parsing, object resolution) |
| `tests/host/run-pdf-conformance.sh` | Test orchestrator (per-suite isolation) |
| `tests/host/fetch-test-pdfs.sh` | Downloads 8 test corpora (~1.8 GB) |
