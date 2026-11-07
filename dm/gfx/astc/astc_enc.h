#ifndef ASTC_ENC_H
#define ASTC_ENC_H

#include <stddef.h>
#include <stdint.h>

#define ASTC_ENC_QUALITY_FASTEST 0.0f
#define ASTC_ENC_QUALITY_FAST 10.0f
#define ASTC_ENC_QUALITY_MEDIUM 60.0f
#define ASTC_ENC_QUALITY_THOROUGH 98.0f
#define ASTC_ENC_QUALITY_VERYTHOROUGH 99.0f
#define ASTC_ENC_QUALITY_EXHAUSTIVE 100.0f   // astcenc's highest preset (ASTCENC_PRE_EXHAUSTIVE)

typedef struct astc_enc astc_enc_t;

astc_enc_t *astc_enc_new(int srgb, float quality, const astc_enc_t *parent);
// An encoder that spreads one image over `threads` threads (astcenc's own work sharing; the output is the same as with one thread). Use it from one caller at a time: astc_enc_rgba8_4x4_mt
// starts threads-1 helper threads for the call, takes part itself and returns when all are done. NULL for threads < 2 or on failure.
astc_enc_t *astc_enc_new_mt(int srgb, float quality, unsigned threads);
size_t astc_enc_size_4x4(unsigned w, unsigned h);
int astc_enc_rgba8_4x4(astc_enc_t *e, const uint8_t *rgba, unsigned w, unsigned h, uint8_t *out, size_t out_len);
int astc_enc_rgba8_4x4_mt(astc_enc_t *e, const uint8_t *rgba, unsigned w, unsigned h, uint8_t *out, size_t out_len);   // e from astc_enc_new_mt
void astc_enc_free(astc_enc_t *e);

#endif
