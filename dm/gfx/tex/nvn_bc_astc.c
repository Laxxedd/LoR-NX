#include "nvn_bc_astc.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>   // strcasecmp
#include <unistd.h>

#include "astc_cache.h"
#include "bcn_decode.h"
#include "nvn_fmt_mtl.h"
#ifdef DM_HAVE_ASTCENC
#include "../astc/astc_enc.h"
#endif

// Everything the cached bytes depend on besides the BC input: this file's format of the transcode (bump the number when the decode, the encode settings or the layout change), the encoder and its quality.
// DM_ASTCENC_TAG (the astcenc release the build links, e.g. "5.7.0"; build.yml's ASTCENC_TAG) is optional: unset, a newer astcenc keeps finding the older one's files until the number below is bumped.
#ifndef DM_ASTCENC_TAG
#define DM_ASTCENC_TAG "unknown"
#endif
#define NVN_BC_ASTC_CACHE_SALT_FMT "dm-bc-astc-1;astcenc=" DM_ASTCENC_TAG ";quality=%g;ldr4x4"   // the quality actually used (g_quality) is part of the key: another quality finds nothing of an older one
#define CACHE_MIN_PIXELS (64u * 64u)   // smaller images encode faster than a file can be found and read

#ifdef DM_HAVE_ASTCENC
// Encode quality (0..100, astcenc's scale): the balance of texture quality and encode speed. Default: thorough (98), which is close to exhaustive in the result and a good deal faster.
// DM_NVN_BC_ASTC_QUALITY overrides it: fastest | fast | medium | thorough | verythorough | exhaustive, or a number from 0 to 100 (a bad value is ignored). Read by nvn_bc_astc_init.
static float g_quality = ASTC_ENC_QUALITY_THOROUGH;
static float parse_quality(const char *s, float fallback) {
    static const struct { const char *name; float q; } names[] = {
        {"fastest", ASTC_ENC_QUALITY_FASTEST}, {"fast", ASTC_ENC_QUALITY_FAST}, {"medium", ASTC_ENC_QUALITY_MEDIUM},
        {"thorough", ASTC_ENC_QUALITY_THOROUGH}, {"verythorough", ASTC_ENC_QUALITY_VERYTHOROUGH}, {"exhaustive", ASTC_ENC_QUALITY_EXHAUSTIVE},
    };
    if (!s || !*s) return fallback;
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) if (!strcasecmp(s, names[i].name)) return names[i].q;
    char *end = NULL;
    double v = strtod(s, &end);
    if (end == s || *end || v < 0 || v > 100) return fallback;
    return (float)v;
}
#endif

static atomic_int g_active;
static atomic_uint g_threads = 1;   // encoder threads for one large image (nvn_bc_astc_init)
#define MT_MIN_PIXELS (128u * 128u)   // smaller images are encoded on the calling thread: starting threads costs more than it saves

int nvn_bc_astc_init(void) {
    int on = 0;
#ifdef DM_HAVE_ASTCENC
    const char *e = getenv("DM_NVN_BC_ASTC");
    on = !e || atoi(e) != 0;
    g_quality = parse_quality(getenv("DM_NVN_BC_ASTC_QUALITY"), ASTC_ENC_QUALITY_THOROUGH);
    // DM_NVN_BC_ASTC_THREADS: threads for one large image; unset = the CPU count, at most 6 (an iPhone has 2 fast and 4 efficiency cores); 0 or 1 = the calling thread only
    long n = sysconf(_SC_NPROCESSORS_ONLN); if (n > 6) n = 6;
    const char *t = getenv("DM_NVN_BC_ASTC_THREADS");
    if (t && *t) n = atoi(t);
    atomic_store(&g_threads, n < 2 ? 1u : n > 64 ? 64u : (unsigned)n);
    // The on-disk cache (astc_cache.h): DM_NVN_BC_ASTC_CACHE names the folder, `0` turns it off, unset = <DM_TEMP>_astc (none without DM_TEMP); DM_NVN_BC_ASTC_CACHE_MB caps it (default 2048)
    astc_cache_close();
    if (on) {
        const char *c = getenv("DM_NVN_BC_ASTC_CACHE"), *tmp = getenv("DM_TEMP"), *mb = getenv("DM_NVN_BC_ASTC_CACHE_MB");
        char dir[1000]; dir[0] = 0;
        if (c && *c) { if (strcmp(c, "0")) snprintf(dir, sizeof dir, "%s", c); }
        else if (tmp && *tmp) snprintf(dir, sizeof dir, "%s_astc", tmp);
        long m = mb && *mb ? atol(mb) : 2048;
        char salt[128]; snprintf(salt, sizeof salt, NVN_BC_ASTC_CACHE_SALT_FMT, (double)g_quality);
        if (*dir && m > 0) astc_cache_open(dir, (uint64_t)m << 20, salt);
    }
#endif
    atomic_store(&g_active, on);
    nvn_fmt_bc_to_astc(on);
    return on;
}

int nvn_bc_astc_active(void) { return atomic_load(&g_active); }
unsigned nvn_bc_astc_threads(void) { return atomic_load(&g_threads); }
#ifdef DM_HAVE_ASTCENC
float nvn_bc_astc_quality(void) { return g_quality; }
#else
float nvn_bc_astc_quality(void) { return 0; }
#endif
int nvn_bc_astc_covers(int f) { return atomic_load(&g_active) && nvn_fmt_bcn(f, NULL); }
size_t nvn_bc_astc_size(unsigned w, unsigned h) { return (size_t)((w + 3) / 4) * ((h + 3) / 4) * 16; }

