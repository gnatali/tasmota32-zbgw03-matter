/* Test-only native crypto for the host Berry interpreter, on Tasmota's BearSSL */
#include <string.h>
#include <stdlib.h>
#include "berry.h"
#include "t_inner.h"

/* _aes_cbc(enc:bool, key:bytes(16), iv:bytes(16), data:bytes) -> in place, like Tasmota */
static int f_aes_cbc(bvm *vm) {
  int enc = be_tobool(vm, 1);
  size_t kl, il, dl;
  const void *k = be_tobytes(vm, 2, &kl);
  void *iv = (void*)be_tobytes(vm, 3, &il);
  void *d = (void*)be_tobytes(vm, 4, &dl);
  if (kl != 16) be_raise(vm, "value_error", "Key size must be 16 bytes");
  if (il != 16) be_raise(vm, "value_error", "IV size must be 16");
  if (dl % 16) be_raise(vm, "value_error", "Data size must be multiple of 16");
  if (enc) { br_aes_small_cbcenc_keys c; br_aes_small_cbcenc_init(&c, k, 16); br_aes_small_cbcenc_run(&c, iv, d, dl); }
  else     { br_aes_small_cbcdec_keys c; br_aes_small_cbcdec_init(&c, k, 16); br_aes_small_cbcdec_run(&c, iv, d, dl); }
  be_pushbool(vm, 1); be_return(vm);
}

/* _gcm(enc, key, iv, aad|nil, data) -> [out, tag] ; same BearSSL sequence as the patched Tasmota */
static int f_gcm(bvm *vm) {
  int enc = be_tobool(vm, 1);
  size_t kl, il, al = 0, dl;
  const void *k = be_tobytes(vm, 2, &kl);
  const void *iv = be_tobytes(vm, 3, &il);
  const void *aad = be_isnil(vm, 4) ? NULL : be_tobytes(vm, 4, &al);
  const void *d = be_tobytes(vm, 5, &dl);
  if (kl != 16 && kl != 32) be_raise(vm, "value_error", "Key size must be 16 or 32 bytes");
  br_aes_small_ctr_keys ctr; br_aes_small_ctr_init(&ctr, k, kl);
  br_gcm_context g; br_gcm_init(&g, &ctr.vtable, &br_ghash_ctmul32);
  br_gcm_reset(&g, iv, il);
  if (aad && al) br_gcm_aad_inject(&g, aad, al);
  br_gcm_flip(&g);
  unsigned char *buf = malloc(dl ? dl : 1); memcpy(buf, d, dl);
  br_gcm_run(&g, enc, buf, dl);
  unsigned char tag[16]; br_gcm_get_tag(&g, tag);
  be_newobject(vm, "list");
  be_pushbytes(vm, buf, dl); be_data_push(vm, -2); be_pop(vm, 1);
  be_pushbytes(vm, tag, 16); be_data_push(vm, -2); be_pop(vm, 1);
  be_pop(vm, 1);
  free(buf);
  be_return(vm);
}

static int f_hmac(bvm *vm) {
  size_t kl, dl; const void *k = be_tobytes(vm, 1, &kl); const void *d = be_tobytes(vm, 2, &dl);
  br_hmac_key_context kc; br_hmac_context c;
  br_hmac_key_init(&kc, &br_sha256_vtable, k, kl); br_hmac_init(&c, &kc, 0);
  br_hmac_update(&c, d, dl); unsigned char o[32]; br_hmac_out(&c, o);
  be_pushbytes(vm, o, 32); be_return(vm);
}
static int f_md5(bvm *vm) {
  size_t dl; const void *d = be_tobytes(vm, 1, &dl);
  br_md5_context c; br_md5_init(&c); br_md5_update(&c, d, dl); unsigned char o[16]; br_md5_out(&c, o);
  be_pushbytes(vm, o, 16); be_return(vm);
}
static int f_random(bvm *vm) {
  int n = be_toint(vm, 1); unsigned char *b = malloc(n ? n : 1);
  for (int i = 0; i < n; i++) b[i] = rand() & 0xFF;
  be_pushbytes(vm, b, n); free(b); be_return(vm);
}
void be_test_crypto_init(bvm *vm) {
  be_regfunc(vm, "_aes_cbc", f_aes_cbc);
  be_regfunc(vm, "_gcm", f_gcm);
  be_regfunc(vm, "_hmac_sha256", f_hmac);
  be_regfunc(vm, "_md5", f_md5);
  be_regfunc(vm, "_random", f_random);
}
