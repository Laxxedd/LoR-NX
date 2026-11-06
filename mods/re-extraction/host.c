// Mod "re-extraction": qzwxecrv's Re-Extraction (Steam Workshop 2748648361), as host callbacks on observation gates.
// The PC mod is one Harmony prefix on LevelUpUI.OnClickHide: with Ctrl held, a click on the pick UI's Hide button re-rolls the emotion coins of every alive player unit and calls
//   StageController.Instance.GetCurrentStageFloorModel().StartPickEmotionCard() again, so the Abnormality Pages offered are drawn anew. Here the key is the mods' special button (mods/README.md): R3, or Alt in Touchscreen Mode:
//   update_pre  LevelUpUI.Update entry (x0 = the LevelUpUI, once a frame while the UI is active): on a new press of R3 or Alt (dm_mod_keys / dm_mod_special, every input source: physical controller, touch pad, keyboard, Touchscreen Mode's Alt key)
//               while the Abnormality Page pick is showing and nothing is picked yet, re-roll and start the pick again
//   pick_pre    StageLibraryFloorModel.StartPickEmotionCard entry (x0 = the floor model): remembered, to start the pick again from update_pre
// Before the pick starts again, the pick screen's background loop (LevelUpUI._loopSound) is released and cleared: the game only releases it on a pick or on hiding, so a re-roll used to leave the old loop playing for about a minute.
// The re-roll is the PC mod's: for each alive unit of the player's faction with n coins in emotionDetail.totalEmotionCoins, a random number from 1 to n of them become positive and the rest negative.
// The PC mod fills the list with two shared coin objects; here the coins already in the list change their type in place (EmotionCoin._coinType), so nothing is allocated on the managed heap.
// Off by default: DM_MOD_REEXTRACTION=1 turns the callbacks on (the launcher's Mods > Re-Extraction switch, or env.txt). The gates are always in the code and pass through while it is off.
#include "dm.h"
#include "dm_input.h"
#include "hle_mods_gen.h"

void dm_mod_gate_run(uint64_t *regs, int param, void (*fn)(uint64_t *, int));

#define K_LEVELUPUI_GET_ISENABLED 0x1E1CD30u       // LevelUpUI.get_IsEnabled
#define K_STAGELIBFLOOR_START_PICK_EMOTION_CARD 0x1D209E0u
#define K_BATTLEOBJMGR_GET_INSTANCE 0x28807A0u     // BattleObjectManager.get_instance
#define K_BATTLEOBJMGR_GET_ALIVE_LIST_FACTION 0x2885570u
#define K_BATTLEUNIT_GET_EMOTIONDETAIL 0x1EEFAA0u  // BattleUnitModel.get_emotionDetail
#define K_BATTLEEFFECTSOUND_RELEASE 0x1E8B5D0u     // BattleEffectSound.Release

#define FACTION_PLAYER 1                           // Faction: Enemy 0, Player 1
#define F_LEVELUPUI_LOOP_SOUND 0x130               // LevelUpUI._loopSound (BattleEffectSound): the pick screen's background loop
#define F_LEVELUPUI_SELECTED_CARD 0x158            // LevelUpUI.selectedCard (bool): a page has been picked
#define F_LEVELUPUI_IS_EGO 0x159                   // LevelUpUI._isEgo (bool): the EGO pick, not the Abnormality Page pick
#define F_EMOTIONDETAIL_TOTAL_COINS 0x18           // BattleUnitEmotionDetail.totalEmotionCoins (List<EmotionCoin>)
#define F_COIN_TYPE 0x10                           // EmotionCoin._coinType: Positive 0, Negative 1
#define F_LIST_ITEMS 0x10
#define F_LIST_SIZE 0x18
#define F_ARRAY_DATA 0x20
#define COIN_POSITIVE 0
#define COIN_NEGATIVE 1

static uint8_t *s_main;
static void *s_floor;        // the StageLibraryFloorModel of the last StartPickEmotionCard
static int s_r3_down;        // the special button (R3, or Alt in Touchscreen Mode) as the last update_pre saw it
static uint64_t s_rng;
static int g_hits[2];
static int first_hits(int which) { return g_hits[which]++ < 4; }

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

