/*
 * fido2bridge.c — host-side libfido2 implementation for the InferNode #F
 * (2fa) device. Shared across all host platforms (macOS, Linux, Windows): each
 * platform's mkfile-gui-sdl3 / build script defines -DHAVE_FIDO2 and links
 * libfido2 when it is present (see the FIDO2_CFLAGS / FIDO2_LIBS wiring there).
 * Includes ONLY libfido2 + libc headers — no Inferno headers — to avoid name
 * clashes, so this single source compiles unchanged on every host.
 *
 * Refactored from tools/2fa-poc/yk-hmac-secret.c (the validated Phase 0 PoC).
 * When libfido2 is absent at build time (-DHAVE_FIDO2 unset), the entry points
 * compile as stubs so the emu still builds without /dev/2fa support.
 */
#include "fido2bridge.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef HAVE_FIDO2
#include <fido.h>

#define RP_ID   "infernode.local"
#define RP_NAME "InferNode secstore"

/* Fixed client-data hash; irrelevant to the hmac-secret output. */
static unsigned char CDH[32] = {
    0x9a,0x1c,0x00,0x5e,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xaa,0xbb,0xcc,
    0xde,0xad,0xbe,0xef,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b,0x0c
};

static int initialised = 0;
static void ensure_init(void) { if(!initialised){ fido_init(0); initialised = 1; } }

static int hex2bin(const char *hex, unsigned char *out, int outlen) {
    int n = (int)strlen(hex);
    if (n != outlen * 2) return -1;
    for (int i = 0; i < outlen; i++)
        if (sscanf(hex + 2 * i, "%2hhx", &out[i]) != 1) return -1;
    return 0;
}
static void bin2hex(const unsigned char *b, int n, char *out) {
    for (int i = 0; i < n; i++) sprintf(out + 2 * i, "%02x", b[i]);
    out[2 * n] = 0;
}

/* Path of the first connected FIDO authenticator; caller frees. */
static char *first_device(void) {
    fido_dev_info_t *dl = fido_dev_info_new(8);
    size_t found = 0;
    char *path = NULL;
    if (dl && fido_dev_info_manifest(dl, 8, &found) == FIDO_OK && found > 0) {
        const fido_dev_info_t *di = fido_dev_info_ptr(dl, 0);
        if (di) path = strdup(fido_dev_info_path(di));
    }
    fido_dev_info_free(&dl, 8);
    return path;
}

/* Number of connected FIDO authenticators. */
static int device_count(void) {
    fido_dev_info_t *dl = fido_dev_info_new(8);
    size_t found = 0;
    if (dl)
        fido_dev_info_manifest(dl, 8, &found);
    fido_dev_info_free(&dl, 8);
    return (int)found;
}

int fido2bridge_available(void) {
    ensure_init();
    fido_dev_info_t *dl = fido_dev_info_new(8);
    size_t found = 0;
    int r = 0;
    if (dl && fido_dev_info_manifest(dl, 8, &found) == FIDO_OK)
        r = (found > 0);
    fido_dev_info_free(&dl, 8);
    return r;
}

int fido2bridge_enroll(const char *pin, char *cred_hex, int cred_hexlen, char *err, int errlen) {
    int rc = -1, e;
    int uv = (pin != NULL && pin[0] != 0);
    ensure_init();
    /* make_cred and the immediate derive must hit the SAME key; with several
     * keys plugged the host picks one arbitrarily and they can diverge. Force a
     * single key for enrollment so the failure is a clear instruction. */
    if (device_count() > 1) {
        snprintf(err, errlen, "multiple security keys present — unplug the others and insert only the key you are enrolling");
        return -1;
    }
    char *path = first_device();
    if (!path) { snprintf(err, errlen, "no FIDO device present"); return -1; }

    fido_dev_t *dev = fido_dev_new();
    fido_cred_t *cred = fido_cred_new();
    unsigned char uid[16] = "infernode-2fa-01";

    if ((e = fido_dev_open(dev, path)) != FIDO_OK) { snprintf(err, errlen, "open: %s", fido_strerr(e)); goto out; }
    fido_cred_set_type(cred, COSE_ES256);
    fido_cred_set_clientdata_hash(cred, CDH, sizeof CDH);
    fido_cred_set_rp(cred, RP_ID, RP_NAME);
    fido_cred_set_user(cred, uid, sizeof uid, "inferno", "InferNode", NULL);
    fido_cred_set_extensions(cred, FIDO_EXT_HMAC_SECRET);
    fido_cred_set_rk(cred, FIDO_OPT_FALSE);   /* non-resident */
    if (uv)
        fido_cred_set_uv(cred, FIDO_OPT_TRUE);   /* AAL3: bind to user verification (PIN) */

    if ((e = fido_dev_make_cred(dev, cred, uv ? pin : NULL)) != FIDO_OK) {
        snprintf(err, errlen, "make_cred: %s%s", fido_strerr(e),
                 e == FIDO_ERR_PIN_REQUIRED ? " (FIDO2 PIN required)" : "");
        goto out;
    }
    {
        const unsigned char *cid = fido_cred_id_ptr(cred);
        size_t cidlen = fido_cred_id_len(cred);
        if ((int)(cidlen * 2 + 1) > cred_hexlen) { snprintf(err, errlen, "cred id too long"); goto out; }
        bin2hex(cid, (int)cidlen, cred_hex);
        rc = 0;
    }
out:
    fido_cred_free(&cred); fido_dev_close(dev); fido_dev_free(&dev); free(path);
    return rc;
}

