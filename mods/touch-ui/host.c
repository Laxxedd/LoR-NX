#include "dm.h"
#include "hle_mods_gen.h"

#define HEARTBEAT 300
#define MAX_LINES 400

static int g_hits, g_lines, g_last = -1;

static int mod_enabled(void) {
    static int on = -1;
    if (on < 0) {
        const char *v = getenv("DM_MOD_TOUCHUI");
        on = v && v[0] == '1';
        LOG("[mod touch-ui] %s (DM_MOD_TOUCHUI=%s)", on ? "on" : "off", v ? v : "unset");
    }
    return on;
}

static void on_touch_count(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled()) return;
    int count = (int)(uint32_t)r[0];
    int hit = g_hits++;
    int changed = count != g_last;
    g_last = count;
    if (g_lines >= MAX_LINES) return;
    if (hit == 0 || changed || hit % HEARTBEAT == 0) {
        LOG("[mod touch-ui] touch_count gate: hit %d, LOR_InputModule.ProcessTouchEvents touchCount=%d%s", hit, count, changed ? " (changed)" : "");
        if (++g_lines == MAX_LINES) LOG("[mod touch-ui] touch_count log capped at %d lines", MAX_LINES);
    }
}

__attribute__((constructor)) static void mod_touch_ui_attach(void) {
    gate_obs_set(MODGATE_TOUCH_UI_TOUCH_COUNT, on_touch_count);
}
