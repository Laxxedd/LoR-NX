#include "dm.h"
#include "front.h"
#include "dm_input.h"
#include "hle_mods_gen.h"

int dm_touchscreen_mode(void);
int dm_opmode(void);
void dm_nvn_window_size(int *w, int *h);

#define INPUT_PREFIX "UnityEngine.Input::"
#define CURSOR_PREFIX "UnityEngine.Cursor::"

static int mod_enabled(void) {
    static int on = -1;
    if (on < 0) {
        const char *v = getenv("DM_MOD_TOUCHUI");
        on = v && v[0] == '1';
        LOG("[mod touch-ui] %s (DM_MOD_TOUCHUI=%s)", on ? "on" : "off", v ? v : "unset");
    }
    return on;
}

static void screen_size(int *w, int *h) {
    dm_nvn_window_size(w, h);
    if (*w > 0 && *h > 0) return;
    int handheld = dm_opmode() == 0;
    *w = handheld ? 1280 : 1920;
    *h = handheld ? 720 : 1080;
}

#define K_BUILD_ID "aeea627ddbd1214764dfef5f965e94a2"
#define K_MANAGER_TABLE 0x54D4828u
#define K_INPUT_MANAGER_SLOT 1u
#define F_MOUSE_X 0xC8u
#define F_MOUSE_Y 0xCCu
#define K_RESOLVE_ICALL 0x32F5B4u

static uint8_t *main_base(void) {
    static uint8_t *base;
    if (!base)
        for (int i = 0; i < g_nmod; i++)
            if (!strcmp(g_mod[i].name, "main") && !g_mod[i].nro) { base = g_mod[i].base; break; }
    return base;
}

static void push_engine_position(float x, float y) {
    static int build_ok = -1;
    if (build_ok < 0) build_ok = strncmp(dm_main_build(), K_BUILD_ID, 32) == 0;
    if (!build_ok) return;
    uint8_t *base = main_base();
    if (!base) return;
    uint8_t *mgr = *(uint8_t *volatile *)(base + K_MANAGER_TABLE + 8u * K_INPUT_MANAGER_SLOT);
    if (!mgr) return;
    volatile float *pos = (volatile float *)(mgr + F_MOUSE_X);
    pos[0] = x;
    *(volatile float *)(mgr + F_MOUSE_Y) = y;
    static int logged;
    if (!logged++) LOG("[mod touch-ui] engine mouse position at InputManager %p fed from the touchpad", (void *)mgr);
}

static int (*g_unity_frame_count)(void);

static uint64_t game_frame(void) {
    static int tried;
    if (!tried) {
        tried = 1;
        uint8_t *base = main_base();
        if (base && strncmp(dm_main_build(), K_BUILD_ID, 32) == 0) {
            void *(*resolve)(const char *) = (void *(*)(const char *))(base + K_RESOLVE_ICALL);
            void *fn = resolve("UnityEngine.Time::get_frameCount()");
            if (!fn) fn = resolve("UnityEngine.Time::get_frameCount");
            if (fn) {
                g_unity_frame_count = (int (*)(void))fn;
                LOG("[mod touch-ui] mouse edges follow Time.frameCount (native %p)", fn);
            } else {
                LOG("[mod touch-ui] Time.frameCount not found, mouse edges follow the present count");
            }
        }
    }
    if (g_unity_frame_count) return (uint64_t)(uint32_t)g_unity_frame_count();
    return dm_nvn_frame_count();
}

static dm_mouse_frame_t frame_now(void) {
    static uint64_t pushed = ~0ull;
    uint64_t frame = game_frame();
    dm_mouse_frame_t f;
    dm_mouse_frame(frame, &f);
    if (pushed != frame) {
        pushed = frame;
        int w, h;
        screen_size(&w, &h);
        push_engine_position(f.nx * (float)(w - 1), (1.0f - f.ny) * (float)(h - 1));
        static uint32_t last_held;
        static int logged_changes;
        if (f.held != last_held && logged_changes < 200) {
            logged_changes++;
            LOG("[mod touch-ui] frame %llu buttons held %#x down %#x up %#x at (%.0f,%.0f)", (unsigned long long)frame, f.held, f.down, f.up, f.nx * (float)(w - 1), (1.0f - f.ny) * (float)(h - 1));
        }
        last_held = f.held;
    }
    return f;
}

static uint32_t button_mask(int button) {
    return button == 0 ? DM_MOUSE_LEFT : button == 1 ? DM_MOUSE_RIGHT : 0;
}

static int host_get_mouse_button(int button) { return (frame_now().held & button_mask(button)) != 0; }
static int host_get_mouse_button_down(int button) { return (frame_now().down & button_mask(button)) != 0; }
static int host_get_mouse_button_up(int button) { return (frame_now().up & button_mask(button)) != 0; }
static int host_get_mouse_present(void) { return 1; }

static void host_get_mouse_position(float *out) {
    dm_mouse_frame_t f = frame_now();
    int w, h;
    screen_size(&w, &h);
    out[0] = f.nx * (float)(w - 1);
    out[1] = (1.0f - f.ny) * (float)(h - 1);
    out[2] = 0.0f;
}

static void host_get_mouse_scroll_delta(float *out) {
    out[0] = 0.0f;
    out[1] = (float)frame_now().wheel;
}

static int usage_of_keycode(int code) {
    switch (code) {
    case 27: return 41;
    case 32: return 44;
    case 303: case 304: return 225;
    case 305: case 306: return 224;
    case 307: case 308: return 226;
    default: return -1;
    }
}

