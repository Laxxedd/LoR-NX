// Mod "post-effects" (RestoreFX in the launcher), host half: brings back the bloom and depth of field the Switch version leaves out, and logs which of the game's bloom sources are alive.
// The game has five: the v1 camera stack (UnityEngine.PostProcessing.PostProcessingBehaviour, BloomModel), the v2 stack (UnityEngine.Rendering.PostProcessing.PostProcessLayer, Bloom settings), the KriptoFX
// effects Bloom_RFX4 and RFX4_DistortionAndBloom, and CameraFilterPack_Blur_Bloom. The shaders of all of them are in the Switch build, so what the Switch build leaves out is data (which components its cameras carry, their settings).
//   bloom_pre     PostProcessingBehaviour.OnPreCull, before mov x19,x0 (x0 = the behaviour): profile = *(this+0x18), bloom model = *(profile+0x58); a disabled model gets m_Enabled = 1 and the v1 settings below,
//                 an enabled one keeps the game's own values (the defaults below are the game's: intensity 0.25, threshold 1.0, knee 0.5, radius 7.0) and only an intensity <= 0 is replaced, unless DM_POSTFX_V1_FORCE is 1, which writes the values below into every v1 bloom model;
//                 the first hit of every behaviour is logged with the model's values before the change, with its camera and the frame; DM_POSTFX_V1=0 keeps this log and changes nothing
//   bloom2_force  Bloom.IsEnabledAndSupported, at its entry (x0 = the Bloom settings blended for this camera): with DM_POSTFX_V2=1 (off by default), when `enabled` is false or intensity <= 0, enabled = true and the v2 settings below are set
//   story_post    CamFilterController.SetFilter, the ldp just before its only return epilogue (x19 = the controller): the story camera's v1 stack (the controller's postProcessor, +0x98) is switched on when the call left it off.
//                 The game only switches it on for the "Paper" filter, so the stories that do not use it render without the v1 bloom (the 60% of stories without bloom); DM_POSTFX_STORY=0 turns this off
//   combat_keep   BattleCamManager.ResetCamSetting, the `mov x2, xzr` before each of its five `bl Behaviour.set_enabled(false)` calls (param 0-4: _bgCamTransform, _fgCamTransform, _mainCam, _characterCam, _effectCam; w1 = 0 is already set, x0 = the component
//                 found on that camera): when it is a PostProcessingBehaviour (v1 stack), the camera's bit is set in DM_POSTFX_COMBAT_MASK (default 25: _bgCamTransform, _characterCam and _effectCam; 31 is all five) and, with DM_POSTFX_V1=0, its bloom model is on (a behaviour with nothing to draw only costs a full-screen pass), w1 becomes 1, so the game's reset leaves the combat bloom behaviours enabled
//                 and bloom_pre then sets their bloom to DM_POSTFX_COMBAT_INTENSITY (0.25) and DM_POSTFX_COMBAT_THRESHOLD (0.6): the game's own threshold of 1.1 on these cameras cannot be exceeded without HDR, so no combat bloom shows with it;
//                 DM_POSTFX_COMBAT=0 turns this off; each behaviour it sees is remembered for combat_post
//   combat_post   BattleCamManager.ResetCamSetting, the ldp x20,x19 before its return (x19 = the manager): every behaviour combat_keep remembered that is still disabled is switched on, so the combat bloom does not depend on the argument write alone
//   ui_platform   the `cmp w8, #4` of the five `PlatformManager.PlatformType == NintentoSwitch` checks that keep the menu bloom off (param 0 UIController.CallUIPhase, 1 CallUIPhaseAsynchronous, 2 SetBloomeIntensity, 3 SetBloomThreshold, 4 SetBloomSoftKnee):
//                 w8 = the platform type; a 4 becomes 2 so the game fetches the Bloom of its UI PostProcessVolume (UIController.pp_bloom, never fetched on Switch) and sets its intensity, threshold and soft knee per UI phase as on PC;
//                 DM_POSTFX_UI=0 turns this off
//   cam_platform  the `cmp w8, #4` of the four battle camera Switch checks (param 0 BattleCamManager.BlurBackgroundCam, 1 BlurCharacterCam, 2 VignetteCharacterCam keep the PC-only blur and vignette off; param 3 ResetCamSetting makes the Switch build disable the camera behaviours of combat, which PC leaves enabled):
//                 w8 = the platform type; a 4 becomes 2 so the game switches the background camera's v1 behaviour and starts BlurRoutine (depth of field of the character camera) and VignetteRoutine as on PC; DM_POSTFX_CAMBLUR=0 turns params 0-2 off;
//                 param 3 (DM_POSTFX_COMBAT_PC, default 1, needs DM_POSTFX_COMBAT) skips the five Behaviour.set_enabled(false) calls as on PC, and while it is active bloom_pre leaves the combat bloom models as the game made them (neither the story values nor the combat values below are written) except that an enabled model's threshold above DM_POSTFX_COMBAT_MAXTHRESHOLD (0.9, the threshold the game itself uses on its one combat camera that blooms; 99 keeps the game's 1.1) is lowered to it; a CamFilterController.SetFilter (stories) ends it; DM_POSTFX_COMBAT_PC=0 gives the combat_keep path back
//   models        the first OnPreCull of every v1 behaviour logs which of its profile's models are on (fog, depthOfField, motionBlur, bloom, colorGrading, vignette ...) and the depthOfField settings;
//                 DM_POSTFX_DOF=1 switches the depthOfField model on for the combat behaviours combat_keep kept (default 0)
//   probe         the entry of the other bloom sources (param: 1 v1 OnEnable, 3 v2 layer OnEnable, 4 v2 layer OnPreCull, 5 Bloom_RFX4.OnRenderImage, 6 RFX4_DistortionAndBloom.LateUpdate,
//                 7 CameraFilterPack_Blur_Bloom.OnRenderImage, 8 UIController.SetBloomeIntensity, 9 Bloom_RFX4.OnEnable,
//                 10 CamFilterController.SetFilter, 11 CamFilterController.BloomRoutine, 12 CamFilterController.BloomAndPillarOfLightRoutine,
//                 13 PostProcessingBehaviour.OnDisable, 14 PostProcessingBehaviour.OnRenderImage): logs the first hit with the object's bloom settings, then hit 10, 100, 1000 ...;
//                 params 1, 3, 9, 10, 11, 12 and 13 (calls that happen once per scene or filter change) log every hit, with the frame number;
//                 param 14 logs the first render of each v1 behaviour, then every power of ten ... (is it ever rendered, and through which camera);
//                 params 1 and 13 also log the caller and a frame pointer backtrace (main+offset) for the first 8 calls on a behaviour that has no camera yet (m_Camera is set by its first OnPreCull)
// Documents/env.txt can change the values: v1 DM_POSTFX_BLOOM_INTENSITY (0.25), _THRESHOLD (1.0), _KNEE (0.5), _RADIUS (7.0), _ANTIFLICKER (0), DM_POSTFX_V1_FORCE (0); v2 DM_POSTFX_V2_INTENSITY (1.0), _THRESHOLD (1.0), _KNEE (0.5),
//   _DIFFUSION (7.0), _CLAMP (65472.0); DM_POSTFX_V1=0 turns the v1 force off, DM_POSTFX_V2=1 turns the v2 force on, DM_POSTFX_STORY (1), DM_POSTFX_COMBAT (1), DM_POSTFX_COMBAT_MASK (25), DM_POSTFX_COMBAT_INTENSITY (0.25), DM_POSTFX_COMBAT_THRESHOLD (0.6) (both only with DM_POSTFX_COMBAT_PC=0), DM_POSTFX_COMBAT_PC (1), DM_POSTFX_UI (1), DM_POSTFX_CAMBLUR (1), DM_POSTFX_BLOOM (1; 0 leaves every bloom of the game as the Switch build has it and switches the combat bloom models off), DM_POSTFX_DOF (1; 0 keeps BlurBackgroundCam and BlurCharacterCam on the Switch path and switches the depthOfField model of the combat behaviours off).
// Off by default: DM_MOD_POSTEFFECTS=1 turns the callbacks on (the launcher's Mods > RestoreFX switch, or env.txt). The gates are always in the code and pass through while it is off.
#include "dm.h"
#include "hle_mods_gen.h"

