#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"

#define NO_XSLOCKS
#include "XSUB.h"
#include "ppport.h"

#define MY_CXT_KEY "Danessl::_guts" XS_VERSION

#include <string.h>
#include <openssl/engine.h>
#include <openssl/conf.h>
#include <openssl/pem.h>
#include <openssl/bio.h>
#include <openssl/x509.h>
#include <danessl.h>

#define PERL_constant_NOTFOUND	1
#define PERL_constant_ISIV	2

static int
constant (pTHX_ const char *name, STRLEN len, IV *iv_return) {
  switch (name[11]) {
  case '1':
    if (memEQ(name, "MATCHING_2512", 13)) {
      *iv_return = DANESSL_MATCHING_2512;
      return PERL_constant_ISIV;
    }
    break;
  case '5':
    if (memEQ(name, "MATCHING_2256", 13)) {
      *iv_return = DANESSL_MATCHING_2256;
      return PERL_constant_ISIV;
    }
    break;
  case 'E':
    if (memEQ(name, "USAGE_DANE_EE", 13)) {
      *iv_return = DANESSL_USAGE_DANE_EE;
      return PERL_constant_ISIV;
    }
    if (memEQ(name, "USAGE_PKIX_EE", 13)) {
      *iv_return = DANESSL_USAGE_PKIX_EE;
      return PERL_constant_ISIV;
    }
    break;
  case 'K':
    if (memEQ(name, "SELECTOR_SPKI", 13)) {
      *iv_return = DANESSL_SELECTOR_SPKI;
      return PERL_constant_ISIV;
    }
    break;
  case 'L':
    if (memEQ(name, "MATCHING_FULL", 13)) {
      *iv_return = DANESSL_MATCHING_FULL;
      return PERL_constant_ISIV;
    }
    break;
  case 'R':
    if (memEQ(name, "SELECTOR_CERT", 13)) {
      *iv_return = DANESSL_SELECTOR_CERT;
      return PERL_constant_ISIV;
    }
    break;
  case 'T':
    if (memEQ(name, "USAGE_DANE_TA", 13)) {
      *iv_return = DANESSL_USAGE_DANE_TA;
      return PERL_constant_ISIV;
    }
    if (memEQ(name, "USAGE_PKIX_TA", 13)) {
      *iv_return = DANESSL_USAGE_PKIX_TA;
      return PERL_constant_ISIV;
    }
    break;
  }
  return PERL_constant_NOTFOUND;
}

/* Cut/paste from OpenSSL 1.0.1: ssl/ssl_cert.c */

static int ssl_verify_cert_chain(SSL *s, STACK_OF(X509) *sk)
{
    X509 *x;
    int i;
    X509_STORE_CTX ctx;

    if ((sk == NULL) || (sk_X509_num(sk) == 0))
	return(0);

    x=sk_X509_value(sk,0);
    if(!X509_STORE_CTX_init(&ctx,s->ctx->cert_store,x,sk)) {
	SSLerr(SSL_F_SSL_VERIFY_CERT_CHAIN,ERR_R_X509_LIB);
	return(0);
    }
    X509_STORE_CTX_set_ex_data(&ctx,SSL_get_ex_data_X509_STORE_CTX_idx(),s);

    X509_STORE_CTX_set_default(&ctx, s->server ? "ssl_client" : "ssl_server");
    X509_VERIFY_PARAM_set1(X509_STORE_CTX_get0_param(&ctx), s->param);

    if (s->verify_callback)
	X509_STORE_CTX_set_verify_cb(&ctx, s->verify_callback);

    if (s->ctx->app_verify_callback != NULL)
	i=s->ctx->app_verify_callback(&ctx, s->ctx->app_verify_arg);
    else {
	i=X509_verify_cert(&ctx);
    }

    s->verify_result=ctx.error;
    X509_STORE_CTX_cleanup(&ctx);

    return(i);
}

static char *btox(unsigned char *data, size_t len)
{
    static char hexdigit[] = "0123456789abcdef";
    size_t i;
    size_t hlen = len + len;
    char *hex;
    char *cp;

    if (hlen < len || (hex = OPENSSL_malloc(hlen + 1)) == 0)
	return 0;
    cp = hex;

    for (i = 0; i < len; ++i) {
	*cp++ = hexdigit[(*data & 0xF0) >> 4];
	*cp++ = hexdigit[*data++ & 0x0F];
    }
    *cp = '\0';

    return hex;
}

