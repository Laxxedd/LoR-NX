// Touchscreen Mode's virtual mouse and keyboard modifiers: dm_mouse_* / dm_key_modifier -> mouse_fill / keyboard_fill, checked against hand-written byte layouts
// (MouseState 0x28 bytes, KeyboardState 0x30 bytes). Runs with DM_TOUCHSCREEN=1 set by the test itself: plain, with DM_TRACKPAD_TOUCH=0 (the left click is a mouse button), and as `t_mouse touch` with the default (the left click is a touch-screen press at the cursor).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
enum { DM_MOUSE_LEFT = 1, DM_MOUSE_RIGHT = 2 };
enum { DM_KEY_CTRL = 1, DM_KEY_SHIFT = 2, DM_KEY_ALT = 4 };
void dm_mouse_move(float dx, float dy);
void dm_mouse_button(uint32_t mask, int down);
void dm_mouse_wheel(int notches);
void dm_mouse_drag(int down);
void dm_key_modifier(uint32_t mask, int down);
int mouse_fill(void *out, int n, int64_t top);
int keyboard_fill(void *out, int n, int64_t top);
typedef struct { uint32_t id; float x, y; } dm_touch;
static int fails, cases;
typedef struct { int64_t samp; int32_t x, y, dx, dy, wx, wy; uint32_t buttons, attr; } mouse_t;
_Static_assert(sizeof(mouse_t) == 0x28, "MouseState is 0x28 bytes");
static void check(const char *what, int ok) { cases++; if (!ok) fails++; printf("%s %s\n", ok ? "✓" : "✗", what); }
static int same(const mouse_t *g, mouse_t w) { return !memcmp(g, &w, sizeof w); }
int touch_fill_n(void *out, int max, uint64_t now_ns);
// The left click as a touch-screen press at the cursor (the default in Touchscreen Mode: the touch-ui mod makes the game read the touch screen, not the mouse's buttons)
static int touch_click_main(void) {
    mouse_t m[2]; uint8_t t[0x10 + 0x28]; int32_t v[4];
    mouse_fill(m, 1, 1);
    dm_mouse_move(100, 50);   // the cursor starts at the panel centre (640, 360); moving it alone presses nothing
    check("moving the cursor gives no touch", touch_fill_n(t, 1, 1000) == 0);
    dm_mouse_button(DM_MOUSE_LEFT, 1);
    check("a left click reaches the touch screen: Start at the cursor", touch_fill_n(t, 1, 2000) == 1 && (memcpy(v, t + 0x10 + 8, 16), v[0] == 1 && v[1] == 0 && v[2] == 740 && v[3] == 410));
    dm_mouse_button(DM_MOUSE_LEFT, 0);
    check("..then End", touch_fill_n(t, 1, 3000) == 1 && (memcpy(v, t + 0x10 + 8, 16), v[0] == 2 && v[2] == 740 && v[3] == 410));
    check("..then nothing", touch_fill_n(t, 1, 4000) == 0);
    dm_mouse_button(DM_MOUSE_LEFT, 1); dm_mouse_button(DM_MOUSE_LEFT, 0);
    check("a click between two reads still gives a Start", touch_fill_n(t, 1, 5000) == 1 && (memcpy(v, t + 0x10 + 8, 16), v[0] == 1));
    touch_fill_n(t, 1, 6000);
    check("the mouse does not report the left button as well", (dm_mouse_button(DM_MOUSE_LEFT, 1), mouse_fill(m, 1, 20) == 1 && !(m[0].buttons & DM_MOUSE_LEFT)));
    dm_mouse_button(DM_MOUSE_LEFT, 0);
    dm_mouse_button(DM_MOUSE_RIGHT, 1);
    check("the right button stays a mouse button", mouse_fill(m, 1, 21) == 1 && m[0].buttons == DM_MOUSE_RIGHT && touch_fill_n(t, 1, 7000) == 1);   // the one touch is the End of the click above
    // a finger dragging the touchpad holds a touch under the cursor, which follows it, and lets go without a click
    mouse_fill(m, 1, 30); touch_fill_n(t, 1, 8000); touch_fill_n(t, 1, 8001);
    dm_mouse_drag(1);
    check("a drag holds a touch at the cursor: Start", touch_fill_n(t, 1, 9000) == 1 && (memcpy(v, t + 0x18, 16), v[0] == 1 && v[2] == 740 && v[3] == 410));
    dm_mouse_move(10, -10);
    check("..it follows the cursor", touch_fill_n(t, 1, 10000) == 1 && (memcpy(v, t + 0x18, 16), v[0] == 0 && v[2] == 750 && v[3] == 400));
    dm_mouse_move(5, 5); dm_mouse_drag(0);
    check("..lifting ends it where the cursor is", touch_fill_n(t, 1, 11000) == 1 && (memcpy(v, t + 0x18, 16), v[0] == 2 && v[2] == 755 && v[3] == 405));
    check("..and nothing follows", touch_fill_n(t, 1, 12000) == 0);
    dm_mouse_drag(1); dm_mouse_button(DM_MOUSE_LEFT, 1); dm_mouse_button(DM_MOUSE_LEFT, 0);
    check("a click ending during a drag does not let the touch go", (touch_fill_n(t, 1, 13000), touch_fill_n(t, 1, 13001) == 1 && (memcpy(v, t + 0x18, 16), v[0] == 0)));
    dm_mouse_drag(0); touch_fill_n(t, 1, 14000); touch_fill_n(t, 1, 14001);
    printf("%d / %d passed\n", cases - fails, cases);
    return fails != 0;
}
int main(int argc, char **argv) {
    setenv("DM_TOUCHSCREEN", "1", 1);
    if (argc > 1 && !strcmp(argv[1], "touch")) return touch_click_main();   // DM_TRACKPAD_TOUCH unset: the default
    setenv("DM_TRACKPAD_TOUCH", "0", 1);   // the mouse-button checks below
    mouse_t m[3];
    check("mouse starts at the panel centre, connected, nothing pressed", mouse_fill(m, 1, 100) == 1 && same(&m[0], (mouse_t){100, 640, 360, 0, 0, 0, 0, 0, 3}));
    dm_mouse_move(10.5f, -20.25f);
    check("movement is reported once, whole pixels", mouse_fill(m, 1, 101) == 1 && same(&m[0], (mouse_t){101, 650, 339, 10, -20, 0, 0, 0, 3}));
    check("and not again", mouse_fill(m, 1, 102) == 1 && same(&m[0], (mouse_t){102, 650, 339, 0, 0, 0, 0, 0, 3}));
    dm_mouse_move(0, 0);
    dm_mouse_move(-1000, 5000);
    check("the cursor is clamped to the panel (0..1279, 0..719)", mouse_fill(m, 1, 103) == 1 && m[0].x == 0 && m[0].y == 719);
    dm_mouse_move(640, -359);
    mouse_fill(m, 1, 104);
    dm_mouse_button(DM_MOUSE_LEFT, 1); dm_mouse_button(DM_MOUSE_LEFT, 0);
    check("a press and release between two reads is reported once", mouse_fill(m, 2, 110) == 1 + 1 && m[0].buttons == DM_MOUSE_LEFT && m[1].buttons == 0 && m[0].samp == 110 && m[1].samp == 109);
    check("then it is released", mouse_fill(m, 2, 120) == 2 && m[0].buttons == 0 && m[1].buttons == DM_MOUSE_LEFT);
    dm_mouse_button(DM_MOUSE_RIGHT, 1);
    check("a held button stays down over reads", mouse_fill(m, 1, 130) == 1 && m[0].buttons == DM_MOUSE_RIGHT);
    check("..and the next", mouse_fill(m, 1, 131) == 1 && m[0].buttons == DM_MOUSE_RIGHT);
    dm_mouse_button(DM_MOUSE_RIGHT, 0);
    check("released", mouse_fill(m, 1, 132) == 1 && m[0].buttons == 0);
    dm_mouse_wheel(-2); dm_mouse_wheel(3);
    check("wheel notches add up and are reported once", mouse_fill(m, 1, 140) == 1 && m[0].wy == 1 && m[0].wx == 0 && mouse_fill(m, 1, 141) == 1 && m[0].wy == 0);
    uint8_t k[0x30 * 2];
    check("keyboard is connected with no modifier", keyboard_fill(k, 1, 200) == 1 && *(int64_t *)k == 200 && *(uint64_t *)(k + 8) == 0 && k[0x10 + 28] == 0);
    dm_key_modifier(DM_KEY_SHIFT, 1);
    check("Shift: modifier bit 1 and key 225", keyboard_fill(k, 1, 201) == 1 && *(uint64_t *)(k + 8) == 2 && k[0x10 + 28] == 2);
    dm_key_modifier(DM_KEY_CTRL | DM_KEY_ALT, 1);
    check("Shift, Ctrl and Alt together", keyboard_fill(k, 1, 202) == 1 && *(uint64_t *)(k + 8) == 7 && k[0x10 + 28] == 7);
    dm_key_modifier(DM_KEY_SHIFT | DM_KEY_CTRL | DM_KEY_ALT, 0);
    dm_key_modifier(DM_KEY_ALT, 1); dm_key_modifier(DM_KEY_ALT, 0);
    check("a short Alt press between two reads is still seen once", keyboard_fill(k, 2, 210) == 1 + 1 && *(uint64_t *)(k + 8) == 4 && *(uint64_t *)(k + 0x30 + 8) == 7 && *(int64_t *)(k + 0x30) == 209);
    check("then released", keyboard_fill(k, 1, 211) == 1 && *(uint64_t *)(k + 8) == 0);
    printf("%d / %d passed\n", cases - fails, cases);
    return fails != 0;
}
