// Mod "post-effects", host half: brings back the bloom the Switch version leaves out, and logs which of the game's bloom sources are alive.
// The game has five: the v1 camera stack (UnityEngine.PostProcessing.PostProcessingBehaviour, BloomModel), the v2 stack (UnityEngine.Rendering.PostProcessing.PostProcessLayer, Bloom settings), the KriptoFX
// effects Bloom_RFX4 and RFX4_DistortionAndBloom, and CameraFilterPack_Blur_Bloom. The shaders of all of them are in the Switch build, so what the Switch build leaves out is data (which components its cameras carry, their settings).
//   bloom_pre     PostProcessingBehaviour.OnPreCull, before mov x19,x0 (x0 = the behaviour): profile = *(this+0x18), bloom model = *(profile+0x58); a disabled model gets m_Enabled = 1 and the v1 settings below,
//                 an enabled one gets them too while DM_POSTFX_V1_FORCE is 1 (the default; the game's own values, intensity 0.25 and threshold 1.0, bloom next to nothing on a camera that is not HDR), else only an intensity <= 0 is replaced;
//                 the first hit of every behaviour is logged with the model's values before the change, with its camera and the frame; DM_POSTFX_V1=0 keeps this log and changes nothing
//   bloom2_force  Bloom.IsEnabledAndSupported, at its entry (x0 = the Bloom settings blended for this camera): when `enabled` is false or intensity <= 0, enabled = true and the v2 settings below are set
//   probe         the entry of the other bloom sources (param: 1 v1 OnEnable, 3 v2 layer OnEnable, 4 v2 layer OnPreCull, 5 Bloom_RFX4.OnRenderImage, 6 RFX4_DistortionAndBloom.LateUpdate,
//                 7 CameraFilterPack_Blur_Bloom.OnRenderImage, 8 UIController.SetBloomeIntensity, 9 Bloom_RFX4.OnEnable,
//                 10 CamFilterController.SetFilter, 11 CamFilterController.BloomRoutine, 12 CamFilterController.BloomAndPillarOfLightRoutine,
//                 13 PostProcessingBehaviour.OnDisable, 14 PostProcessingBehaviour.OnRenderImage): logs the first hit with the object's bloom settings, then hit 10, 100, 1000 ...;
//                 params 1, 3, 9, 10, 11, 12 and 13 (calls that happen once per scene or filter change) log every hit, with the frame number;
//                 param 14 logs the first render of each v1 behaviour, then every power of ten ... (is it ever rendered, and through which camera)
// Documents/env.txt can change the values: v1 DM_POSTFX_BLOOM_INTENSITY (0.8), _THRESHOLD (0.6), _KNEE (0.5), _RADIUS (5.0), _ANTIFLICKER (0), DM_POSTFX_V1_FORCE (1); v2 DM_POSTFX_V2_INTENSITY (1.0), _THRESHOLD (1.0), _KNEE (0.5),
//   _DIFFUSION (7.0), _CLAMP (65472.0); DM_POSTFX_V1=0 / DM_POSTFX_V2=0 turn one of the two forces off.
// Off by default: DM_MOD_POSTEFFECTS=1 turns the callbacks on (the launcher's Mods > Post Effects switch, or env.txt). The gates are always in the code and pass through while it is off.
#include "dm.h"
#include "hle_mods_gen.h"

#define F_PPB_PROFILE 0x18
#define F_PPB_CAMERA 0x58
#define F_PROFILE_BLOOM 0x58
#define F_MODEL_ENABLED 0x10
#define F_V1_INTENSITY 0x18
#define F_V1_THRESHOLD 0x1C
#define F_V1_KNEE 0x20
#define F_V1_RADIUS 0x24
#define F_V1_ANTIFLICKER 0x28

#define F_V2_ENABLED 0x20
#define F_V2_INTENSITY 0x30
#define F_V2_THRESHOLD 0x38
#define F_V2_KNEE 0x40
#define F_V2_CLAMP 0x48
#define F_V2_DIFFUSION 0x50
#define P_OVERRIDE 0x10
#define P_FLOAT 0x14
#define P_BOOL 0x11

