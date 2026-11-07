// Mod "skip-intro", host half: the screen before the opening AMV (the auto-save notice, AutoSavingUI) ends on a tap or a key press in Touchscreen Mode.
// The game ends that notice only on Input.GetButtonDown of its confirm button (A), which Touchscreen Mode has no key for, so a tap on the screen did nothing until the notice ran out by itself.
// AutoSavingUI.Update does, with _isPlayingNotification set: if (Input.GetButtonDown(...)) { StopCoroutine(_notificationCoroutine); _isPlayingNotification = false; OnEndDisplayNotification(); }
//   splash_pre  AutoSavingUI.Update, the join point before the _isPlayingNotification check (x19 = the AutoSavingUI, once a frame while the notice is active): in Touchscreen Mode, while the notice is playing,
//               Input.anyKeyDown (Touch UI's touchpad mouse and keys: a tap or click, Space, Esc, Shift, Ctrl, Alt) runs the game's own sequence above, so the opening goes on as it does after A
// Only Touchscreen Mode: with a controller or the touch gamepad (a tap is A there) the game's own check is enough, and Input.anyKeyDown would count every pad button there.
// The edge comes from the game's own Input.anyKeyDown, not from dm_mouse_frame: Touch UI replaces that native in Touchscreen Mode and keys the touchpad's edges by Time.frameCount, which a second reader would disturb.
// Off by default: DM_MOD_SKIPINTRO=1 turns the callback on (the launcher's Mods > Skip Intro switch, or env.txt). The gate is always in the code and passes through while it is off.
#include "dm.h"
#include "hle_mods_gen.h"

void dm_mod_gate_run(uint64_t *regs, int param, void (*fn)(uint64_t *, int));
int dm_touchscreen_mode(void);

#define K_AUTOSAVINGUI_ON_END_DISPLAY_NOTIFICATION 0x353D440u   // AutoSavingUI.OnEndDisplayNotification
#define K_MONOBEHAVIOUR_STOP_COROUTINE 0x19B1770u               // MonoBehaviour.StopCoroutine(Coroutine)
#define K_INPUT_GET_ANYKEYDOWN 0x35309A0u                       // UnityEngine.Input.get_anyKeyDown

#define F_AUTOSAVINGUI_IS_PLAYING_NOTIFICATION 0x59             // AutoSavingUI._isPlayingNotification (bool)
#define F_AUTOSAVINGUI_NOTIFICATION_COROUTINE 0x60              // AutoSavingUI._notificationCoroutine (Coroutine)

static uint8_t *s_main;

static uint8_t *main_base(void) {
    if (!s_main)
        for (int i = 0; i < g_nmod; i++)
            if (!strcmp(g_mod[i].name, "main") && !g_mod[i].nro) { s_main = g_mod[i].base; break; }
    return s_main;
}

#define FN(rva, ret, ...) ((ret (*)(__VA_ARGS__))(s_main + (rva)))

static int playing(const uint8_t *ui) { return ui && ui[F_AUTOSAVINGUI_IS_PLAYING_NOTIFICATION] != 0; }

static void splash_run(uint64_t *r, int p) {
    (void)p;
    if (!main_base()) return;
    uint8_t *ui = (uint8_t *)(uintptr_t)r[19];
    if (!playing(ui)) return;
    if (!(FN(K_INPUT_GET_ANYKEYDOWN, uint32_t, const void *)(NULL) & 1u)) return;
    void *routine = *(void **)(ui + F_AUTOSAVINGUI_NOTIFICATION_COROUTINE);
    if (routine) FN(K_MONOBEHAVIOUR_STOP_COROUTINE, void, void *, void *, const void *)(ui, routine, NULL);
    ui[F_AUTOSAVINGUI_IS_PLAYING_NOTIFICATION] = 0;
    FN(K_AUTOSAVINGUI_ON_END_DISPLAY_NOTIFICATION, void, void *, const void *)(ui, NULL);
    static int logged;
    if (!logged++) LOG("[mod skip-intro] auto-save notice %p ended by a tap / key press", (void *)ui);
}

// Read once, at the first gate hit: the launcher's choices are in the environment by then, but not yet when constructors run
static int mod_enabled(void) {
    static int on = -1;
    if (on < 0) {
        const char *v = getenv("DM_MOD_SKIPINTRO");
        on = v && v[0] == '1';
        LOG("[mod skip-intro] %s (DM_MOD_SKIPINTRO=%s)", on ? "on" : "off", v ? v : "unset");
    }
    return on;
}

// The cheap checks run on the gate stack; the game's functions only while the notice is playing (dm_mod_gate_run)
static void on_splash_pre(uint64_t *r, int p) {
    if (!mod_enabled() || !dm_touchscreen_mode()) return;
    if (!playing((const uint8_t *)(uintptr_t)r[19])) return;
    dm_mod_gate_run(r, p, splash_run);
}

__attribute__((constructor)) static void mod_skip_intro_attach(void) {
    gate_obs_set(MODGATE_SKIP_INTRO_SPLASH_PRE, on_splash_pre);
}
