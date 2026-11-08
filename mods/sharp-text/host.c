// Mod "sharp-text": UI and text at full 1080p, only the 3D scene at a lower resolution.
// Why: in handheld mode Unity draws everything, text included, into 1280x720; MetalFX (the present's upscaler) only sees the finished frame, so it cannot add detail to small text.
// How: Unity's dynamic resolution. The backbuffer stays at the docked size (1920x1080), cameras that render the scene get allowDynamicResolution = true and
// ScalableBufferManager.ResizeBuffers(scale, scale) shrinks only their targets. Cameras that render nothing but the UI layer stay at full size, and so do Screen Space - Overlay canvases.
//   cam_pre     BattleCamManager.FixedUpdate entry: its _uiCam and _characterUiCam (fields) are kept at full size and logged with the other battle cameras
//   frame_pre   InputManager.Update entry (once a frame): first hit switches a handheld run to the docked draw size; every 30 frames the cameras are flagged and the scale is re-applied if it drifted
// Untested on a device: every step logs "[mod sharp-text] ..." so a log.txt shows which one did not hold.
// Diagnostic env (not in the launcher): DM_MOD_SHARPTEXT_UIMASK (culling mask of a UI-only camera, hex or decimal, default 0x20 = layer 5 "UI"), DM_MOD_SHARPTEXT_DOCKED=0 (keep the operation mode as it is).
// Off by default: DM_MOD_SHARPTEXT=1 turns the callback on (the launcher's Mods > Sharp Text switch, or env.txt).
#include "dm.h"
#include "hle_mods_gen.h"

void dm_mod_gate_run(uint64_t *regs, int param, void (*fn)(uint64_t *, int));
int dm_opmode(void);
void dm_set_opmode(int m);
void dm_nvn_window_size(int *w, int *h);

#define K_BUILD_ID "aeea627ddbd1214764dfef5f965e94a2"
#define K_RESOLVE_ICALL 0x32F5B4u               // il2cpp icall resolver (as touch-ui uses it)
#define K_CAM_GET_ALLCAMERAS 0x17EE210u         // Camera.get_allCameras (static)
#define K_CAM_SET_ALLOWDYN 0x17E9320u           // Camera.set_allowDynamicResolution
#define K_CAM_GET_ALLOWDYN 0x17E92D0u
#define K_CAM_GET_CULLINGMASK 0x17E9BE0u
#define K_SBM_GET_WIDTH 0x17F8710u              // ScalableBufferManager.widthScaleFactor
#define F_MGR_UICAM 0x50                        // BattleCamManager._uiCam
#define F_MGR_EFFECTCAM 0x58
#define F_MGR_CHARCAM 0x60
#define F_MGR_CHARUICAM 0x68
#define F_MGR_MAINCAM 0x70
#define F_ARRAY_LEN 0x18
#define F_ARRAY_DATA 0x20

static uint8_t *s_main;
static int g_frame, g_pass, g_state;           // g_state: 0 first hit pending, 1 running, -1 wrong build
static float g_scale;
static void *g_uicam[2];                       // BattleCamManager._uiCam and ._characterUiCam: kept at full size
static uint32_t g_uimask = 0x20;
static int (*g_resize)(float, float);

static uint8_t *main_base(void) {
    if (!s_main)
        for (int i = 0; i < g_nmod; i++)
            if (!strcmp(g_mod[i].name, "main") && !g_mod[i].nro) { s_main = g_mod[i].base; break; }
    return s_main;
}

#define FN(rva, ret, ...) ((ret (*)(__VA_ARGS__))(s_main + (rva)))

static void *field(void *self, uintptr_t off) { return self ? *(void *const *)((uintptr_t)self + off) : NULL; }

static float want_scale(void) {
    const char *v = getenv("DM_MOD_SHARPTEXT_SCALE");
    double s = v && v[0] ? atof(v) : 0.67;
    if (s >= 10.0) s /= 100.0;                  // a percentage (67)
    if (s < 0.5) s = 0.5;
    if (s > 1.0) s = 1.0;
    return (float)s;
}

