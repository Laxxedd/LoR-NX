// Mod "post-effects", host half: brings back the bloom the Switch version leaves out, and logs which of the game's bloom sources are alive.
// The game has five: the v1 camera stack (UnityEngine.PostProcessing.PostProcessingBehaviour, BloomModel), the v2 stack (UnityEngine.Rendering.PostProcessing.PostProcessLayer, Bloom settings), the KriptoFX
// effects Bloom_RFX4 and RFX4_DistortionAndBloom, and CameraFilterPack_Blur_Bloom. The shaders of all of them are in the Switch build, so what the Switch build leaves out is data (which components its cameras carry, their settings).
//   bloom_pre     PostProcessingBehaviour.OnPreCull, before mov x19,x0 (x0 = the behaviour): profile = *(this+0x18), bloom model = *(profile+0x58); a disabled model gets m_Enabled = 1 and the v1 settings below,
//                 an enabled one at intensity <= 0 gets the intensity only
//   bloom2_force  Bloom.IsEnabledAndSupported, at its entry (x0 = the Bloom settings blended for this camera): when `enabled` is false or intensity <= 0, enabled = true and the v2 settings below are set
//   story_filter  OptionDataModel.GetStoryFilterOn, at its entry (x0 = the options): storyFilterOn (+0x40) is set to 1. CamFilterController.SetFilter, which every story and battle filter goes through (bloom, rain,
//                 blood, shake ...), returns at once unless that value is 1, and a save has it 0 unless the Story Filter dropdown of the options was set
//   probe         the entry of the other bloom sources (param: 1 v1 OnEnable, 3 v2 layer OnEnable, 4 v2 layer OnPreCull, 5 Bloom_RFX4.OnRenderImage, 6 RFX4_DistortionAndBloom.LateUpdate,
//                 7 CameraFilterPack_Blur_Bloom.OnRenderImage, 8 UIController.SetBloomeIntensity, 9 Bloom_RFX4.OnEnable): logs the first hit with the object's bloom settings, then hit 10, 100, 1000 ...
// Documents/env.txt can change the values: v1 DM_POSTFX_BLOOM_INTENSITY (0.5), _THRESHOLD (1.1), _KNEE (0.5), _RADIUS (4.0), _ANTIFLICKER (0); v2 DM_POSTFX_V2_INTENSITY (1.0), _THRESHOLD (1.0), _KNEE (0.5),
//   _DIFFUSION (7.0), _CLAMP (65472.0); DM_POSTFX_V1=0 / DM_POSTFX_V2=0 turn one of the two forces off, DM_POSTFX_STORYFILTER=0 the story filter force.
// Off by default: DM_MOD_POSTEFFECTS=1 turns the callbacks on (the launcher's Mods > Post Effects switch, or env.txt). The gates are always in the code and pass through while it is off.
#include "dm.h"
#include "hle_mods_gen.h"

#define F_PPB_PROFILE 0x18
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
#define F_OPTION_STORYFILTER 0x40

static float s_v1_intensity = 0.5f, s_v1_threshold = 1.1f, s_v1_knee = 0.5f, s_v1_radius = 4.0f;
static uint8_t s_v1_antiflicker;
static float s_v2_intensity = 1.0f, s_v2_threshold = 1.0f, s_v2_knee = 0.5f, s_v2_diffusion = 7.0f, s_v2_clamp = 65472.0f;
static int s_v1_on = 1, s_v2_on = 1, s_storyfilter_on = 1;

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
        s_storyfilter_on = env_float("DM_POSTFX_STORYFILTER", 1) != 0;
        LOG("[mod post-effects] %s (DM_MOD_POSTEFFECTS=%s) v1 %s (intensity %.2f threshold %.2f knee %.2f radius %.2f) v2 %s (intensity %.2f threshold %.2f knee %.2f diffusion %.1f clamp %.0f) story filter force %s",
            on ? "on" : "off", v ? v : "unset", s_v1_on ? "on" : "off", s_v1_intensity, s_v1_threshold, s_v1_knee, s_v1_radius,
            s_v2_on ? "on" : "off", s_v2_intensity, s_v2_threshold, s_v2_knee, s_v2_diffusion, s_v2_clamp, s_storyfilter_on ? "on" : "off");
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

