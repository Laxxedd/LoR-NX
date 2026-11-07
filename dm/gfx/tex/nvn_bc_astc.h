// BC → ASTC 4x4 transcode of one texture image: BC1 / BC2 / BC3 / BC7 and unsigned BC4 / BC5 blocks are decoded (bcn_decode) and encoded with astcenc (../astc/astc_enc). Pure C, no Metal.
// Which NVN formats it covers: nvn_fmt_bcn (nvn_fmt_mtl.h). The format mapping (nvn_fmt_to_mtl → ASTC 4x4) and this module are switched together by nvn_bc_astc_init.
#pragma once
#include <stddef.h>
#include <stdint.h>

// Reads the switch DM_NVN_BC_ASTC (unset or non-zero: on; 0: off, the BC formats stay BC) and turns the format mapping (nvn_fmt_bc_to_astc) on or off with it.
// Always off when the host is built without astcenc (DM_HAVE_ASTCENC unset: ASTCENC_DIR not given to make). Call once, before any texture is made. Returns 1 when the transcode is on.
int nvn_bc_astc_init(void);
int nvn_bc_astc_active(void);
// Threads one large image (128×128 and up) is encoded on: DM_NVN_BC_ASTC_THREADS, else the CPU count up to 6; 1 = the calling thread only. Read by nvn_bc_astc_init.
unsigned nvn_bc_astc_threads(void);
// The encode quality in use, 0..100 on astcenc's scale (default 98, thorough; DM_NVN_BC_ASTC_QUALITY overrides, read by nvn_bc_astc_init); 0 when the host is built without astcenc.
float nvn_bc_astc_quality(void);

// 1 when the transcode is on and covers this NVN format (BC1 / BC2 / BC3 / BC7, sRGB or not; unsigned BC4 / BC5 as ASTC 4x4; signed BC4 / BC5 as R8Snorm / RG8Snorm, which need no astcenc to convert but are switched with the rest)
int nvn_bc_astc_covers(int nvn_format);

// Bytes of one w×h image as ASTC 4x4 (16 bytes per 4x4 block, rows of ceil(w/4) blocks, no padding between rows)
size_t nvn_bc_astc_size(unsigned w, unsigned h);

int nvn_bc_astc_host(int nvn_format, int *block_w, int *block_h, int *bytes_per_block);
size_t nvn_bc_astc_host_size(int nvn_format, unsigned w, unsigned h);

// Transcodes one w×h image of a covered format: bc holds the BC blocks, rows of ceil(w/4) blocks with no padding (bc_len bytes), astc receives nvn_bc_astc_size(w, h) bytes.
// sRGB formats are encoded with the sRGB profile. Thread safe: a large image is spread over the threads above while no other large image is being encoded, otherwise (and for small images) the calling thread encodes it alone with its own encoder. Returns 0, or -1 for an uncovered format, a short buffer or an allocation failure.
int nvn_bc_astc_image(int nvn_format, const uint8_t *bc, size_t bc_len, unsigned w, unsigned h, uint8_t *astc, size_t astc_len);

// The on-disk cache of transcoded images (astc_cache.h) is opened by nvn_bc_astc_init and used by nvn_bc_astc_image for images of 64×64 and up (BC1 / BC2 / BC3 / BC7 / unsigned BC4 / BC5, the ones astcenc encodes):
// a hit copies the stored ASTC bytes, a miss encodes and stores. DM_NVN_BC_ASTC_CACHE: a folder, `0` = off, unset = <DM_TEMP>_astc; DM_NVN_BC_ASTC_CACHE_MB: its cap, default 2048.