static dm_key_frame_t key_frame_now(void) {
    dm_key_frame_t k;
    dm_key_frame(game_frame(), &k);
    return k;
}

static int key_bit(const uint32_t *set, int code) {
    int u = usage_of_keycode(code);
    return u >= 0 && ((set[u / 32] >> (u % 32)) & 1u);
}

static int host_get_key(int code) { dm_key_frame_t k = key_frame_now(); return key_bit(k.held, code); }
static int host_get_key_down(int code) { dm_key_frame_t k = key_frame_now(); return key_bit(k.down, code); }
static int host_get_key_up(int code) { dm_key_frame_t k = key_frame_now(); return key_bit(k.up, code); }

static int host_get_any_key_down(void) {
    dm_key_frame_t k = key_frame_now();
    for (int i = 0; i < 8; i++) if (k.down[i]) return 1;
    return (frame_now().down & (DM_MOUSE_LEFT | DM_MOUSE_RIGHT)) != 0;
}

static const struct { const char *name; void (*fn)(void); } k_icalls[] = {
    { "GetKeyInt", (void (*)(void))host_get_key },
    { "GetKeyDownInt", (void (*)(void))host_get_key_down },
    { "GetKeyUpInt", (void (*)(void))host_get_key_up },
    { "get_anyKeyDown", (void (*)(void))host_get_any_key_down },
    { "GetMouseButton", (void (*)(void))host_get_mouse_button },
    { "GetMouseButtonDown", (void (*)(void))host_get_mouse_button_down },
    { "GetMouseButtonUp", (void (*)(void))host_get_mouse_button_up },
    { "get_mousePresent", (void (*)(void))host_get_mouse_present },
    { "get_mousePosition_Injected", (void (*)(void))host_get_mouse_position },
    { "get_mouseScrollDelta_Injected", (void (*)(void))host_get_mouse_scroll_delta },
};

// Pointer Mode "Touch" (the launcher's DM_POINTER_MODE=touch, with Touchscreen Mode): the cursor is the finger, so the game's own cursor (CursorManager draws its textures with
// UnityEngine.Cursor.SetCursor and shows them with Cursor.visible) must stay hidden. Both natives are replaced when the icall resolves, in Touch mode only, so Trackpad mode is untouched:
// SetCursor_Injected(texture, hotspot, mode) does nothing (no cursor image is ever set), and set_visible(bool) hands the engine false whatever the game asks for.
// Read at the first icall, like the mod's own switch: the launcher's choices are not in the environment yet when constructors run.
static int pointer_touch(void) {
    static int on = -1;
    if (on < 0) {
        const char *v = getenv("DM_POINTER_MODE");
        on = v && !strcmp(v, "touch");
        LOG("[mod touch-ui] pointer mode %s (DM_POINTER_MODE=%s)", on ? "touch: the game's cursor is hidden" : "trackpad", v ? v : "unset");
    }
    return on;
}

static void (*g_real_set_visible)(int);

static void host_cursor_set_cursor(void *texture, void *hotspot, int mode) { (void)texture; (void)hotspot; (void)mode; }
static void host_cursor_set_visible(int visible) {
    (void)visible;
    if (g_real_set_visible) g_real_set_visible(0);
}

static int on_cursor_icall(const char *name, uint64_t *r) {
    const char *method = name + sizeof CURSOR_PREFIX - 1;
    if (!strncmp(method, "SetCursor_Injected", 18) && (method[18] == '\0' || method[18] == '(')) {
        LOG("[mod touch-ui] %s: icall %#llx replaced, the game's cursor image is never set", name, (unsigned long long)r[0]);
        r[0] = (uint64_t)(uintptr_t)host_cursor_set_cursor;
        return 1;
    }
    if (!strncmp(method, "set_visible", 11) && (method[11] == '\0' || method[11] == '(')) {
        LOG("[mod touch-ui] %s: icall %#llx replaced, the game's cursor stays hidden", name, (unsigned long long)r[0]);
        g_real_set_visible = (void (*)(int))(uintptr_t)r[0];
        r[0] = (uint64_t)(uintptr_t)host_cursor_set_visible;
        return 1;
    }
    return 0;
}

static void on_icall_resolved(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled()) return;
    const char *name = (const char *)(uintptr_t)r[19];
    if (!name || !r[0]) return;
    if (!strncmp(name, CURSOR_PREFIX, sizeof CURSOR_PREFIX - 1)) {
        if (dm_touchscreen_mode() && pointer_touch()) on_cursor_icall(name, r);
        return;
    }
    if (strncmp(name, INPUT_PREFIX, sizeof INPUT_PREFIX - 1)) return;
    if (!dm_touchscreen_mode()) return;
    const char *method = name + sizeof INPUT_PREFIX - 1;
    for (size_t i = 0; i < sizeof k_icalls / sizeof k_icalls[0]; i++) {
        size_t n = strlen(k_icalls[i].name);
        if (strncmp(method, k_icalls[i].name, n) || (method[n] != '\0' && method[n] != '(')) continue;
        LOG("[mod touch-ui] %s: icall %#llx replaced by the host's touchpad mouse", name, (unsigned long long)r[0]);
        r[0] = (uint64_t)(uintptr_t)k_icalls[i].fn;
        return;
    }
}

__attribute__((constructor)) static void mod_touch_ui_attach(void) {
    gate_obs_set(MODGATE_TOUCH_UI_ICALL_RESOLVED, on_icall_resolved);
}
