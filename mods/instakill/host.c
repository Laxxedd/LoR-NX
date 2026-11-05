// Mod "instakill": every librarian (Player faction) die rolls and deals 999, and whatever a librarian die hits dies at once, as host callbacks on observation gates.
//   final_value_post       x19 = BattleDiceBehavior  (UpdateDiceFinalValue epilogue; get_DiceResultValue reads _diceFinalResultValue, DiceVanillaValue reads _diceResultValue)
//   give_damage_post       x19 = BattleDiceBehavior  (GiveDamage, after _diceResultDamage / _diceDamageAll are stored)
//   take_damage_pre        x0 = the unit that was hit, x1 = the BattleDiceBehavior   (BattleUnitModel.OnTakeDamageByAttack entry, once TakeDamage is done)
//   after_give_damage_pre  x0 = the attacker, x1 = the unit that was hit             (BattleUnitModel.AfterGiveDamage entry, once TakeDamage is done)
// A die belongs to a librarian when dice.card.owner.faction == Faction.Player (1); enemies (Faction.Enemy = 0) are untouched.
//   final_value_post: _diceResultValue and _diceFinalResultValue = 999, so the roll wins every clash and feeds the game's own damage code with 999.
//   give_damage_post: _diceResultDamage and _diceDamageAll = 999 (what readers of DiceResultDamage see; the damage the game applies comes from the 999 roll).
//   The two later gates: the 999 roll still goes through the target's own defences, and those can leave 0 damage (an AtkResist.Immune resistance, IsImmuneDmg, IsInvincibleHp, a buff or passive
//   that changes the damage, a fixed 0) or stop the death at the end (IsImmortal, GetMinHp, a passive that cancels it). So after the game's own TakeDamage is over, a target that is not a librarian
//   and is still alive is killed outright: hp = 0 and BattleUnitModel.Die(attacker, callEvent = true), the call TakeDamage makes itself when the hp runs out, so the death goes through the game's own
//   events (OnDie, OnDieOtherUnit, the dying animation, the end-of-battle check). Nothing of the target's is looked at or switched off, so nothing it has can stop this.
//   Both gates run the same kill and each one checks "already dead" first, so a target the game's own damage killed, or that the other gate killed, is left alone: Die runs once.
// Why not INT_MAX: an overkill of ~2 billion fed the kill effects (DamagedBloodEffect / DamagedEffectManager scale with damage and the victim's remaining HP) and the Unity particle/job allocations ran the 4 GB alias region dry within a second; ALLOC_DEFAULT then returned null and a Unity job worker crashed in a memcpy to address 0, about 0.5 s after the kill.
// Why the kill is not in give_damage_post: that gate is in the middle of GiveDamage, before TakeDamage; a death there would be followed by the game's own TakeDamage on a dead unit (a second hit on a target the game is already killing ran the death twice).
// Not touched: units of the Player faction (a librarian hit by a librarian's mass attack lives), and what the game does not hand to GiveDamage at all (a die that deals no hit has hit nothing).
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
#define F_UNIT_HP 0x74                         // BattleUnitModel.<hp>k__BackingField (float)
#define F_UNIT_DISPOSED 0xB8                   // BattleUnitModel.disposed (bool)

#define RVA_IS_DEAD 0x1EEEF80                  // bool BattleUnitBaseModel.IsDead(this, MethodInfo*)
#define RVA_DIE 0x1EFC780                      // void BattleUnitModel.Die(this, BattleUnitModel *attacker, bool callEvent, MethodInfo*)

#define FACTION_PLAYER 1                       // Faction: Enemy 0, Player 1
#define DICE_VALUE 999

static uint8_t *s_main;
enum { G_FINAL, G_DAMAGE, G_TAKE, G_AFTER, G_N };
static int g_hits[G_N];
static const char *const g_gate_name[G_N] = { "final_value_post", "give_damage_post", "take_damage_pre", "after_give_damage_pre" };
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
    if (u[F_BASE_DEAD_REAL] || u[F_BASE_KNOCKOUT]) return 1;
    return FN(RVA_IS_DEAD, int, void *, const void *)(unit, NULL) & 1;
}

// A librarian's hit has been dealt: whatever the target's defences left of it, the target dies unless it is a librarian or is already dead
static void kill_hit_target(void *attacker, void *target, int gate) {
    if (!attacker || !target || attacker == target || !main_base()) return;
    if (unit_faction(attacker) != FACTION_PLAYER || unit_faction(target) == FACTION_PLAYER) return;
    if (((const uint8_t *)target)[F_UNIT_DISPOSED] || unit_is_dead(target)) return;
    const float hp = *(float *)((uintptr_t)target + F_UNIT_HP);
    *(float *)((uintptr_t)target + F_UNIT_HP) = 0.0f;
    FN(RVA_DIE, void, void *, void *, int, const void *)(target, attacker, 1, NULL);
    if (first_hits(gate))
        LOG("[mod instakill] %s: %#llx (hp %.0f, faction %d) killed by %#llx -> %s", g_gate_name[gate], (unsigned long long)(uintptr_t)target, hp, unit_faction(target),
            (unsigned long long)(uintptr_t)attacker, unit_is_dead(target) ? "dead" : "still alive after Die");
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
    if (first_hits(G_DAMAGE)) LOG("[mod instakill] %s: die %#llx deals %d", g_gate_name[G_DAMAGE], (unsigned long long)(uintptr_t)die, DICE_VALUE);
}

// BattleUnitModel.OnTakeDamageByAttack(this = target, atkDice, dmg)
static void take_damage_run(uint64_t *r, int param) {
    (void)param;
    void *target = (void *)r[0], *die = (void *)r[1];
    void *attacker = librarian_owner(die);
    if (attacker) kill_hit_target(attacker, target, G_TAKE);
}

// BattleUnitModel.AfterGiveDamage(this = attacker, target, dmg)
static void after_give_damage_run(uint64_t *r, int param) {
    (void)param;
    kill_hit_target((void *)r[0], (void *)r[1], G_AFTER);
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
static void on_take_damage_pre(uint64_t *r, int p) { if (!mod_enabled()) return; dm_mod_gate_run(r, p, take_damage_run); }
static void on_after_give_damage_pre(uint64_t *r, int p) { if (!mod_enabled()) return; dm_mod_gate_run(r, p, after_give_damage_run); }

__attribute__((constructor)) static void mod_instakill_attach(void) {
    gate_obs_set(MODGATE_INSTAKILL_FINAL_VALUE_POST, on_final_value_post);
    gate_obs_set(MODGATE_INSTAKILL_GIVE_DAMAGE_POST, on_give_damage_post);
    gate_obs_set(MODGATE_INSTAKILL_TAKE_DAMAGE_PRE, on_take_damage_pre);
    gate_obs_set(MODGATE_INSTAKILL_AFTER_GIVE_DAMAGE_PRE, on_after_give_damage_pre);
}
