# Xenith Image Display Implementation

This document tracks the implementation of multimodal image display in Xenith windows.

## Status: Complete

### Implementation Complete
- [x] Add QWimage constant to dat.m
- [x] Add image fields to Window adt in wind.m
- [x] Create imgload.m module interface
- [x] Create imgload.b image loader implementation
- [x] Add "image" file to fsys.b dirtabw
- [x] Add QWimage read/write handlers in xfid.b
- [x] Implement Window.loadimage(), clearimage(), drawimage() in wind.b
- [x] Add ctl commands (image, clearimage) in xfid.b
- [x] Update mkfile for imgload module
- [x] Build successfully

### Testing
Runtime results (PNG, interlaced PNG, PPM, async loading, cancellation) are
recorded under "Verified Working" in IMAGE-LOADING.md.

## Design

### Overview
Images replace body content entirely when displayed. The tag remains functional.
Supports every format `imgload` reads (see `module/imgload.m`).

### Data Structures

**Window adt additions (wind.m):**
```limbo
imagemode : int;              # 0 = text, 1 = image
bodyimage : ref Draw->Image;  # loaded image
imagepath : string;           # path to current image
imageoffset : Draw->Point;    # pan offset for large images
```

### 9P Interface

New file per window: `/mnt/xenith/<id>/image`
- Read: Returns "path width height\n" or empty string
- Write: Load image from path

New ctl commands:
- `image <path>` - Load and display image
- `clearimage` - Return to text mode

### Image Loading (imgload.b)

Uses existing Inferno infrastructure:
1. Try native Inferno format via `display.open(path)`
2. Detect format by magic bytes, then by extension (`format`)
3. PNG: pngload (subsampling large images), or RImagefile (READPNGPATH)
4. PPM/PGM: Custom parser (trivial)
5. Everything else: the format's RImagefile + Imageremap.remap()

### Rendering (wind.b)

`Window.drawimage()`:
- Fill body background
- Center small images
- Use imageoffset for panning large images
- Draw image to body area

`Window.reshape()` modification:
- If imagemode && bodyimage != nil, call drawimage()

## Usage

### Right-click to Open (Acme-style)
Just right-click (B3) on an image file path and it opens in a new window:
```
/path/to/photo.png    # Right-click to open
./images/logo.ppm     # Works with relative paths too
```

Supported extensions (from `appl/lib/imgload.b`): `.png`, `.jpg`, `.jpeg`, `.jpe`, `.gif`, `.webp`, `.avif`, `.svg`, `.xbm`, `.pic`, `.ppm`, `.pgm`, `.bit`

### Via 9P Interface
```sh
# Load via ctl
echo 'image /path/to/photo.png' > /mnt/xenith/1/ctl

# Load via image file
echo '/path/to/image.ppm' > /mnt/xenith/1/image

# Get info
cat /mnt/xenith/1/image
# Output: /path/to/photo.png 800 600

# Return to text
echo clearimage > /mnt/xenith/1/ctl
```

## Files

### Modified
- `appl/xenith/dat.m` - QWimage constant
- `appl/xenith/wind.m` - Image fields and methods
- `appl/xenith/wind.b` - Image method implementations
- `appl/xenith/fsys.b` - Add "image" to dirtabw
- `appl/xenith/xfid.b` - QWimage handlers, ctl commands
- `appl/xenith/look.b` - Auto-detect and open image files
- `appl/xenith/mkfile` - imgload.m added as a dependency

### New
- `appl/xenith/imgload.m` - Module interface
- `appl/xenith/imgload.b` - Image loader implementation

(Since moved to `module/imgload.m` and `appl/lib/imgload.b`, shared
with the browser, wm/view and lib/scene.)

## Build Notes

Use the native compiler with ROOT set:
```sh
PATH=/path/to/infernode/MacOSX/arm64/bin:$PATH ROOT=/path/to/infernode mk
```

Or from the project root:
```sh
PATH=$PWD/MacOSX/arm64/bin:$PATH ROOT=$PWD mk
```

### API Note
The image loader function is named `readimage()` (not `load()`) because
`load` is a reserved keyword in Limbo.
