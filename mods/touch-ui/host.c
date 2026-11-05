#include "dm.h"
#include "hle_mods_gen.h"

#define HEARTBEAT 300
#define MAX_LINES 400

static int g_lines;

static int mod_enabled(void) {
    static int on = -1;
    if (on < 0) {
        const char *v = getenv("DM_MOD_TOUCHUI");
        on = v && v[0] == '1';
        LOG("[mod touch-ui] %s (DM_MOD_TOUCHUI=%s)", on ? "on" : "off", v ? v : "unset");
    }
    return on;
}

static int should_log(int hit, int changed) {
    if (g_lines >= MAX_LINES) return 0;
    if (!(hit == 0 || changed || hit % HEARTBEAT == 0)) return 0;
    if (++g_lines == MAX_LINES) LOG("[mod touch-ui] log capped at %d lines", MAX_LINES);
    return 1;
}

static int g_hits_count, g_last_count = -1;

static void on_touch_count(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled()) return;
    int count = (int)(uint32_t)r[0];
    int hit = g_hits_count++;
    int changed = count != g_last_count;
    g_last_count = count;
    if (should_log(hit, changed))
        LOG("[mod touch-ui] touch_count gate: hit %d, LOR_InputModule.ProcessTouchEvents touchCount=%d%s", hit, count, changed ? " (changed)" : "");
}

static int g_hits_get, g_last_flag = -1, g_last_cnt = -1;
static uint64_t g_last_obj;

static void on_getter(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled()) return;
    uint8_t *obj = (uint8_t *)(uintptr_t)r[0];
    if (!obj) return;
    int flag = (int)(uint32_t)r[8] & 0xff;
    int cnt = *(int32_t *)(obj + 2272);
    int hit = g_hits_get++;
    int changed = flag != g_last_flag || cnt != g_last_cnt || r[0] != g_last_obj;
    g_last_flag = flag; g_last_cnt = cnt; g_last_obj = r[0];
    if (should_log(hit, changed))
        LOG("[mod touch-ui] getter gate: hit %d, obj %#llx flag[+24]=%d count[+2272]=%d%s", hit, (unsigned long long)r[0], flag, cnt, changed ? " (changed)" : "");
}

static int g_hits_poll;
static int64_t g_last_samp = -1; static int32_t g_last_n = -1, g_last_c = -1;
static uint64_t g_last_this;

static void on_poll(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled()) return;
    uint8_t *obj = (uint8_t *)(uintptr_t)r[0];
    if (!obj) return;
    int64_t samp = *(int64_t *)(obj + 2248);
    int32_t n = *(int32_t *)(obj + 2240), c = *(int32_t *)(obj + 2272);
    int hit = g_hits_poll++;
    int changed = samp != g_last_samp || n != g_last_n || c != g_last_c || r[0] != g_last_this;
    g_last_samp = samp; g_last_n = n; g_last_c = c; g_last_this = r[0];
    if (should_log(hit, changed))
        LOG("[mod touch-ui] poll gate: hit %d, this %#llx lastSample[+2248]=%lld count[+2240]=%d count[+2272]=%d cap[+24]=%llu%s", hit, (unsigned long long)r[0], (long long)samp, n, c,
            (unsigned long long)*(uint64_t *)(obj + 24), changed ? " (changed)" : "");
}

__attribute__((constructor)) static void mod_touch_ui_attach(void) {
    gate_obs_set(MODGATE_TOUCH_UI_TOUCH_COUNT, on_touch_count);
    gate_obs_set(MODGATE_TOUCH_UI_GETTER, on_getter);
    gate_obs_set(MODGATE_TOUCH_UI_POLL, on_poll);
}
