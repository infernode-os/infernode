/*
 * yk-hmac-secret — Phase 0 PoC for InferNode second-factor auth.
 *
 * Proves the cryptographic foundation of doc/second-factor-auth.md on real
 * hardware: a YubiKey deterministically derives a 32-byte device-bound secret
 * from a 32-byte salt via the FIDO2 hmac-secret extension, gated by touch.
 * No private key ever leaves the key; the secret is uncomputable off-device.
 *
 * This is also the reference for the future emu host bridge (emu/port/dev2fa.c):
 * the bridge will call exactly these libfido2 entry points on the host side of
 * the Inferno emulator and relay challenge -> response over a 9P interface.
 *
 * Touch-only (UP), no UV/PIN, to avoid spending FIDO2 PIN retries.
 *
 * Build:  cc -I$(brew --prefix)/include yk-hmac-secret.c \
 *             -L$(brew --prefix)/lib -lfido2 -o yk-hmac-secret
 *
 * Usage:
 *   yk-hmac-secret enroll <cred-id-out.hex>
 *       Create a non-resident hmac-secret credential; write its credential id
 *       (hex) to the given file. Requires one touch.
 *   yk-hmac-secret derive <cred-id.hex> <salt-32-byte-hex>
 *       Output the 32-byte hmac-secret (hex) for that credential + salt.
 *       Requires one touch. Deterministic: same (key, cred, salt) -> same out.
 */

#include <fido.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RP_ID   "infernode.local"
#define RP_NAME "InferNode secstore"

static unsigned char CDH[32] = { /* fixed client-data hash; irrelevant to hmac-secret output */
    0x9a,0x1c,0x00,0x5e,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xaa,0xbb,0xcc,
    0xde,0xad,0xbe,0xef,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b,0x0c
};

static int hex2bin(const char *hex, unsigned char *out, size_t outlen) {
    size_t n = strlen(hex);
    if (n != outlen * 2) return -1;
    for (size_t i = 0; i < outlen; i++)
        if (sscanf(hex + 2 * i, "%2hhx", &out[i]) != 1) return -1;
    return 0;
}
static void printhex(const unsigned char *b, size_t n) {
    for (size_t i = 0; i < n; i++) printf("%02x", b[i]);
    printf("\n");
}

/* Pick the first FIDO device on the system. */
static char *first_device(void) {
    fido_dev_info_t *dl = fido_dev_info_new(64);
    size_t found = 0;
    char *path = NULL;
    if (fido_dev_info_manifest(dl, 64, &found) == FIDO_OK && found > 0) {
        const fido_dev_info_t *di = fido_dev_info_ptr(dl, 0);
        path = strdup(fido_dev_info_path(di));
    }
    fido_dev_info_free(&dl, 64);
    return path;
}

static int do_enroll(const char *outpath) {
    int r = 1;
    char *path = first_device();
    if (!path) { fprintf(stderr, "no FIDO device found\n"); return 1; }
    fido_dev_t *dev = fido_dev_new();
    fido_cred_t *cred = fido_cred_new();
    unsigned char uid[16] = "infernode-poc-01";
    int e;

    if ((e = fido_dev_open(dev, path)) != FIDO_OK) { fprintf(stderr, "open: %s\n", fido_strerr(e)); goto out; }
    fido_cred_set_type(cred, COSE_ES256);
    fido_cred_set_clientdata_hash(cred, CDH, sizeof CDH);
    fido_cred_set_rp(cred, RP_ID, RP_NAME);
    fido_cred_set_user(cred, uid, sizeof uid, "inferno", "InferNode", NULL);
    fido_cred_set_extensions(cred, FIDO_EXT_HMAC_SECRET);
    fido_cred_set_rk(cred, FIDO_OPT_FALSE);   /* non-resident: nothing enumerable on a lost key */
    /* makeCredential always requires user presence (touch); no set_up for creds. */

    fprintf(stderr, "Touch the YubiKey to create the hmac-secret credential...\n");
    if ((e = fido_dev_make_cred(dev, cred, NULL)) != FIDO_OK) {
        fprintf(stderr, "make_cred: %s\n", fido_strerr(e));
        if (e == FIDO_ERR_PIN_REQUIRED)
            fprintf(stderr, "(this YubiKey requires the FIDO2 PIN for makeCredential)\n");
        goto out;
    }
    const unsigned char *cid = fido_cred_id_ptr(cred);
    size_t cidlen = fido_cred_id_len(cred);

    FILE *f = fopen(outpath, "w");
    if (!f) { perror("fopen"); goto out; }
    for (size_t i = 0; i < cidlen; i++) fprintf(f, "%02x", cid[i]);
    fprintf(f, "\n");
    fclose(f);
    fprintf(stderr, "enrolled: credential id (%zu bytes) -> %s\n", cidlen, outpath);
    r = 0;
out:
    fido_cred_free(&cred); fido_dev_close(dev); fido_dev_free(&dev); free(path);
    return r;
}

