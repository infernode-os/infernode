/*
 * tests/host/vmdisplay_check.c -- the host half of the display boot test.
 *
 * The guest (os/9vm/display.c) draws two deterministic frames into 9vm's
 * shared display and waits for one input record.  This opens the same
 * POSIX shared memory, waits for the second frame, verifies both slots
 * pixel by pixel against the agreed pattern, and sends the input that
 * lets the guest finish.
 *
 * Started before 9vm, so it retries until the region appears.  Exit 0 on
 * success, 1 on a bad frame, 2 on a timeout.  Not installed.
 */

#define _POSIX_C_SOURCE 200809L

#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

enum
{
	Width		= 1024,
	Height		= 768,
	Slots		= 2,
	Events		= 256,
	EventBytes	= 96,
	FrameBytes	= Width * Height * 4,
	Free		= 0,
	Ready		= 2,
};

#define MAGIC	0x56444c39U
#define VERSION	1

struct vmdisplay
{
	uint32_t	magic;
	uint32_t	version;
	uint32_t	width;
	uint32_t	height;
	uint64_t	latest_serial;
	uint32_t	latest_slot;
	uint32_t	state[Slots];
	uint32_t	written[Slots];
	uint64_t	slot_serial[Slots];
	uint32_t	input_head;
	uint32_t	input_tail;
	char		input[Events][EventBytes];
	uint32_t	pixels[Slots][Width * Height];
	uint32_t	scale;
};

static void
pause_ms(int ms)
{
	struct timespec t;

	t.tv_sec = ms / 1000;
	t.tv_nsec = (ms % 1000) * 1000000L;
	nanosleep(&t, NULL);
}

static struct vmdisplay*
openwait(const char *name, int ms)
{
	struct stat st;
	struct vmdisplay *d;
	int fd, elapsed;
	void *p;

	for(elapsed = 0; elapsed <= ms; elapsed += 50){
		fd = shm_open(name, O_RDWR, 0);
		if(fd >= 0){
			if(fstat(fd, &st) == 0 &&
			   st.st_size >= (off_t)sizeof(struct vmdisplay)){
				p = mmap(NULL, sizeof(struct vmdisplay),
					PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
				close(fd);
				if(p != MAP_FAILED){
					d = p;
					return d;
				}
			}else
				close(fd);
		}
		pause_ms(50);
	}
	return NULL;
}

/* the guest's frame: red x, green y, blue x^y; frame two has a marker */
static uint32_t
testpixel(int x, int y, int frame)
{
	uint32_t p;

	if(frame == 2 && x < 64 && y < 64)
		return 0x00FF00FF;
	p = (uint32_t)(x * 255 / (Width - 1)) << 16;
	p |= (uint32_t)(y * 255 / (Height - 1)) << 8;
	p |= (uint32_t)((x ^ y) & 0xFF);
	return p;
}

static int
checkframe(struct vmdisplay *d, int slot)
{
	uint32_t want;
	int x, y;

	for(y = 0; y < Height; y++)
		for(x = 0; x < Width; x++){
			want = testpixel(x, y, slot + 1);
			if(d->pixels[slot][y*Width + x] != want){
				fprintf(stderr,
					"vmdisplay: slot %d pixel %d,%d is %#x, want %#x\n",
					slot, x, y,
					d->pixels[slot][y*Width + x], want);
				return -1;
			}
		}
	return 0;
}

int
main(int argc, char **argv)
{
	struct vmdisplay *d;
	uint64_t serial;
	uint32_t head, tail;
	int elapsed, i;

	if(argc != 2){
		fprintf(stderr, "usage: vmdisplay_check /shm-name\n");
		return 2;
	}
	d = openwait(argv[1], 5000);
	if(d == NULL){
		fprintf(stderr, "vmdisplay: no shared display at %s\n", argv[1]);
		return 2;
	}

	serial = 0;
	for(elapsed = 0; elapsed <= 10000; elapsed += 10){
		serial = __atomic_load_n(&d->latest_serial, __ATOMIC_ACQUIRE);
		if(serial >= 2)
			break;
		pause_ms(10);
	}
	if(serial < 2){
		fprintf(stderr, "vmdisplay: no second frame (serial %llu)\n",
			(unsigned long long)serial);
		return 2;
	}
	if(__atomic_load_n(&d->magic, __ATOMIC_ACQUIRE) != MAGIC ||
	   d->version != VERSION || d->width != Width || d->height != Height){
		fprintf(stderr, "vmdisplay: bad header\n");
		return 1;
	}
	if(d->scale != 100){
		fprintf(stderr, "vmdisplay: scale %u, want 100\n", d->scale);
		return 1;
	}
	if(d->latest_slot != 1){
		fprintf(stderr, "vmdisplay: latest slot %u, want 1\n", d->latest_slot);
		return 1;
	}
	for(i = 0; i < Slots; i++){
		if(d->state[i] != Ready){
			fprintf(stderr, "vmdisplay: slot %d state %u, want ready\n",
				i, d->state[i]);
			return 1;
		}
		if(d->slot_serial[i] != (uint64_t)i + 1){
			fprintf(stderr, "vmdisplay: slot %d serial %llu\n", i,
				(unsigned long long)d->slot_serial[i]);
			return 1;
		}
		if(d->written[i] != FrameBytes){
			fprintf(stderr, "vmdisplay: slot %d written %u\n", i,
				d->written[i]);
			return 1;
		}
		if(checkframe(d, i) < 0)
			return 1;
	}

	/* the input that ends the guest's wait */
	head = __atomic_load_n(&d->input_head, __ATOMIC_RELAXED);
	tail = __atomic_load_n(&d->input_tail, __ATOMIC_ACQUIRE);
	if(head - tail >= Events){
		fprintf(stderr, "vmdisplay: input ring full\n");
		return 1;
	}
	strcpy(d->input[head % Events], "key 113 0\n");
	__atomic_store_n(&d->input_head, head + 1, __ATOMIC_RELEASE);

	printf("vmdisplay: 2 frames verified, input sent\n");
	return 0;
}
