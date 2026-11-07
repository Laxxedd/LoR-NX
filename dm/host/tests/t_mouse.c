// Touchscreen Mode's virtual mouse and keyboard keys (modifiers, Esc, Space): dm_mouse_* / dm_key_modifier / dm_key_press -> mouse_fill / keyboard_fill, checked against hand-written byte layouts
// (MouseState 0x28 bytes, KeyboardState 0x30 bytes). Runs with DM_TOUCHSCREEN=1 set by the test itself: plain (the left click is a mouse button), and as `t_mouse touch` with DM_TRACKPAD_TOUCH=1 (the left button is also a touch-screen press at the cursor).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
enum { DM_MOUSE_LEFT = 1, DM_MOUSE_RIGHT = 2 };
enum { DM_KEY_CTRL = 1, DM_KEY_SHIFT = 2, DM_KEY_ALT = 4 };
enum { DM_KEYCODE_ESCAPE = 41, DM_KEYCODE_SPACE = 44 };
void dm_mouse_move(float dx, float dy);
void dm_mouse_set(float x, float y);
void dm_mouse_button(uint32_t mask, int down);
void dm_mouse_wheel(int notches);
void dm_key_modifier(uint32_t mask, int down);
void dm_key_press(uint32_t usage, int down);
int mouse_fill(void *out, int n, int64_t top);
int keyboard_fill(void *out, int n, int64_t top);
typedef struct { float nx, ny; uint32_t held, down, up; int32_t wheel; } frame_t;
void dm_mouse_frame(uint64_t frame, frame_t *out);
typedef struct { uint32_t held[8], down[8], up[8]; } kframe_t;
void dm_key_frame(uint64_t frame, kframe_t *out);
typedef struct { uint32_t id; float x, y; } dm_touch;
static int fails, cases;
typedef struct { int64_t samp; int32_t x, y, dx, dy, wx, wy; uint32_t buttons, attr; } mouse_t;
_Static_assert(sizeof(mouse_t) == 0x28, "MouseState is 0x28 bytes");
static void check(const char *what, int ok) { cases++; if (!ok) fails++; printf("%s %s\n", ok ? "✓" : "✗", what); }
static int same(const mouse_t *g, mouse_t w) { return !memcmp(g, &w, sizeof w); }
int touch_fill_n(void *out, int max, uint64_t now_ns);
static void key_frame_cases(void)
{
        kframe_t a, b;
        #define KB(set, u) (((set)[(u) / 32] >> ((u) % 32)) & 1u)
        dm_key_press(DM_KEYCODE_SPACE, 1); dm_key_press(DM_KEYCODE_SPACE, 0);
        dm_key_frame(2000, &a);
        check("keys: the first read drops what happened before the game asked", !KB(a.held, 44) && !KB(a.down, 44));
        dm_key_press(DM_KEYCODE_SPACE, 1);
        dm_key_frame(2001, &a); dm_key_frame(2001, &b);
        check("keys: a press is Down and held for exactly its frame", KB(a.held, 44) && KB(a.down, 44) && !KB(a.up, 44) && !memcmp(&a, &b, sizeof a));
        dm_key_frame(2002, &a);
        check("keys: then held, no longer Down", KB(a.held, 44) && !KB(a.down, 44));
        dm_key_press(DM_KEYCODE_SPACE, 0);
        dm_key_frame(2003, &a);
        check("keys: the release is Up for one frame", !KB(a.held, 44) && KB(a.up, 44));
        dm_key_press(DM_KEYCODE_ESCAPE, 1); dm_key_press(DM_KEYCODE_ESCAPE, 0);
        dm_key_frame(2004, &a);
        check("keys: a press and release between two frames is Down and held once", KB(a.held, 41) && KB(a.down, 41));
        dm_key_frame(2005, &a);
        check("keys: ..and Up in the next", !KB(a.held, 41) && KB(a.up, 41));
        dm_key_modifier(DM_KEY_SHIFT, 1);
        dm_key_frame(2006, &a);
        check("keys: Shift is usage 225", KB(a.held, 225) && KB(a.down, 225) && !KB(a.held, 224));
        dm_key_modifier(DM_KEY_SHIFT, 0);
        dm_key_frame(2007, &a);
        check("keys: ..and its release is Up", !KB(a.held, 225) && KB(a.up, 225));
        dm_key_press(DM_KEYCODE_SPACE, 1);
        dm_key_frame(2020, &a);
        check("keys: after frames nobody asked in, a held key is not Down", KB(a.held, 44) && !KB(a.down, 44));
        dm_key_press(DM_KEYCODE_SPACE, 0);
        #undef KB
}
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
    // a drag moves the cursor and nothing else: no touch follows it
    mouse_fill(m, 1, 30); touch_fill_n(t, 1, 8000); touch_fill_n(t, 1, 8001);
    dm_mouse_move(10, -10); dm_mouse_move(5, 5);
    check("moving the cursor holds no touch", touch_fill_n(t, 1, 9000) == 0 && touch_fill_n(t, 1, 9001) == 0);
    check("..the mouse has the new position", mouse_fill(m, 1, 31) == 1 && m[0].x == 755 && m[0].y == 405);
    key_frame_cases();
    printf("%d / %d passed\n", cases - fails, cases);
    return fails != 0;
}
int main(int argc, char **argv) {
    setenv("DM_TOUCHSCREEN", "1", 1);
    if (argc > 1 && !strcmp(argv[1], "touch")) { setenv("DM_TRACKPAD_TOUCH", "1", 1); return touch_click_main(); }   // the fallback
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
    // Esc and Space are plain keys of the key bit set (USB usages 41 and 44, both in byte 5), beside the modifiers' bits 224..226
    #define KEY(entry, usage) ((k[0x30 * (entry) + 0x10 + (usage) / 8] >> ((usage) % 8)) & 1)
    dm_key_press(DM_KEYCODE_ESCAPE, 1);
    check("Esc: key 41 set, Space and the modifiers not", keyboard_fill(k, 1, 220) == 1 && *(uint64_t *)(k + 8) == 0 && KEY(0, 41) && !KEY(0, 44) && !KEY(0, 225));
    dm_key_press(DM_KEYCODE_SPACE, 1); dm_key_modifier(DM_KEY_SHIFT, 1);
    check("Esc, Space and Shift together", keyboard_fill(k, 1, 221) == 1 && *(uint64_t *)(k + 8) == 2 && KEY(0, 41) && KEY(0, 44) && KEY(0, 225) && !KEY(0, 224));
    dm_key_press(DM_KEYCODE_ESCAPE, 0); dm_key_press(DM_KEYCODE_SPACE, 0); dm_key_modifier(DM_KEY_SHIFT, 0);
    keyboard_fill(k, 1, 222); keyboard_fill(k, 1, 223);
    dm_key_press(DM_KEYCODE_SPACE, 1); dm_key_press(DM_KEYCODE_SPACE, 0);
    check("a short Space press between two reads is still seen once", keyboard_fill(k, 2, 230) == 2 && KEY(0, 44) && !KEY(1, 44) && !KEY(0, 41));
    check("then released", keyboard_fill(k, 2, 231) == 2 && !KEY(0, 44) && KEY(1, 44));
    check("..and nothing is left in any entry", keyboard_fill(k, 2, 232) == 2 && !*(uint64_t *)(k + 0x10) && !*(uint64_t *)(k + 0x30 + 0x10));
    dm_key_press(300, 1);
    check("a usage beyond the 256-bit set is ignored", keyboard_fill(k, 1, 233) == 1 && !*(uint64_t *)(k + 0x10) && !*(uint64_t *)(k + 0x18) && !*(uint64_t *)(k + 0x20) && !*(uint64_t *)(k + 0x28));
    #undef KEY
    frame_t f, g;
    dm_mouse_button(DM_MOUSE_LEFT, 1); dm_mouse_button(DM_MOUSE_LEFT, 0); dm_mouse_wheel(4);
    dm_mouse_frame(1000, &f);
    check("the first read drops what happened before the game asked", !f.held && !f.down && !f.up && f.wheel == 0);
    dm_mouse_button(DM_MOUSE_LEFT, 1);
    dm_mouse_frame(1000, &f);
    check("nothing changes inside a frame", !f.held && !f.down && !f.up);
    dm_mouse_frame(1001, &f); dm_mouse_frame(1001, &g);
    check("a press is Down and held for exactly its frame", f.held == DM_MOUSE_LEFT && f.down == DM_MOUSE_LEFT && !f.up && !memcmp(&f, &g, sizeof f));
    dm_mouse_frame(1002, &f);
    check("then held, no longer Down", f.held == DM_MOUSE_LEFT && !f.down && !f.up);
    dm_mouse_button(DM_MOUSE_LEFT, 0);
    dm_mouse_frame(1003, &f);
    check("the release is Up for one frame", !f.held && !f.down && f.up == DM_MOUSE_LEFT);
    dm_mouse_frame(1004, &f);
    check("then nothing", !f.held && !f.down && !f.up);
    dm_mouse_button(DM_MOUSE_LEFT, 1); dm_mouse_button(DM_MOUSE_LEFT, 0);
    dm_mouse_frame(1005, &f);
    check("a press and release between two frames is Down and held once", f.held == DM_MOUSE_LEFT && f.down == DM_MOUSE_LEFT && !f.up);
    dm_mouse_frame(1006, &f);
    check("..and Up in the next", !f.held && !f.down && f.up == DM_MOUSE_LEFT);
    dm_mouse_button(DM_MOUSE_RIGHT, 1);
    dm_mouse_frame(1007, &f);
    check("the right button is its own bit", f.held == DM_MOUSE_RIGHT && f.down == DM_MOUSE_RIGHT);
    dm_mouse_button(DM_MOUSE_RIGHT, 0);
    dm_mouse_wheel(2); dm_mouse_wheel(-1);
    dm_mouse_frame(1008, &f); dm_mouse_frame(1008, &g);
    check("wheel notches add up per frame and repeat within it", f.wheel == 1 && g.wheel == 1 && f.up == DM_MOUSE_RIGHT);
    dm_mouse_frame(1009, &f);
    check("..and are gone the next frame", f.wheel == 0);
    dm_mouse_button(DM_MOUSE_LEFT, 1); dm_mouse_wheel(3);
    dm_mouse_frame(1020, &f);
    check("after frames nobody asked in, a held button is not Down and the wheel is dropped", f.held == DM_MOUSE_LEFT && !f.down && !f.up && f.wheel == 0);
    dm_mouse_button(DM_MOUSE_LEFT, 0);
    dm_mouse_frame(1021, &f);
    check("..and its release is still Up", !f.held && f.up == DM_MOUSE_LEFT);
    dm_mouse_move(-5000, -5000);
    dm_mouse_frame(1022, &f);
    check("the cursor at the top left is (0, 0)", f.nx == 0.0f && f.ny == 0.0f);
    dm_mouse_move(5000, 5000);
    dm_mouse_frame(1023, &f);
    check("..at the bottom right (1, 1)", f.nx == 1.0f && f.ny == 1.0f);
    dm_mouse_move(-640, -360);
    dm_mouse_frame(1024, &f);
    check("..and the position follows each frame, not each call", f.nx > 0.49f && f.nx < 0.51f && f.ny > 0.49f && f.ny < 0.51f);
    {   // Touch pointer mode: dm_mouse_set puts the cursor where the finger is
        mouse_t a[1];
        mouse_fill(a, 1, 3000); int px = a[0].x, py = a[0].y;
        dm_mouse_set(200.0f, 100.0f);
        check("dm_mouse_set puts the cursor at the point; the jump is reported once as the delta", mouse_fill(a, 1, 3001) == 1 && a[0].x == 200 && a[0].y == 100 && a[0].dx == 200 - px && a[0].dy == 100 - py);
        check("and it stays there with no movement", mouse_fill(a, 1, 3002) == 1 && a[0].x == 200 && a[0].y == 100 && a[0].dx == 0 && a[0].dy == 0);
        dm_mouse_set(-50.0f, 9999.0f);
        check("dm_mouse_set clamps to the panel", mouse_fill(a, 1, 3003) == 1 && a[0].x == 0 && a[0].y == 719);
    }
    key_frame_cases();
    printf("%d / %d passed\n", cases - fails, cases);
    return fails != 0;
}
