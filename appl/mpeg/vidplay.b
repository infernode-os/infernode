implement VidPlay;
#
# VidPlay - MPEG-1 video pane with an optional shaped matte.
# Ported/modernized from inferno-2e appl/mpeg (MIT). Decodes MPEG-1 in pure
# Limbo and blits each frame into a WM window THROUGH a matte image, so the
# feed appears inside an arbitrary cutout (oval/rounded/full). Multiplex by
# launching one VidPlay per feed.
#
# usage: vidplay [-shape oval|rect] file.m1v
#
include "sys.m";    sys: Sys;
include "draw.m";   draw: Draw;
    Display, Image, Rect, Point: import draw;
include "wmclient.m"; wmclient: Wmclient;
    Window: import wmclient;
include "mpegio.m";

mio: Mpegio; decode: Mpegd; remap: Remap;
Mpegi: import mio;

VidPlay: module { init: fn(ctxt: ref Draw->Context, args: list of string); };

display: ref Display;
stderr: ref Sys->FD;

init(ctxt: ref Draw->Context, args: list of string)
{
    sys = load Sys Sys->PATH;
    draw = load Draw Draw->PATH;
    wmclient = load Wmclient Wmclient->PATH;
    mio = load Mpegio Mpegio->PATH;
    decode = load Mpegd Mpegd->PATH;
    remap = load Remap Remap->PATH24;
    stderr = sys->fildes(2);
    if(ctxt == nil){ sys->fprint(stderr, "vidplay: needs a window context\n"); return; }
    wmclient->init();
    display = ctxt.display;

    shape := "oval";
    args = tl args;
    while(args != nil && len hd args > 0 && (hd args)[0] == '-'){
        case hd args {
        "-shape" => args = tl args; if(args != nil) shape = hd args;
        }
        args = tl args;
    }
    if(args == nil){ sys->fprint(stderr, "usage: vidplay [-shape oval|rect] file\n"); return; }
    file := hd args;

    mio->init();
    fd := sys->open(file, Sys->OREAD);
    if(fd == nil){ sys->fprint(stderr, "vidplay: open %s: %r\n", file); return; }
    m := mio->prepare(fd, file);
    m.streaminit(Mpegio->VIDEO_STR0);
    p := m.getpicture(1);
    decode->init(m); remap->init(m);
    w := m.width; h := m.height;

    win := wmclient->window(ctxt, "VidPlay", Wmclient->Appl);
    win.reshape(Rect((0,0),(w+8,h+8)));
    win.startinput("kbd"::"ptr"::nil);
    win.onscreen(nil);

    vr := Rect((0,0),(w,h));
    frame := display.newimage(vr, draw->RGB24, 0, draw->Black);
    matte := mkmatte(shape, w, h);

    # centre the pane in the window's content image
    org := win.image.r.min;
    dst := Rect(org, org.add((w,h)));

    rate := 25; if(m.rate > 0 && m.rate < 120) rate = m.rate;
    delay := 1000/rate;

    {
        for(;;){
            f: ref Mpegio->YCbCr;
            case p.ptype {
            Mpegio->IPIC => f = decode->Idecode(p);
            Mpegio->PPIC => f = decode->Pdecode(p);
            Mpegio->BPIC => f = decode->Bdecode(p);
            }
            frame.writepixels(vr, remap->remap(f));
            win.image.draw(dst, frame, matte, vr.min);   # video THROUGH the matte
            win.image.flush(Draw->Flushnow);
            # drain control/resize without blocking the stream
            alt {
            c := <-win.ctl => win.wmctl(c);
            <-win.ctxt.ptr => ;
            * => ;
            }
            sys->sleep(delay);
            if((p = m.getpicture(1)) == nil) break;
        }
    } exception { * => ; }
    sys->fprint(stderr, "vidplay: end of stream\n");
}

# Build the matte: GREY8, 0 where hidden, 255 (opaque) where the feed shows.
mkmatte(shape: string, w, h: int): ref Image
{
    if(shape == "rect")
        return display.opaque;                 # full-frame, plain blit
    matte := display.newimage(Rect((0,0),(w,h)), draw->GREY8, 0, draw->Transparent);
    matte.fillellipse((w/2,h/2), w/2, h/2, display.opaque, (0,0));
    return matte;
}
