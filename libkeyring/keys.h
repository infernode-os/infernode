typedef struct SigAlg SigAlg;
typedef struct SigAlgVec SigAlgVec;
typedef struct SK SK;
typedef struct PK PK;
typedef struct Certificate Certificate;
typedef struct XDigestState XDigestState;
typedef struct XAESstate XAESstate;
typedef struct XRC4state XRC4state;

enum
{
	Maxbuf=	49152,	/* 48KB for SLH-DSA-256s base64 signatures */
	MaxBigBytes = 1024
};

/* generic certificate */
struct Certificate
{
	Keyring_Certificate x;
	void		*signa;	/* actual signature */
	SigAlgVec	*vec;	/* the algorithm signa is for: see SK */
};

/* generic public key */
struct PK
{
	Keyring_PK	x;
	void		*key;	/* key and system parameters */
	SigAlgVec	*vec;	/* the algorithm key is for: see SK */
};

/* digest state */
struct XDigestState
{
	Keyring_DigestState	x;
	DigestState	state;
};

/* AES state */
struct XAESstate
{
	Keyring_AESstate	x;
	AESstate	state;
};

/* AES-GCM state */
typedef struct XAESGCMstate XAESGCMstate;
struct XAESGCMstate
{
	Keyring_AESGCMstate	x;
	AESGCMstate	state;
};

/* ChaCha state */
typedef struct XChaChastate XChaChastate;
struct XChaChastate
{
	Keyring_ChaChastate	x;
	ChaChastate	state;
};

/* EC point */
typedef struct XECpoint XECpoint;
struct XECpoint
{
	Keyring_ECpoint	x;
	ECpoint	point;
};

/* RC4 state */
struct XRC4state
{
	Keyring_RC4state	x;
	RC4state	state;
};

/* generic secret key */
struct SK
{
	Keyring_SK	x;
	void		*key;	/* key and system parameters */
	/*
	 * The algorithm it was made by, for freeing it. Not x.sa's vec: a
	 * sweep frees an SK and its SigAlg together, in either order, and
	 * the SigAlg's may be gone already (checkSigAlg then raised
	 * "bad signature algorithm" in the collector, and emu faulted in
	 * handler()).
	 */
	SigAlgVec	*vec;
};

struct SigAlgVec {
	char	*name;

	char**	skattr;
	char**	pkattr;
	char**	sigattr;

	void*	(*str2sk)(char*, char**);
	void*	(*str2pk)(char*, char**);
	void*	(*str2sig)(char*, char**);

	int	(*sk2str)(void*, char*, int);
	int	(*pk2str)(void*, char*, int);
	int	(*sig2str)(void*, char*, int);

	void*	(*sk2pk)(void*);

	void*	(*gensk)(int);
	void*	(*genskfrompk)(void*);
	void*	(*sign)(mpint*, void*);
	int	(*verify)(mpint*, void*, void*);
	/*
	 * For an algorithm that signs bytes (Ed25519, ML-DSA, SLH-DSA),
	 * the digest as it is, at its full length; nil for one that signs
	 * a number (RSA, DSA, ElGamal), to which a digest is that number
	 * and its leading zero bytes are no part of it.  The byte signers
	 * used to be handed the number's bytes too (mptobe), so a digest
	 * beginning 00 was signed as 31 bytes of a 32-byte hash.
	 */
	void*	(*signb)(uchar*, int, void*);
	int	(*verifyb)(uchar*, int, void*, void*);

	void	(*skfree)(void*);
	void	(*pkfree)(void*);
	void	(*sigfree)(void*);
};

struct SigAlg
{
	Keyring_SigAlg	x;
	SigAlgVec	*vec;
};

int	bigtobase64(mpint* b, char *buf, int blen);
mpint*	base64tobig(char *str, char **strp);
SigAlgVec*	findsigalg(char*);
//Keyring_IPint*	newIPint(mpint*);
void*	newIPint(mpint*);
