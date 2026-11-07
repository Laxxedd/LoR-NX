# dm/gfx/tex — texture format mapping, block-linear deswizzling, BC decompression

The part of the graphics layer that deals with texture data, called by the replay layer `../nvn/nvn_mtl.m`. It does three things:

1. converts NVN texture format numbers to Metal pixel formats;
2. unpacks the Switch's "block-linear" layout into an ordinary row-by-row layout;
3. decompresses BC textures on GPUs that do not support BC compressed textures.

Block linear is how the Tegra X1 GPU stores textures: the data is not one row after another, but interleaved in small blocks of 64 bytes × 8 rows (GOBs), and several GOBs are then stacked into larger blocks according to a "block height" and a "block depth". The game's packaged texture files are in exactly this layout, and it must be undone before uploading to Metal.

## Files

| File | Contents |
|---|---|
| `nvn_fmt_mtl.h`, `nvn_fmt_mtl.c` | `nvn_fmt_to_mtl()`: NVN format (0x01–0x9C) → Metal pixel format + component remapping. Returns 1 for an exact match, 2 for a substitute (precision, bit order or interpretation differs and a conversion is needed), 0 when Metal has no corresponding format. How each format is handled is written in the comments inside the table. Pure C, no dependency on Metal headers. `nvn_fmt_bc_to_astc(1)` switches BC1 / BC2 / BC3 / BC7 (and their sRGB forms) to ASTC 4x4 LDR / sRGB (returned as a substitute, 2), `nvn_fmt_bcn()` says which `bcn_decode` format such an NVN format is; off by default until the upload path transcodes (BC4, BC5 and BC6H are not covered yet) |
| `nvn_deswizzle.h`, `nvn_deswizzle.c` | `nvn_deswizzle()`: deswizzles one level and one layer from block linear to linear; `nvn_swizzle()`: the reverse, used for round trips in unit tests; `nvn_bl_offset()`: the block-linear address of a single point. Pure C |
| `nvn_deswizzle_gpu.h`, `nvn_deswizzle_gpu.m` | A Metal compute shader version of the same deswizzling algorithm, used by the replay layer when uploading packaged textures; when initialization fails or an unsupported format is encountered, the replay layer falls back to the CPU version |
| `bcn_decode.h`, `bcn_decode.c` | `bcn_decode_image()` / `bcn_decode_block()`: decode BC1, BC2, BC3, BC4, BC5 (unsigned and signed) and BC7 blocks to RGBA8 (BC4 gives R only, BC5 gives R and G, alpha 255; the signed ones give two's-complement SNORM8 bytes, alpha 127, -128 read as -127). Pure C. Used by the BCn to ASTC 4x4 transcode below |
| `nvn_bc_astc.h`, `nvn_bc_astc.c` | `nvn_bc_astc_init()` (reads `DM_NVN_BC_ASTC`, turns the format mapping on or off with it), `nvn_bc_astc_covers()`, `nvn_bc_astc_image()`: one BC1 / BC2 / BC3 / BC7 image → `bcn_decode` → astcenc (`../astc/astc_enc`, thorough quality (98) by default, `DM_NVN_BC_ASTC_QUALITY` = fastest / fast / medium / thorough / verythorough / exhaustive or 0–100, one encoder per thread) → ASTC 4x4 blocks. Pure C. Compiled out without `DM_HAVE_ASTCENC` (the host Makefile sets it when given `ASTCENC_DIR`) |
| `tests/` | Unit tests |

The offsets of each level and layer within the storage, and the block height and block depth actually used by each level, are all taken from `../nvn/nvn_tex.c` (`nvn_tex_layout`, `nvn_tex_level_offset`, `nvn_tex_level_tiles`); this directory only does addressing and moving within a level. Packaged parameters override the automatic block dimensions: [Packaged texture block dimensions and linear storage rows](../../../docs/reference/nvn-objects.md#packaged-texture-block-dimensions-and-linear-storage-rows).

## BC textures: transcoded to ASTC 4x4

BC1, BC2, BC3 and BC7 textures (sRGB too) and unsigned BC4 / BC5 are ASTC 4x4 on the host, signed BC4 / BC5 are R8Snorm / RG8Snorm (uncompressed, exact: ASTC LDR is unsigned, and no astcenc is involved in them), on every device, unless `DM_NVN_BC_ASTC=0` or the host was built without astcenc (then they stay BC, as below). The guest's storage stays BC (it is what the game reads and writes); only the Metal texture changes:

- **Full upload** (`pkg_upload_` in `nvn_mtl.m`): deswizzled on the CPU (the GPU deswizzle only produces BC blocks), decoded, encoded, and copied level by level. The staging size is the ASTC one: 16 bytes per 4x4 block, so a BC1 or BC4 texture takes twice the memory (BC2, BC3, BC5 and BC7 the same). BC4 and BC5 are decoded to (r, 0, 0, 1) and (r, g, 0, 1) and encoded as plain RGBA, so they need no texture swizzle; a normal map in BC5 is encoded with astcenc's default error metric, not its normal-map mode (open: a better encoding would need a swizzle on the view).
- **Buffer → texture copy** (`copy_b2t`): the source bytes are transcoded on the CPU at replay into a staging area. A source the GPU writes cannot be read then: the copy is skipped with a red line (open).
- **Not done yet (stage 4, red lines say so):** texture → buffer copies and CPU readbacks of such a texture whose content is not in storage (they would return ASTC blocks; the copy is skipped, the readback returns zeros), the storage mirror of GPU copies into them (skipped, logged), BC6H (still BC), render targets in transcoded BC textures (below), and the cost: the encode runs on the submit thread at upload, which waits for it.
- **Encode threads** (`DM_NVN_BC_ASTC_THREADS`): an image of 128×128 or more is encoded by up to 6 threads together (astcenc's own work sharing, same bytes as one thread; 2.1× on two cores, 2048×2048 BC7 of random blocks, the worst case: 6.5 s → 3.1 s). Only one large image uses the shared encoders at a time; a second one meanwhile, and every small one, is encoded by the calling thread alone. Still on the submit thread, so the game waits: moving it off (stage 5b) and the on-disk cache (5c) are open.

- **Render targets in a transcoded texture: not working** (open, stage 4). The shadow that lets a game draw into a BC texture (`bcrt_attach`) is made for Metal BC pixel formats, so an ASTC host texture is "not attached: draws to this attachment are lost" (red line 78). This hit Tears of the Kingdom's BC render targets with BC1 / BC2 / BC3 / BC7, and now Breath of the Wild's 32×32 BC4 one. The GPU writes BC blocks there that the host texture, being ASTC, cannot hold. `DM_NVN_BC_ASTC=0` restores both on a device with BC support.

The rest of this section is about BC kept as BC (BC6H, and everything with the transcode off).

BC6H is not transcoded on purpose (Library of Ruina does not use it). On a GPU without BC (`nvn_fmt_bc_native(0)`, set by `mtl_init`) BC6H, and every BC format when the transcode is off, has no Metal counterpart: `nvn_fmt_to_mtl` returns 0 and the texture is refused with a red line. On a GPU with BC it stays BC.


A GPU without BC compressed textures (`supportsBCTextureCompression` of `MTLDevice` false: the A16 and older iPhones) is no longer refused at start: the transcode above covers the formats, and the BC formats it does not cover (BC6H) are refused as textures ([GPUs without BC textures use the ASTC transcode](../../../docs/reference/rendering.md#gpus-without-bc-textures-use-the-astc-transcode)). With the transcode off, BC textures are created and uploaded as BC. A BC texture is never a render target and its raw blocks are not sampled through an uncompressed view (Metal has no such views; Breath of the Wild encodes one 32×32 BC4 texture on the GPU, GitHub issue #4).

## Tests

```sh
make -C dm/gfx/tex/tests run       # run t_fmt_mtl and t_tex
```

- **`t_fmt_mtl`**: takes the mapping for every NVN format in 0x01–0x9C and, for every one whose mapping is not 0, actually creates a texture on the local Metal device; all of them must be created successfully. It also checks that every NVN format with sRGB in its name lands on a Metal sRGB format. No game files needed.
- **`t_fmt_bc`**: the BC → ASTC mapping mode, without Metal: off leaves the table as it was, on moves exactly BC1 / BC2 / BC3 / BC7 and unsigned BC4 / BC5 to ASTC 4x4 (sRGB to sRGB, RGB_DXT1 keeps alpha reading 1) and signed BC4 / BC5 to R8Snorm / RG8Snorm, and every other format is unchanged. `t_fmt_mtl` runs its creation check for both modes.
- **`t_bc_astc`** (needs astcenc: `make run ASTCENC_DIR=<dir>`, `CXXLIB=-lstdc++` off macOS): every covered format through `nvn_bc_astc_image`, the result decoded with astcenc and compared with `bcn_decode` by PSNR (BC4 / BC5 also: the channels they lack stay 0 and 1), odd sizes, the switch, refusals (signed BC4 / BC5, BC6H), two threads, and large images with 1, 3 and 64 encoder threads, one at a time and four at once, which must give the single-thread bytes.
- **`t_bcn`**: decodes 1,024 pseudo-random blocks of each format (BC7 in all eight modes) and compares a hash of the pixels with one made by Pillow's decoder (`tests/bcn_ref.py` prints the expected hashes; it needs Pillow), plus hand-made blocks (BC1 three-colour mode, BC2 alpha, BC4 modes) and cropping of sizes that are not a multiple of 4.
- **`t_tex`**: the deswizzling tests, in several groups:

  | Group | Criterion |
  |---|---|
  | A round trip | Writes random data into each level and layer and reads it back out; must be byte-for-byte equal. Covers 2D, 2D array and 3D, several bytes-per-block values and non-power-of-two sizes |
  | B address formula | The result of `nvn_bl_offset()` equals the address computed by hand from the public layout rules |
  | D differential copies | Both copy directions match a byte-address oracle for 1,029 deterministic layouts, including padded pitches, byte tails, sparse mip tails, packaged block dimensions, arrays and cubes; untouched storage and row padding are compared too |
  | E hand-made 3D | Places markers at hand-computed addresses, checks where they land after deswizzling, and checks block height, block depth and storage size |

  The A round trip can only prove "one-to-one and within bounds"; it cannot prove that the layout formula is right. What backs it up is the hand-computed addresses of groups B and E, and the games that render right.

## Limitations

- `nvn_deswizzle()` does not support multisampled textures, textures with the LINEAR flag (which are linear to begin with) or the BUFFER target; it returns -1 when it encounters them.
- Cubes and cube arrays are handled as layered textures.
- The component bit order of the 16-bit packed formats (565 / 5551 / 4444) is mapped according to the format names and has not been checked with real data; they are marked as "substitute" in the format table.

## On-disk cache of transcoded textures (`astc_cache.c`)

The ASTC bytes of every transcoded image of 64×64 and up are kept in a folder (`<DM_TEMP>_astc`, `DM_NVN_BC_ASTC_CACHE`, capped by `DM_NVN_BC_ASTC_CACHE_MB`), named by a hash of the NVN format, size and BC bytes and of a salt (this file format, astcenc tag, quality). The next launch finds them instead of encoding. A file that is damaged, cut, foreign or of another salt is a miss. Test: `t_astc_cache` (`make run`), which also builds `nvn_bc_astc.c` against `tests/fake_astc_enc.c`, so it runs without astcenc.
