// Mod "max-emotion": holding R3 (Alt in Touchscreen Mode, the mods' special button, mods/README.md) raises every librarian on the field to the maximum emotion level, as a host callback on one observation gate.
//   fixed_update_pre  StageController.OnFixedUpdate entry (x0 = the StageController, every fixed step of a battle): the button is read here, and while the round is being planned (_phase 5, ApplyLibrarianCardPhase)
//                     each living unit of the Player faction gets one emotion level per tick, through the game's own functions.
// One level is the game's own level-up, not a write to the level field: BattleUnitEmotionDetail.CreateEmotionCoin(Positive, n) fills the unit's coin list up to its _maximumCoinNumber (the coins the game would have
// counted, with the same side effects: passives' OnGetEmotionCoin, the EGO cooldown), then BattleUnitEmotionDetail.CheckLevelUp() sees the full list, runs the private LevelUp (stat bonus, soul card, the level-up
// events, the mental state from the coins: all positive, so Positive) and refreshes the unit's profile UI. Coins that the game does not hand out (CreateEmotionCoin returns at once for a unit that cannot get any) leave
// the list short, CheckLevelUp returns 0 and the unit is left alone, so the loop of ticks never spins on it. At the maximum level (_maximumEmotionLevel) nothing is done.
// Every level of a unit adds one to its skillPoint, as in a normal battle, so the round end (RoundEndPhase_ChoiceEmotionCard) offers one emotion card per level, the game's way of choosing what the levels give.
// A level every 6th fixed step while the button is held (about 0.12 s) keeps the level-up effects of one unit from stacking in a single frame; the five levels take about 0.6 s.
// Not touched: units of other factions, units that are dead or knocked out, and every phase other than planning (the held button is checked again at each fixed step, so holding it into the planning phase works).
// Off by default: DM_MOD_MAXEMOTION=1 turns the callback on (the launcher's Mods > Max Emotion switch, or env.txt). The gate is always in the code and passes through while it is off.
#include "dm.h"
#include "dm_input.h"
#include "hle_mods_gen.h"

void dm_mod_gate_run(uint64_t *regs, int param, void (*fn)(uint64_t *, int));

// RVAs of dump.cs (main = RVA in the module)
#define RVA_BATTLEOBJMGR_GET_INSTANCE 0x28807A0u      // BattleObjectManager.get_instance
#define RVA_BATTLEOBJMGR_GET_ALIVE_LIST 0x2885570u    // BattleObjectManager.GetAliveList(Faction)
#define RVA_UNIT_GET_EMOTION_DETAIL 0x1EEFAA0u        // BattleUnitModel.get_emotionDetail
#define RVA_EMOTION_CREATE_COIN 0x1B407A0u            // int BattleUnitEmotionDetail.CreateEmotionCoin(this, EmotionCoinType coinType, int count, MethodInfo*)
#define RVA_EMOTION_CHECK_LEVEL_UP 0x1B41100u         // bool BattleUnitEmotionDetail.CheckLevelUp(this, MethodInfo*)

#define F_STAGE_PHASE 0x70                            // StageController._phase (int)
#define F_BASE_DEAD_REAL 0x20                         // BattleUnitBaseModel._isDeadReal (bool)
#define F_BASE_KNOCKOUT 0x21                          // BattleUnitBaseModel._isKnockout (bool)
#define F_UNIT_FACTION 0x60                           // BattleUnitModel.faction
#define F_UNIT_DISPOSED 0xB8                          // BattleUnitModel.disposed (bool)
#define F_EMO_MAX_LEVEL 0x10                          // BattleUnitEmotionDetail._maximumEmotionLevel (int)
#define F_EMO_MAX_COINS 0x20                          // ._maximumCoinNumber (int): coins the next level needs
#define F_EMO_COINS 0x30                              // ._emotionCoins (List<EmotionCoin>)
#define F_EMO_LEVEL 0x44                              // ._emotionLevel (int)
#define F_LIST_ITEMS 0x10
#define F_LIST_SIZE 0x18
#define F_ARRAY_DATA 0x20

#define PHASE_APPLY_LIBRARIAN_CARD 5                  // StageController.StagePhase.ApplyLibrarianCardPhase
#define FACTION_PLAYER 1                              // Faction: Enemy 0, Player 1
#define COIN_POSITIVE 0                               // EmotionCoinType: Positive 0, Negative 1
#define TICK_STEPS 6                                  // fixed steps between two levels while the button is held

static uint8_t *s_main;
static unsigned s_tick;
static int g_hits;
static int first_hits(void) { return g_hits++ < 8; }

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

// One level for one unit; 1 when it went up
static int level_up_once(void *unit) {
    void *detail = FN(RVA_UNIT_GET_EMOTION_DETAIL, void *, void *, const void *)(unit, NULL);
    if (!detail || field_int(detail, F_EMO_LEVEL) >= field_int(detail, F_EMO_MAX_LEVEL)) return 0;
    int need = field_int(detail, F_EMO_MAX_COINS) - list_count(field(detail, F_EMO_COINS));
    if (need > 0) FN(RVA_EMOTION_CREATE_COIN, int, void *, int, int, const void *)(detail, COIN_POSITIVE, need, NULL);
    return FN(RVA_EMOTION_CHECK_LEVEL_UP, int, void *, const void *)(detail, NULL) & 1;
}

static void level_run(uint64_t *r, int param) {
    (void)r; (void)param;
    if (!main_base()) return;
    void *manager = FN(RVA_BATTLEOBJMGR_GET_INSTANCE, void *, const void *)(NULL);
    void *units = manager ? FN(RVA_BATTLEOBJMGR_GET_ALIVE_LIST, void *, void *, int, const void *)(manager, FACTION_PLAYER, NULL) : NULL;
    for (int i = 0, n = list_count(units); i < n; i++) {
        void *unit = list_get(units, i);
        if (!unit || field_int(unit, F_UNIT_FACTION) != FACTION_PLAYER || field_bool(unit, F_UNIT_DISPOSED) || field_bool(unit, F_BASE_DEAD_REAL) || field_bool(unit, F_BASE_KNOCKOUT)) continue;
        if (level_up_once(unit) && first_hits())
            LOG("[mod max-emotion] unit %#llx is at emotion level %d", (unsigned long long)(uintptr_t)unit, field_int(FN(RVA_UNIT_GET_EMOTION_DETAIL, void *, void *, const void *)(unit, NULL), F_EMO_LEVEL));
    }
}

// Read once, at the first gate hit: the launcher's choices are in the environment by then, but not yet when constructors run
static int mod_enabled(void) {
    static int on = -1;
    if (on < 0) {
        const char *v = getenv("DM_MOD_MAXEMOTION");
        on = v && v[0] == '1';
        LOG("[mod max-emotion] %s (DM_MOD_MAXEMOTION=%s)", on ? "on" : "off", v ? v : "unset");
    }
    return on;
}

static void on_fixed_update_pre(uint64_t *r, int p) {
    if (!mod_enabled()) return;
    if (!(dm_mod_keys() & dm_mod_special())) { s_tick = 0; return; }
    void *stage = (void *)r[0];
    if (!stage || field_int(stage, F_STAGE_PHASE) != PHASE_APPLY_LIBRARIAN_CARD) return;
    if (s_tick++ % TICK_STEPS) return;
    dm_mod_gate_run(r, p, level_run);
}

__attribute__((constructor)) static void mod_max_emotion_attach(void) {
    gate_obs_set(MODGATE_MAX_EMOTION_FIXED_UPDATE_PRE, on_fixed_update_pre);
}