static void on_bloom_pre(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled() || !s_v1_on) return;
    const uint8_t *ppb = (const uint8_t *)(uintptr_t)r[0];
    if (!ppb) return;
    const uint8_t *profile = ptr(ppb, F_PPB_PROFILE);
    if (!profile) return;
    uint8_t *bloom = (uint8_t *)ptr(profile, F_PROFILE_BLOOM);
    static int hits;
    int log_it = mod_log_hit(&hits);
    if (!bloom) {
        if (log_it) LOG("[mod post-effects] v1 OnPreCull #%d: profile %p has no bloom model", hits, (const void *)profile);
        return;
    }
    uint8_t was_on = bloom[F_MODEL_ENABLED];
    float was_i = f32(bloom, F_V1_INTENSITY);
    if (!was_on) {
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
            hits, (void *)bloom, (const void *)profile, was_on, was_i, f32(bloom, F_V1_THRESHOLD), bloom[F_MODEL_ENABLED], f32(bloom, F_V1_INTENSITY));
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

static void on_story_filter(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled() || !s_storyfilter_on) return;
    uint8_t *opt = (uint8_t *)(uintptr_t)r[0];
    if (!opt) return;
    int32_t *flag = (int32_t *)(opt + F_OPTION_STORYFILTER);
    static int hits;
    int log_it = mod_log_hit(&hits);
    int32_t was = *flag;
    if (was != 1) *flag = 1;
    if (log_it) LOG("[mod post-effects] OptionDataModel.GetStoryFilterOn #%d: options %p storyFilterOn %d -> %d", hits, (void *)opt, was, *flag);
}

static void on_probe(uint64_t *r, int p) {
    if (!mod_enabled()) return;
    static int hits[16];
    if (p < 0 || p >= 16) return;
    if (!mod_log_hit(&hits[p])) return;
    const uint8_t *o = (const uint8_t *)(uintptr_t)r[0];
    int n = hits[p];
    switch (p) {
    case 1: {
        const uint8_t *prof = o ? ptr(o, F_PPB_PROFILE) : NULL;
        const uint8_t *bl = prof ? ptr(prof, F_PROFILE_BLOOM) : NULL;
        LOG("[mod post-effects] probe v1 PostProcessingBehaviour.OnEnable #%d: %p profile %p bloom model %p enabled %d intensity %.3f", n, (const void *)o, (const void *)prof, (const void *)bl,
            bl ? bl[F_MODEL_ENABLED] : -1, bl ? f32(bl, F_V1_INTENSITY) : -1.0f);
        break; }
    case 3:
        LOG("[mod post-effects] probe v2 PostProcessLayer.OnEnable #%d: %p volumeLayer 0x%x antialiasing %d", n, (const void *)o, o ? *(const uint32_t *)(o + 0x20) : 0, o ? *(const int *)(o + 0x28) : -1);
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
        LOG("[mod post-effects] probe Bloom_RFX4.OnEnable #%d: %p", n, (const void *)o);
        break;
    default:
        break;
    }
}

__attribute__((constructor)) static void mod_post_effects_attach(void) {
    gate_obs_set(MODGATE_POST_EFFECTS_BLOOM_PRE, on_bloom_pre);
    gate_obs_set(MODGATE_POST_EFFECTS_BLOOM2_FORCE, on_bloom2_force);
    gate_obs_set(MODGATE_POST_EFFECTS_STORY_FILTER, on_story_filter);
    gate_obs_set(MODGATE_POST_EFFECTS_PROBE, on_probe);
    LOG("[mod post-effects] callbacks attached");
}
