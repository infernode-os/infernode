implement Renderer;

#
# Image renderer - wraps imgload (module/imgload.m) to conform to the
# Renderer interface.  The formats are imgload's.
#
# This is the reference renderer implementation: it delegates all
# actual decoding to imgload and adapts the progress/result types.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	drawm: Draw;
	Display, Image, Rect, Point: import drawm;

include "renderer.m";

include "bufio.m";
include "imagefile.m";
include "imgload.m";

imgload: Imgload;
display: ref Display;

init(d: ref Draw->Display)
{
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;
	display = d;

	imgload = load Imgload Imgload->PATH;
	if(imgload != nil)
		imgload->init(d);
}

info(): ref RenderInfo
{
	return ref RenderInfo(
		"Image",
		exts(),
		0  # Images have no text content
	);
}

exts(): string
{
	if(imgload == nil)
		return nil;
	return imgload->extensions();
}

canrender(data: array of byte, hint: string): int
{
	if(data == nil || len data < 4 || imgload == nil)
		return 0;
	n := len data;
	if(n > 512)
		n = 512;
	# A binary signature is proof; the text formats (SVG, PPM, XBM,
	# PIC) begin like other text, so they also need the name to agree.
	case imgload->format(data[0:n], nil) {
	"png" or "jpeg" or "gif" or "webp" or "avif" or "bit" =>
		return 100;
	}
	if(imgload->isimage(hint) && imgload->format(data[0:n], hint) != nil)
		return 90;
	return 0;
}

render(data: array of byte, hint: string,
       width, height: int,
       progress: chan of ref RenderProgress): (ref Draw->Image, string, string)
{
	if(imgload == nil)
		return (nil, nil, "image loader not available");

	# Create an adapter channel for imgload's progress format
	imgprogress := chan[4] of ref Imgload->ImgProgress;

	# Spawn a forwarder that converts ImgProgress -> RenderProgress
	spawn progressadapter(imgprogress, progress);

	# Delegate to imgload
	(im, err) := imgload->readimagedataprogressive(data, hint, imgprogress);

	# Signal end of progress
	imgprogress <-= nil;

	# Scale to requested width (for zoom support)
	if(im != nil && width > 0 && im.r.dx() != width)
		im = scaleimage(im, width);

	# No text content for images
	return (im, nil, err);
}

commands(): list of ref Command
{
	return
		ref Command("Zoom+", "b3", "+", "2") ::
		ref Command("Zoom-", "b3", "-", "2") ::
		ref Command("Fit", "b3", "f", nil) ::
		ref Command("1:1", "b3", "1", nil) ::
		ref Command("Grab", "b3", "g", nil) ::
		ref Command("Rotate", "b3", "r", "90") ::
		nil;
}

command(cmd: string, arg: string,
        data: array of byte, hint: string,
        width, height: int): (ref Draw->Image, string)
{
	# Image commands will be implemented as the renderer gains state.
	# For now, re-render from source data is the pattern.
	case cmd {
	"Zoom+" or "Zoom-" or "Fit" or "1:1" or "Grab" or "Rotate" =>
		return (nil, "not yet implemented: " + cmd);
	* =>
		return (nil, "unknown command: " + cmd);
	}
}

# Nearest-neighbor scale of a decoded image to the given output width.
# Preserves aspect ratio.  Returns the original image on any error.
scaleimage(im: ref Image, width: int): ref Image
{
	srcw := im.r.dx();
	srch := im.r.dy();
	if(srcw <= 0 || srch <= 0)
		return im;
	dstw := width;
	dsth := srch * dstw / srcw;
	if(dsth <= 0)
		dsth = 1;

	bpp := im.depth / 8;
	if(bpp < 1)
		return im;	# sub-byte pixel format — skip scaling

	# Read all source pixels at once
	srcbuf := array[srcw * srch * bpp] of byte;
	n := im.readpixels(im.r, srcbuf);
	if(n <= 0)
		return im;

	# Allocate destination image with same channel format
	dst := display.newimage(Rect((0, 0), (dstw, dsth)), im.chans, 0, drawm->White);
	if(dst == nil)
		return im;

	# Nearest-neighbor scale, written one row at a time
	rowbuf := array[dstw * bpp] of byte;
	for(dy := 0; dy < dsth; dy++) {
		sy := dy * srch / dsth;
		srcrowoff := sy * srcw * bpp;
		for(dx := 0; dx < dstw; dx++) {
			sx := dx * srcw / dstw;
			srcoff := srcrowoff + sx * bpp;
			dstoff := dx * bpp;
			for(b := 0; b < bpp; b++)
				rowbuf[dstoff + b] = srcbuf[srcoff + b];
		}
		dst.writepixels(Rect((0, dy), (dstw, dy + 1)), rowbuf);
	}
	return dst;
}

# Convert imgload progress updates to renderer progress updates
progressadapter(src: chan of ref Imgload->ImgProgress,
                dst: chan of ref RenderProgress)
{
	for(;;){
		p := <-src;
		if(p == nil)
			return;

		rp := ref RenderProgress(p.image, p.rowsdone, p.rowstotal);
		# Non-blocking send - drop if consumer is slow
		alt {
			dst <-= rp => ;
			* => ;
		}
	}
}
