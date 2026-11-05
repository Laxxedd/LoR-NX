// Mod "instakill": every librarian (Player faction) die rolls 999, and whatever a librarian die hits dies at once, as host callbacks on two observation gates.
//   final_value_post  x19 = BattleDiceBehavior  (UpdateDiceFinalValue epilogue): _diceResultValue and _diceFinalResultValue = 999, so the roll wins every clash and feeds the game's own damage code.
//   give_damage_post  x19 = BattleDiceBehavior, x27 = &card, x28 = &target  (BattleDiceBehavior.GiveDamage at 0x2450b08)
// The 999 roll still goes through the target's own defences, and those can leave 0 damage (AtkResist.Immune, IsInvincible / IsImmuneByFarAtk turn the damage argument into 0, buffs, ChangeDamage, a fixed 0)
// or stop the death (IsImmortal and GetMinHp keep hp at 1 or more inside TakeDamage). give_damage_post sits right after the game's own TakeDamage and TakeBreakDamage calls (w25 = the damage really taken is
// stored there) and before GiveDamage records the death state and decides whether to call OnTakeDamageByAttack on a living target. So a target that is not a librarian and is still alive is killed here
// with BattleUnitModel.Die(target, attacker, callEvent = false), the exact call TakeDamage itself makes when the hp runs out. Die returns at once for a unit already dead or knocked out, and sets
// the dead flag and the hp (the dead line) itself. The rest of GiveDamage then sees a dead target, as after a natural kill. Nothing of the target's is looked at or switched off.
// The recorded _diceResultDamage / _diceDamageAll are set to 999 too (what readers of DiceResultDamage see; the damage actually applied is the game's own).
// Why not INT_MAX: an overkill of ~2 billion fed the kill effects (DamagedBloodEffect / DamagedEffectManager scale with damage and the victim's remaining HP) and the Unity particle/job allocations ran the 4 GB alias region dry within a second; ALLOC_DEFAULT then returned null and a Unity job worker crashed in a memcpy to address 0, about 0.5 s after the kill.
// Not touched: units of the Player faction (a librarian hit by a librarian's mass attack lives), and dice the game never hands to TakeDamage (a die blocked before damage is dealt has hit nothing).
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
#define F_BASE_DEAD_REAL 0x20                  // BattleUnitBaseModel._isDeadReal (bool)
#define F_BASE_KNOCKOUT 0x21                   // BattleUnitBaseModel._isKnockout (bool)
#define F_UNIT_FACTION 0x60                    // BattleUnitModel.faction
#define F_UNIT_DISPOSED 0xB8                   // BattleUnitModel.disposed (bool)

#define RVA_DIE 0x1EFC780                      // void BattleUnitModel.Die(this, BattleUnitModel *attacker, bool callEvent, MethodInfo*)

#define FACTION_PLAYER 1                       // Faction: Enemy 0, Player 1
#define DICE_VALUE 999

static uint8_t *s_main;
enum { G_FINAL, G_DAMAGE, G_N };
static int g_hits[G_N + 1];
static const char *const g_gate_name[G_N] = { "final_value_post", "give_damage_post" };
static int first_hits(int which) { return g_hits[which]++ < 4; }

static uint8_t *main_base(void) {
    if (!s_main)
        for (int i = 0; i < g_nmod; i++)
            if (!strcmp(g_mod[i].name, "main") && !g_mod[i].nro) { s_main = g_mod[i].base; break; }
    return s_main;
}

#define FN(rva, ret, ...) ((ret (*)(__VA_ARGS__))(main_base() + (rva)))

static int unit_faction(void *unit) { return *(int *)((uintptr_t)unit + F_UNIT_FACTION); }

// the owner of a die when it is a librarian's, else NULL
static void *librarian_owner(void *die) {
    if (!die) return NULL;
    void *card = *(void **)((uintptr_t)die + F_DICE_CARD);
    if (!card) return NULL;
    void *owner = *(void **)((uintptr_t)card + F_CARD_OWNER);
    if (!owner) return NULL;
    return unit_faction(owner) == FACTION_PLAYER ? owner : NULL;
}

static int unit_is_dead(void *unit) {
    const uint8_t *u = (const uint8_t *)unit;
    return u[F_BASE_DEAD_REAL] || u[F_BASE_KNOCKOUT];
}

static void final_value_run(uint64_t *r, int param) {
    (void)param;
    void *die = (void *)r[19];
    if (!librarian_owner(die)) return;
    *(int *)((uintptr_t)die + F_DICE_RESULT_VALUE) = DICE_VALUE;
    *(int *)((uintptr_t)die + F_DICE_FINAL_VALUE) = DICE_VALUE;
    if (first_hits(G_FINAL)) LOG("[mod instakill] %s: die %#llx rolls %d", g_gate_name[G_FINAL], (unsigned long long)(uintptr_t)die, DICE_VALUE);
}

static void give_damage_run(uint64_t *r, int param) {
    (void)param;
    void *die = (void *)r[19];
    void *owner = librarian_owner(die);
    if (!owner) return;
    *(int *)((uintptr_t)die + F_DICE_RESULT_DAMAGE) = DICE_VALUE;
    *(int *)((uintptr_t)die + F_DICE_DAMAGE_ALL) = DICE_VALUE;
    // x28 = &closure.target, kept in x28 for the whole of GiveDamage; checked against the attacker's class before it is trusted
    void **slot = (void **)r[28];
    void *target = slot ? *slot : NULL;
    if (!target || target == owner || !main_base()) return;
    if (*(void **)target != *(void **)owner) { if (first_hits(G_N)) LOG("[mod instakill] target %#llx is not a unit, left alone", (unsigned long long)(uintptr_t)target); return; }
    if (unit_faction(target) == FACTION_PLAYER || ((const uint8_t *)target)[F_UNIT_DISPOSED] || unit_is_dead(target)) return;
    FN(RVA_DIE, void, void *, void *, int, const void *)(target, owner, 0, NULL);
    if (first_hits(G_DAMAGE))
        LOG("[mod instakill] %s: unit %#llx (faction %d) killed by %#llx -> %s", g_gate_name[G_DAMAGE], (unsigned long long)(uintptr_t)target, unit_faction(target), (unsigned long long)(uintptr_t)owner,
            unit_is_dead(target) ? "dead" : "still alive after Die");
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