void dm_mod_gate_run(uint64_t *regs, int param, void (*fn)(uint64_t *, int));

#define K_BEHAVIOUR_GET_ENABLED 0x19ADF90u
#define K_BEHAVIOUR_SET_ENABLED 0x19ADFE0u
#define K_COMPONENT_GET_GAMEOBJECT 0x19AE220u
#define K_GAMEOBJECT_GET_LAYER 0x19AFBF0u
#define K_OBJECT_GET_NAME 0x19B4080u
#define K_CAMERA_GET_CULLINGMASK 0x17E9BE0u
#define K_BEHAVIOUR_ACTIVE_ENABLED 0x19AE050u
#define K_GAMEOBJECT_ACTIVE_IN_HIERARCHY 0x19AFE30u
#define F_OBJECT_CACHEDPTR 0x10

#define F_UIC_CAMERA 0x18
#define F_UIC_VOLUME 0x118
#define F_UIC_PPBLOOM 0x1E0
#define F_VOL_SHAREDPROFILE 0x18
#define F_VOL_GLOBAL 0x20
#define F_VOL_WEIGHT 0x28
#define F_VOL_PRIORITY 0x2C
#define F_VOL_INTERNALPROFILE 0x40
#define F_LAYER_TRIGGER 0x18
#define F_LAYER_MASK 0x20

