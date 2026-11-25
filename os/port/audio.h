#define	AUDIO_BITS_FLAG		0x00000001
#define	AUDIO_BUF_FLAG		0x00000002
#define	AUDIO_CHAN_FLAG		0x00000004
#define	AUDIO_COUNT_FLAG	0x00000008
#define	AUDIO_DEV_FLAG		0x00000010
#define	AUDIO_ENC_FLAG		0x00000020
#define	AUDIO_RATE_FLAG		0x00000040
#define	AUDIO_VOL_FLAG		0x00000080
#define	AUDIO_LEFT_FLAG		0x00000100
#define	AUDIO_RIGHT_FLAG	0x00000200
#define	AUDIO_IN_FLAG		0x00000400
#define	AUDIO_OUT_FLAG		0x00000800
#define	AUDIO_MOD_FLAG		0x10000000

#define	Audio_Min_Val		0
#define	Audio_Max_Val		100

#define 	Audio_No_Val		0
#define 	Audio_In_Val		1
#define 	Audio_Out_Val		2

#define	Audio_Max_Buf		32768
#define	Bits_Per_Byte		8

typedef struct Audio_d Audio_d;
struct Audio_d {
	ulong	flags;		/* bit flag for fields */
	ulong	bits;		/* bits per sample */
	ulong	buf;		/* buffer size */
	ulong	chan;		/* number of channels */
	ulong	dev;		/* device */
	ulong	enc;		/* encoding format */
	ulong	rate;		/* samples per second */
	ulong	left;		/* left channel gain */
	ulong	right;		/* right channel gain */
};

typedef struct Audio_t Audio_t;
struct Audio_t {
	Audio_d	in;		/* input device */
	Audio_d	out;		/* output device */
};

#define AUDIO_CMD_MAXNUM 32

void audio_info_init(Audio_t*);
int audioparse(char*, int n, Audio_t*);

enum
{
	Qdir = 0,		/* must start at 0 representing a directory */
	Qaudio,
	Qaudioctl,
	Qaudiostat
};

/*
 * One output, the board's half of it: devaudio.c serves its audio,
 * audioctl and audiostat. A board with more than one output (a 3B+'s
 * jack and HDMI) has more than one, and each is a device of its own:
 * #A is the first, #A1 the second (9front's arrangement, #1216).
 * Which one is /dev/audio is the profile's choice, not the kernel's.
 */
typedef struct Audioout Audioout;
struct Audioout
{
	char	*name;		/* "jack", "hdmi" */
	void	(*init)(void);
	void	(*open)(Chan*, int);
	long	(*read)(Chan*, void*, long, vlong);
	long	(*write)(Chan*, void*, long, vlong);
	long	(*ctl)(Chan*, void*, long, vlong);
	void	(*close)(Chan*);
	char*	(*status)(char*, char*);	/* audiostat's one line, into buf..e */
	Audio_t*	(*dev)(void);		/* what audioctl reports */
};

/* the board's: its nth output, or nil past the last */
Audioout*	audioout(int);

/* the values audio-tbls.h names, which a board's half uses too */
#define Audio_Mic_Val		0
#define Audio_Linein_Val	1
#define Audio_Speaker_Val	2
#define Audio_Headphone_Val	3
#define Audio_Lineout_Val	4
#define Audio_Pcm_Val		0
#define Audio_Ulaw_Val		1
#define Audio_Alaw_Val		2

typedef struct _svp_t {
	char*		s;	/* string */
	unsigned long	v;	/* value */
} svp_t;

/* string value pairs for default audio values */
extern svp_t audio_chan_tbl[];
extern svp_t audio_indev_tbl[];
extern svp_t audio_outdev_tbl[];
extern svp_t audio_enc_tbl[];
extern svp_t audio_rate_tbl[];
extern svp_t audio_val_tbl[];
extern svp_t audio_bits_tbl[];

extern Audio_d Default_Audio_Format;
extern int Default_Audio_Input, Default_Audio_Output;