static uint32_t rnd(uint32_t n) {   // xorshift64*, seeded from the clock at the first use
    if (!s_rng) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); s_rng = ((uint64_t)ts.tv_sec << 30) ^ (uint64_t)ts.tv_nsec ^ 0x9E3779B97F4A7C15ull; }
    s_rng ^= s_rng >> 12; s_rng ^= s_rng << 25; s_rng ^= s_rng >> 27;
    return (uint32_t)(((s_rng * 0x2545F4914F6CDD1Dull) >> 32) % n);
}

// The PC mod's loop: positives = 1 + Random.Next(0, count), the first ones of the list; the rest negative
static int reroll_coins(void) {
    void *manager = FN(K_BATTLEOBJMGR_GET_INSTANCE, void *, const void *)(NULL);
    if (!manager) return 0;
    void *units = FN(K_BATTLEOBJMGR_GET_ALIVE_LIST_FACTION, void *, void *, int, const void *)(manager, FACTION_PLAYER, NULL);
    int n = list_count(units), changed = 0;
    for (int i = 0; i < n; i++) {
        void *unit = list_get(units, i);
        if (!unit) continue;
        void *detail = FN(K_BATTLEUNIT_GET_EMOTIONDETAIL, void *, void *, const void *)(unit, NULL);
        void *coins = field(detail, F_EMOTIONDETAIL_TOTAL_COINS);
        int count = list_count(coins);
        if (count <= 0) continue;
        int positives = 1 + (int)rnd((uint32_t)count);
        for (int k = 0; k < count; k++) {
            void *coin = list_get(coins, k);
            if (coin) *(int *)((uintptr_t)coin + F_COIN_TYPE) = k < positives ? COIN_POSITIVE : COIN_NEGATIVE;
        }
        changed++;
    }
    return changed;
}

static void update_run(uint64_t *r, int param) {
    (void)param;
    if (!main_base()) return;
    void *ui = (void *)r[0];
    if (!ui || !s_floor) return;
    if (!(FN(K_LEVELUPUI_GET_ISENABLED, int, void *, const void *)(ui, NULL) & 1)) return;   // the pick UI is not showing
    if (field_bool(ui, F_LEVELUPUI_SELECTED_CARD) || field_bool(ui, F_LEVELUPUI_IS_EGO)) return;   // a page is already picked, or it is the EGO pick
    // The game releases _loopSound when a page is picked (OnSelectPassive) or the UI hides; starting the pick again makes a new loop and overwrites the field, so the old loop would play on with nobody left to stop it. Release it first and clear the field
    void *loop = field(ui, F_LEVELUPUI_LOOP_SOUND);
    if (loop) {
        FN(K_BATTLEEFFECTSOUND_RELEASE, void, void *, const void *)(loop, NULL);
        *(void **)((uintptr_t)ui + F_LEVELUPUI_LOOP_SOUND) = NULL;
    }
    int units = reroll_coins();
    FN(K_STAGELIBFLOOR_START_PICK_EMOTION_CARD, void, void *, const void *)(s_floor, NULL);
    if (first_hits(0)) LOG("[mod re-extraction] R3 / Alt: coins of %d unit(s) re-rolled, pick %#llx started again", units, (unsigned long long)(uintptr_t)s_floor);
}

// Read once, at the first gate hit: the launcher's choices are in the environment by then, but not yet when constructors run
static int mod_enabled(void) {
    static int on = -1;
    if (on < 0) {
        const char *v = getenv("DM_MOD_REEXTRACTION");
        on = v && v[0] == '1';
        LOG("[mod re-extraction] %s (DM_MOD_REEXTRACTION=%s)", on ? "on" : "off", v ? v : "unset");
    }
    return on;
}

// A frame's work is only the key read: the game's functions run (dm_mod_gate_run) on a new press of the special button alone
static void on_update_pre(uint64_t *r, int p) {
    if (!mod_enabled()) return;
    int down = (dm_mod_keys() & dm_mod_special()) != 0;
    int pressed = down && !s_r3_down;
    s_r3_down = down;
    if (pressed) dm_mod_gate_run(r, p, update_run);
}
static void on_pick_pre(uint64_t *r, int p) {
    (void)p;
    if (!mod_enabled()) return;
    s_floor = (void *)r[0];
    if (first_hits(1)) LOG("[mod re-extraction] pick_pre: floor model %#llx", (unsigned long long)r[0]);
}

__attribute__((constructor)) static void mod_re_extraction_attach(void) {
    gate_obs_set(MODGATE_RE_EXTRACTION_UPDATE_PRE, on_update_pre);
    gate_obs_set(MODGATE_RE_EXTRACTION_PICK_PRE, on_pick_pre);
}