#define F_PPB_PROFILE 0x18
#define F_PPB_CAMERA 0x58
#define F_PROFILE_BLOOM 0x58
#define F_PROFILE_DOF 0x40
#define F_PROFILE_MODELS 0x18
#define F_DOF_FOCUS 0x14
#define F_DOF_APERTURE 0x18
#define F_DOF_FOCAL 0x1C
#define F_DOF_KERNEL 0x24
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

#define F_CLASS_NAME 0x10

#define F_CFC_BLOOMFILTER 0x20
#define F_CFC_POSTPROCESSOR 0x98
#define F_STRING_LENGTH 0x10
#define F_STRING_CHARS 0x14

static float s_v1_intensity = 0.25f, s_v1_threshold = 1.0f, s_v1_knee = 0.5f, s_v1_radius = 7.0f;
static float s_combat_intensity = 0.25f, s_combat_threshold = 0.6f;
static uint8_t s_v1_antiflicker;
static float s_v2_intensity = 1.0f, s_v2_threshold = 1.0f, s_v2_knee = 0.5f, s_v2_diffusion = 7.0f, s_v2_clamp = 65472.0f;
static int s_v1_on = 1, s_v2_on = 0, s_v1_force = 0, s_story_on = 1, s_combat_on = 1, s_combat_mask = 25, s_ui_on = 1, s_cam_on = 1, s_dof_on = 1, s_bloom_on = 1, s_combat_pc = 1;
static volatile int s_pc_combat_active;
static float s_combat_max_threshold = 0.9f;

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
        s_combat_intensity = env_float("DM_POSTFX_COMBAT_INTENSITY", s_combat_intensity);
        s_combat_threshold = env_float("DM_POSTFX_COMBAT_THRESHOLD", s_combat_threshold);
        s_v2_intensity = env_float("DM_POSTFX_V2_INTENSITY", s_v2_intensity);
        s_v2_threshold = env_float("DM_POSTFX_V2_THRESHOLD", s_v2_threshold);
        s_v2_knee = env_float("DM_POSTFX_V2_KNEE", s_v2_knee);
        s_v2_diffusion = env_float("DM_POSTFX_V2_DIFFUSION", s_v2_diffusion);
        s_v2_clamp = env_float("DM_POSTFX_V2_CLAMP", s_v2_clamp);
        s_v1_on = env_float("DM_POSTFX_V1", 1) != 0;
        s_v2_on = env_float("DM_POSTFX_V2", 0) != 0;
        s_v1_force = env_float("DM_POSTFX_V1_FORCE", 0) != 0;
        s_story_on = env_float("DM_POSTFX_STORY", 1) != 0;
        s_combat_on = env_float("DM_POSTFX_COMBAT", 1) != 0;
        s_combat_mask = (int)env_float("DM_POSTFX_COMBAT_MASK", 25);
        s_ui_on = env_float("DM_POSTFX_UI", 1) != 0;
        s_cam_on = env_float("DM_POSTFX_CAMBLUR", 1) != 0;
        s_dof_on = env_float("DM_POSTFX_DOF", 1) != 0;
        s_bloom_on = env_float("DM_POSTFX_BLOOM", 1) != 0;
        if (!s_bloom_on) s_v1_on = s_story_on = s_ui_on = 0;
        s_combat_pc = env_float("DM_POSTFX_COMBAT_PC", 1) != 0;
        s_combat_max_threshold = env_float("DM_POSTFX_COMBAT_MAXTHRESHOLD", s_combat_max_threshold);
        LOG("[mod post-effects] %s (DM_MOD_POSTEFFECTS=%s) v1 %s%s (intensity %.2f threshold %.2f knee %.2f radius %.2f) v2 %s (intensity %.2f threshold %.2f knee %.2f diffusion %.1f clamp %.0f) story %s combat %s (mask %d, game values %s) ui %s cam-blur %s dof %s bloom %s",
            on ? "on" : "off", v ? v : "unset", s_v1_on ? "on" : "off", s_v1_force ? " forced" : "", s_v1_intensity, s_v1_threshold, s_v1_knee, s_v1_radius,
            s_v2_on ? "on" : "off", s_v2_intensity, s_v2_threshold, s_v2_knee, s_v2_diffusion, s_v2_clamp, s_story_on ? "on" : "off", s_combat_on ? "on" : "off", s_combat_mask, s_combat_pc ? "on" : "off", s_ui_on ? "on" : "off", s_cam_on ? "on" : "off", s_dof_on ? "on" : "off", s_bloom_on ? "on" : "off");
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