int fido2bridge_derive(const char *pin, const char *cred_hex, const char *salt_hex,
                       char *secret_hex, int secret_hexlen,
                       char *err, int errlen) {
    int rc = -1, e;
    int uv = (pin != NULL && pin[0] != 0);
    unsigned char salt[32];
    ensure_init();

    if (hex2bin(salt_hex, salt, sizeof salt) != 0) { snprintf(err, errlen, "salt must be 64 hex chars"); return -1; }
    int cidlen = (int)strlen(cred_hex) / 2;
    if (cidlen <= 0) { snprintf(err, errlen, "empty credential id"); return -1; }
    unsigned char *cid = malloc(cidlen);
    if (!cid || hex2bin(cred_hex, cid, cidlen) != 0) { snprintf(err, errlen, "bad credential id hex"); free(cid); return -1; }

    char *path = first_device();
    if (!path) { snprintf(err, errlen, "no FIDO device present"); free(cid); return -1; }

    fido_dev_t *dev = fido_dev_new();
    fido_assert_t *as = fido_assert_new();

    if ((e = fido_dev_open(dev, path)) != FIDO_OK) { snprintf(err, errlen, "open: %s", fido_strerr(e)); goto out; }
    fido_assert_set_clientdata_hash(as, CDH, sizeof CDH);
    fido_assert_set_rp(as, RP_ID);
    fido_assert_allow_cred(as, cid, cidlen);
    fido_assert_set_extensions(as, FIDO_EXT_HMAC_SECRET);
    fido_assert_set_hmac_salt(as, salt, sizeof salt);
    fido_assert_set_up(as, FIDO_OPT_TRUE);
    /* When a PIN is supplied, libfido2 performs user verification via pinUvAuth;
     * do NOT also set the uv option — the authenticator rejects the combination
     * (FIDO_ERR_UNSUPPORTED_OPTION). Passing the PIN is the UV, and it selects
     * the hmac-secret's WithUV CredRandom (a different secret than touch-only). */

    if ((e = fido_dev_get_assert(dev, as, uv ? pin : NULL)) != FIDO_OK) { snprintf(err, errlen, "get_assert: %s", fido_strerr(e)); goto out; }
    {
        const unsigned char *hs = fido_assert_hmac_secret_ptr(as, 0);
        size_t hslen = fido_assert_hmac_secret_len(as, 0);
        if (!hs || hslen == 0) { snprintf(err, errlen, "no hmac-secret returned"); goto out; }
        if ((int)(hslen * 2 + 1) > secret_hexlen) { snprintf(err, errlen, "secret buffer too small"); goto out; }
        bin2hex(hs, (int)hslen, secret_hex);
        rc = 0;
    }
out:
    fido_assert_free(&as); fido_dev_close(dev); fido_dev_free(&dev); free(path); free(cid);
    return rc;
}

#else /* !HAVE_FIDO2 */

int fido2bridge_available(void) { return 0; }
int fido2bridge_enroll(const char *pin, char *cred_hex, int cred_hexlen, char *err, int errlen) {
    (void)pin; (void)cred_hex; (void)cred_hexlen; snprintf(err, errlen, "fido2 support not built in"); return -1;
}
int fido2bridge_derive(const char *pin, const char *cred_hex, const char *salt_hex,
                       char *secret_hex, int secret_hexlen, char *err, int errlen) {
    (void)pin; (void)cred_hex; (void)salt_hex; (void)secret_hex; (void)secret_hexlen;
    snprintf(err, errlen, "fido2 support not built in"); return -1;
}

#endif /* HAVE_FIDO2 */
