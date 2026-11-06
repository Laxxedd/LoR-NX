// Mod "targetable-mass-attacks": Cyaminthe's Targetable Mass Attacks (Steam Workshop 2803192752), as host callbacks on observation gates.
// The PC mod is a set of Harmony patches around a mouse mode ("click twice on a speed die that holds a mass attack, then click a target die"). A controller has no such click, so this port is a small
// selector of its own, opened with R3, or Alt in Touchscreen Mode (the mods' special button, mods/README.md):
//   R3 / Alt while an ally speed die is selected (or focused) and the page in it has sub-targets (BattlePlayingCardDataInUnitModel.subTargets is not empty): the selector opens on the first sub-target.
//   Left / Right (D-pad or left stick) move a cursor over the speed dice that can take that sub-target, A sets it and moves on to the next sub-target arrow, and after the last one the selector closes.
//   B or R3 / Alt close it at once (the sub-targets set so far stay).
// While the selector is open the host hides A, B, X, Y, L, R, the D-pad and the left stick from the game (dm_mod_input_mask, dm/host/hle_hid.c), so the game's own targeting does not also act on them; the keys are read
// from dm_mod_keys, which the mask does not touch. The mask lapses on its own a quarter of a second after the last refresh, and is held after the selector closes until the keys are up again, so the A that
// set the last sub-target does not become a new press for the game.
//   frame_pre  BattleUnitTargetArrowManagerUI.Update entry (x0 = the arrow manager, once a frame in a battle): key edges, the mask, and the selector's steps
//   ui_pre     BattleManagerUI.Init / set_selectedAllyDice entry (x0 = the BattleManagerUI): remembered, with a new battle the selector starts over
// What is written: SubTarget.target and SubTarget.targetSlotOrder of the page's entry for the arrow being set (the same two fields the game's own AddCard fills), then BattleUnitTargetArrowManagerUI.UpdateTargetList redraws the arrows.
// Not ported: the PC mod's patch that keeps the sub-targets when the main target is switched (BattlePlayingCardSlotDetail.AddCard); here a later change of the main target may draw the sub-targets again.
// Off by default: DM_MOD_TARGETABLEMASSATTACKS=1 turns the callbacks on (the launcher's Mods > Targetable Mass Attacks switch, or env.txt). The gates are always in the code and pass through while it is off.
#include "dm.h"
#include "dm_input.h"
#include "hle_mods_gen.h"

void dm_mod_gate_run(uint64_t *regs, int param, void (*fn)(uint64_t *, int));
void dm_mod_input_mask(uint64_t keys, uint32_t ms);   // dm/host/hle_hid.c

// RVAs of dump.cs (main = RVA in the module)
#define K_BATTLEOBJMGR_GET_INSTANCE 0x28807A0u     // BattleObjectManager.get_instance
#define K_BATTLEOBJMGR_GET_ALIVE_LIST_FACTION 0x2885570u
#define K_SPEEDDICEUI_GET_CARD_IN_DICE 0x233E240u  // SpeedDiceUI.get_CardInDice
#define K_SPEEDDICEUI_SET_HIGHLIGHT 0x233E550u     // SpeedDiceUI.SetHighlight(bool)
#define K_SPEEDDICESETTER_GET_BY_INDEX 0x233B5B0u  // SpeedDiceSetter.GetSpeedDiceByIndex(int)
#define K_ARROWMGR_UPDATE_TARGET_LIST 0x2355A90u   // BattleUnitTargetArrowManagerUI.UpdateTargetList