static float current_scale(void) { return FN(K_SBM_GET_WIDTH, float, const void *)(NULL); }

static void apply_scale(void) {
    if (!g_resize) {
        void *(*resolve)(const char *) = (void *(*)(const char *))(s_main + K_RESOLVE_ICALL);
        void *fn = resolve("UnityEngine.ScalableBufferManager::ResizeBuffers");
        if (!fn) fn = resolve("UnityEngine.ScalableBufferManager::ResizeBuffers(System.Single,System.Single)");
        if (!fn) { static int once; if (!once++) LOG("[mod sharp-text] ScalableBufferManager.ResizeBuffers icall not found"); return; }
        g_resize = (int (*)(float, float))fn;
        LOG("[mod sharp-text] ResizeBuffers icall %p", fn);
    }
    int ok = g_resize(g_scale, g_scale);
    static int logged;
    if (logged++ < 8) LOG("[mod sharp-text] ResizeBuffers(%.2f) -> %d, widthScaleFactor now %.3f", g_scale, ok, current_scale());
}

static void flag_cameras(void) {
    void *arr = FN(K_CAM_GET_ALLCAMERAS, void *, const void *)(NULL);
    if (!arr) return;
    uint64_t n = *(const uint64_t *)((uintptr_t)arr + F_ARRAY_LEN);
    if (n > 64) n = 64;
    // a signature of the camera set (pointers and masks): details are logged whenever it changes (a new scene), at most 40 times
    uint64_t sig = n;
    for (uint64_t i = 0; i < n; i++) {
        void *cam = *(void *const *)((uintptr_t)arr + F_ARRAY_DATA + 8 * i);
        if (!cam) continue;
        uint32_t mask = (uint32_t)FN(K_CAM_GET_CULLINGMASK, int, void *, const void *)(cam, NULL);
        sig = sig * 1099511628211ull ^ (uint64_t)(uintptr_t)cam ^ ((uint64_t)mask << 32);
    }
    static uint64_t last_sig;
    int verbose = sig != last_sig && g_pass < 40;
    if (verbose) { last_sig = sig; g_pass++; }
    int flagged = 0, kept = 0;
    for (uint64_t i = 0; i < n; i++) {
        void *cam = *(void *const *)((uintptr_t)arr + F_ARRAY_DATA + 8 * i);
        if (!cam) continue;
        uint32_t mask = (uint32_t)FN(K_CAM_GET_CULLINGMASK, int, void *, const void *)(cam, NULL);
        int ui_only = mask != 0 && (mask & ~g_uimask) == 0;
        int cur = FN(K_CAM_GET_ALLOWDYN, uint8_t, void *, const void *)(cam, NULL) & 1;
        int battle_ui = cam == g_uicam[0] || cam == g_uicam[1];
        int want = !ui_only && !battle_ui;
        if (cur != want) FN(K_CAM_SET_ALLOWDYN, void, void *, uint8_t, const void *)(cam, (uint8_t)want, NULL);
        if (want) flagged++; else kept++;
        if (verbose) LOG("[mod sharp-text] camera %#llx cullingMask %#x -> %s", (unsigned long long)(uintptr_t)cam, mask, battle_ui ? "full size (battle UI camera)" : ui_only ? "full size (UI only)" : "scaled scene");
    }
    if (verbose) LOG("[mod sharp-text] camera set %d (frame %d): %d scene camera(s) flagged, %d UI camera(s) left at full size", g_pass, g_frame, flagged, kept);
}

