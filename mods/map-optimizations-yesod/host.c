// Mod "map-optimizations-yesod": uGuardian's Map Optimizations: Yesod (Steam Workshop 2798869790), as host callbacks on observation gates.
// The PC mod swaps Yesod's map prefab for an optimized one from an asset bundle whose manager is a script class (YesodMapManager_Optimized) that does not exist in the IL2CPP build, so the bundle cannot be loaded here.
// What is ported are its three particle settings, applied to the game's own Yesod map (a YesodMapManager); a switched-off object stays inactive:
//   DM_MOD_YESOD_GEARSPARKS  the 13 gear sparks (YesodMapManager._gearParticles), default off
//   DM_MOD_YESOD_SMOKE       the background smoke (_groundParticle), default on
//   DM_MOD_YESOD_SCREENSPARKS the screen sparks (the root object "spark_g1 (2)"), default on
// Layer switches for finding what costs GPU time (1 = shown, 0 = hidden), all default on:
//   DM_MOD_YESOD_BUILDINGS   the building sprites (_spriteBuildingList)
//   DM_MOD_YESOD_BGLAYERS    the background sprite layers (_spriteList, each one's transform object)
//   DM_MOD_YESOD_GEARS       the gear objects (_gearList)
// The game switches them back on in three places, so each is followed by the same clean-up:
//   start_pre    YesodMapManager.Start entry (x0 = the map)
//   enable_pre   MapManager.EnableMap entry (x0 = the map): remembered
//   enable_ret1, enable_ret2  the last instruction before each of the two returns of MapManager.EnableMap (a ret cannot take a gate; the registers are already restored): the roots were just switched, so clean up the remembered map
//   quake_post   just after the call of YesodMapManager.ActiveSpark in <EarthQuake>.MoveNext (x20 = the map; ActiveDusts is inlined just before): the 10 second loop switches smoke and gear sparks on again
// Off by default: DM_MOD_YESOD=1 turns the callbacks on (the launcher's Mods > Map Optimizations: Yesod switch, or env.txt). The gates are always in the code and pass through while it is off.
#include "dm.h"
#include "hle_mods_gen.h"

void dm_mod_gate_run(uint64_t *regs, int param, void (*fn)(uint64_t *, int));

#define K_COMPONENT_GET_GAMEOBJECT 0x19AE220u
#define K_GAMEOBJECT_SET_ACTIVE 0x19AFD70u
#define K_OBJECT_GET_NAME 0x19B4080u

#define F_CLASS_NAME 0x10
#define F_CLASS_PARENT 0x58
#define F_STRING_LENGTH 0x10
#define F_STRING_CHARS 0x14
#define F_ARRAY_LENGTH 0x18
#define F_ARRAY_DATA 0x20
#define F_MAP_SEPHIRAH 0x30                     // MapManager.sephirahType
#define F_MAP_ROOTS 0x60                        // MapManager._roots (GameObject[])
#define F_LIST_ITEMS 0x10                       // List<T>._items
#define F_LIST_SIZE 0x18                        // List<T>._size
#define F_YESOD_GEAR_LIST 0xB8                  // YesodMapManager._gearList (List<MapBgObjRotator>)
#define F_YESOD_BUILDING_LIST 0xC0              // YesodMapManager._spriteBuildingList (List<SpriteRenderer>)
#define F_YESOD_SPRITE_LIST 0xC8                // YesodMapManager._spriteList (List<YesodSpriteBG>)
#define F_YESODBG_TRANSFORM 0x28                // YesodSpriteBG.transform
#define F_YESOD_GEAR_PARTICLES 0xD0             // YesodMapManager._gearParticles (ParticleSystem[])
#define F_YESOD_GROUND_PARTICLE 0xE8            // YesodMapManager._groundParticle (GameObject)
#define SCREEN_SPARKS_NAME "spark_g1 (2)"

static uint8_t *s_main;
static void *s_enable_map;
static int g_hits[3];
static int first_hits(int which) { return g_hits[which]++ < 4; }

static uint8_t *main_base(void) {
    if (!s_main)
        for (int i = 0; i < g_nmod; i++)
            if (!strcmp(g_mod[i].name, "main") && !g_mod[i].nro) { s_main = g_mod[i].base; break; }
    return s_main;
}

#define FN(rva, ret, ...) ((ret (*)(__VA_ARGS__))(s_main + (rva)))

static void *field(void *self, uintptr_t off) { return self ? *(void *const *)((uintptr_t)self + off) : NULL; }
static int field_int(void *self, uintptr_t off) { return self ? *(const int *)((uintptr_t)self + off) : 0; }

static int is_instance_of(void *obj, const char *class_name) {
    if (!obj) return 0;
    void *klass = *(void *const *)obj;
    for (; klass; klass = field(klass, F_CLASS_PARENT)) {
        const char *n = *(const char *const *)((uintptr_t)klass + F_CLASS_NAME);
        if (n && !strcmp(n, class_name)) return 1;
    }
    return 0;
}

static int string_is(void *str, const char *ascii) {
    if (!str) return 0;
    int n = field_int(str, F_STRING_LENGTH);
    if (n != (int)strlen(ascii)) return 0;
    const uint16_t *c = (const uint16_t *)((uintptr_t)str + F_STRING_CHARS);
    for (int i = 0; i < n; i++) if (c[i] != (uint16_t)(uint8_t)ascii[i]) return 0;
    return 1;
}

