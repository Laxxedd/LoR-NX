// Touchscreen Mode's virtual mouse and keyboard modifiers: dm_mouse_* / dm_key_modifier -> mouse_fill / keyboard_fill, checked against hand-written byte layouts
// (MouseState 0x28 bytes, KeyboardState 0x30 bytes). Runs with DM_TOUCHSCREEN=1 set by the test itself; a second program run without it checks "not connected".
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
enum { DM_MOUSE_LEFT = 1, DM_MOUSE_RIGHT = 2 };
enum { DM_KEY_CTRL = 1, DM_KEY_SHIFT = 2, DM_KEY_ALT = 4 };
void dm_mouse_move(float dx, float dy);
void dm_mouse_button(uint32_t mask, int down);
void dm_mouse_wheel(int notches);
void dm_key_modifier(uint32_t mask, int down);
int mouse_fill(void *out, int n, int64_t top);
int keyboard_fill(void *out, int n, int64_t top);
typedef struct { uint32_t id; float x, y; } dm_touch;
static int fails, cases;
typedef struct { int64_t samp; int32_t x, y, dx, dy, wx, wy; uint32_t buttons, attr; } mouse_t;
_Static_assert(sizeof(mouse_t) == 0x28, "MouseState is 0x28 bytes");
static void check(const char *what, int ok) { cases++; if (!ok) fails++; printf("%s %s\n", ok ? "✓" : "✗", what); }
static int same(const mouse_t *g, mouse_t w) { return !memcmp(g, &w, sizeof w); }
int main(void) {
    setenv("DM_TOUCHSCREEN", "1", 1);
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