static uint8_t *s_main;
static const uint8_t *s_v2_layer;

static uint8_t *main_base(void) {
    if (!s_main)
        for (int i = 0; i < g_nmod; i++)
            if (!strcmp(g_mod[i].name, "main") && !g_mod[i].nro) { s_main = g_mod[i].base; break; }
    return s_main;
}

#define FN(rva, ret, ...) ((ret (*)(__VA_ARGS__))(s_main + (rva)))

static void log_caller(const char *what, const uint64_t *r, unsigned long long frame) {
    const uint64_t *block = (const uint64_t *)(uintptr_t)r[99];
    const uint64_t lr = block ? block[1] : 0;
    const uint8_t *base = main_base();
    LOG("[mod post-effects] %s frame %llu: caller main+%#llx", what, frame, lr && base ? (unsigned long long)(lr - (uint64_t)(uintptr_t)base) : 0ull);
    dm_backtrace(r[29]);
}

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

static const uint8_t *s_combat_set[16];
static int s_combat_set_next;

static int combat_registered(const uint8_t *ppb) {
    for (int i = 0; i < 16; i++)
        if (s_combat_set[i] == ppb) return 1;
    return 0;
}

static void combat_register(const uint8_t *ppb) {
    if (combat_registered(ppb)) return;
    s_combat_set[s_combat_set_next] = ppb;
    s_combat_set_next = (s_combat_set_next + 1) % 16;
}

static void log_models(const uint8_t *ppb, const uint8_t *profile) {
    static const char *const names[] = {"debugViews", "fog", "antialiasing", "ambientOcclusion", "screenSpaceReflection", "depthOfField", "motionBlur", "eyeAdaptation",
        "bloom", "colorGrading", "userLut", "chromaticAberration", "grain", "vignette", "dithering"};
    char line[640];
    size_t n = 0;
    for (int i = 0; i < 15 && n < sizeof line - 40; i++) {
        const uint8_t *m = ptr(profile, F_PROFILE_MODELS + i * 8);
        n += (size_t)snprintf(line + n, sizeof line - n, " %s %d", names[i], m ? m[F_MODEL_ENABLED] : -1);
    }
    const uint8_t *dof = ptr(profile, F_PROFILE_DOF);
    LOG("[mod post-effects] v1 behaviour %p models:%s", (const void *)ppb, line);
    if (dof)
        LOG("[mod post-effects] v1 behaviour %p depthOfField focusDistance %.3f aperture %.3f focalLength %.3f kernelSize %d", (const void *)ppb, f32(dof, F_DOF_FOCUS),
            f32(dof, F_DOF_APERTURE), f32(dof, F_DOF_FOCAL), *(const int *)(dof + F_DOF_KERNEL));
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
    if (is_new) log_models(ppb, profile);
    if (s_pc_combat_active) {
        if (!s_dof_on) {
            uint8_t *dof = (uint8_t *)ptr(profile, F_PROFILE_DOF);
            if (dof) dof[F_MODEL_ENABLED] = 0;
        }
        if (!s_bloom_on) bloom[F_MODEL_ENABLED] = 0;
        else if (was_on && was_t > s_combat_max_threshold) {
            *(float *)(bloom + F_V1_THRESHOLD) = s_combat_max_threshold;
            if (is_new)
                LOG("[mod post-effects] combat: behaviour %p bloom threshold %.3f -> %.3f (a threshold above 1 is never reached by an 8-bit scene)", (const void *)ppb, was_t, s_combat_max_threshold);
        }
        return;
    }
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
    if (s_combat_on && combat_registered(ppb)) {
        bloom[F_MODEL_ENABLED] = 1;
        *(float *)(bloom + F_V1_INTENSITY) = s_combat_intensity;
        *(float *)(bloom + F_V1_THRESHOLD) = s_combat_threshold;
    }
    if (s_dof_on && combat_registered(ppb)) {
        uint8_t *dof = (uint8_t *)ptr(profile, F_PROFILE_DOF);
        if (dof) dof[F_MODEL_ENABLED] = 1;
    }
    if (log_it)
        LOG("[mod post-effects] v1 OnPreCull #%d: bloom model %p (profile %p) enabled %d intensity %.3f threshold %.3f -> enabled %d intensity %.3f",
            hits, (void *)bloom, (const void *)profile, was_on, was_i, was_t, bloom[F_MODEL_ENABLED], f32(bloom, F_V1_INTENSITY));
}

