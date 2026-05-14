/*
 * Fuzz harness for 9P/Styx message parsing and framing.
 *
 * This targets the boundary exercised by emu/port/exportfs.c and
 * emu/port/devmnt.c: length-prefixed 9P messages, convM2S/convS2M decoding,
 * and the special Rread framing path used by mount-side reply handling.
 */

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "lib9.h"
#include "fcall.h"

enum {
	Min9P = BIT32SZ + BIT8SZ + BIT16SZ,
	MaxMsg = 128 * 1024,
};

static void
fuzz_roundtrip(const uint8_t *data, size_t size)
{
	Fcall in, out;
	uint encsz;
	uchar *encbuf, *decbuf;

	if(size < Min9P || size > MaxMsg)
		return;

	decbuf = malloc(size);
	if(decbuf == nil)
		return;
	memmove(decbuf, data, size);

	memset(&in, 0, sizeof in);
	if(convM2S(decbuf, size, &in) != size){
		free(decbuf);
		return;
	}

	encsz = sizeS2M(&in);
	if(encsz == 0 || encsz > MaxMsg){
		free(decbuf);
		return;
	}

	encbuf = malloc(encsz);
	if(encbuf == nil){
		free(decbuf);
		return;
	}
	if(convS2M(&in, encbuf, encsz) != encsz){
		free(encbuf);
		free(decbuf);
		return;
	}

	memset(&out, 0, sizeof out);
	convM2S(encbuf, encsz, &out);

	if(encsz > Min9P){
		memset(&out, 0, sizeof out);
		convM2S(encbuf, encsz - 1, &out);
	}

	free(encbuf);
	free(decbuf);
}

static void
fuzz_reply_framing(const uint8_t *data, size_t size)
{
	uchar *msg;
	u32int len, msize;
	int hlen;
	Fcall reply;

	if(size < Min9P)
		return;

	msize = GBIT32(data);
	if(msize < Min9P)
		msize = Min9P;
	if(msize > MaxMsg)
		msize = MaxMsg;

	len = GBIT32(data);
	if(len < Min9P || len > size || len > msize)
		return;

	msg = malloc(len);
	if(msg == nil)
		return;
	memmove(msg, data, len);

	switch(msg[BIT32SZ]){
	case Rread:
		hlen = BIT32SZ + BIT8SZ + BIT16SZ + BIT32SZ;
		break;
	default:
		hlen = len;
		break;
	}
	if(hlen > len){
		free(msg);
		return;
	}

	memset(&reply, 0, sizeof reply);
	convM2S(msg, len, &reply);

	free(msg);
}

static void
fuzz_stream(const uint8_t *data, size_t size)
{
	size_t off;
	u32int len;
	int i;

	off = 0;
	for(i = 0; i < 32 && off + BIT32SZ <= size; i++){
		len = GBIT32(data + off);
		if(len < Min9P){
			off++;
			continue;
		}
		if(len > size - off)
			break;
		fuzz_roundtrip(data + off, len);
		fuzz_reply_framing(data + off, len);
		off += len;
	}
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	fuzz_stream(data, size);
	fuzz_roundtrip(data, size);
	fuzz_reply_framing(data, size);
	return 0;
}