int nvn_bc_astc_host(int f, int *bw, int *bh, int *bpb) {
    int k = nvn_fmt_bcn(f, NULL);
    if (!k) return 0;
    int snorm = k == BCN_BC4S ? 1 : k == BCN_BC5S ? 2 : 0;
    if (bw) *bw = snorm ? 1 : 4;
    if (bh) *bh = snorm ? 1 : 4;
    if (bpb) *bpb = snorm ? snorm : 16;
    return 1;
}

size_t nvn_bc_astc_host_size(int f, unsigned w, unsigned h) {
    int bw, bh, bpb;
    if (!nvn_bc_astc_host(f, &bw, &bh, &bpb)) return 0;
    return (size_t)((w + bw - 1) / bw) * ((h + bh - 1) / bh) * bpb;
}

static int snorm_image(int fmt, const uint8_t *bc, size_t bc_len, unsigned w, unsigned h, uint8_t *out, size_t out_len) {
    unsigned n = fmt == BCN_BC4S ? 1 : 2;
    size_t px = (size_t)w * h;
    if (!bc || !out || !w || !h || out_len < px * n) return -1;
    uint8_t *rgba = malloc(px * 4);
    if (!rgba) return -1;
    int rc = bcn_decode_image(fmt, bc, bc_len, w, h, rgba) ? -1 : 0;
    if (!rc)
        for (size_t i = 0; i < px; i++)
            for (unsigned c = 0; c < n; c++) out[i * n + c] = rgba[i * 4 + c];
    free(rgba);
    return rc;
}

#ifdef DM_HAVE_ASTCENC
// One encoder per thread and profile (LDR / sRGB), made on first use at g_quality (the choice is part of the on-disk cache's key, see the plan: stage 5). A thread's encoders live as long as the thread.
static _Thread_local astc_enc_t *tl_enc[2];
static _Thread_local float tl_q[2];   // the quality each tl_enc was made with
// The multi-threaded encoders (LDR / sRGB), one image at a time (a context takes a single image): the first large image to find the lock free uses them, one that finds it taken is encoded on its own thread
static pthread_mutex_t g_mt_lock = PTHREAD_MUTEX_INITIALIZER;
static astc_enc_t *g_mt_enc[2]; static unsigned g_mt_n; static float g_mt_q;
static int encode(int srgb, const uint8_t *rgba, unsigned w, unsigned h, uint8_t *astc, size_t astc_len) {
    unsigned thr = atomic_load(&g_threads);
    if (thr > 1 && (size_t)w * h >= MT_MIN_PIXELS && pthread_mutex_trylock(&g_mt_lock) == 0) {
        if (g_mt_n != thr || g_mt_q != g_quality) { for (int i = 0; i < 2; i++) { astc_enc_free(g_mt_enc[i]); g_mt_enc[i] = NULL; } g_mt_n = thr; g_mt_q = g_quality; }   // the switch or the quality changed (tests)
        if (!g_mt_enc[srgb != 0]) g_mt_enc[srgb != 0] = astc_enc_new_mt(srgb, g_quality, thr);
        astc_enc_t *m = g_mt_enc[srgb != 0];
        int rc = m ? astc_enc_rgba8_4x4_mt(m, rgba, w, h, astc, astc_len) : -2;
        pthread_mutex_unlock(&g_mt_lock);
        if (rc != -2) return rc;   // -2: the shared encoder could not be made: the calling thread's own below
    }
    astc_enc_t **e = &tl_enc[srgb != 0];
    if (*e && tl_q[srgb != 0] != g_quality) { astc_enc_free(*e); *e = NULL; }   // this thread's encoder is of another quality (init ran again)
    if (!*e) { if (!(*e = astc_enc_new(srgb, g_quality, NULL))) return -1; tl_q[srgb != 0] = g_quality; }
    return astc_enc_rgba8_4x4(*e, rgba, w, h, astc, astc_len);
}
#endif

int nvn_bc_astc_image(int f, const uint8_t *bc, size_t bc_len, unsigned w, unsigned h, uint8_t *astc, size_t astc_len) {
    int srgb, fmt = nvn_fmt_bcn(f, &srgb);
    if (bcn_is_signed(fmt)) return snorm_image(fmt, bc, bc_len, w, h, astc, astc_len);
#ifdef DM_HAVE_ASTCENC
    if (!fmt || !bc || !astc || !w || !h || astc_len < nvn_bc_astc_size(w, h)) return -1;
    size_t need = nvn_bc_astc_size(w, h);
    int cached = astc_cache_enabled() && (size_t)w * h >= CACHE_MIN_PIXELS;
    astc_cache_key key = {0, 0};
    if (cached) {
        key = astc_cache_make_key(f, w, h, bc, bc_len);
        if (astc_cache_load(key, astc, need)) return 0;
    }
    uint8_t *rgba = malloc((size_t)w * h * 4);
    if (!rgba) return -1;
    int rc = bcn_decode_image(fmt, bc, bc_len, w, h, rgba) || encode(srgb != 0, rgba, w, h, astc, astc_len) ? -1 : 0;
    free(rgba);
    if (!rc && cached) astc_cache_store(key, astc, need);
    return rc;
#else
    (void)f; (void)bc; (void)bc_len; (void)w; (void)h; (void)astc; (void)astc_len;
    return -1;
#endif
}