#define FACTION_ENEMY 0                            // Faction: Enemy 0, Player 1
#define FACTION_PLAYER 1
#define F_BMUI_SELECTED_ALLY 0xB0                  // BattleManagerUI._selectedAllyDice
#define F_BMUI_FOCUSED 0xC0                        // BattleManagerUI.focusedDice
#define F_CARD_OWNER 0x18                          // BattlePlayingCardDataInUnitModel.owner
#define F_CARD_SUBTARGETS 0x30                     // .subTargets (List<SubTarget>)
#define F_SUB_TARGET 0x10                          // BattlePlayingCardDataInUnitModel.SubTarget.target
#define F_SUB_SLOT 0x18                            // .targetSlotOrder
#define F_UNIT_VIEW 0x50                           // BattleUnitModel.view
#define F_UNIT_FACTION 0x60                        // BattleUnitModel.faction
#define F_UNIT_DICE 0x80                           // BattleUnitModel.speedDiceResult (List<SpeedDice>)
#define F_VIEW_SETTER 0x1C0                        // BattleUnitView.speedDiceSetterUI
#define F_SPEEDDICE_BREAKED 0x1C                   // SpeedDice.breaked (bool)
#define F_LIST_ITEMS 0x10
#define F_LIST_SIZE 0x18
#define F_ARRAY_DATA 0x20

#define KEY_STICK_L_LEFT (1ull << 16)              // dm_cheats_keys: the left stick's directions (dm_input.h)
#define KEY_STICK_L_RIGHT (1ull << 18)
#define KEYS_HIDDEN (DM_BTN_A | DM_BTN_B | DM_BTN_X | DM_BTN_Y | DM_BTN_L | DM_BTN_R | DM_BTN_LEFT | DM_BTN_UP | DM_BTN_RIGHT | DM_BTN_DOWN | (0xFull << 16))
#define MAX_CAND 64

static uint8_t *s_main;
static void *s_bmui;           // the BattleManagerUI of this battle
static int s_active;           // the selector is open
static int s_hold;             // it closed: the keys stay hidden until they are up
static void *s_anchor;         // the SpeedDiceUI whose page is being edited
static void *s_card;           // that page (BattlePlayingCardDataInUnitModel)
static int s_arrow;            // the sub-target being set
static int s_cur, s_nc;        // the cursor, and the number of dice it can go over
static struct { void *unit; int slot; } s_cand[MAX_CAND];
static void *s_lit;            // the speed die the cursor lights
static uint64_t s_prev, s_edges;
static int g_hits[4];
static int first_hits(int which) { return g_hits[which]++ < 6; }

// main's image start, so main + RVA is the game function
static uint8_t *main_base(void) {
    if (!s_main)
        for (int i = 0; i < g_nmod; i++)
            if (!strcmp(g_mod[i].name, "main") && !g_mod[i].nro) { s_main = g_mod[i].base; break; }
    return s_main;
}

#define FN(rva, ret, ...) ((ret (*)(__VA_ARGS__))(s_main + (rva)))

static void *field(void *self, uintptr_t off) { return self ? *(void *const *)((uintptr_t)self + off) : NULL; }
static int field_int(void *self, uintptr_t off) { return self ? *(const int *)((uintptr_t)self + off) : 0; }
static int field_bool(void *self, uintptr_t off) { return self ? *(const uint8_t *)((uintptr_t)self + off) != 0 : 0; }
static int list_count(void *list) { return field_int(list, F_LIST_SIZE); }
static void *list_get(void *list, int index) {
    void *items = field(list, F_LIST_ITEMS);
    if (!items || index < 0 || index >= list_count(list)) return NULL;
    return *(void *const *)((uintptr_t)items + F_ARRAY_DATA + sizeof(void *) * (size_t)index);
}

// the speed die of a unit's slot, as the game's own arrows find it
static void *dice_ui(void *unit, int slot) {
    void *setter = field(field(unit, F_UNIT_VIEW), F_VIEW_SETTER);
    return setter ? FN(K_SPEEDDICESETTER_GET_BY_INDEX, void *, void *, int, const void *)(setter, slot, NULL) : NULL;
}
static void light(void *ui) {
    if (ui == s_lit) return;
    if (s_lit) FN(K_SPEEDDICEUI_SET_HIGHLIGHT, void, void *, int, const void *)(s_lit, 0, NULL);
    s_lit = ui;
    if (ui) FN(K_SPEEDDICEUI_SET_HIGHLIGHT, void, void *, int, const void *)(ui, 1, NULL);
}