static int setting(const char *env, int dflt) {
    const char *v = getenv(env);
    return v && v[0] ? v[0] == '1' : dflt;
}

static void deactivate(void *game_object) {
    if (game_object) FN(K_GAMEOBJECT_SET_ACTIVE, void, void *, int, const void *)(game_object, 0, NULL);
}

static void hide_list(void *list, uintptr_t member_off, int via_transform) {
    void *items = field(list, F_LIST_ITEMS);
    int n = field_int(list, F_LIST_SIZE);
    int cap = field_int(items, F_ARRAY_LENGTH);
    if (n > cap) n = cap;
    for (int i = 0; i < n; i++) {
        void *e = *(void *const *)((uintptr_t)items + F_ARRAY_DATA + sizeof(void *) * (size_t)i);
        if (e && via_transform) e = field(e, member_off);
        if (e) deactivate(FN(K_COMPONENT_GET_GAMEOBJECT, void *, void *, const void *)(e, NULL));
    }
}

static void clean_map(void *map) {
    if (!is_instance_of(map, "YesodMapManager")) return;
    if (!setting("DM_MOD_YESOD_BUILDINGS", 1)) hide_list(field(map, F_YESOD_BUILDING_LIST), 0, 0);
    if (!setting("DM_MOD_YESOD_BGLAYERS", 1)) hide_list(field(map, F_YESOD_SPRITE_LIST), F_YESODBG_TRANSFORM, 1);
    if (!setting("DM_MOD_YESOD_GEARS", 1)) hide_list(field(map, F_YESOD_GEAR_LIST), 0, 0);
    if (!setting("DM_MOD_YESOD_GEARSPARKS", 0)) {
        void *arr = field(map, F_YESOD_GEAR_PARTICLES);
        int n = field_int(arr, F_ARRAY_LENGTH);
        for (int i = 0; i < n; i++) {
            void *ps = *(void *const *)((uintptr_t)arr + F_ARRAY_DATA + sizeof(void *) * (size_t)i);
            if (ps) deactivate(FN(K_COMPONENT_GET_GAMEOBJECT, void *, void *, const void *)(ps, NULL));
        }
    }
    if (!setting("DM_MOD_YESOD_SMOKE", 1)) deactivate(field(map, F_YESOD_GROUND_PARTICLE));
    if (!setting("DM_MOD_YESOD_SCREENSPARKS", 1)) {
        void *roots = field(map, F_MAP_ROOTS);
        int n = field_int(roots, F_ARRAY_LENGTH);
        for (int i = 0; i < n; i++) {
            void *go = *(void *const *)((uintptr_t)roots + F_ARRAY_DATA + sizeof(void *) * (size_t)i);
            if (go && string_is(FN(K_OBJECT_GET_NAME, void *, void *, const void *)(go, NULL), SCREEN_SPARKS_NAME)) deactivate(go);
        }
    }
}

static void start_run(uint64_t *r, int param) { (void)param; if (main_base()) { clean_map((void *)r[0]); if (first_hits(0)) LOG("[mod map-optimizations-yesod] start: map %#llx", (unsigned long long)r[0]); } }
static void enable_run(uint64_t *r, int param) { (void)r; (void)param; if (main_base()) { clean_map(s_enable_map); if (first_hits(1)) LOG("[mod map-optimizations-yesod] enable: map %#llx", (unsigned long long)(uintptr_t)s_enable_map); } }
static void quake_run(uint64_t *r, int param) { (void)param; if (main_base()) { clean_map((void *)r[20]); if (first_hits(2)) LOG("[mod map-optimizations-yesod] quake: map %#llx", (unsigned long long)r[20]); } }

static int mod_enabled(void) {
    static int on = -1;
    if (on < 0) {
        const char *v = getenv("DM_MOD_YESOD");
        on = v && v[0] == '1';
        LOG("[mod map-optimizations-yesod] %s (DM_MOD_YESOD=%s)", on ? "on" : "off", v ? v : "unset");
    }
    return on;
}

static void on_start_pre(uint64_t *r, int p) { if (mod_enabled()) dm_mod_gate_run(r, p, start_run); }
static void on_enable_pre(uint64_t *r, int p) { (void)p; if (mod_enabled()) s_enable_map = (void *)r[0]; }
static void on_enable_ret(uint64_t *r, int p) { if (mod_enabled() && s_enable_map) dm_mod_gate_run(r, p, enable_run); }
static void on_quake_post(uint64_t *r, int p) { if (mod_enabled()) dm_mod_gate_run(r, p, quake_run); }

__attribute__((constructor)) static void mod_map_optimizations_yesod_attach(void) {
    gate_obs_set(MODGATE_MAP_OPTIMIZATIONS_YESOD_START_PRE, on_start_pre);
    gate_obs_set(MODGATE_MAP_OPTIMIZATIONS_YESOD_ENABLE_PRE, on_enable_pre);
    gate_obs_set(MODGATE_MAP_OPTIMIZATIONS_YESOD_ENABLE_RET1, on_enable_ret);
    gate_obs_set(MODGATE_MAP_OPTIMIZATIONS_YESOD_ENABLE_RET2, on_enable_ret);
    gate_obs_set(MODGATE_MAP_OPTIMIZATIONS_YESOD_QUAKE_POST, on_quake_post);
}