static unsigned char *xtob(const char *hex, size_t *len)
{
    size_t hlen = strlen(hex);
    size_t i;
    unsigned char *data;
    unsigned char *cp;
    char h;

    if (hlen % 2)
    	return (0);
    hlen /= 2;
    if ((data = OPENSSL_malloc(hlen)) == 0)
    	return data;
    cp = data;

#define convert_if_between(c, low, high, add) \
	if (c >= low && c <= high) *cp |= c - low + add;

    for (h = *hex; h != '\0'; ++cp) {
    	*cp = 0;
	for (i = 0; i < 2; ++i) {
	    *cp <<= 4;
	    convert_if_between(h, '0', '9', 0)
	    else convert_if_between(h, 'A', 'F', 10)
	    else convert_if_between (h, 'a', 'f', 10)
	    else { free(data); return (0); }
	    h = *++hex;
	}
    }
    *len = hlen;
    return data;
}

static int add_tlsa(SSL *ssl, int u, int s,
		    const char *marg,
		    const char *darg)
{
    const char *mdname = *marg ? marg : 0;
    size_t len;
    unsigned char *data = xtob(darg, &len);
    int ret = DANESSL_add_tlsa(ssl, u, s, mdname, data, len);

    free(data);
    return ret;
}

static STACK_OF(X509) *load_chain(const char *chainbuf)
{
    BIO *bp = BIO_new_mem_buf((char *)chainbuf, -1);
    char *name = 0;
    char *header = 0;
    unsigned char *data = 0;
    long len;
    int count;
    char *errtype = 0;		/* if error: cert or pkey? */
    STACK_OF(X509) *chain;
    typedef X509 *(*d2i_X509_t)(X509 **, const unsigned char **, long);

    if ((chain = sk_X509_new_null()) == 0)
	croak("out of memory\n");

    for (count = 0;
	 errtype == 0 && PEM_read_bio(bp, &name, &header, &data, &len);
	 ++count) {
	const unsigned char *p = data;

	if (strcmp(name, PEM_STRING_X509) == 0
	    || strcmp(name, PEM_STRING_X509_TRUSTED) == 0
	    || strcmp(name, PEM_STRING_X509_OLD) == 0) {
	    d2i_X509_t d = strcmp(name, PEM_STRING_X509_TRUSTED) ?
		d2i_X509_AUX : d2i_X509;
	    X509 *cert = d(0, &p, len);

	    if (cert == 0 || (p - data) != len)
		errtype = "certificate";
	    else if (sk_X509_push(chain, cert) == 0)
		croak("out of memory\n");
	} else {
	    croak("unexpected chain object: %s\n", name);
	}

	/*
	 * If any of these were null, PEM_read() would have failed.
	 */
	OPENSSL_free(name);
	OPENSSL_free(header);
	OPENSSL_free(data);
    }
    BIO_free(bp);

    if (errtype)
	croak("malformed chain: %s", errtype);
    if (ERR_GET_REASON(ERR_peek_last_error()) == PEM_R_NO_START_LINE) {
	/* Reached end of PEM file */
	ERR_clear_error();
	if (count > 0)
	    return chain;
	croak("no certificates in chain\n");
    }
    /* Some other PEM read error */
    croak("error processing chain\n");
}

typedef struct {
    SSL_CTX *ssl_ctx;
} my_cxt_t;
START_MY_CXT

MODULE = Danessl PACKAGE = Danessl PREFIX = DANESSL_

BOOT:
{
    SSL_CTX *c;
    MY_CXT_INIT;

    SSL_load_error_strings();
    SSL_library_init();

    if (DANESSL_library_init() <= 0)
	croak("Error initializing Danessl library\n");

    if ((c = SSL_CTX_new(SSLv23_client_method())) == 0)
	croak("error allocating SSL_CTX\n");
    SSL_CTX_set_verify(c, SSL_VERIFY_NONE, 0);
    if (DANESSL_CTX_init(c) <= 0)
	croak("error initializing Danessl context\n");

    MY_CXT.ssl_ctx = c;
}