#define F_UICONTROLLER_PPBLOOM 0x1E0

#define F_CFC_BLOOMFILTER 0x20
#define F_CFC_POSTPROCESSOR 0x98
#define F_STRING_LENGTH 0x10
#define F_STRING_CHARS 0x14

static float s_v1_intensity = 0.8f, s_v1_threshold = 0.6f, s_v1_knee = 0.5f, s_v1_radius = 5.0f;
static uint8_t s_v1_antiflicker;
static float s_v2_intensity = 1.0f, s_v2_threshold = 1.0f, s_v2_knee = 0.5f, s_v2_diffusion = 7.0f, s_v2_clamp = 65472.0f;
static int s_v1_on = 1, s_v2_on = 1, s_v1_force = 1;

static float env_float(const char *name, float def) {
    const char *v = getenv(name);
    if (!v || !v[0]) return def;
    char *end;
    float f = strtof(v, &end);
    return end == v ? def : f;
}

static int mod_enabled(void) {
    static int on = -1;
    if (on < 0) {
        const char *v = getenv("DM_MOD_POSTEFFECTS");
        on = v && v[0] == '1';
        s_v1_intensity = env_float("DM_POSTFX_BLOOM_INTENSITY", s_v1_intensity);
        s_v1_threshold = env_float("DM_POSTFX_BLOOM_THRESHOLD", s_v1_threshold);
        s_v1_knee = env_float("DM_POSTFX_BLOOM_KNEE", s_v1_knee);
        s_v1_radius = env_float("DM_POSTFX_BLOOM_RADIUS", s_v1_radius);
        s_v1_antiflicker = (uint8_t)(env_float("DM_POSTFX_BLOOM_ANTIFLICKER", 0) != 0);
        s_v2_intensity = env_float("DM_POSTFX_V2_INTENSITY", s_v2_intensity);
        s_v2_threshold = env_float("DM_POSTFX_V2_THRESHOLD", s_v2_threshold);
        s_v2_knee = env_float("DM_POSTFX_V2_KNEE", s_v2_knee);
        s_v2_diffusion = env_float("DM_POSTFX_V2_DIFFUSION", s_v2_diffusion);
        s_v2_clamp = env_float("DM_POSTFX_V2_CLAMP", s_v2_clamp);
        s_v1_on = env_float("DM_POSTFX_V1", 1) != 0;
        s_v2_on = env_float("DM_POSTFX_V2", 1) != 0;
        s_v1_force = env_float("DM_POSTFX_V1_FORCE", 1) != 0;
        LOG("[mod post-effects] %s (DM_MOD_POSTEFFECTS=%s) v1 %s%s (intensity %.2f threshold %.2f knee %.2f radius %.2f) v2 %s (intensity %.2f threshold %.2f knee %.2f diffusion %.1f clamp %.0f)",
            on ? "on" : "off", v ? v : "unset", s_v1_on ? "on" : "off", s_v1_force ? " forced" : "", s_v1_intensity, s_v1_threshold, s_v1_knee, s_v1_radius,
            s_v2_on ? "on" : "off", s_v2_intensity, s_v2_threshold, s_v2_knee, s_v2_diffusion, s_v2_clamp);
    }
    return on;
}

static int mod_log_hit(int *count) {
    int n = ++*count;
    if (n == 1) return 1;
    for (int p = 10; p <= 1000000; p *= 10)
        if (n == p) return 1;
    return 0;
}

static float f32(const uint8_t *base, int off) { return *(const float *)(base + off); }
static const uint8_t *ptr(const uint8_t *base, int off) { return *(const uint8_t *const *)(base + off); }

static void string_ascii(const uint8_t *str, char *out, int cap) {
    int n = 0;
    if (!str) {
        snprintf(out, (size_t)cap, "(null)");
        return;
    }
    int len = *(const int *)(str + F_STRING_LENGTH);
    const uint16_t *c = (const uint16_t *)(str + F_STRING_CHARS);
    if (len < 0 || len > 1024) {
        snprintf(out, (size_t)cap, "(bad length %d)", len);
        return;
    }
    for (int i = 0; i < len && n < cap - 1; i++)
        out[n++] = c[i] >= 0x20 && c[i] < 0x7F ? (char)c[i] : '?';
    out[n] = 0;
}

