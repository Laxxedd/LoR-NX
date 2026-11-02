// Mod "instakill": every librarian (Player faction) die rolls and deals the 32-bit integer limit (2147483647), as host callbacks on observation gates.
//   final_value_post  x19 = BattleDiceBehavior  (UpdateDiceFinalValue epilogue; get_DiceResultValue reads _diceFinalResultValue, DiceVanillaValue reads _diceResultValue)
//   give_damage_post  x19 = BattleDiceBehavior  (GiveDamage, after _diceResultDamage / _diceDamageAll are stored)
// A die belongs to a librarian when dice.card.owner.faction == Faction.Player (1); enemies (Faction.Enemy = 0) are untouched.
//   final_value_post: _diceResultValue and _diceFinalResultValue = INT_MAX, so the roll wins every clash and feeds the game's own damage code with INT_MAX.
//   give_damage_post: _diceResultDamage and _diceDamageAll = INT_MAX (the damage the game's own code applies comes from the INT_MAX roll;
//                     no extra TakeDamage call: a second hit on a target the game is already killing ran the death twice and crashed a Unity job thread about 0.5 s later)
// Off by default: DM_MOD_INSTAKILL=1 turns the callbacks on (the launcher's Mods > instakill switch, or env.txt). The gates are always in the code and pass through while it is off.
#include "dm.h"
#include "hle_mods_gen.h"

void dm_mod_gate_run(uint64_t *regs, int param, void (*fn)(uint64_t *, int));

#define F_DICE_CARD 0x20                       // BattleDiceBehavior.card
#define F_DICE_RESULT_VALUE 0x30               // BattleDiceBehavior._diceResultValue (int)
#define F_DICE_FINAL_VALUE 0x4C                // BattleDiceBehavior._diceFinalResultValue (int)
#define F_DICE_RESULT_DAMAGE 0x54              // BattleDiceBehavior._diceResultDamage (int)
#define F_DICE_DAMAGE_ALL 0x58                 // BattleDiceBehavior._diceDamageAll (int)
#define F_CARD_OWNER 0x18                      // BattlePlayingCardDataInUnitModel.owner
#define F_UNIT_FACTION 0x60                    // BattleUnitModel.faction

#define FACTION_PLAYER 1                       // Faction: Enemy 0, Player 1
#define INT_LIMIT 2147483647

static uint8_t *s_main;
static int g_hits[2];
static const char *const g_gate_name[2] = { "final_value_post", "give_damage_post" };
static int first_hits(int which) { return g_hits[which]++ < 4; }

static uint8_t *main_base(void) {
    if (!s_main)
        for (int i = 0; i < g_nmod; i++)
            if (!strcmp(g_mod[i].name, "main") && !g_mod[i].nro) { s_main = g_mod[i].base; break; }
    return s_main;
}

#define FN(rva, ret, ...) ((ret (*)(__VA_ARGS__))(s_main + (rva)))

// the owner of a die when it is a librarian's, else NULL
static void *librarian_owner(void *die) {
    if (!die) return NULL;
    void *card = *(void **)((uintptr_t)die + F_DICE_CARD);
    if (!card) return NULL;
    void *owner = *(void **)((uintptr_t)card + F_CARD_OWNER);
    if (!owner) return NULL;
    return *(int *)((uintptr_t)owner + F_UNIT_FACTION) == FACTION_PLAYER ? owner : NULL;
}

static void final_value_run(uint64_t *r, int param) {
    (void)param;
    void *die = (void *)r[19];
    if (!librarian_owner(die)) return;
    *(int *)((uintptr_t)die + F_DICE_RESULT_VALUE) = INT_LIMIT;
    *(int *)((uintptr_t)die + F_DICE_FINAL_VALUE) = INT_LIMIT;
    if (first_hits(0)) LOG("[mod instakill] %s: die %#llx rolls %d", g_gate_name[0], (unsigned long long)(uintptr_t)die, INT_LIMIT);
}

static void give_damage_run(uint64_t *r, int param) {
    (void)param;
    void *die = (void *)r[19];
    void *owner = librarian_owner(die);
    if (!owner) return;
    *(int *)((uintptr_t)die + F_DICE_RESULT_DAMAGE) = INT_LIMIT;
    *(int *)((uintptr_t)die + F_DICE_DAMAGE_ALL) = INT_LIMIT;
    if (first_hits(1)) LOG("[mod instakill] %s: die %#llx deals %d", g_gate_name[1], (unsigned long long)(uintptr_t)die, INT_LIMIT);
}

// Read once, at the first gate hit: the launcher's choices are in the environment by then, but not yet when constructors run
static int mod_enabled(void) {
    static int on = -1;
    if (on < 0) {
        const char *v = getenv("DM_MOD_INSTAKILL");
        on = v && v[0] == '1';
        LOG("[mod instakill] %s (DM_MOD_INSTAKILL=%s)", on ? "on" : "off", v ? v : "unset");
    }
    return on;
}
static void on_final_value_post(uint64_t *r, int p) { if (!mod_enabled()) return; dm_mod_gate_run(r, p, final_value_run); }
static void on_give_damage_post(uint64_t *r, int p) { if (!mod_enabled()) return; dm_mod_gate_run(r, p, give_damage_run); }

__attribute__((constructor)) static void mod_instakill_attach(void) {
    gate_obs_set(MODGATE_INSTAKILL_FINAL_VALUE_POST, on_final_value_post);
    gate_obs_set(MODGATE_INSTAKILL_GIVE_DAMAGE_POST, on_give_damage_post);
}