static void frame_run(uint64_t *r, int param) {
    (void)r; (void)param;
    if (g_state < 0 || !main_base()) return;
    if (g_state == 0) {
        if (strncmp(dm_main_build(), K_BUILD_ID, 32) != 0) { g_state = -1; LOG("[mod sharp-text] wrong build, mod stays out"); return; }
        g_state = 1;
        const char *m = getenv("DM_MOD_SHARPTEXT_UIMASK");
        if (m && m[0]) g_uimask = (uint32_t)strtoul(m, NULL, 0);
        g_scale = want_scale();
        const char *d = getenv("DM_MOD_SHARPTEXT_DOCKED");
        int w = 0, h = 0; dm_nvn_window_size(&w, &h);
        LOG("[mod sharp-text] on: scene scale %.2f, UI mask %#x, opmode %d, window %dx%d", g_scale, g_uimask, dm_opmode(), w, h);
        if (dm_opmode() == 0 && !(d && d[0] == '0')) { dm_set_opmode(1); LOG("[mod sharp-text] operation mode set to docked: the game redraws at 1920x1080"); }
    }
    g_frame++;
    if (g_frame % 30 != 5) return;
    flag_cameras();
    if (current_scale() < g_scale - 0.01f || current_scale() > g_scale + 0.01f) apply_scale();
}


// BattleCamManager.FixedUpdate: the battle's own UI cameras are known by field, so they are kept at full size whatever their culling mask is.
static void cam_run(uint64_t *r, int param) {
    (void)param;
    if (g_state != 1 || !main_base()) return;
    static int tick;
    if (tick++ % 10) return;
    void *mgr = (void *)r[0];
    if (!mgr) return;
    static void *last_mgr;
    g_uicam[0] = field(mgr, F_MGR_UICAM);
    g_uicam[1] = field(mgr, F_MGR_CHARUICAM);
    for (int k = 0; k < 2; k++) {
        void *cam = g_uicam[k];
        if (cam && (FN(K_CAM_GET_ALLOWDYN, uint8_t, void *, const void *)(cam, NULL) & 1))
            FN(K_CAM_SET_ALLOWDYN, void, void *, uint8_t, const void *)(cam, 0, NULL);
    }
    if (mgr != last_mgr) {
        last_mgr = mgr;
        static const struct { const char *name; uintptr_t off; } f[] = {
            {"_uiCam", F_MGR_UICAM}, {"_effectCam", F_MGR_EFFECTCAM}, {"_characterCam", F_MGR_CHARCAM}, {"_characterUiCam", F_MGR_CHARUICAM}, {"_mainCam", F_MGR_MAINCAM}};
        for (int k = 0; k < 5; k++) {
            void *cam = field(mgr, f[k].off);
            uint32_t mask = cam ? (uint32_t)FN(K_CAM_GET_CULLINGMASK, int, void *, const void *)(cam, NULL) : 0;
            LOG("[mod sharp-text] BattleCamManager %p %s %#llx cullingMask %#x allowDynamicResolution %d", mgr, f[k].name, (unsigned long long)(uintptr_t)cam, mask,
                cam ? FN(K_CAM_GET_ALLOWDYN, uint8_t, void *, const void *)(cam, NULL) & 1 : -1);
        }
    }
}

static int mod_enabled(void) {
    static int on = -1;
    if (on < 0) {
        const char *v = getenv("DM_MOD_SHARPTEXT");
        on = v && v[0] == '1';
        LOG("[mod sharp-text] %s (DM_MOD_SHARPTEXT=%s)", on ? "on" : "off", v ? v : "unset");
    }
    return on;
}

static void on_frame_pre(uint64_t *r, int p) { if (mod_enabled()) dm_mod_gate_run(r, p, frame_run); }
static void on_cam_pre(uint64_t *r, int p) { if (mod_enabled()) dm_mod_gate_run(r, p, cam_run); }

__attribute__((constructor)) static void mod_sharp_text_attach(void) {
    gate_obs_set(MODGATE_SHARP_TEXT_FRAME_PRE, on_frame_pre);
    gate_obs_set(MODGATE_SHARP_TEXT_CAM_PRE, on_cam_pre);
}