static void on_bloom_pre(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled()) return;
    const uint8_t *ppb = (const uint8_t *)(uintptr_t)r[0];
    if (!ppb) return;
    const uint8_t *profile = ptr(ppb, F_PPB_PROFILE);
    if (!profile) return;
    uint8_t *bloom = (uint8_t *)ptr(profile, F_PROFILE_BLOOM);
    static int hits;
    static const uint8_t *seen[64];
    static int nseen;
    int log_it = mod_log_hit(&hits);
    int is_new = 1;
    for (int i = 0; i < nseen; i++)
        if (seen[i] == ppb) is_new = 0;
    if (is_new && nseen < 64) seen[nseen++] = ppb;
    else is_new = 0;
    if (!bloom) {
        if (log_it || is_new) LOG("[mod post-effects] v1 OnPreCull #%d: behaviour %p profile %p has no bloom model", hits, (const void *)ppb, (const void *)profile);
        return;
    }
    uint8_t was_on = bloom[F_MODEL_ENABLED];
    float was_i = f32(bloom, F_V1_INTENSITY);
    float was_t = f32(bloom, F_V1_THRESHOLD);
    if (is_new)
        LOG("[mod post-effects] v1 behaviour #%d first seen at OnPreCull #%d frame %llu: %p camera %p profile %p bloom model %p enabled %d intensity %.3f threshold %.3f knee %.3f radius %.3f antiflicker %d",
            nseen, hits, (unsigned long long)dm_nvn_frame_count(), (const void *)ppb, (const void *)ptr(ppb, F_PPB_CAMERA), (const void *)profile, (void *)bloom, was_on, was_i, was_t, f32(bloom, F_V1_KNEE), f32(bloom, F_V1_RADIUS), bloom[F_V1_ANTIFLICKER]);
    if (!s_v1_on) return;
    if (!was_on || s_v1_force) {
        *(float *)(bloom + F_V1_INTENSITY) = s_v1_intensity;
        *(float *)(bloom + F_V1_THRESHOLD) = s_v1_threshold;
        *(float *)(bloom + F_V1_KNEE) = s_v1_knee;
        *(float *)(bloom + F_V1_RADIUS) = s_v1_radius;
        bloom[F_V1_ANTIFLICKER] = s_v1_antiflicker;
        bloom[F_MODEL_ENABLED] = 1;
    } else if (!(was_i > 0.0f)) {
        *(float *)(bloom + F_V1_INTENSITY) = s_v1_intensity;
    }
    if (log_it)
        LOG("[mod post-effects] v1 OnPreCull #%d: bloom model %p (profile %p) enabled %d intensity %.3f threshold %.3f -> enabled %d intensity %.3f",
            hits, (void *)bloom, (const void *)profile, was_on, was_i, was_t, bloom[F_MODEL_ENABLED], f32(bloom, F_V1_INTENSITY));
}

static void set_float_param(uint8_t *settings, int field, float v) {
    uint8_t *prm = (uint8_t *)ptr(settings, field);
    if (!prm) return;
    prm[P_OVERRIDE] = 1;
    *(float *)(prm + P_FLOAT) = v;
}

static void on_bloom2_force(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled() || !s_v2_on) return;
    uint8_t *bloom = (uint8_t *)(uintptr_t)r[0];
    if (!bloom) return;
    uint8_t *en = (uint8_t *)ptr(bloom, F_V2_ENABLED);
    const uint8_t *in = ptr(bloom, F_V2_INTENSITY);
    if (!en || !in) return;
    static int hits;
    int log_it = mod_log_hit(&hits);
    uint8_t was_on = en[P_BOOL];
    float was_i = f32(in, P_FLOAT);
    if (!was_on || !(was_i > 0.0f)) {
        en[P_OVERRIDE] = 1;
        en[P_BOOL] = 1;
        set_float_param(bloom, F_V2_INTENSITY, s_v2_intensity);
        set_float_param(bloom, F_V2_THRESHOLD, s_v2_threshold);
        set_float_param(bloom, F_V2_KNEE, s_v2_knee);
        set_float_param(bloom, F_V2_CLAMP, s_v2_clamp);
        set_float_param(bloom, F_V2_DIFFUSION, s_v2_diffusion);
    }
    if (log_it)
        LOG("[mod post-effects] v2 Bloom.IsEnabledAndSupported #%d: settings %p enabled %d intensity %.3f -> enabled %d intensity %.3f",
            hits, (void *)bloom, was_on, was_i, en[P_BOOL], f32(ptr(bloom, F_V2_INTENSITY), P_FLOAT));
}

