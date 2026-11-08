#include "dm.h"
#include "hle_mods_gen.h"
#include <time.h>

int dm_touchscreen_mode(void);
void dm_mod_gate_run(uint64_t *regs, int param, void (*fn)(uint64_t *, int));

#define K_ON_SELECT_EGO_CARD 0x1E1E9A0u
#define K_SET_BLOCKS_RAYCASTS 0x34FAF30u
#define K_OBJECT_GET_NAME 0x19B4080u
#define K_GO_GET_TRANSFORM 0x19AFBA0u
#define K_TRANSFORM_GET_PARENT 0x19BC440u
#define K_COMPONENT_GET_TRANSFORM 0x19AE1D0u
// UICustomSelectable.OnPointerEnter / OnPointerExit: what a mouse hovering the card's selectable runs. Its SelectEvent / DeselectEvent are the prefab's pad hooks for the slot
// (BattleDiceCardUI_EgoSelection.OnPdCursorEnter / OnPdCursorExit): the card grows 1.25x, its Animator goes to the highlighted state, the hover sound plays and the page's
// description opens on the right.
#define K_SELECTABLE_POINTER_ENTER 0x1BD1310u
#define K_SELECTABLE_POINTER_EXIT 0x1BD13F0u

#define F_LU_CARD_GROUP 0x40u
#define F_LU_EGO_SLOTS 0xA0u
#define F_LU_SELECTED 0x158u
#define F_LU_IS_EGO 0x159u
#define F_SLOT_SELECTABLE 0x80u
#define F_ARRAY_LENGTH 0x18u
#define F_ARRAY_DATA 0x20u
#define F_EVENT_POINTER_PRESS 0x28u
#define F_EVENT_CURRENT_RAYCAST_GO 0x50u   // pointerCurrentRaycast.m_GameObject
#define F_EVENT_ELIGIBLE 0xF8u
#define F_EVENT_POSITION 0x100u
#define F_EVENT_PRESS_POSITION 0x110u
#define F_EVENT_BUTTON 0x144u

// A tap is a press and a release that stay within this many screen pixels (the touchpad mouse reports the same position for both).
#define TAP_SLOP_PX 48.0f

// A press held on a card for at least this long is "look at this page": the description stays open while the finger is down and the release does not pick the page.
#define HOLD_MS 350u

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
static void *s_left_event;     // the left mouse button's PointerEventData: the input module reuses one object for it, so what ReleaseMouse sees of it is what every frame has
static void *s_hover_slot;     // the slot whose hover the mod started (finger down on its card)
static uint64_t s_hover_ms;    // when the finger went down on it

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

static void *tf_of_component(void *c);
static void chain_of_tf(void *t, char *out, size_t cap);

static void raycast_run(uint64_t *r, int p) {
    (void)r; (void)p;
    void *group = ptr_at(s_raycast_ui, F_LU_CARD_GROUP);
    if (group) FN(K_SET_BLOCKS_RAYCASTS, void, void *, int, void *)(group, 1, NULL);
    static int dumped;
    if (dumped++ < 2) {   // where each slot and its selectable sit, to compare with the chain of the object the finger hits
        void *slots = ptr_at(s_raycast_ui, F_LU_EGO_SLOTS);
        int n = int_at(slots, F_ARRAY_LENGTH);
        for (int i = 0; i < n && i < 8; i++) {
            void *slot = ptr_at(slots, F_ARRAY_DATA + 8u * (uintptr_t)i);
            char a[320], b[320];
            chain_of_tf(tf_of_component(slot), a, sizeof a);
            chain_of_tf(tf_of_component(ptr_at(slot, F_SLOT_SELECTABLE)), b, sizeof b);
            LOG("[mod ego-page-select]   slot %d at [%s]; selectable at [%s]", i, a, b);
        }
    }
}

// Not "the pointer is still over the slot": PointerEventData.pointerEnter is the deepest object the raycast hit (the card's artwork, name or icon, all children of
// the slot), never the selectable's own GameObject, so comparing the two failed whenever the finger landed on a child graphic. UGUI delivers OnPointerUp to the
// object that took the press whatever is under the finger afterwards, so a release at (nearly) the press position is the tap.
static int is_tap(void *event) {
    if (!event || byte_at(event, F_EVENT_BUTTON) != 0) return 0;
    const float *pos = (const float *)((uintptr_t)event + F_EVENT_POSITION);
    const float *press = (const float *)((uintptr_t)event + F_EVENT_PRESS_POSITION);
    float dx = pos[0] - press[0], dy = pos[1] - press[1];
    return dx * dx + dy * dy <= TAP_SLOP_PX * TAP_SLOP_PX;
}

