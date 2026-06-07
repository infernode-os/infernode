implement MpegTest;
include "sys.m";   sys: Sys;
include "draw.m";
include "mpegio.m";
mio: Mpegio; decode: Mpegd; remap: Remap;
Mpegi: import mio;
MpegTest: module { init: fn(nil: ref Draw->Context, args: list of string); };

writeppm(name: string, w, h: int, rgb: array of byte)
{
    fd := sys->create(name, Sys->OWRITE, 8r644);
    if(fd == nil){ sys->print("create %s failed: %r\n", name); return; }
    hdr := array of byte sys->sprint("P6\n%d %d\n255\n", w, h);
    sys->write(fd, hdr, len hdr);
    sys->write(fd, rgb, len rgb);
}

init(nil: ref Draw->Context, args: list of string)
{
    sys = load Sys Sys->PATH;
    mio = load Mpegio Mpegio->PATH;
    decode = load Mpegd Mpegd->PATH;
    remap = load Remap Remap->PATH24;
    if(mio==nil||decode==nil||remap==nil){ sys->print("load failed: %r\n"); return; }
    mio->init();
    args = tl args;
    file := hd args;
    fd := sys->open(file, Sys->OREAD);
    if(fd==nil){ sys->print("open %s: %r\n", file); return; }
    m := mio->prepare(fd, file);
    m.streaminit(Mpegio->VIDEO_STR0);
    p := m.getpicture(1);
    decode->init(m);
    remap->init(m);
    sys->print("stream: %dx%d  rate=%d\n", m.width, m.height, m.rate);
    n := 0;
    f: ref Mpegio->YCbCr;
    while(p != nil && n < 8){
        case p.ptype {
        Mpegio->IPIC => f = decode->Idecode(p);
        Mpegio->PPIC => f = decode->Pdecode(p);
        Mpegio->BPIC => f = decode->Bdecode(p);
        }
        rgb := remap->remap(f);
        nm := sys->sprint("/scratchrun/frame%02d.ppm", n);
        writeppm(nm, m.width, m.height, rgb);
        sys->print("frame %d type=%c bytes=%d -> %s\n", n, "0IPBD"[p.ptype], len rgb, nm);
        n++;
        p = m.getpicture(1);
    }
    sys->print("done, %d frames\n", n);
}
