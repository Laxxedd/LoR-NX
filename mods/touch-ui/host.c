#include "dm.h"
#include "front.h"
#include "dm_input.h"
#include "hle_mods_gen.h"

int dm_touchscreen_mode(void);
int dm_opmode(void);
void dm_nvn_window_size(int *w, int *h);

#define INPUT_PREFIX "UnityEngine.Input::"

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

static dm_mouse_frame_t frame_now(void) {
    dm_mouse_frame_t f;
    dm_mouse_frame(dm_nvn_frame_count(), &f);
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

static const struct { const char *name; void (*fn)(void); } k_icalls[] = {
    { "GetMouseButton", (void (*)(void))host_get_mouse_button },
    { "GetMouseButtonDown", (void (*)(void))host_get_mouse_button_down },
    { "GetMouseButtonUp", (void (*)(void))host_get_mouse_button_up },
    { "get_mousePresent", (void (*)(void))host_get_mouse_present },
    { "get_mousePosition_Injected", (void (*)(void))host_get_mouse_position },
    { "get_mouseScrollDelta_Injected", (void (*)(void))host_get_mouse_scroll_delta },
};

static void on_icall_resolved(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled()) return;
    const char *name = (const char *)(uintptr_t)r[19];
    if (!name || !r[0] || strncmp(name, INPUT_PREFIX, sizeof INPUT_PREFIX - 1)) return;
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