// Why the original approach never saw a press: UGUI hands a press to the first IPointerDownHandler / IPointerClickHandler on the object under the finger or one of its
// parents (ExecuteEvents.ExecuteHierarchy). The log shows the finger is over "LeftArea_Root < VibeRect < Prefab_LevelUPEgoCard (n) < EgoCardLayout", and
// ReleaseMouse sees pointerPress == null every time, so nothing on that path takes the press: the EGO slot's UICustomSelectable (BattleDiceCardUI_EgoSelection.selectable) is
// not an ancestor of the graphic that gets hit (OnPointerDown on it never runs), and the slot itself is a plain MonoBehaviour. The abnormality cards avoid this because
// EmotionPassiveCardUI implements IPointerDownHandler / IPointerUpHandler on its own root.
//
// So the tap is recognised at ReleaseMouse instead, from what the input module already knows: the object under the pointer (x2) and the PointerEventData (x1).
// The slot is found by hierarchy, not by a component on the hit object: the slot whose transform shares the deepest ancestor with the hit object, if exactly one does
// (the hit graphic lives in one card's subtree, so it shares that card's root with that card's slot and only the common layout with the others).
static void *s_rel_event;
static void *s_rel_over;

static void il2cpp_ascii(void *str, char *out, size_t cap) {
    size_t n = 0;
    if (str) {
        int len = *(const int *)((uintptr_t)str + 0x10);
        const uint16_t *ch = (const uint16_t *)((uintptr_t)str + 0x14);
        for (int i = 0; i < len && n + 1 < cap; i++) out[n++] = ch[i] < 128 ? (char)ch[i] : '?';
    }
    out[n] = 0;
}

static void *tf_of_go(void *go) { return go ? FN(K_GO_GET_TRANSFORM, void *, void *, void *)(go, NULL) : NULL; }
static void *tf_of_component(void *c) { return c ? FN(K_COMPONENT_GET_TRANSFORM, void *, void *, void *)(c, NULL) : NULL; }

static void chain_of_tf(void *t, char *out, size_t cap) {
    out[0] = 0;
    if (!t) { snprintf(out, cap, "(none)"); return; }
    size_t used = 0;
    for (int depth = 0; t && depth < 8 && used + 40 < cap; depth++) {
        char name[48];
        il2cpp_ascii(FN(K_OBJECT_GET_NAME, void *, void *, void *)(t, NULL), name, sizeof name);
        used += (size_t)snprintf(out + used, cap - used, "%s%s", depth ? " < " : "", name);
        t = FN(K_TRANSFORM_GET_PARENT, void *, void *, void *)(t, NULL);
    }
}

#define MAX_DEPTH 64

// The transform and its parents, nearest first; -1 when the hierarchy is deeper than MAX_DEPTH (the root alignment below would be wrong).
static int up_chain(void *t, void **out) {
    int n = 0;
    while (t) {
        if (n == MAX_DEPTH) return -1;
        out[n++] = t;
        t = FN(K_TRANSFORM_GET_PARENT, void *, void *, void *)(t, NULL);
    }
    return n;
}

// How many ancestors, counted from the scene root, the two chains share.
static int shared_depth(void **a, int na, void **b, int nb) {
    int i = na - 1, j = nb - 1, shared = 0;
    while (i >= 0 && j >= 0 && a[i] == b[j]) { shared++; i--; j--; }
    return shared;
}

// The EGO slot whose card the hit object belongs to, or NULL (hit outside every card, or ambiguous). Runs guest code: only from a dm_mod_gate_run callback.
static void *slot_under(void *over_go) {
    void *slots = ptr_at(s_levelup, F_LU_EGO_SLOTS);
    int n = int_at(slots, F_ARRAY_LENGTH);
    if (!over_go || n < 2 || n > 8) return NULL;
    void *over_chain[MAX_DEPTH], *slot_chain[MAX_DEPTH];
    int over_n = up_chain(tf_of_go(over_go), over_chain);
    if (over_n <= 0) return NULL;
    void *best = NULL;
    int best_shared = -1, tie = 0;
    for (int i = 0; i < n; i++) {
        void *slot = ptr_at(slots, F_ARRAY_DATA + 8u * (uintptr_t)i);
        int slot_n = up_chain(tf_of_component(slot), slot_chain);
        if (slot_n <= 0) continue;
        int shared = shared_depth(over_chain, over_n, slot_chain, slot_n);
        if (shared > best_shared) { best_shared = shared; best = slot; tie = 0; }
        else if (shared == best_shared) tie = 1;
    }
    return tie ? NULL : best;
}

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

// The game's own hover on a card, as the cursor entering / leaving its selectable would run it (guest code: only from a dm_mod_gate_run callback).
static void hover(void *slot, int enter) {
    void *selectable = ptr_at(slot, F_SLOT_SELECTABLE);
    if (!selectable) return;
    FN(enter ? K_SELECTABLE_POINTER_ENTER : K_SELECTABLE_POINTER_EXIT, void, void *, void *, void *)(selectable, s_left_event, NULL);
}