static uint8_t *s_combat_ppb[5];

static int bloom_model_on(const uint8_t *ppb) {
    const uint8_t *profile = ptr(ppb, F_PPB_PROFILE);
    const uint8_t *bloom = profile ? ptr(profile, F_PROFILE_BLOOM) : NULL;
    return !bloom || bloom[F_MODEL_ENABLED];
}

static void on_combat_keep(uint64_t *r, int p) {
    if (!mod_enabled() || !s_combat_on) return;
    const uint8_t *o = (const uint8_t *)(uintptr_t)r[0];
    const uint8_t *klass = o ? ptr(o, 0) : NULL;
    const char *name = klass ? *(const char *const *)(klass + F_CLASS_NAME) : NULL;
    if (!name || strcmp(name, "PostProcessingBehaviour") || !(s_combat_mask >> p & 1)) return;
    if (!s_v1_on && !bloom_model_on(o)) return;
    if (p >= 0 && p < 5) s_combat_ppb[p] = (uint8_t *)(uintptr_t)o;
    combat_register(o);
    r[1] = 1;
    static int hits;
    if (hits++ < 32)
        LOG("[mod post-effects] combat: ResetCamSetting camera slot %d: v1 behaviour %p kept enabled, frame %llu", p, (const void *)o, (unsigned long long)dm_nvn_frame_count());
}

static void set_float_param(uint8_t *settings, int field, float v) {
    uint8_t *prm = (uint8_t *)ptr(settings, field);
    if (!prm) return;
    prm[P_OVERRIDE] = 1;
    *(float *)(prm + P_FLOAT) = v;
}

static void on_bloom2_force(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled()) return;
    uint8_t *bloom = (uint8_t *)(uintptr_t)r[0];
    if (!bloom) return;
    uint8_t *en = (uint8_t *)ptr(bloom, F_V2_ENABLED);
    const uint8_t *in = ptr(bloom, F_V2_INTENSITY);
    if (!en || !in) return;
    static int hits;
    int log_it = mod_log_hit(&hits);
    uint8_t was_on = en[P_BOOL];
    float was_i = f32(in, P_FLOAT);
    if (s_v2_on && (!was_on || !(was_i > 0.0f))) {
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
        static int enable_traces;
        if (o && !ptr(o, F_PPB_CAMERA) && enable_traces < 8) {
            enable_traces++;
            log_caller("v1 OnEnable without a camera", r, frame);
        }
        break; }
    case 3:
        LOG("[mod post-effects] probe v2 PostProcessLayer.OnEnable #%d frame %llu: %p volumeLayer 0x%x antialiasing %d", n, frame, (const void *)o, o ? *(const uint32_t *)(o + 0x20) : 0, o ? *(const int *)(o + 0x28) : -1);
        break;
    case 4:
        s_v2_layer = o;
        LOG("[mod post-effects] probe v2 PostProcessLayer.OnPreCull #%d frame %llu: %p volumeLayer 0x%x", n, frame, (const void *)o, o ? *(const uint32_t *)(o + 0x20) : 0);
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
        static int disable_traces;
        if (o && !ptr(o, F_PPB_CAMERA) && disable_traces < 8) {
            disable_traces++;
            log_caller("v1 OnDisable without a camera", r, frame);
        }
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

