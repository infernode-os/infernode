/*
 * virtio over MMIO: what the drivers in this directory share.
 * virtio.c has the explanation; this is the interface.
 */

typedef struct Vdev Vdev;
typedef struct Vq Vq;
typedef struct Vbuf Vbuf;
typedef struct Vqdesc Vqdesc;
typedef struct Vqavail Vqavail;
typedef struct Vqused Vqused;
typedef struct Vqusedelem Vqusedelem;

enum
{
	/* device ids, as the transport's DeviceID register reports them */
	Vidnet		= 1,
	Vidblk		= 2,
	Vidrng		= 4,
	Vidgpu		= 16,
	Vidinput	= 18,

	Vqmax		= 256,	/* the most descriptors this code will give a queue */
	Vdevqueues	= 4,	/* the most queues any driver here uses */
};

/* feature bits that are the transport's rather than any one device's */
#define Vfversion1	(1ULL<<32)	/* a modern device; mandatory on one */

/* the three shared structures, laid out as the specification fixes them */
struct Vqdesc
{
	u64int	addr;
	u32int	len;
	u16int	flags;
	u16int	next;
};

enum
{
	Vdnext		= 1<<0,	/* the chain continues at .next */
	Vdwrite		= 1<<1,	/* the DEVICE writes this buffer */
};

struct Vqavail
{
	u16int	flags;
	u16int	idx;
	u16int	ring[];
};

struct Vqusedelem
{
	u32int	id;		/* head of the chain that was used */
	u32int	len;		/* bytes the device wrote into it */
};

struct Vqused
{
	u16int	flags;
	u16int	idx;
	Vqusedelem ring[];
};

/* one piece of a request: where, how long, and who writes it */
struct Vbuf
{
	void	*p;
	ulong	len;
	int	write;		/* nonzero: the device writes here */
};

struct Vq
{
	Lock	l;
	Vdev	*dev;
	int	idx;		/* which of the device's queues */
	int	n;		/* descriptors */
	Vqdesc	*desc;
	Vqavail	*avail;
	Vqused	*used;
	int	free;		/* head of the free-descriptor chain, or -1 */
	int	nfree;
	u16int	lastused;	/* how far into used->ring we have read */
	void	*cookie[Vqmax];	/* per chain, by head: whatever the driver passed */
};

struct Vdev
{
	int	slot;		/* which transport: address and interrupt follow from it */
	uintptr	regs;
	int	irq;
	int	id;		/* Vidnet, Vidblk, ... */
	int	legacy;		/* a version-1 transport; see virtio.c */
	u64int	features;	/* what was negotiated */
	Vq	*q[Vdevqueues];
};

void	virtioscan(void);
Vdev*	virtiofind(int id, int nth);
int	virtiostart(Vdev*, u64int want);
Vq*	virtioqueue(Vdev*, int idx, int n);
void	virtioready(Vdev*);
void	virtiofail(Vdev*);
u32int	virtiointr(Vdev*);
void	virtiocfgread(Vdev*, int off, void *buf, int n);
void	virtiocfgwrite(Vdev*, int off, int v);

int	vqsubmit(Vq*, Vbuf*, int nbuf, void *cookie);
void	vqkick(Vq*);
int	vqcollect(Vq*, u32int *lenp, void **cookiep);
int	vqroom(Vq*);
