#include "dm.h"
#include "hle_mods_gen.h"

#define HEARTBEAT 600
#define MAX_LINES 120

typedef struct { int hits, lines; uint64_t key[4]; } gate_t;
static gate_t g_count, g_getter, g_end, g_icall;

static int mod_enabled(void) {
    static int on = -1;
    if (on < 0) {
        const char *v = getenv("DM_MOD_TOUCHUI");
        on = v && v[0] == '1';
        LOG("[mod touch-ui] %s (DM_MOD_TOUCHUI=%s)", on ? "on" : "off", v ? v : "unset");
    }
    return on;
}

static int want_log(gate_t *g, const uint64_t key[4]) {
    int hit = g->hits++;
    int changed = hit == 0 || memcmp(g->key, key, sizeof g->key) != 0;
    memcpy(g->key, key, sizeof g->key);
    if (g->lines >= MAX_LINES) return 0;
    if (!(changed || hit % HEARTBEAT == 0)) return 0;
    if (++g->lines == MAX_LINES) LOG("[mod touch-ui] a gate's log capped at %d lines", MAX_LINES);
    return 1;
}

static void on_touch_count(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled()) return;
    int count = (int)(uint32_t)r[0];
    uint64_t key[4] = { (uint64_t)count, 0, 0, 0 };
    if (want_log(&g_count, key)) LOG("[mod touch-ui] touch_count: hit %d touchCount=%d", g_count.hits - 1, count);
}

static void on_getter(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled() || !r[0]) return;
    const uint8_t *obj = (const uint8_t *)(uintptr_t)r[0];
    int flag = (int)(r[8] & 0xff), cnt = *(const int32_t *)(obj + 2272);
    uint64_t key[4] = { r[0], (uint64_t)flag, (uint64_t)(uint32_t)cnt, 0 };
    if (want_log(&g_getter, key)) LOG("[mod touch-ui] getter: hit %d obj %#llx flag[+24]=%d count[+2272]=%d", g_getter.hits - 1, (unsigned long long)r[0], flag, cnt);
}

static void on_poll_end(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled() || !r[19]) return;
    const uint8_t *obj = (const uint8_t *)(uintptr_t)r[19];
    int n = *(const int32_t *)(obj + 2240);
    uint64_t key[4] = { (uint64_t)(uint32_t)n, (uint64_t)*(const int64_t *)(obj + 48), 0, 0 };
    if (want_log(&g_end, key)) LOG("[mod touch-ui] poll exit: hit %d this %#llx count[+2240]=%d tracked[+48]=%lld lastSample[+2248]=%lld", g_end.hits - 1, (unsigned long long)r[19], n, (long long)*(const int64_t *)(obj + 48), (long long)*(const int64_t *)(obj + 2248));
}

static uint8_t *main_base(void) {
    static uint8_t *base;
    if (!base)
        for (int i = 0; i < g_nmod; i++)
            if (!strcmp(g_mod[i].name, "main") && !g_mod[i].nro) { base = g_mod[i].base; break; }
    return base;
}

static void on_icall(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled()) return;
    uint64_t target = r[0];
    uint64_t key[4] = { target, 0, 0, 0 };
    if (want_log(&g_icall, key)) LOG("[mod touch-ui] Input.get_touchCount icall target %#llx = main+%#llx (hit %d)", (unsigned long long)target, (unsigned long long)(target - (uint64_t)(uintptr_t)main_base()), g_icall.hits - 1);
}

__attribute__((constructor)) static void mod_touch_ui_attach(void) {
    gate_obs_set(MODGATE_TOUCH_UI_TOUCH_COUNT, on_touch_count);
    gate_obs_set(MODGATE_TOUCH_UI_GETTER, on_getter);
    gate_obs_set(MODGATE_TOUCH_UI_ICALL, on_icall);
    gate_obs_set(MODGATE_TOUCH_UI_POLL_END, on_poll_end);
}
