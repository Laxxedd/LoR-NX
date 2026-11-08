#include "dm.h"
#include "hle_mods_gen.h"

int dm_touchscreen_mode(void);
void dm_mod_gate_run(uint64_t *regs, int param, void (*fn)(uint64_t *, int));

#define K_ON_SELECT_EGO_CARD 0x1E1E9A0u
#define K_SET_BLOCKS_RAYCASTS 0x34FAF30u
#define K_OBJECT_GET_NAME 0x19B4080u
#define K_GO_GET_TRANSFORM 0x19AFBA0u
#define K_TRANSFORM_GET_PARENT 0x19BC440u

#define F_LU_CARD_GROUP 0x40u
#define F_LU_EGO_SLOTS 0xA0u
#define F_LU_SELECTED 0x158u
#define F_LU_IS_EGO 0x159u
#define F_SLOT_SELECTABLE 0x80u
#define F_ARRAY_LENGTH 0x18u
#define F_ARRAY_DATA 0x20u
#define F_EVENT_ELIGIBLE 0xF8u
#define F_EVENT_POSITION 0x100u
#define F_EVENT_PRESS_POSITION 0x110u
#define F_EVENT_BUTTON 0x144u

// A tap is a press and a release that stay within this many screen pixels (the touchpad mouse reports the same position for both).
#define TAP_SLOP_PX 48.0f

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

// Not "the pointer is still over the slot": PointerEventData.pointerEnter is the deepest object the raycast hit (the card's artwork, name or icon, all children of
// the slot), never the selectable's own GameObject, so comparing the two failed whenever the finger landed on a child graphic. UGUI delivers OnPointerUp to the
// object that took the press whatever is under the finger afterwards, so a release at (nearly) the press position is the tap.
static int is_tap(void *event) {
    if (!event || byte_at(event, F_EVENT_BUTTON) != 0 || !byte_at(event, F_EVENT_ELIGIBLE)) return 0;
    const float *pos = (const float *)((uintptr_t)event + F_EVENT_POSITION);
    const float *press = (const float *)((uintptr_t)event + F_EVENT_PRESS_POSITION);
    float dx = pos[0] - press[0], dy = pos[1] - press[1];
    return dx * dx + dy * dy <= TAP_SLOP_PX * TAP_SLOP_PX;
}

// Diagnostics: the names of the object under the finger and of its parents, as the input module saw them at a release (LOR_InputModule.ReleaseMouse(pointerEvent, currentOverGo)).
static void *s_diag_over;
static void *s_diag_press;
static void *s_diag_event;

static void il2cpp_ascii(void *str, char *out, size_t cap) {
    size_t n = 0;
    if (str) {
        int len = *(const int *)((uintptr_t)str + 0x10);
        const uint16_t *ch = (const uint16_t *)((uintptr_t)str + 0x14);
        for (int i = 0; i < len && n + 1 < cap; i++) out[n++] = ch[i] < 128 ? (char)ch[i] : '?';
    }
    out[n] = 0;
}

static void chain_of(void *go, char *out, size_t cap) {
    out[0] = 0;
    if (!go) { snprintf(out, cap, "(none)"); return; }
    void *t = FN(K_GO_GET_TRANSFORM, void *, void *, void *)(go, NULL);
    size_t used = 0;
    for (int depth = 0; t && depth < 6 && used + 40 < cap; depth++) {
        char name[48];
        il2cpp_ascii(FN(K_OBJECT_GET_NAME, void *, void *, void *)(t, NULL), name, sizeof name);
        used += (size_t)snprintf(out + used, cap - used, "%s%s", depth ? " < " : "", name);
        t = FN(K_TRANSFORM_GET_PARENT, void *, void *, void *)(t, NULL);
    }
}

static void diag_run(uint64_t *r, int p) {
    (void)r; (void)p;
    static int n;
    if (n++ >= 60) return;
    char over[320], press[320];
    chain_of(s_diag_over, over, sizeof over);
    chain_of(s_diag_press, press, sizeof press);
    LOG("[mod ego-page-select] release: over %p [%s]; pressed %p [%s]", s_diag_over, over, s_diag_press, press);
}

static void on_ego_ui(uint64_t *r, int p) {
    if (!mod_enabled() || !dm_touchscreen_mode() || !main_base()) return;
    void *self = (void *)(uintptr_t)r[0];
    void *event = (void *)(uintptr_t)r[1];
    static int logged_dump, logged_any, logged, logged_open, logged_raycast, logged_press, logged_reject;
    switch (p) {
    case 6:
        if (ego_open(s_levelup)) {
            s_diag_event = self;
            s_diag_over = (void *)(uintptr_t)r[2];
            s_diag_press = ptr_at(self, 0x28u);
            dm_mod_gate_run(r, p, diag_run);
        }
        break;
    case 1:
        s_levelup = self;
        s_pressed = NULL;
        if (logged_open++ < 10) LOG("[mod ego-page-select] InitEgo: LevelUpUI %p", self);
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
            if (logged_raycast++ < 10) LOG("[mod ego-page-select] EGO selection open on %p: card group %p raycasts on", self, ptr_at(self, F_LU_CARD_GROUP));
            dm_mod_gate_run(r, p, raycast_run);
            if (logged_dump++ < 4) {
                void *slots = ptr_at(self, F_LU_EGO_SLOTS);
                int n = int_at(slots, F_ARRAY_LENGTH);
                LOG("[mod ego-page-select] %d EGO slots", n);
                for (int i = 0; i < n && i < 8; i++) {
                    void *slot = ptr_at(slots, F_ARRAY_DATA + 8u * (uintptr_t)i);
                    LOG("[mod ego-page-select]   slot %d %p selectable %p", i, slot, ptr_at(slot, F_SLOT_SELECTABLE));
                }
            }
        }
        break;
    case 4:
        if (ego_open(s_levelup) && logged_any++ < 60)
            LOG("[mod ego-page-select] down on selectable %p button %d at (%.0f,%.0f) pointerEnter %p, EGO slot %p", self, byte_at(event, F_EVENT_BUTTON),
                *(const float *)((uintptr_t)event + F_EVENT_POSITION), *(const float *)((uintptr_t)event + F_EVENT_POSITION + 4), ptr_at(event, 0x20u), slot_of(self));
        s_pressed = (slot_of(self) && byte_at(event, F_EVENT_BUTTON) == 0) ? self : NULL;
        if (s_pressed && logged_press++ < 20) LOG("[mod ego-page-select] press on EGO slot %p", slot_of(self));
        break;
    case 5:
        if (!s_pressed || s_pressed != self) break;
        s_pressed = NULL;
        void *slot = slot_of(self);
        if (!slot) break;
        if (!is_tap(event)) {
            if (logged_reject++ < 20) LOG("[mod ego-page-select] release on EGO slot %p is not a tap (button %d, eligible %d)", slot, byte_at(event, F_EVENT_BUTTON), byte_at(event, F_EVENT_ELIGIBLE));
            break;
        }
        s_pick_ui = s_levelup;
        s_pick_slot = slot;
        if (logged++ < 20) LOG("[mod ego-page-select] EGO page %p picked from a tap", slot);
        dm_mod_gate_run(r, p, pick_run);
        break;
    default:
        break;
    }
}

__attribute__((constructor)) static void mod_ego_page_select_attach(void) {
    gate_obs_set(MODGATE_EGO_PAGE_SELECT_EGO_UI, on_ego_ui);
}