static void story_post_run(uint64_t *r, int p) {
    (void)p;
    if (!main_base()) return;
    const uint8_t *controller = (const uint8_t *)(uintptr_t)r[19];
    uint8_t *pp = controller ? (uint8_t *)ptr(controller, F_CFC_POSTPROCESSOR) : NULL;
    if (!pp) return;
    if ((uint8_t)FN(K_BEHAVIOUR_GET_ENABLED, int, void *, const void *)(pp, NULL)) return;
    FN(K_BEHAVIOUR_SET_ENABLED, void, void *, int, const void *)(pp, 1, NULL);
    static int hits;
    int n = ++hits;
    LOG("[mod post-effects] story: v1 behaviour %p switched on after SetFilter #%d frame %llu", (const void *)pp, n, (unsigned long long)dm_nvn_frame_count());
}

static void on_story_post(uint64_t *r, int p) {
    if (!mod_enabled()) return;
    s_pc_combat_active = 0;
    if (s_story_on) dm_mod_gate_run(r, p, story_post_run);
}

static void combat_post_run(uint64_t *r, int p) {
    (void)r; (void)p;
    if (!main_base()) return;
    for (int i = 0; i < 5; i++) {
        uint8_t *pp = s_combat_ppb[i];
        s_combat_ppb[i] = NULL;
        if (!pp) continue;
        if ((uint8_t)FN(K_BEHAVIOUR_GET_ENABLED, int, void *, const void *)(pp, NULL)) continue;
        FN(K_BEHAVIOUR_SET_ENABLED, void, void *, int, const void *)(pp, 1, NULL);
        LOG("[mod post-effects] combat: v1 behaviour %p switched on after ResetCamSetting slot %d frame %llu", (const void *)pp, i, (unsigned long long)dm_nvn_frame_count());
    }
}

static void on_combat_post(uint64_t *r, int p) {
    if (mod_enabled() && s_combat_on) dm_mod_gate_run(r, p, combat_post_run);
}

static int obj_alive(const void *o) {
    return o && *(const uint64_t *)((const uint8_t *)o + F_OBJECT_CACHEDPTR) != 0;
}

static void obj_desc(const char *what, const void *comp, char *out, int cap) {
    char name[64];
    if (!comp) {
        snprintf(out, (size_t)cap, "%s (null)", what);
        return;
    }
    if (!obj_alive(comp)) {
        snprintf(out, (size_t)cap, "%s %p (destroyed)", what, comp);
        return;
    }
    void *go = FN(K_COMPONENT_GET_GAMEOBJECT, void *, const void *, const void *)(comp, NULL);
    int layer = go && obj_alive(go) ? FN(K_GAMEOBJECT_GET_LAYER, int, void *, const void *)(go, NULL) : -1;
    int in_hierarchy = go && obj_alive(go) ? (uint8_t)FN(K_GAMEOBJECT_ACTIVE_IN_HIERARCHY, int, void *, const void *)(go, NULL) : -1;
    int active_enabled = (uint8_t)FN(K_BEHAVIOUR_ACTIVE_ENABLED, int, const void *, const void *)(comp, NULL);
    string_ascii(FN(K_OBJECT_GET_NAME, const uint8_t *, const void *, const void *)(comp, NULL), name, sizeof name);
    snprintf(out, (size_t)cap, "%s %p \"%s\" layer %d activeInHierarchy %d activeAndEnabled %d", what, comp, name, layer, in_hierarchy, active_enabled);
}

