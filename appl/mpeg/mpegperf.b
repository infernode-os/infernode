implement MpegPerf;
include "sys.m";   sys: Sys;
include "draw.m";
include "mpegio.m";
mio: Mpegio; decode: Mpegd; remap: Remap;
Mpegi: import mio;
MpegPerf: module { init: fn(nil: ref Draw->Context, args: list of string); };
init(nil: ref Draw->Context, args: list of string)
{
    sys = load Sys Sys->PATH;
    mio = load Mpegio Mpegio->PATH;
    decode = load Mpegd Mpegd->PATH;
    remap = load Remap Remap->PATH24;
    mio->init();
    file := hd tl args;
    cap := int hd tl tl args;
    fd := sys->open(file, Sys->OREAD);
    m := mio->prepare(fd, file);
    m.streaminit(Mpegio->VIDEO_STR0);
    p := m.getpicture(1);
    decode->init(m); remap->init(m);
    nf := 0; t0 := sys->millisec();
    { while(p != nil && nf < cap){
        f: ref Mpegio->YCbCr;
        case p.ptype {
        Mpegio->IPIC => f = decode->Idecode(p);
        Mpegio->PPIC => f = decode->Pdecode(p);
        Mpegio->BPIC => f = decode->Bdecode(p);
        }
        remap->remap(f); nf++;
        p = m.getpicture(1);
    } } exception { * => ; }
    dt := sys->millisec() - t0;
    fps := 0; if(dt>0) fps = nf*1000/dt;
    rfd := sys->create("/scratchrun/result.txt", Sys->OWRITE, 8r644);
    b := array of byte sys->sprint("%d frames %dx%d in %d ms = %d fps\n", nf, m.width, m.height, dt, fps);
    sys->write(rfd, b, len b);
}
