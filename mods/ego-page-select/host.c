#include "dm.h"
#include "hle_mods_gen.h"

int dm_touchscreen_mode(void);
void dm_mod_gate_run(uint64_t *regs, int param, void (*fn)(uint64_t *, int));

#define K_ON_SELECT_EGO_CARD 0x1E1E9A0u
#define K_SET_BLOCKS_RAYCASTS 0x34FAF30u
#define K_GET_GAMEOBJECT 0x19AE220u

#define F_LU_CARD_GROUP 0x40u
#define F_LU_EGO_SLOTS 0xA0u
#define F_LU_SELECTED 0x158u
#define F_LU_IS_EGO 0x159u
#define F_SLOT_SELECTABLE 0x80u
#define F_ARRAY_LENGTH 0x18u
#define F_ARRAY_DATA 0x20u
#define F_EVENT_POINTER_ENTER 0x20u
#define F_EVENT_ELIGIBLE 0xF8u
#define F_EVENT_BUTTON 0x144u

#define FN(rva, ret, ...) ((ret (*)(__VA_ARGS__))(main_base() + (rva)))

static uint8_t *main_base(void) {
    static uint8_t *base;
    if (!base)
        for (int i = 0; i < g_nmod; i++)
            if (!strcmp(g_mod[i].name, "main") && !g_mod[i].nro) { base = g_mod[i].base; break; }
    return base;
}

static int mod_enabled(void) {
    static int on = -1;
    if (on < 0) {
        const char *v = getenv("DM_MOD_EGOPAGESELECT");
        on = v && v[0] == '1';
        LOG("[mod ego-page-select] %s (DM_MOD_EGOPAGESELECT=%s)", on ? "on" : "off", v ? v : "unset");
    }
    return on;
}

static void *s_levelup;
static void *s_pressed;
static void *s_pick_ui;
static void *s_pick_slot;
static void *s_raycast_ui;

static void *ptr_at(void *self, uintptr_t off) { return self ? *(void *const *)((uintptr_t)self + off) : NULL; }
static int byte_at(void *self, uintptr_t off) { return self ? *(const uint8_t *)((uintptr_t)self + off) : 0; }
static int int_at(void *self, uintptr_t off) { return self ? *(const int *)((uintptr_t)self + off) : 0; }

static int ego_open(void *levelup) {
    return levelup && byte_at(levelup, F_LU_IS_EGO) && !byte_at(levelup, F_LU_SELECTED);
}

static void *slot_of(void *selectable) {
    void *levelup = s_levelup;
    if (!selectable || !ego_open(levelup)) return NULL;
    void *slots = ptr_at(levelup, F_LU_EGO_SLOTS);
    int n = int_at(slots, F_ARRAY_LENGTH);
    for (int i = 0; i < n; i++) {
        void *slot = ptr_at(slots, F_ARRAY_DATA + 8u * (uintptr_t)i);
        if (slot && ptr_at(slot, F_SLOT_SELECTABLE) == selectable) return slot;
    }
    return NULL;
}

static void pick_run(uint64_t *r, int p) {
    (void)r; (void)p;
    FN(K_ON_SELECT_EGO_CARD, void, void *, void *, void *)(s_pick_ui, s_pick_slot, NULL);
}

static void raycast_run(uint64_t *r, int p) {
    (void)r; (void)p;
    void *group = ptr_at(s_raycast_ui, F_LU_CARD_GROUP);
    if (group) FN(K_SET_BLOCKS_RAYCASTS, void, void *, int, void *)(group, 1, NULL);
}

static int released_over(void *selectable, void *event) {
    if (!event || byte_at(event, F_EVENT_BUTTON) != 0 || !byte_at(event, F_EVENT_ELIGIBLE)) return 0;
    void *object = FN(K_GET_GAMEOBJECT, void *, void *, void *)(selectable, NULL);
    return object && ptr_at(event, F_EVENT_POINTER_ENTER) == object;
}

static void on_ego_ui(uint64_t *r, int p) {
    if (!mod_enabled() || !dm_touchscreen_mode() || !main_base()) return;
    void *self = (void *)(uintptr_t)r[0];
    void *event = (void *)(uintptr_t)r[1];
    static int logged;
    switch (p) {
    case 1:
        s_levelup = self;
        s_pressed = NULL;
        break;
    case 2:
        if (s_levelup == self) s_levelup = NULL;
        s_pressed = NULL;
        break;
    case 3:
        if (!self) break;
        s_levelup = self;
        if (ego_open(self)) {
            s_raycast_ui = self;
            dm_mod_gate_run(r, p, raycast_run);
        }
        break;
    case 4:
        s_pressed = (slot_of(self) && byte_at(event, F_EVENT_BUTTON) == 0) ? self : NULL;
        break;
    case 5:
        if (!s_pressed || s_pressed != self) break;
        s_pressed = NULL;
        void *slot = slot_of(self);
        if (!slot || !released_over(self, event)) break;
        s_pick_ui = s_levelup;
        s_pick_slot = slot;
        if (logged++ < 20) LOG("[mod ego-page-select] EGO page %p picked from a pointer release", slot);
        dm_mod_gate_run(r, p, pick_run);
        break;
    default:
        break;
    }
}

__attribute__((constructor)) static void mod_ego_page_select_attach(void) {
    gate_obs_set(MODGATE_EGO_PAGE_SELECT_EGO_UI, on_ego_ui);
}