// The page in the speed die, when it has sub-targets
static void *mass_card(void *ui) {
    if (!ui) return NULL;
    void *card = FN(K_SPEEDDICEUI_GET_CARD_IN_DICE, void *, void *, const void *)(ui, NULL);
    if (!card || list_count(field(card, F_CARD_SUBTARGETS)) <= 0) return NULL;
    return card;
}

// The speed dice that arrow s_arrow can take: every die that is not broken, of the units of the faction its current target is of (the opponents' when it has none)
static void build_cands(void) {
    s_nc = 0;
    void *sub = list_get(field(s_card, F_CARD_SUBTARGETS), s_arrow);
    void *cur = field(sub, F_SUB_TARGET);
    int cur_slot = field_int(sub, F_SUB_SLOT);
    int faction = cur ? field_int(cur, F_UNIT_FACTION) : (field_int(field(s_card, F_CARD_OWNER), F_UNIT_FACTION) == FACTION_PLAYER ? FACTION_ENEMY : FACTION_PLAYER);
    void *manager = FN(K_BATTLEOBJMGR_GET_INSTANCE, void *, const void *)(NULL);
    void *units = manager ? FN(K_BATTLEOBJMGR_GET_ALIVE_LIST_FACTION, void *, void *, int, const void *)(manager, faction, NULL) : NULL;
    s_cur = 0;
    for (int i = 0, n = list_count(units); i < n; i++) {
        void *unit = list_get(units, i), *dice = field(unit, F_UNIT_DICE);
        for (int k = 0, m = list_count(dice); unit && k < m && s_nc < MAX_CAND; k++) {
            void *sd = list_get(dice, k);
            if (!sd || field_bool(sd, F_SPEEDDICE_BREAKED)) continue;
            if (unit == cur && k == cur_slot) s_cur = s_nc;
            s_cand[s_nc].unit = unit; s_cand[s_nc].slot = k; s_nc++;
        }
    }
    light(s_nc ? dice_ui(s_cand[s_cur].unit, s_cand[s_cur].slot) : NULL);
}

static void close_selector(void) {
    light(NULL);
    s_active = 0; s_hold = 1; s_card = s_anchor = NULL;
    void *arrows = field(s_bmui, 0x40);   // BattleManagerUI.ui_TargetArrow
    if (arrows) FN(K_ARROWMGR_UPDATE_TARGET_LIST, void, void *, const void *)(arrows, NULL);
}

static void open_run(uint64_t *r, int param) {
    (void)r; (void)param;
    if (!main_base() || !s_bmui) return;
    void *ui = field(s_bmui, F_BMUI_SELECTED_ALLY);
    void *card = mass_card(ui);
    if (!card) { ui = field(s_bmui, F_BMUI_FOCUSED); card = mass_card(ui); }
    if (!card || field_int(field(card, F_CARD_OWNER), F_UNIT_FACTION) != FACTION_PLAYER) return;   // not a page of the player's with sub-targets
    s_anchor = ui; s_card = card; s_arrow = 0; s_active = 1; s_lit = NULL;
    build_cands();
    if (first_hits(0)) LOG("[mod targetable-mass-attacks] R3 / Alt: selector open on page %#llx, %d sub-target(s), %d die(s) for the first", (unsigned long long)(uintptr_t)card, list_count(field(card, F_CARD_SUBTARGETS)), s_nc);
}