static void set_hover(void *slot) {
    static int n_log;
    if (slot == s_hover_slot) return;
    if (s_hover_slot) hover(s_hover_slot, 0);
    s_hover_slot = slot;
    if (slot) { hover(slot, 1); s_hover_ms = now_ms(); }
    if (n_log++ < 30) LOG("[mod ego-page-select] hover %s", slot ? "on a card" : "off");
}

// Every frame while the EGO selection is open (LOR_InputModule.Process entry): a finger down on a card is the hover the game expects from a cursor, so the card opens its
// description and highlights while it is held, and closes them when the finger leaves the card or lifts.
static void tick_run(uint64_t *r, int p) {
    (void)r; (void)p;
    void *event = s_left_event;
    if (!ego_open(s_levelup)) { s_hover_slot = NULL; return; }
    int down = byte_at(event, F_EVENT_BUTTON) == 0 && byte_at(event, F_EVENT_ELIGIBLE);
    set_hover(down ? slot_under(ptr_at(event, F_EVENT_CURRENT_RAYCAST_GO)) : NULL);
}

// Runs on the guest stack (dm_mod_gate_run) at LOR_InputModule.ReleaseMouse entry while the EGO selection is open.
static void release_run(uint64_t *r, int p) {
    (void)r; (void)p;
    static int n_diag, n_reject, n_nohit, n_pick, n_hold;
    void *event = s_rel_event, *over = s_rel_over;
    void *press = ptr_at(event, F_EVENT_POINTER_PRESS);
    if (n_diag++ < 40) {
        char chain[320];
        chain_of_tf(tf_of_go(over), chain, sizeof chain);
        LOG("[mod ego-page-select] release: over %p [%s]; pointerPress %p", over, chain, press);
    }
    // The game found a press target (a selectable of its own, a card that handles the press): its hooks above and its own handlers deal with the release.
    if (press) return;
    if (!ego_open(s_levelup)) return;
    if (!is_tap(event)) {
        if (n_reject++ < 20) {
            const float *pos = (const float *)((uintptr_t)event + F_EVENT_POSITION);
            const float *pp = (const float *)((uintptr_t)event + F_EVENT_PRESS_POSITION);
            LOG("[mod ego-page-select] release with no press target is not a tap (button %d, eligible %d, at (%.0f,%.0f), pressed at (%.0f,%.0f))",
                byte_at(event, F_EVENT_BUTTON), byte_at(event, F_EVENT_ELIGIBLE), pos[0], pos[1], pp[0], pp[1]);
        }
        return;
    }
    void *slot = slot_under(over);
    if (!slot) {
        if (n_nohit++ < 20) LOG("[mod ego-page-select] tap over %p belongs to no single EGO card", over);
        return;
    }
    uint64_t held = (s_hover_slot == slot) ? now_ms() - s_hover_ms : 0;
    if (held >= HOLD_MS) {
        // Looked at, not picked: the next frame's tick sees the finger up and closes the description.
        if (n_hold++ < 20) LOG("[mod ego-page-select] card %p held %llu ms: shown, not picked", slot, (unsigned long long)held);
        return;
    }
    // A tap picks the page the way a cursor would: hovering it first (highlight state, description, sound) and then the submit.
    set_hover(slot);
    s_hover_slot = NULL;   // the card keeps the highlight the pick animation starts from; the selection closing resets the rest
    if (n_pick++ < 20) LOG("[mod ego-page-select] EGO page %p picked from a tap (found by hierarchy)", slot);
    FN(K_ON_SELECT_EGO_CARD, void, void *, void *, void *)(s_levelup, slot, NULL);
}

static void on_ego_ui(uint64_t *r, int p) {
    if (!mod_enabled() || !dm_touchscreen_mode() || !main_base()) return;
    void *self = (void *)(uintptr_t)r[0];
    void *event = (void *)(uintptr_t)r[1];
    static int logged_dump, logged_any, logged, logged_open, logged_raycast, logged_press, logged_reject;
    switch (p) {
    case 6:
        if (byte_at(event, F_EVENT_BUTTON) == 0) s_left_event = event;
        if (ego_open(s_levelup)) {
            s_rel_event = event;
            s_rel_over = (void *)(uintptr_t)r[2];
            dm_mod_gate_run(r, p, release_run);
        }
        break;
    case 7:   // LOR_InputModule.Process entry, every frame: cheap unless the EGO selection is open
        if (s_left_event && ego_open(s_levelup)) dm_mod_gate_run(r, p, tick_run);
        break;
    case 1:
        s_levelup = self;
        s_pressed = NULL;
        s_hover_slot = NULL;
        if (logged_open++ < 10) LOG("[mod ego-page-select] InitEgo: LevelUpUI %p", self);
        break;
    case 2:
        if (s_levelup == self) s_levelup = NULL;
        s_pressed = NULL;
        s_hover_slot = NULL;
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
