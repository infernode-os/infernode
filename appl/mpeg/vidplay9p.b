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
# What is drawn over the frames is the feed's layer/ directory as this
# name space has it (#1095, layers(2)): each file a layer of records,
# stacked in the union's order by bind -a and bind -b, taken off by
# unmount, while it plays:
#
#   bind -a /mnt/vision/1/layer /mnt/video/0/layer
#
# Frame N is the Nth read from the start, as vid9p numbers them. A feed
# whose status has no playhead (pos=), as camsrv(4)'s camera, names no
# frames: on it only frame=* records are drawn.
#
# usage: vidplay9p [-shape oval|rect] /mnt/video/0
#
include "sys.m";    sys: Sys;
include "draw.m";   draw: Draw;
    Display, Font, Image, Rect, Point: import draw;
include "wmclient.m"; wmclient: Wmclient;
    Window: import wmclient;
include "mpegio.m";
    mio: Mpegio;
    Mpegi, YCbCr: import mio;

remap: Remap;
include "layers.m";
    layers: Layers;
    Stack: import layers;

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
    layers = load Layers Layers->PATH;
    if(layers == nil){
        sys->fprint(stderr, "vidplay9p: cannot load %s: %r\n", Layers->PATH);
        return;
    }
    if((le := layers->init()) != nil){
        sys->fprint(stderr, "vidplay9p: %s\n", le);
        return;
    }
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

    numbered := hasplayhead(mnt + "/status");
    stack := Stack.watch(mnt + "/layer");
    font := Font.open(display, "*default*");
    (accent, colours) := layers->themed(display);

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

    # frames keep to a deadline, one every delay ms, whatever the drawing
    # took (a live feed also paces itself: its reads wait for frames)
    next := sys->millisec();
    for(n := 0;; n++){
        if(!readfull(ffd, buf))
            break;                          # EOF / short read = end of stream
        p := ref YCbCr(buf[0:wh], buf[wh:wh+csz], buf[wh+csz:wh+2*csz]);
        frame.writepixels(vr, remap->remap(p));
        win.image.draw(dst, frame, matte, vr.min);
        f := -1;                            # a feed naming no frames: frame=* alone
        if(numbered)
            f = n;
        layers->draw(stack.due(f), win.image, dst, w, h, font, accent, colours);
        win.image.flush(Draw->Flushnow);
        alt {
        c := <-win.ctl => win.wmctl(c);
        <-win.ctxt.ptr => ;
        * => ;
        }
        next += delay;
        d := next - sys->millisec();
        if(d > 0)
            sys->sleep(d);
        else
            next = sys->millisec();         # behind: go on without bursting
    }
    stack.stop();
    sys->fprint(stderr, "vidplay9p: end of stream\n");
}

# whether the feed's status has a playhead (pos=), as vid9p's does:
# such a feed's frames are numbered by their place in the frame file
hasplayhead(path: string): int
{
    fd := sys->open(path, Sys->OREAD);
    if(fd == nil)
        return 0;
    b := array[512] of byte;
    n := sys->read(fd, b, len b);
    if(n <= 0)
        return 0;
    (nil, toks) := sys->tokenize(string b[0:n], " \t\n");
    for(; toks != nil; toks = tl toks)
        if(len hd toks > 4 && (hd toks)[0:4] == "pos=")
            return 1;
    return 0;
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