// One frame of the open selector (guest stack: the game's functions run here)
static void step_run(uint64_t *r, int param) {
    (void)r; (void)param;
    if (!main_base() || !s_bmui) return;
    // the selection is still the one the selector opened on, and the page still has the arrow
    void *ui = field(s_bmui, F_BMUI_SELECTED_ALLY);
    if (!ui) ui = field(s_bmui, F_BMUI_FOCUSED);
    if (ui != s_anchor || mass_card(ui) != s_card || s_arrow >= list_count(field(s_card, F_CARD_SUBTARGETS))) { close_selector(); return; }
    if (s_edges & (DM_BTN_B | dm_mod_special())) { close_selector(); return; }
    if (s_nc <= 0) { build_cands(); if (s_nc <= 0) { close_selector(); return; } }
    if (s_edges & (DM_BTN_LEFT | KEY_STICK_L_LEFT)) { s_cur = (s_cur + s_nc - 1) % s_nc; light(dice_ui(s_cand[s_cur].unit, s_cand[s_cur].slot)); }
    if (s_edges & (DM_BTN_RIGHT | KEY_STICK_L_RIGHT)) { s_cur = (s_cur + 1) % s_nc; light(dice_ui(s_cand[s_cur].unit, s_cand[s_cur].slot)); }
    if (s_edges & DM_BTN_A) {
        void *sub = list_get(field(s_card, F_CARD_SUBTARGETS), s_arrow);
        if (sub) {   // the game's collector is not generational: plain stores need no write barrier
            *(void **)((uintptr_t)sub + F_SUB_TARGET) = s_cand[s_cur].unit;
            *(int *)((uintptr_t)sub + F_SUB_SLOT) = s_cand[s_cur].slot;
            if (first_hits(1)) LOG("[mod targetable-mass-attacks] sub-target %d of page %#llx set to unit %#llx die %d", s_arrow, (unsigned long long)(uintptr_t)s_card, (unsigned long long)(uintptr_t)s_cand[s_cur].unit, s_cand[s_cur].slot);
        }
        void *arrows = field(s_bmui, 0x40);
        if (arrows) FN(K_ARROWMGR_UPDATE_TARGET_LIST, void, void *, const void *)(arrows, NULL);
        if (++s_arrow >= list_count(field(s_card, F_CARD_SUBTARGETS))) close_selector();   // the last arrow is set
        else build_cands();                                                                  // on to the next one
    }
}

// Read once, at the first gate hit: the launcher's choices are in the environment by then, but not yet when constructors run
static int mod_enabled(void) {
    static int on = -1;
    if (on < 0) {
        const char *v = getenv("DM_MOD_TARGETABLEMASSATTACKS");
        on = v && v[0] == '1';
        LOG("[mod targetable-mass-attacks] %s (DM_MOD_TARGETABLEMASSATTACKS=%s)", on ? "on" : "off", v ? v : "unset");
    }
    return on;
}

static void on_ui_pre(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled()) return;
    if (s_bmui != (void *)r[0]) {   // a new battle: nothing of the last one is kept
        s_bmui = (void *)r[0]; s_active = 0; s_hold = 0; s_card = s_anchor = s_lit = NULL; s_nc = 0;
        if (first_hits(2)) LOG("[mod targetable-mass-attacks] ui_pre: BattleManagerUI %#llx", (unsigned long long)r[0]);
    }
}

// A frame's work is the key read; the game's functions run (dm_mod_gate_run) on R3 / Alt while closed and on every frame while the selector is open
static void on_frame_pre(uint64_t *r, int p) {
    if (!mod_enabled()) return;
    uint64_t keys = dm_mod_keys();
    s_edges = keys & ~s_prev;
    s_prev = keys;
    if (s_active) { dm_mod_input_mask(KEYS_HIDDEN, 250); dm_mod_gate_run(r, p, step_run); }
    else if (s_hold) {
        if (keys & KEYS_HIDDEN) dm_mod_input_mask(KEYS_HIDDEN, 250);   // the key that closed it is still down
        else s_hold = 0;
    } else if (s_edges & dm_mod_special()) dm_mod_gate_run(r, p, open_run);
}

__attribute__((constructor)) static void mod_targetable_mass_attacks_attach(void) {
    gate_obs_set(MODGATE_TARGETABLE_MASS_ATTACKS_FRAME_PRE, on_frame_pre);
    gate_obs_set(MODGATE_TARGETABLE_MASS_ATTACKS_UI_PRE, on_ui_pre);
}
