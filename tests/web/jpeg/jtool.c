/* jtool: make JPEG test vectors with libjpeg-turbo, and decode with its defaults.
 * jtool enc out.jpg W H cs samp quality mode restart optimize arith seed
 *   cs: rgb ycc gray cmyk ycck   (jpeg colour space; input is rgb/gray/cmyk to match)
 *   samp: e.g. 2x2,1x1,1x1  (per component h x v)
 *   mode: 0 baseline/sequential interleaved, 1 simple progression, 2 sequential one scan per component,
 *         3 progressive spectral selection only (no successive approximation)
 *   restart: 0 none, Nr = N MCU rows, Nb = N blocks(MCUs)
 * jtool dec in.jpg out  -> writes P5/P6, or P7 CMYK raw ("P7\nW H 4\n" + bytes)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <jpeglib.h>

static unsigned seedv;
static unsigned rnd(void){ seedv = seedv*1103515245u + 12345u; return (seedv>>16)&0x7fff; }

static int enc(int argc, char **argv){
	const char *out = argv[2]; int W = atoi(argv[3]), H = atoi(argv[4]);
	const char *cs = argv[5]; const char *samp = argv[6]; int q = atoi(argv[7]);
	int mode = atoi(argv[8]); const char *rs = argv[9]; int opt = atoi(argv[10]); int arith = atoi(argv[11]);
	seedv = atoi(argv[12]);
	struct jpeg_compress_struct c; struct jpeg_error_mgr e;
	c.err = jpeg_std_error(&e); jpeg_create_compress(&c);
	FILE *f = fopen(out, "wb"); jpeg_stdio_dest(&c, f);
	c.image_width = W; c.image_height = H;
	int nc; J_COLOR_SPACE in, jcs;
	if(!strcmp(cs,"gray")){ nc=1; in=JCS_GRAYSCALE; jcs=JCS_GRAYSCALE; }
	else if(!strcmp(cs,"rgb")){ nc=3; in=JCS_RGB; jcs=JCS_RGB; }
	else if(!strcmp(cs,"ycc")){ nc=3; in=JCS_RGB; jcs=JCS_YCbCr; }
	else if(!strcmp(cs,"cmyk")){ nc=4; in=JCS_CMYK; jcs=JCS_CMYK; }
	else { nc=4; in=JCS_CMYK; jcs=JCS_YCCK; }
	c.input_components = nc; c.in_color_space = in;
	jpeg_set_defaults(&c); jpeg_set_colorspace(&c, jcs); jpeg_set_quality(&c, q, TRUE);
	const char *p = samp;
	for(int i=0;i<nc && *p;i++){ int h=0,v=0; sscanf(p,"%dx%d",&h,&v); c.comp_info[i].h_samp_factor=h; c.comp_info[i].v_samp_factor=v; p=strchr(p,','); if(!p) break; p++; }
	c.optimize_coding = opt; c.arith_code = arith;
	int rn = atoi(rs); if(rn){ if(strchr(rs,'r')) c.restart_in_rows = rn; else c.restart_interval = rn; }
	static jpeg_scan_info sc[16];
	if(mode==1) jpeg_simple_progression(&c);
	else if(mode==2){ for(int i=0;i<nc;i++){ sc[i].comps_in_scan=1; sc[i].component_index[0]=i; sc[i].Ss=0; sc[i].Se=63; sc[i].Ah=0; sc[i].Al=0; } c.scan_info=sc; c.num_scans=nc; }
	else if(mode==3){ int k=0;
		sc[k].comps_in_scan=nc; for(int i=0;i<nc;i++) sc[k].component_index[i]=i; sc[k].Ss=0; sc[k].Se=0; sc[k].Ah=0; sc[k].Al=0; k++;
		for(int i=0;i<nc;i++){ sc[k].comps_in_scan=1; sc[k].component_index[0]=i; sc[k].Ss=1; sc[k].Se=9; sc[k].Ah=0; sc[k].Al=0; k++;
			sc[k].comps_in_scan=1; sc[k].component_index[0]=i; sc[k].Ss=10; sc[k].Se=63; sc[k].Ah=0; sc[k].Al=0; k++; }
		c.scan_info=sc; c.num_scans=k; }
	jpeg_start_compress(&c, TRUE);
	unsigned char *row = malloc(W*nc);
	for(int y=0;y<H;y++){
		for(int x=0;x<W;x++) for(int k=0;k<nc;k++){
			int v = (k==0? x*255/(W>1?W-1:1) : k==1? y*255/(H>1?H-1:1) : k==2? ((x/7+y/5)&1)*200+20 : (x*y)%256);
			v = (v*3 + ((x/9)%3==0? 255:0) + (int)(rnd()%64)) / 4 + (((x-W/2)*(x-W/2)+(y-H/2)*(y-H/2)) < W*H/16 ? 40 : 0);
			if(v>255) v=255;
			row[x*nc+k] = v;
		}
		JSAMPROW r = row; jpeg_write_scanlines(&c, &r, 1);
	}
	jpeg_finish_compress(&c); fclose(f); return 0;
}

static int dec(int argc, char **argv){
	struct jpeg_decompress_struct d; struct jpeg_error_mgr e;
	d.err = jpeg_std_error(&e); jpeg_create_decompress(&d);
	FILE *f = fopen(argv[2], "rb"); jpeg_stdio_src(&d, f);
	jpeg_read_header(&d, TRUE); jpeg_start_decompress(&d);
	int nc = d.output_components; FILE *o = fopen(argv[3], "wb");
	if(nc==1) fprintf(o,"P5\n%d %d\n255\n",d.output_width,d.output_height);
	else if(nc==3) fprintf(o,"P6\n%d %d\n255\n",d.output_width,d.output_height);
	else fprintf(o,"P7\n%d %d 4\n",d.output_width,d.output_height);
	unsigned char *row = malloc(d.output_width*nc);
	while(d.output_scanline < d.output_height){ JSAMPROW r=row; jpeg_read_scanlines(&d,&r,1); fwrite(row,1,d.output_width*nc,o); }
	fprintf(stderr, "%s: %dx%d comps %d cs %d out %d prog %d adobe %d\n", argv[2], d.image_width, d.image_height, d.num_components, d.jpeg_color_space, d.out_color_space, d.progressive_mode, d.saw_Adobe_marker);
	jpeg_finish_decompress(&d); fclose(o); return 0;
}

int main(int argc, char **argv){
	if(argc>2 && !strcmp(argv[1],"enc")) return enc(argc, argv);
	if(argc>3 && !strcmp(argv[1],"dec")) return dec(argc, argv);
	fprintf(stderr,"usage\n"); return 1;
}
