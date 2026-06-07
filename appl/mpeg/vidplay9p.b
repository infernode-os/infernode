implement VidPlay9p;
#
# VidPlay9p - render a video feed served by vid9p over 9P (INFR-268).
#
# Sibling of vidplay.b, but instead of decoding MPEG-1 in-VM it reads decoded
# I420 frames from a mounted /mnt/video/<id> (see vid9p.b / docs/H264-9P-BRIDGE.md):
#   fmt   -> "<w> <h> i420 <fps>"
#   frame -> the I420 stream; each w*h*3/2 bytes is one frame.
# Frames are wrapped as Mpegio->YCbCr and pushed through the SAME proven
# remap24 (YCbCr->RGB24) + masked-pane draw path the MPEG player uses, so there
# is no new rendering code. Multiplex by launching one VidPlay9p per feed.
#
# usage: vidplay9p [-shape oval|rect] /mnt/video/0
#
include "sys.m";    sys: Sys;
include "draw.m";   draw: Draw;
    Display, Image, Rect, Point: import draw;
include "wmclient.m"; wmclient: Wmclient;
    Window: import wmclient;
include "mpegio.m";
    mio: Mpegio;
    Mpegi, YCbCr: import mio;

remap: Remap;

VidPlay9p: module { init: fn(ctxt: ref Draw->Context, args: list of string); };

display: ref Display;
stderr: ref Sys->FD;

init(ctxt: ref Draw->Context, args: list of string)
{
    sys = load Sys Sys->PATH;
    draw = load Draw Draw->PATH;
    wmclient = load Wmclient Wmclient->PATH;
    mio = load Mpegio Mpegio->PATH;
    remap = load Remap Remap->PATH24;
    stderr = sys->fildes(2);
    if(ctxt == nil){ sys->fprint(stderr, "vidplay9p: needs a window context\n"); return; }
    wmclient->init();
    display = ctxt.display;

    shape := "rect";
    args = tl args;
    while(args != nil && len hd args > 0 && (hd args)[0] == '-'){
        case hd args {
        "-shape" => args = tl args; if(args != nil) shape = hd args;
        }
        args = tl args;
    }
    mnt := "/mnt/video/0";
    if(args != nil) mnt = hd args;

    (w, h, rate) := readfmt(mnt + "/fmt");
    if(w <= 0 || h <= 0){ sys->fprint(stderr, "vidplay9p: bad/empty fmt at %s\n", mnt); return; }

    ffd := sys->open(mnt + "/frame", Sys->OREAD);
    if(ffd == nil){ sys->fprint(stderr, "vidplay9p: open %s/frame: %r\n", mnt); return; }

    # minimal Mpegi just to size the converter; remap only reads width/height
    m := ref Mpegi;
    m.width = w; m.height = h;
    mio->init();
    remap->init(m);

    win := wmclient->window(ctxt, "VidPlay9p", Wmclient->Appl);
    win.reshape(Rect((0,0),(w+8,h+8)));
    win.startinput("kbd"::"ptr"::nil);
    win.onscreen(nil);

    vr := Rect((0,0),(w,h));
    frame := display.newimage(vr, draw->RGB24, 0, draw->Black);
    matte := mkmatte(shape, w, h);
    org := win.image.r.min;
    dst := Rect(org, org.add((w,h)));

    if(rate <= 0 || rate > 120) rate = 25;
    delay := 1000/rate;

    wh := w*h;
    cw := w/2; ch := h/2; csz := cw*ch;
    framesize := wh + 2*csz;
    buf := array[framesize] of byte;

    for(;;){
        if(!readfull(ffd, buf))
            break;                          # EOF / short read = end of stream
        p := ref YCbCr(buf[0:wh], buf[wh:wh+csz], buf[wh+csz:wh+2*csz]);
        frame.writepixels(vr, remap->remap(p));
        win.image.draw(dst, frame, matte, vr.min);
        win.image.flush(Draw->Flushnow);
        alt {
        c := <-win.ctl => win.wmctl(c);
        <-win.ctxt.ptr => ;
        * => ;
        }
        sys->sleep(delay);
    }
    sys->fprint(stderr, "vidplay9p: end of stream\n");
}

# read "<w> <h> i420 <fps>" from the fmt file
readfmt(path: string): (int, int, int)
{
    fd := sys->open(path, Sys->OREAD);
    if(fd == nil)
        return (0, 0, 0);
    b := array[256] of byte;
    n := sys->read(fd, b, len b);
    if(n <= 0)
        return (0, 0, 0);
    (nt, toks) := sys->tokenize(string b[0:n], " \t\n");
    if(nt < 4)
        return (0, 0, 0);
    w := int hd toks; toks = tl toks;
    h := int hd toks; toks = tl toks;
    # toks now "i420"; skip it
    toks = tl toks;
    rate := int hd toks;
    return (w, h, rate);
}

readfull(fd: ref Sys->FD, buf: array of byte): int
{
    got := 0;
    while(got < len buf){
        n := sys->read(fd, buf[got:], len buf - got);
        if(n <= 0)
            return 0;
        got += n;
    }
    return 1;
}

# GREY8 matte: 0 hidden, 255 visible. rect -> plain full-frame blit.
mkmatte(shape: string, w, h: int): ref Image
{
    if(shape == "rect")
        return display.opaque;
    matte := display.newimage(Rect((0,0),(w,h)), draw->GREY8, 0, draw->Transparent);
    matte.fillellipse((w/2,h/2), w/2, h/2, display.opaque, (0,0));
    return matte;
}