void
constant(sv)
    PREINIT:
	dXSTARG;
	STRLEN		len;
        int		type;
	IV		iv;
    INPUT:
	SV *		sv;
        const char *	s = SvPV(sv, len);
    PPCODE:
	type = constant(aTHX_ s, len, &iv);
        switch (type) {
        case PERL_constant_NOTFOUND:
          sv =
	    sv_2mortal(newSVpvf("%s is not a valid Danessl macro", s));
          PUSHs(sv);
          break;
        case PERL_constant_ISIV:
          EXTEND(SP, 1);
          PUSHs(&PL_sv_undef);
          PUSHi(iv);
          break;
        default:
          sv = sv_2mortal(newSVpvf(
	    "Unexpected return type %d while processing Danessl macro %s, used",
               type, s));
          PUSHs(sv);
        }

# Allow verify(@tlsa, ..., @hostnames) to expand to multiple arguments
PROTOTYPES: DISABLE

void
verify(uarg, sarg, m, d, ...)
	 const char *uarg
	 const char *sarg
	 const char *m
	 const char *d
    PREINIT:
    	dMY_CXT;
    PPCODE:
	dXCPT;
    	SSL_CTX *c = MY_CXT.ssl_ctx;
	SSL *ssl = 0;
	STACK_OF(X509) *xs = 0;
	const char *chain = 0;
	const char *base = 0;
	const char **peernames = 0;
	const char *mhost;
	int u;
	int s;
	int mdepth;
	long ok;
	int i;

	XCPT_TRY_START {
	    char tmp[16];

	    if (c == 0)
		croak("Danessl module not initialized\n");

	    if (!uarg || !sarg || !m || !d)
	    	croak("All TLSA fields must be defined\n");

	    u = atoi(uarg);
	    if (u < 0 || u > 0xFF
	        || (snprintf(tmp, sizeof(tmp), "%d", u) && strcmp(tmp, uarg) != 0))
	    	croak("Invalid TLSA certificate usage: %s\n", uarg);
	    s = atoi(sarg);
	    if (s < 0 || s > 0xFF
	        || (snprintf(tmp, sizeof(tmp), "%d", s) && strcmp(tmp, sarg) != 0))
	    	croak("Invalid TLSA selector: %s\n", sarg);

	    /* Support built-in standard one-digit mtypes */
	    if (m[0] && m[1] == '\0') 
	    	switch (m[0]) {
		    case '0': m = ""; break;
		    case '1': m = "sha256"; break;
		    case '2': m = "sha512"; break;
		}

	    if (items > 4)
		chain = (const char *)SvPV_nolen(ST(4));

	    if (items > 5) {
		peernames = (const char **)
			OPENSSL_malloc((items - 5 + 1) * sizeof(*peernames));
		if (! peernames)
		    croak("Out of memory\n");
		for (i = 5; i < items; ++i) {
		    peernames[i-5] = (const char *)SvPV_nolen(ST(i));
		}
		peernames[items - 5] = 0;
		/* Base domain is first peername */
		base = peernames[0];
	    }

	    /* Create a connection handle */
	    if ((ssl = SSL_new(c)) == 0)
		croak("error allocating SSL handle\n");
	    if (DANESSL_init(ssl, base, peernames) <= 0)
		croak("error initializing DANESSL handle\n");

	    if (!add_tlsa(ssl, u, s, m, d))
		croak("error processing TLSA RR\n");

	    /*
	     * Verify a chain if provided, otherwise, we're
	     * just checking the TLSA RRset
	     */
	    if (chain) {
		xs = load_chain(chain);
		SSL_set_connect_state(ssl);
		ssl_verify_cert_chain(ssl, xs);
		if (DANESSL_get_match_cert(ssl, 0, &mhost, &mdepth)) {
		    EXTEND(SP, 2);
		    mXPUSHi(mdepth);
		    mXPUSHs(newSVpv(mhost, 0));
		} else {
		    long err = SSL_get_verify_result(ssl);
		    const char *reason = X509_verify_cert_error_string(err);
		    croak("%s: (%ld)\n", reason ? reason : "Verify error code", err);
		}
	    }
	} XCPT_TRY_END

	if (peernames)
	    OPENSSL_free(peernames);
	if (ssl) {
	    DANESSL_cleanup(ssl);
	    SSL_free(ssl);
	}
	if (xs)
	    sk_X509_pop_free(xs, X509_free);

	XCPT_CATCH
	{
	    XCPT_RETHROW;
	}
