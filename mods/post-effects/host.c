// Mod "post-effects", host half: the camera post-processing bloom of the PC version, switched back on in the Switch version.
// The game's cameras carry UnityEngine.PostProcessing.PostProcessingBehaviour (the v1 stack, stock code: BloomComponent.active is model.enabled && settings.bloom.intensity > 0 && !context.interrupted),
// so the Switch build's missing bloom is in the data (the profile's bloom model), not in the code. This callback fixes the data before the behaviour looks at it:
//   bloom_pre  PostProcessingBehaviour.OnPreCull, before mov x19,x0 (x0 = the behaviour): profile = *(this+0x18), bloom = *(profile+0x58). A bloom model that is disabled gets m_Enabled = 1 and the settings below;
//              an enabled one with intensity <= 0 gets the intensity only. An enabled model with intensity above 0 is left as the game has it.
// Settings (BloomModel.Settings at +0x18, BloomSettings first): intensity +0x18, threshold +0x1C, softKnee +0x20, radius +0x24, antiFlicker +0x28. Defaults are Unity's BloomModel defaults; Documents/env.txt can change them:
//   DM_POSTFX_BLOOM_INTENSITY (0.5), DM_POSTFX_BLOOM_THRESHOLD (1.1), DM_POSTFX_BLOOM_KNEE (0.5), DM_POSTFX_BLOOM_RADIUS (4.0), DM_POSTFX_BLOOM_ANTIFLICKER (0)
// The first distinct bloom models seen are logged with their state before and after ("[mod post-effects] ..."): when the game shows no bloom with the mod on, that line says what the profile held.
// Off by default: DM_MOD_POSTEFFECTS=1 turns the callback on (the launcher's Mods > Post Effects switch, or env.txt). The gate is always in the code and passes through while it is off.
#include "dm.h"
#include "hle_mods_gen.h"

#define F_PPB_PROFILE 0x18      // PostProcessingBehaviour.profile
#define F_PROFILE_BLOOM 0x58    // PostProcessingProfile.bloom
#define F_MODEL_ENABLED 0x10    // PostProcessingModel.m_Enabled (bool)
#define F_BLOOM_INTENSITY 0x18  // BloomModel.m_Settings.bloom.intensity
#define F_BLOOM_THRESHOLD 0x1C
#define F_BLOOM_KNEE 0x20
#define F_BLOOM_RADIUS 0x24
#define F_BLOOM_ANTIFLICKER 0x28

#define MAX_LOGGED 6

static float s_intensity = 0.5f, s_threshold = 1.1f, s_knee = 0.5f, s_radius = 4.0f;
static uint8_t s_antiflicker;
static const uint8_t *s_logged[MAX_LOGGED];
static int s_nlogged;

static float env_float(const char *name, float def) {
    const char *v = getenv(name);
    if (!v || !v[0]) return def;
    char *end;
    float f = strtof(v, &end);
    return end == v ? def : f;
}

// Read once, at the first gate hit: the launcher's choices are in the environment by then, but not yet when constructors run
static int mod_enabled(void) {
    static int on = -1;
    if (on < 0) {
        const char *v = getenv("DM_MOD_POSTEFFECTS");
        on = v && v[0] == '1';
        s_intensity = env_float("DM_POSTFX_BLOOM_INTENSITY", s_intensity);
        s_threshold = env_float("DM_POSTFX_BLOOM_THRESHOLD", s_threshold);
        s_knee = env_float("DM_POSTFX_BLOOM_KNEE", s_knee);
        s_radius = env_float("DM_POSTFX_BLOOM_RADIUS", s_radius);
        s_antiflicker = (uint8_t)(env_float("DM_POSTFX_BLOOM_ANTIFLICKER", 0) != 0);
        LOG("[mod post-effects] %s (DM_MOD_POSTEFFECTS=%s) bloom intensity %.2f threshold %.2f knee %.2f radius %.2f antiflicker %d",
            on ? "on" : "off", v ? v : "unset", s_intensity, s_threshold, s_knee, s_radius, s_antiflicker);
    }
    return on;
}

static int first_sight(const uint8_t *bloom) {
    for (int i = 0; i < s_nlogged; i++)
        if (s_logged[i] == bloom) return 0;
    if (s_nlogged >= MAX_LOGGED) return 0;
    s_logged[s_nlogged++] = bloom;
    return 1;
}

static void on_bloom_pre(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled()) return;
    const uint8_t *ppb = (const uint8_t *)(uintptr_t)r[0];
    if (!ppb) return;
    const uint8_t *profile = *(const uint8_t *const *)(ppb + F_PPB_PROFILE);
    if (!profile) return;
    uint8_t *bloom = *(uint8_t *const *)(profile + F_PROFILE_BLOOM);
    if (!bloom) {
        static int warned;
        if (!warned++) LOG("[mod post-effects] profile %p has no bloom model", (const void *)profile);
        return;
    }
    int log_it = first_sight(bloom);
    uint8_t was_on = bloom[F_MODEL_ENABLED];
    float was_i = *(float *)(bloom + F_BLOOM_INTENSITY);
    if (!was_on) {
        *(float *)(bloom + F_BLOOM_INTENSITY) = s_intensity;
        *(float *)(bloom + F_BLOOM_THRESHOLD) = s_threshold;
        *(float *)(bloom + F_BLOOM_KNEE) = s_knee;
        *(float *)(bloom + F_BLOOM_RADIUS) = s_radius;
        bloom[F_BLOOM_ANTIFLICKER] = s_antiflicker;
        bloom[F_MODEL_ENABLED] = 1;
    } else if (!(was_i > 0.0f)) {
        *(float *)(bloom + F_BLOOM_INTENSITY) = s_intensity;
    }
    if (log_it)
        LOG("[mod post-effects] bloom model %p (profile %p): enabled %d intensity %.3f threshold %.3f knee %.3f radius %.3f -> enabled %d intensity %.3f",
            (void *)bloom, (const void *)profile, was_on, was_i, *(float *)(bloom + F_BLOOM_THRESHOLD), *(float *)(bloom + F_BLOOM_KNEE),
            *(float *)(bloom + F_BLOOM_RADIUS), bloom[F_MODEL_ENABLED], *(float *)(bloom + F_BLOOM_INTENSITY));
}

__attribute__((constructor)) static void mod_post_effects_attach(void) {
    gate_obs_set(MODGATE_POST_EFFECTS_BLOOM_PRE, on_bloom_pre);
}