static void ui_diag_run(uint64_t *r, int p) {
    (void)p;
    static int hits;
    if (hits >= 6 || !main_base()) return;
    const uint8_t *ui = (const uint8_t *)(uintptr_t)r[19];
    if (!ui) return;
    hits++;
    const uint8_t *vol = ptr(ui, F_UIC_VOLUME);
    const uint8_t *cam = ptr(ui, F_UIC_CAMERA);
    const uint8_t *bloom = ptr(ui, F_UIC_PPBLOOM);
    char dv[160], dc[160], dl[160];
    obj_desc("volume", vol, dv, sizeof dv);
    obj_desc("uiCamera", cam, dc, sizeof dc);
    obj_desc("v2 layer", s_v2_layer, dl, sizeof dl);
    LOG("[mod post-effects] ui diag #%d frame %llu: %s global %d weight %.3f priority %.3f sharedProfile %p internalProfile %p", hits, (unsigned long long)dm_nvn_frame_count(), dv,
        vol ? vol[F_VOL_GLOBAL] : -1, vol ? f32(vol, F_VOL_WEIGHT) : -1.0f, vol ? f32(vol, F_VOL_PRIORITY) : -1.0f, vol ? (const void *)ptr(vol, F_VOL_SHAREDPROFILE) : NULL, vol ? (const void *)ptr(vol, F_VOL_INTERNALPROFILE) : NULL);
    LOG("[mod post-effects] ui diag #%d: %s cullingMask 0x%x", hits, dc, obj_alive(cam) ? (unsigned)FN(K_CAMERA_GET_CULLINGMASK, int, const void *, const void *)(cam, NULL) : 0u);
    LOG("[mod post-effects] ui diag #%d: %s volumeLayer 0x%x trigger %p", hits, dl, s_v2_layer ? *(const uint32_t *)(s_v2_layer + F_LAYER_MASK) : 0u, s_v2_layer ? (const void *)ptr(s_v2_layer, F_LAYER_TRIGGER) : NULL);
    const uint8_t *en = bloom ? ptr(bloom, F_V2_ENABLED) : NULL;
    const uint8_t *in = bloom ? ptr(bloom, F_V2_INTENSITY) : NULL;
    const uint8_t *th = bloom ? ptr(bloom, F_V2_THRESHOLD) : NULL;
    const uint8_t *kn = bloom ? ptr(bloom, F_V2_KNEE) : NULL;
    LOG("[mod post-effects] ui diag #%d: pp_bloom %p enabled override %d value %d, intensity override %d value %.3f, threshold override %d value %.3f, knee override %d value %.3f", hits, (const void *)bloom,
        en ? en[P_OVERRIDE] : -1, en ? en[P_BOOL] : -1, in ? in[P_OVERRIDE] : -1, in ? f32(in, P_FLOAT) : -1.0f, th ? th[P_OVERRIDE] : -1, th ? f32(th, P_FLOAT) : -1.0f, kn ? kn[P_OVERRIDE] : -1, kn ? f32(kn, P_FLOAT) : -1.0f);
}

static void on_ui_platform(uint64_t *r, int p) {
    if (!mod_enabled()) return;
    if (p == 4) dm_mod_gate_run(r, p, ui_diag_run);
    if (!s_ui_on) return;
    if ((uint32_t)r[8] != 4u) return;
    r[8] = 2;
    static int hits;
    if (hits++ < 16)
        LOG("[mod post-effects] ui: Switch platform check %d passed as Steam, frame %llu", p, (unsigned long long)dm_nvn_frame_count());
}

static void on_cam_platform(uint64_t *r, int p) {
    if (!mod_enabled()) return;
    if (p == 3) {
        if (!s_combat_on || !s_combat_pc) return;
        if ((uint32_t)r[8] != 4u) return;
        r[8] = 2;
        s_pc_combat_active = 1;
        static int combat_hits;
        if (combat_hits++ < 16)
            LOG("[mod post-effects] combat: ResetCamSetting Switch platform check passed as Steam, the five camera behaviours stay enabled with the game's own bloom values, frame %llu", (unsigned long long)dm_nvn_frame_count());
        return;
    }
    if (!s_cam_on || (p < 2 && !s_dof_on)) return;
    if ((uint32_t)r[8] != 4u) return;
    r[8] = 2;
    static int hits;
    if (hits++ < 16)
        LOG("[mod post-effects] cam: Switch platform check %d passed as Steam, frame %llu", p, (unsigned long long)dm_nvn_frame_count());
}

__attribute__((constructor)) static void mod_post_effects_attach(void) {
    gate_obs_set(MODGATE_POST_EFFECTS_BLOOM_PRE, on_bloom_pre);
    gate_obs_set(MODGATE_POST_EFFECTS_BLOOM2_FORCE, on_bloom2_force);
    gate_obs_set(MODGATE_POST_EFFECTS_PROBE, on_probe);
    gate_obs_set(MODGATE_POST_EFFECTS_STORY_POST, on_story_post);
    gate_obs_set(MODGATE_POST_EFFECTS_COMBAT_KEEP, on_combat_keep);
    gate_obs_set(MODGATE_POST_EFFECTS_COMBAT_POST, on_combat_post);
    gate_obs_set(MODGATE_POST_EFFECTS_UI_PLATFORM, on_ui_platform);
    gate_obs_set(MODGATE_POST_EFFECTS_CAM_PLATFORM, on_cam_platform);
    LOG("[mod post-effects] callbacks attached");
}