static void on_probe(uint64_t *r, int p) {
    if (!mod_enabled()) return;
    static int hits[16];
    if (p < 0 || p >= 16) return;
    if (p == 1 || p == 3 || (p >= 9 && p <= 14)) hits[p]++;
    else if (!mod_log_hit(&hits[p])) return;
    const unsigned long long frame = (unsigned long long)dm_nvn_frame_count();
    const uint8_t *o = (const uint8_t *)(uintptr_t)r[0];
    int n = hits[p];
    switch (p) {
    case 1: {
        const uint8_t *prof = o ? ptr(o, F_PPB_PROFILE) : NULL;
        const uint8_t *bl = prof ? ptr(prof, F_PROFILE_BLOOM) : NULL;
        LOG("[mod post-effects] probe v1 PostProcessingBehaviour.OnEnable #%d frame %llu: %p camera %p profile %p bloom model %p enabled %d intensity %.3f threshold %.3f knee %.3f radius %.3f", n, frame, (const void *)o,
            o ? (const void *)ptr(o, F_PPB_CAMERA) : NULL, (const void *)prof, (const void *)bl, bl ? bl[F_MODEL_ENABLED] : -1, bl ? f32(bl, F_V1_INTENSITY) : -1.0f,
            bl ? f32(bl, F_V1_THRESHOLD) : -1.0f, bl ? f32(bl, F_V1_KNEE) : -1.0f, bl ? f32(bl, F_V1_RADIUS) : -1.0f);
        break; }
    case 3:
        LOG("[mod post-effects] probe v2 PostProcessLayer.OnEnable #%d frame %llu: %p volumeLayer 0x%x antialiasing %d", n, frame, (const void *)o, o ? *(const uint32_t *)(o + 0x20) : 0, o ? *(const int *)(o + 0x28) : -1);
        break;
    case 4:
        LOG("[mod post-effects] probe v2 PostProcessLayer.OnPreCull #%d: %p volumeLayer 0x%x", n, (const void *)o, o ? *(const uint32_t *)(o + 0x20) : 0);
        break;
    case 5:
        LOG("[mod post-effects] probe Bloom_RFX4.OnRenderImage #%d: %p threshold %.3f knee %.3f radius %.3f intensity %.3f", n, (const void *)o, o ? f32(o, 0x18) : -1.0f, o ? f32(o, 0x1C) : -1.0f,
            o ? f32(o, 0x20) : -1.0f, o ? f32(o, 0x24) : -1.0f);
        break;
    case 6:
        LOG("[mod post-effects] probe RFX4_DistortionAndBloom.LateUpdate #%d: %p UseBloom %d threshold %.3f knee %.3f radius %.3f intensity %.3f", n, (const void *)o, o ? o[0x1C] : -1, o ? f32(o, 0x20) : -1.0f,
            o ? f32(o, 0x24) : -1.0f, o ? f32(o, 0x28) : -1.0f, o ? f32(o, 0x2C) : -1.0f);
        break;
    case 7:
        LOG("[mod post-effects] probe CameraFilterPack_Blur_Bloom.OnRenderImage #%d: %p amount %.3f glow %.3f", n, (const void *)o, o ? f32(o, 0x30) : -1.0f, o ? f32(o, 0x34) : -1.0f);
        break;
    case 8: {
        const uint8_t *b = o ? ptr(o, F_UICONTROLLER_PPBLOOM) : NULL;
        const uint8_t *en = b ? ptr(b, F_V2_ENABLED) : NULL;
        const uint8_t *in = b ? ptr(b, F_V2_INTENSITY) : NULL;
        LOG("[mod post-effects] probe UIController.SetBloomeIntensity #%d: %p pp_bloom %p enabled %d intensity %.3f", n, (const void *)o, (const void *)b, en ? en[P_BOOL] : -1, in ? f32(in, P_FLOAT) : -1.0f);
        break; }
    case 9:
        LOG("[mod post-effects] probe Bloom_RFX4.OnEnable #%d frame %llu: %p", n, frame, (const void *)o);
        break;
    case 10: {
        char id[64];
        string_ascii((const uint8_t *)(uintptr_t)r[1], id, sizeof id);
        const uint8_t *pp = o ? ptr(o, F_CFC_POSTPROCESSOR) : NULL;
        const uint8_t *prof = pp ? ptr(pp, F_PPB_PROFILE) : NULL;
        const uint8_t *bl = prof ? ptr(prof, F_PROFILE_BLOOM) : NULL;
        const uint8_t *bf = o ? ptr(o, F_CFC_BLOOMFILTER) : NULL;
        LOG("[mod post-effects] probe CamFilterController.SetFilter #%d frame %llu: controller %p filter \"%s\" postProcessor %p v1 bloom model %p enabled %d intensity %.3f bloomFilter %p amount %.3f glow %.3f",
            n, frame, (const void *)o, id, (const void *)pp, (const void *)bl, bl ? bl[F_MODEL_ENABLED] : -1, bl ? f32(bl, F_V1_INTENSITY) : -1.0f,
            (const void *)bf, bf ? f32(bf, 0x30) : -1.0f, bf ? f32(bf, 0x34) : -1.0f);
        break; }
    case 13: {
        const uint8_t *prof = o ? ptr(o, F_PPB_PROFILE) : NULL;
        const uint8_t *bl = prof ? ptr(prof, F_PROFILE_BLOOM) : NULL;
        LOG("[mod post-effects] probe v1 PostProcessingBehaviour.OnDisable #%d frame %llu: %p camera %p profile %p bloom model %p enabled %d intensity %.3f", n, frame, (const void *)o,
            o ? (const void *)ptr(o, F_PPB_CAMERA) : NULL, (const void *)prof, (const void *)bl, bl ? bl[F_MODEL_ENABLED] : -1, bl ? f32(bl, F_V1_INTENSITY) : -1.0f);
        break; }
    case 14: {
        static const uint8_t *seen[64];
        static int count[64];
        static int nseen;
        int k = 0;
        for (; k < nseen; k++)
            if (seen[k] == o) break;
        if (k == nseen) {
            if (nseen >= 64) break;
            seen[nseen++] = o;
        }
        int c = ++count[k];
        int log_it = c == 1;
        for (int q = 100; q <= 1000000; q *= 10)
            if (c == q) log_it = 1;
        if (log_it)
            LOG("[mod post-effects] probe v1 PostProcessingBehaviour.OnRenderImage behaviour %p (#%d) camera %p frame %llu: render #%d", (const void *)o, k + 1, o ? (const void *)ptr(o, F_PPB_CAMERA) : NULL, frame, c);
        break; }
    case 11:
    case 12:
        LOG("[mod post-effects] probe CamFilterController.%s #%d frame %llu: controller %p postProcessor %p bloomFilter %p", p == 11 ? "BloomRoutine" : "BloomAndPillarOfLightRoutine", n, frame,
            (const void *)o, o ? (const void *)ptr(o, F_CFC_POSTPROCESSOR) : NULL, o ? (const void *)ptr(o, F_CFC_BLOOMFILTER) : NULL);
        break;
    default:
        break;
    }
}

__attribute__((constructor)) static void mod_post_effects_attach(void) {
    gate_obs_set(MODGATE_POST_EFFECTS_BLOOM_PRE, on_bloom_pre);
    gate_obs_set(MODGATE_POST_EFFECTS_BLOOM2_FORCE, on_bloom2_force);
    gate_obs_set(MODGATE_POST_EFFECTS_PROBE, on_probe);
    LOG("[mod post-effects] callbacks attached");
}