static int do_derive(const char *cidpath, const char *salthex) {
    int r = 1;
    unsigned char salt[32];
    if (hex2bin(salthex, salt, sizeof salt) != 0) { fprintf(stderr, "salt must be 64 hex chars (32 bytes)\n"); return 1; }

    /* read credential id hex */
    FILE *f = fopen(cidpath, "r");
    if (!f) { perror("fopen cred"); return 1; }
    char hexbuf[4096]; if (!fgets(hexbuf, sizeof hexbuf, f)) { fclose(f); return 1; } fclose(f);
    hexbuf[strcspn(hexbuf, "\r\n")] = 0;
    size_t cidlen = strlen(hexbuf) / 2;
    unsigned char *cid = malloc(cidlen);
    if (hex2bin(hexbuf, cid, cidlen) != 0) { fprintf(stderr, "bad cred id hex\n"); free(cid); return 1; }

    char *path = first_device();
    if (!path) { fprintf(stderr, "no FIDO device found\n"); free(cid); return 1; }
    fido_dev_t *dev = fido_dev_new();
    fido_assert_t *as = fido_assert_new();
    int e;

    if ((e = fido_dev_open(dev, path)) != FIDO_OK) { fprintf(stderr, "open: %s\n", fido_strerr(e)); goto out; }
    fido_assert_set_clientdata_hash(as, CDH, sizeof CDH);
    fido_assert_set_rp(as, RP_ID);
    fido_assert_allow_cred(as, cid, cidlen);
    fido_assert_set_extensions(as, FIDO_EXT_HMAC_SECRET);
    fido_assert_set_hmac_salt(as, salt, sizeof salt);
    fido_assert_set_up(as, FIDO_OPT_TRUE);    /* touch */

    fprintf(stderr, "Touch the YubiKey to derive the hmac-secret...\n");
    if ((e = fido_dev_get_assert(dev, as, NULL)) != FIDO_OK) { fprintf(stderr, "get_assert: %s\n", fido_strerr(e)); goto out; }

    const unsigned char *hs = fido_assert_hmac_secret_ptr(as, 0);
    size_t hslen = fido_assert_hmac_secret_len(as, 0);
    if (!hs || hslen == 0) { fprintf(stderr, "no hmac-secret returned\n"); goto out; }
    printhex(hs, hslen);   /* the device-bound secret R, to stdout */
    r = 0;
out:
    fido_assert_free(&as); fido_dev_close(dev); fido_dev_free(&dev); free(path); free(cid);
    return r;
}

int main(int argc, char **argv) {
    fido_init(0);
    if (argc == 3 && strcmp(argv[1], "enroll") == 0)  return do_enroll(argv[2]);
    if (argc == 4 && strcmp(argv[1], "derive") == 0)   return do_derive(argv[2], argv[3]);
    fprintf(stderr,
        "usage:\n"
        "  %s enroll <cred-id-out.hex>\n"
        "  %s derive <cred-id.hex> <salt-32-byte-hex>\n", argv[0], argv[0]);
    return 2;
}
