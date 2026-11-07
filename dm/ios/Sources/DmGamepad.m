// Virtual gamepad (Nintendo button positions) + physical controllers (GameController), handed to the host through dm_input_set and dm_pad_set_player (hle_hid.c, bit layout in dm_input.h).
//   One layout: Swipe. The 2D, 3D and Tap layouts and the layout button at the top centre were removed; the code of those layouts is still below but unreachable.
//   Swipe: the swipe gamepad of GesturePad.swift over the whole screen (swipes are the D-pad, a tap is A, a hold is B; L, R, ZL, ZR, X, Y, − and + are outlined buttons, with toggles for the right stick and for repeating swipes),
//     placed by the launcher's layout editor (Launcher.swift, GestureLayoutEditor.swift). It presses through dm_gesture_button / dm_gesture_stick, below.
//   2D (simple): top corners ZL above L (one column), ZR above R likewise, teardrops with the tip toward the screen corner; − and + side by side at the top centre; the left stick in the bottom-left corner (fixed ring, tilt measured from the ring centre, small dead zone);
//     the A (right) B (bottom) X (top) Y (left) diamond in the bottom-right corner, sliding a finger between keys switches keys. Each bottom corner holds a single control, so it sits close in (reaching halfway into the side safe-area inset).
//   3D (full, Pro Controller style): everything in 2D (left stick and diamond keep their place and size), plus a D-pad (inward of and below the left stick, 8-way), a right stick that is not drawn
//     (a touch landing in the right third of the screen on no control holds it: centred where it lands, the centre dragged along once the finger passes the stick radius) and L3 / R3 (small round keys in the top row, inward of ZL / ZR).
//     Breath of the Wild crouches with L3 and uses the scope with R3; 3D World and Breath of the Wild turn the camera with the right stick.
//   Touch-down ownership: locked keys first (shoulders, − / +, the layout button, L3 / R3), then whichever of the diamond, the D-pad and the left stick has the smallest distance / grab radius (the left stick's grab circle borders the D-pad),
//     then in 3D the right stick for a touch in the right third.
//   Everything hugs the edges and corners to leave the picture room; controls sit over the picture, one CAShapeLayer each: a press only swaps the fill, a stick only moves its knob, nothing redraws the whole screen.
//   Touches no control takes (in 3D, those outside the right third) go to the game's touch screen (pushGame; Super Mario Galaxy's pointer in handheld mode).
//   The virtual gamepad (layout button included) hides while a physical controller is connected and comes back when it is removed; meanwhile every touch goes to the game. Physical controllers keep every button (D-pad and right stick included) and map by position: bottom = B, right = A, left = Y, top = X (same positions as on a Switch controller); a Nintendo pad maps by its labels (pad_apple.h).
//   Each physical controller is a player of its own (local co-op), as on the Mac: the first one connected is player 1, together with the touch gamepad, the next player 2, and so on up to 8; see "Physical controllers" below.
//   Touchscreen Mode (DM_TOUCHSCREEN=1) replaces all of it: the screen is a touchpad for the game's mouse (tsBegan below: one finger drags the cursor, a tap is the left button, a hold the right button, two fingers moving up or down scroll the wheel;
//     (Pointer Mode Touch, DM_POINTER_MODE=touch, puts the cursor under the finger instead: tap = left click, double tap = right click, hold = the left button held; the touch-ui mod then hides the game's own cursor)
//     the app draws no cursor: the game's own is moved by the mouse; the left click reaches the game as a touch-screen press at the cursor, since the touch-ui mod makes the game read the touch screen: hle_touch.c trackpad_touch) and Esc, Space, Shift, Ctrl and Alt are the keyboard's keys (front.h dm_mouse_*, dm_key_modifier, dm_key_press), placed by the launcher's touchscreen layout editor (Launcher.swift, TouchscreenLayoutEditor.swift): Esc at the top left, a thin wide Space at the bottom middle and the three modifiers at the bottom left
//     unless the player moved them. Clicks, scroll steps and the keys give a haptic tap while DM_TOUCH_HAPTICS is on.
//   Shaking the phone shakes the controller (DM_BTN_SHAKE: its six-axis sensor, hle_hid.c), whichever controls are in use; see "Shaking the phone" below.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreText/CoreText.h>
#include <pthread.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "game_profile.h"
#include "haptics_apple.h"
#include "motion_apple.h"
#include "motion_fusion.h"
#include "pad_apple.h"
#include "pad_slots.h"
#include "DmGesture.h"
#include <stdatomic.h>

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_SWAP, C_GAME };   // which control a touch holds; C_GAME: none, the touch goes to the game's touch screen (finger slot << 8)

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn, g_shake_btn;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry;
static uint64_t g_gesture_btn;   // the Swipe layout's buttons and right stick (GesturePad.swift), kept apart from the other layouts' so neither can release the other's
static int32_t g_gesture_rx, g_gesture_ry;
static void publish(void) {   // the touch gamepad and the shake; the host ORs them with player 1's controller and takes whichever stick is deflected more (hle_hid.c)
    pthread_mutex_lock(&g_mu);
    BOOL swipeStick = g_gesture_rx || g_gesture_ry;   // only the Swipe layout is up while it is held: the other layouts' touches are not read then
    dm_input_set(g_touch_btn | g_shake_btn | g_gesture_btn, g_touch_lx, g_touch_ly, swipeStick ? g_gesture_rx : g_touch_rx, swipeStick ? g_gesture_ry : g_touch_ry);
    pthread_mutex_unlock(&g_mu);
}
void dm_gesture_button(uint64_t mask, int pressed) {
    pthread_mutex_lock(&g_mu);
    if (pressed) g_gesture_btn |= mask; else g_gesture_btn &= ~mask;
    pthread_mutex_unlock(&g_mu);
    publish();
}
void dm_gesture_stick(int32_t x, int32_t y) {
    pthread_mutex_lock(&g_mu); g_gesture_rx = x; g_gesture_ry = y; pthread_mutex_unlock(&g_mu);
    publish();
}

// ---- Shaking the phone ----
// The accelerometer at 60 Hz (no gyroscope, no permission prompt): gravity is followed by a slow low-pass (about 0.8 s), and a sample whose acceleration beyond it exceeds DM_SHAKE_G
// (1.5 G by default; Documents/env.txt overrides) is a hit. The controller is shaken until 120 ms after the last hit: a flick is one shake (the host finishes it as a whole cycle)
// and shaking on keeps it going. Holding the phone and pressing the screen stays far below the threshold. Each detected shake is logged with its peak
static CMMotionManager *g_motion;
static void motion_start(void) {
    if (g_motion) return;
    g_motion = [CMMotionManager new];
    if (!g_motion.accelerometerAvailable) { LOG("front end: no accelerometer, shaking the phone does nothing"); return; }
    const char *e = getenv("DM_SHAKE_G"); double thr = e && atof(e) > 0 ? atof(e) : 1.5;
    LOG("front end: shaking the phone shakes the controller (threshold %.2f G)", thr);
    g_motion.accelerometerUpdateInterval = 1.0 / 60;
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    __block double gx = 0, gy = 0, gz = 0, last = -1, peak = 0; __block BOOL init = NO;
    [g_motion startAccelerometerUpdatesToQueue:q withHandler:^(CMAccelerometerData *d, NSError *err) {
        (void)err; if (!d) return;
        CMAcceleration a = d.acceleration;
        if (!init) { gx = a.x; gy = a.y; gz = a.z; init = YES; }
        double dx = a.x - gx, dy = a.y - gy, dz = a.z - gz, g = sqrt(dx * dx + dy * dy + dz * dz);
        gx += (a.x - gx) * 0.02; gy += (a.y - gy) * 0.02; gz += (a.z - gz) * 0.02;
        if (g > thr) { if (last < 0) peak = 0; last = d.timestamp; peak = fmax(peak, g); }
        BOOL on = last >= 0 && d.timestamp - last < 0.12;
        if (!on && last >= 0) { LOG("front end: phone shaken (peak %.1f G)", peak); last = -1; }
        uint64_t want = on ? DM_BTN_SHAKE : 0;
        pthread_mutex_lock(&g_mu); BOOL changed = g_shake_btn != want; g_shake_btn = want; pthread_mutex_unlock(&g_mu);
        if (changed) publish();
    }];
}

// ---- The phone's gyro ----
// A controller mounted on the phone (Backbone One, Razer Kishi, GameSir G8) has no motion sensors of its own: the phone in the middle is the console, as a Switch in handheld.
// So the phone's device motion (gyro + accelerometer, CoreMotion's fused gravity and user acceleration, 100 Hz, no permission prompt) drives player 1's six-axis sensor, turned
// into the Switch frame for the screen's orientation (motion_phone_to_switch, motion_fusion.h): x to the right of the picture, y to its top, z toward the player.
// The host keeps phone and controller orientations separately, choosing fresh controller data in auto mode and the phone alone in forced mode.
// DM_PHONE_MOTION: auto (default) while no controller supplies fresh gyro data (a DualSense held apart from the phone uses its own, motion_apple.h), 1 always, 0 never.
// DM_MOTION=0 (all live motion off; the NSP script's --no-motion builds it in) never starts device motion.
// Which frame the samples come in: on iOS 27 and later the pad view (full screen, over the picture) is the motion body (CMMotionManager.deviceMotionBody), so Core Motion delivers
// them in that view's frame for whichever display shows it and however it is turned: x to the right of the picture, y to its top, z toward the player, the Switch frame as it is.
// Before that they come in the hardware frame, turned here by the interface orientation, which holds only where the hardware frame is the screen's portrait frame: not on iPhone
// Duo's inner display, whose picture is a quarter turn from it (up / down and left / right swapped, GitHub issue #569). Open: while the scene is not full screen (Split View on the
// inner display) Core Motion falls back to the hardware frame without saying so, and the samples are then taken as the view's frame
static _Atomic int g_iface_orient = 3;      // UIInterfaceOrientation, updated on layout
static BOOL g_motion_body;                  // samples in the body's frame (iOS 27+)
static void phone_motion_start(UIView *body) {
    const char *e = getenv("DM_MOTION");
    if (e && !atoi(e)) { LOG("front end: motion is off (DM_MOTION=0), the phone's gyro is not used"); return; }
    e = getenv("DM_PHONE_MOTION"); int mode = !e || !strcmp(e, "auto") ? -1 : atoi(e);
    if (!mode) { LOG("front end: the phone's gyro is off (DM_PHONE_MOTION=0)"); return; }
    if (!g_motion.deviceMotionAvailable) { LOG("front end: no device motion, the phone's gyro is not used"); return; }
    LOG("front end: the phone's gyro drives the controller's six-axis sensor %s", mode < 0 ? "while no controller supplies fresh motion" : "always (DM_PHONE_MOTION=1)");
    g_motion.deviceMotionUpdateInterval = 1.0 / 100;
    if (@available(iOS 27.0, *)) { g_motion.deviceMotionBody = body; g_motion_body = YES; LOG("front end: the phone's motion comes in the pad view's frame (deviceMotionBody)"); }
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    [g_motion startDeviceMotionUpdatesToQueue:q withHandler:^(CMDeviceMotion *d, NSError *err) {
        (void)err; if (!d) return;
        float a[3] = {(float)(d.gravity.x + d.userAcceleration.x), (float)(d.gravity.y + d.userAcceleration.y), (float)(d.gravity.z + d.userAcceleration.z)};
        float w[3] = {(float)d.rotationRate.x, (float)d.rotationRate.y, (float)d.rotationRate.z}, as[3], ws[3];
        int o = g_motion_body ? 1 : atomic_load(&g_iface_orient);   // the body's frame is already the picture's: the portrait map, which leaves it as it is
        motion_phone_to_switch(o, a, as); motion_phone_to_switch(o, w, ws);
        dm_motion_set_switch(0, as, ws);
    }];
}

// ---- Layout constants (in u; x measured from the outer edge, the right half mirrors) ----
static const CGFloat
    K_ZL_X = 44, K_ZL_Y = 40, K_ZL_R = 26,          // ZL / ZR: centre from the outer edge and the top, radius
    K_L_X = 44, K_L_Y = 108, K_L_R = 24,            // L / R: same column as ZL / ZR
    K_DROP_TIP = 1.45,                              // teardrop tip distance from the centre (times the radius)
    K_CORNER_IN = 0.5,                              // how far the bottom-corner controls reach into the side safe-area inset (in landscape there is only the rounded screen corner there; the Dynamic Island is mid-edge)
    K_FACE_X = 81, K_PAD_Y = 82,                    // diamond centre from the outer edge; diamond and stick centre from the bottom (B's lower edge about 5 above it)
    K_FACE_GAP = 50, K_FACE_R = 27,                 // diamond: key distance from the centre, key radius
    K_PILL_DX = 52, K_PILL_Y = 22, K_PILL_W = 50, K_PILL_H = 28,   // − / +: centre from the screen's midline (the middle goes to the layout button) and from the top, size
    K_STICK_X = 81, K_STICK_R = 77, K_KNOB_R = 30,  // left stick: mirrors the diamond, the ring as large as the whole diamond (key distance + key radius), the knob a little larger than a diamond key
    K_STICK_GRAB = 1.4,                             // how near the ring centre a touch-down grabs a stick (times the ring radius)
    K_FULL = 0.8,                                   // full tilt at this fraction of the ring radius (the knob still travels to the ring edge)
    K_DEAD = 0.1,                                   // stick dead zone (times the ring radius)
    // controls only the 3D layout has
    K_LOW_X = 231, K_LOW_Y = 64,                    // D-pad centre from the outer edge and the bottom (inward of and below the left stick, as on a Pro Controller)
    K_DPAD_R = 48, K_ARM_W = 17, K_ARM_IN = 11,     // D-pad: arm outer edge from the centre, half-width, tip from the centre
    K_DPAD_GRAB = 1.3,                              // D-pad grab radius (times the outer edge)
    K_RSTICK_R = 60,                                // right stick (not drawn): radius around its centre, the touch-down point
    K_RSWIPE = 1.0 / 3,                             // right stick area: this fraction of the screen width from the right edge (not in u)
    K_CLICK_X = 102, K_CLICK_R = 17;                // L3 / R3: centre from the outer edge (level with ZL / ZR), radius
// Touchscreen Mode: the touchpad (points) and the keys (u)
static const CGFloat
    K_TP_GAIN = 1.5,                                // cursor speed: panel pixels per screen pixel of the picture, times this (and times the launcher's Cursor sensitivity)
    K_TP_SLOP = 9,                                  // a finger that stays within this many points of where it landed has not moved (a tap, or a hold)
    K_TP_STEP = 26,                                 // two fingers travelling this many points up or down scroll the wheel one notch
    K_KB_GAP = 8, K_KB_R = 8,                       // the keys' hit areas reach half this far beyond them; the corner radius of the squircle keys
    K_KB_HIT = 44;                                  // a key is at least this big to hit, however small it is drawn (the thin Space key is 4 points tall)
static const NSTimeInterval K_TP_HOLD = 0.45;       // a finger held still this long is the right button (Touch pointer mode: the left button, held)
static const NSTimeInterval K_PT_DOUBLE = 0.28;     // Touch pointer mode: a second tap this soon after a first makes a double tap (right click); a lone tap waits this long before it is a left click
static const CGFloat K_PT_DOUBLE_DIST = 36;         // ... and this close (points) to the first
// The touchscreen keys, in the order of TouchscreenLayout.swift's TouchKey (position, size and opacity come from there: dm_ts_key_frame / dm_ts_key_opacity)
enum { TS_SHIFT, TS_CTRL, TS_ALT, TS_ESC, TS_SPACE, TS_N };
static NSString *const k_tsNames[TS_N] = {@"Shift", @"Ctrl", @"Alt", @"Esc", nil};   // Space is a thin bar with no label
static void ts_key(int k, int down) {
    switch (k) {
    case TS_SHIFT: dm_key_modifier(DM_KEY_SHIFT, down); break;
    case TS_CTRL: dm_key_modifier(DM_KEY_CTRL, down); break;
    case TS_ALT: dm_key_modifier(DM_KEY_ALT, down); break;
    case TS_ESC: dm_key_press(DM_KEYCODE_ESCAPE, down); break;
    case TS_SPACE: dm_key_press(DM_KEYCODE_SPACE, down); break;
    }
}
static const int k_btns[] = {B_ZL, B_L, B_ZR, B_R, B_MINUS, B_PLUS, B_LS, B_RS};   // keys locked at touch-down (L3 / R3 only in the 3D layout)
int dm_opmode(void);   // hle_oe.c: 0 = handheld
void *dm_gesture_view_make(void);   // GesturePad.swift: the Swipe layout's view, returned retained
void dm_gesture_view_release_inputs(void *view);   // lets go of every button and the stick it holds
void dm_gesture_view_set_passthrough(void *view, CGRect rect);   // touches inside rect go to the views below (the layout button)
CGRect dm_ts_key_frame(int key, CGSize bounds, double unit);   // TouchscreenLayout.swift: where a touchscreen key sits on a screen of that size (the player's layout, else the default one), unit = u
double dm_ts_key_opacity(int key);   // ...and how opaque it is, 0.1 to 1

@interface DmGamepad : UIView
@end
static __weak DmGamepad *g_view;
static void pads_start(void);   // Physical controllers, below

@implementation DmGamepad {
    NSMapTable<UITouch *, NSNumber *> *_owner;     // touch → control (with the key for C_BTN or the stick for C_STICK, << 8)
    UITouch *_stick[2]; CGPoint _stickNow[2];      // the touch holding each stick and where it is now (0 left, 1 right)
    CGPoint _rCentre;                              // the right stick's centre: where its touch landed, dragged along past K_RSTICK_R
    uint64_t _faceBits, _dpadBits, _btnBits;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;    // which keys each touch on the diamond currently holds
    CAShapeLayer *_key[B_N]; CATextLayer *_label[B_N];   // one layer per key
    CAShapeLayer *_ring, *_knob;                   // the left stick (the right one is not drawn)
    UIImpactFeedbackGenerator *_touchFeedback;       // one short feedback per touch-control press edge
    unsigned _hapticSticks;
    BOOL _stickShown;                              // the left stick was held at the last refresh
    BOOL _full, _tap, _gesture;                    // the 3D layout / the Tap layout / the Swipe layout is current
    UIView *_gestureView;                          // the Swipe layout's view over the whole pad, made while that layout is current
    CALayer *_controls;                            // holds every control layer: hidden while a physical controller is connected (the view itself stays, for game touches)
    BOOL _padOff;                                  // a physical controller is connected: every touch goes to the game
    UITouch *_game[16];                            // touches on the game's touch screen by finger slot
    CALayer *_tsLayer;                             // Touchscreen Mode's layer (the keys), over the picture; hidden otherwise
    CAShapeLayer *_kbKey[TS_N]; CATextLayer *_kbLabel[TS_N];
    UITouch *_kbTouch[TS_N];                       // the finger holding each key
    CGRect _kbFrame[TS_N];                         // where each key is now: the layout's answer at the last layout pass, so a touch-down does not ask for it again
    NSMutableArray<UITouch *> *_pad;               // the fingers on the touchpad in the order they landed (the first two count)
    CGPoint _padStart, _padLast; BOOL _padMoved, _padDead, _padRight;   // one finger: where it landed / was last applied, moved past the slop, the gesture is over (two fingers were down: nothing more until all lift), the right button is held
    CGFloat _padScroll, _padScrollY;               // two fingers: vertical travel not yet turned into a notch, their mid point's last y
    BOOL _ptHold, _ptSecond, _ptPending; CGPoint _ptPendingAt; NSTimer *_ptClickTimer; NSUInteger _rmbEpoch;   // Touch pointer mode: the left button is held by a hold, the finger down is a double tap's second tap, a tap waits for a second one (and where), the timer that sends it, counts right clicks like _lmbEpoch
    NSTimer *_padTimer; NSUInteger _lmbEpoch;      // the hold timer; counts left clicks so an old release cannot let go of a newer press
    UIImpactFeedbackGenerator *_clickFeedback, *_rightFeedback; UISelectionFeedbackGenerator *_scrollFeedback;
}

static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_text, *k_textOn;
static UIColor *k_kbIdle, *k_kbOn, *k_kbLine, *k_kbLineOn, *k_kbText, *k_kbTextOn;   // the touchscreen keys: the swipe gamepad's outline look (GesturePad.swift ControlView.refresh), a 1 point border and almost no fill
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = 0.2; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}
static CATextLayer *label(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor; t.contentsScale = UIScreen.mainScreen.scale;
    [parent addSublayer:t]; return t;
}
// The launcher's Cursor sensitivity (DM_TRACKPAD_SPEED, a multiplier of K_TP_GAIN; 0.5 to 3, 1 when unset or not a number)
static CGFloat touchpad_speed(void) {
    static CGFloat v = 0;
    if (v == 0) { const char *e = getenv("DM_TRACKPAD_SPEED"); double d = e ? atof(e) : 0; v = d >= 0.5 && d <= 3.0 ? d : 1.0; }
    return v;
}
static BOOL touchscreen_mode(void) { const char *e = getenv("DM_TOUCHSCREEN"); return e && atoi(e); }   // the launcher's Touchscreen Mode
// The launcher's Pointer Mode (DM_POINTER_MODE, with Touchscreen Mode): "trackpad" (the default) drags the cursor like a trackpad; "touch" puts the cursor under the finger (tap = left click, double tap = right click, hold = left button held)
static BOOL pointer_touch(void) { static int v = -1; if (v < 0) { const char *e = getenv("DM_POINTER_MODE"); v = touchscreen_mode() && e && !strcmp(e, "touch"); } return v; }
static BOOL fullOnly(int b) { return b == B_LS || b == B_RS || b >= B_LEFT; }   // keys shown only in the 3D layout

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        const char *feedback = getenv("DM_TOUCH_HAPTICS");
        if (!feedback || atoi(feedback)) {
            _touchFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [_touchFeedback prepare];
            _clickFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            _rightFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            _scrollFeedback = [UISelectionFeedbackGenerator new];
            if (touchscreen_mode()) { [_clickFeedback prepare]; [_rightFeedback prepare]; [_scrollFeedback prepare]; }
        }
        _pad = [NSMutableArray array];
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _faceOf = [NSMapTable strongToStrongObjectsMapTable];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // each colour carries its own low opacity instead of lowering the whole view's alpha (that would add an off-screen pass for the full-screen layer)
            k_idle = [UIColor colorWithWhite:1 alpha:0.14]; k_on = [UIColor colorWithWhite:1 alpha:0.45]; k_line = [UIColor colorWithWhite:1 alpha:0.38];
            k_ringFill = [UIColor colorWithWhite:1 alpha:0.06]; k_text = [UIColor colorWithWhite:1 alpha:0.6]; k_textOn = [UIColor colorWithWhite:0 alpha:0.7];
            k_kbIdle = [UIColor colorWithWhite:1 alpha:0.04]; k_kbOn = [UIColor colorWithWhite:1 alpha:0.30];
            k_kbLine = [UIColor colorWithWhite:1 alpha:0.42]; k_kbLineOn = [UIColor colorWithWhite:1 alpha:0.95];
            k_kbText = [UIColor colorWithWhite:1 alpha:0.85]; k_kbTextOn = [UIColor colorWithWhite:1 alpha:1];
        });
        _controls = [CALayer layer]; [self.layer addSublayer:_controls];
        _ring = shape(_controls); _ring.fillColor = k_ringFill.CGColor;
        _knob = shape(_controls);
        CAShapeLayer *in = [CAShapeLayer layer]; in.fillColor = nil; in.strokeColor = k_line.CGColor; in.lineWidth = 1.5;   // inner ring of the knob
        [_knob addSublayer:in];
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−"};
        for (int b = 0; b < B_N; b++) {
            _key[b] = shape(_controls);
            if (names[b]) _label[b] = label(_key[b], names[b]);   // the D-pad arms carry no label
        }
        _tsLayer = [CALayer layer]; _tsLayer.hidden = !touchscreen_mode(); [self.layer addSublayer:_tsLayer];
        for (int i = 0; i < TS_N; i++) {
            _kbKey[i] = shape(_tsLayer);
            _kbKey[i].lineWidth = 1; _kbKey[i].shadowOpacity = 0;   // thin and flat, not the gamepad keys' 1.5 point line and soft shadow
            _kbLabel[i] = label(_kbKey[i], k_tsNames[i] ?: @""); _kbLabel[i].hidden = k_tsNames[i] == nil;
        }
        _gesture = YES;
        [self applyLayout];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidDisconnectNotification object:nil];
        pads_start();
        [self padsChanged:nil];
        motion_start();
        phone_motion_start(self);
    }
    return self;
}
- (void)applyLayout {   // show / hide the controls for the current layout
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) _key[b].hidden = _tap || _gesture || (fullOnly(b) && !_full);
    _ring.hidden = _knob.hidden = _tap || _gesture;
    [CATransaction commit];
    // Touchscreen Mode never shows the swipe layout, so its full-screen view is not made at all: it starts out enabled (_padOff only turns it off on the next main-queue turn, in padsChanged:) and it takes every touch
    // that lands on it, as a tap (A), a swipe (D-pad) or a hold (B), so nothing may sit over the touchpad that Touchscreen Mode's touches go to
    if (_gesture && !_gestureView && !touchscreen_mode()) {
        _gestureView = (__bridge_transfer UIView *)dm_gesture_view_make();
        _gestureView.frame = self.bounds; _gestureView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_gestureView];
    } else if (!_gesture && _gestureView) {
        dm_gesture_view_release_inputs((__bridge void *)_gestureView);
        [_gestureView removeFromSuperview]; _gestureView = nil;
    }
    _gestureView.hidden = _padOff; _gestureView.userInteractionEnabled = !_padOff;
}
// ---- Layout (points; computed inside the safe area) ----
- (CGRect)safe { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }
- (CGRect)corner { UIEdgeInsets i = self.safeAreaInsets; i.left *= K_CORNER_IN; i.right *= K_CORNER_IN; return UIEdgeInsetsInsetRect(self.bounds, i); }   // the rectangle the bottom-corner controls use
- (CGFloat)u { return MIN(self.bounds.size.height / 430.0, 1.3); }   // 1 = 430 points tall (iPhone Pro Max landscape)
static CGPoint side(CGRect s, int right, CGFloat dx, CGFloat y) { return CGPointMake(right ? CGRectGetMaxX(s) - dx : CGRectGetMinX(s) + dx, y); }
- (CGPoint)faceCenter { CGRect s = self.corner; CGFloat u = self.u; return side(s, 1, K_FACE_X * u, CGRectGetMaxY(s) - K_PAD_Y * u); }
- (CGFloat)faceGap { return K_FACE_GAP * self.u; }
- (CGFloat)faceR { return K_FACE_R * self.u; }
- (CGPoint)facePos:(int)b { CGPoint c = self.faceCenter; CGFloat g = self.faceGap;
    switch (b) { case B_A: return CGPointMake(c.x + g, c.y); case B_B: return CGPointMake(c.x, c.y + g); case B_X: return CGPointMake(c.x, c.y - g); default: return CGPointMake(c.x - g, c.y); } }
- (CGPoint)stickHome { CGRect s = self.corner; return side(s, 0, K_STICK_X * self.u, CGRectGetMaxY(s) - K_PAD_Y * self.u); }   // the left stick's ring centre
- (CGPoint)stickCentre:(int)i { return i ? _rCentre : self.stickHome; }
- (CGFloat)stickR:(int)i { return (i ? K_RSTICK_R : K_STICK_R) * self.u; }
- (BOOL)inRightArea:(CGPoint)p { CGRect b = self.bounds; return p.x >= CGRectGetMaxX(b) - b.size.width * K_RSWIPE; }
- (CGPoint)dpadCenter { CGRect s = self.corner; CGFloat u = self.u; return side(s, 0, K_LOW_X * u, CGRectGetMaxY(s) - K_LOW_Y * u); }
- (CGFloat)dpadR { return K_DPAD_R * self.u; }
static BOOL isDrop(int b) { return b == B_ZL || b == B_L || b == B_ZR || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
- (CGPoint)dropCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;
    return side(s, b == B_ZR || b == B_R, (z ? K_ZL_X : K_L_X) * u, CGRectGetMinY(s) + (z ? K_ZL_Y : K_L_Y) * u); }
- (CGFloat)dropR:(int)b { return (b == B_ZL || b == B_ZR ? K_ZL_R : K_L_R) * self.u; }
- (CGPoint)clickCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; return side(s, b == B_RS, K_CLICK_X * u, CGRectGetMinY(s) + K_ZL_Y * u); }
- (CGRect)pillRect:(int)b { CGRect s = self.safe; CGFloat u = self.u, w = K_PILL_W * u, h = K_PILL_H * u;
    CGPoint c = CGPointMake(CGRectGetMidX(s) + (b == B_PLUS ? K_PILL_DX : -K_PILL_DX) * u, CGRectGetMinY(s) + K_PILL_Y * u);   // − on the left, + on the right
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }

static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
- (int)btnAt:(CGPoint)p {   // locked keys (tested on touch-down only, then locked)
    CGFloat u = self.u;
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (fullOnly(b) && !_full) continue;
        BOOL hit = isDrop(b) ? dist(p, [self dropCenter:b]) <= [self dropR:b] * 1.35
                 : isClick(b) ? dist(p, [self clickCenter:b]) <= K_CLICK_R * u * 1.35
                 : CGRectContainsPoint(CGRectInset([self pillRect:b], -8 * u, -8 * u), p);
        if (hit) return b; }
    return -1;
}
- (uint64_t)faceAt:(CGPoint)p {   // keys under the finger in the diamond (between two keys both count)
    uint64_t m = 0; CGFloat r = self.faceR * 1.25;
    for (int b = B_A; b <= B_Y; b++) if (dist(p, [self facePos:b]) <= r) m |= 1ull << b;
    return m;
}
- (uint64_t)dpadAt:(CGPoint)p {   // 8 directions: 45° each, diagonals press two keys; a small centre circle counts as none
    CGPoint c = self.dpadCenter; CGFloat dx = p.x - c.x, dy = p.y - c.y;
    if (hypot(dx, dy) < self.dpadR * 0.25) return 0;
    double a = atan2(-dy, dx) * 180 / M_PI; uint64_t m = 0;
    if (a > -67.5 && a < 67.5) m |= 1ull << B_RIGHT;
    if (a > 22.5 && a < 157.5) m |= 1ull << B_UP;
    if (a > 112.5 || a < -112.5) m |= 1ull << B_LEFT;
    if (a < -22.5 && a > -157.5) m |= 1ull << B_DOWN;
    return m;
}
- (CGPoint)knobOffset:(int)i {   // knob offset from the stick centre (clamped to the stick radius)
    if (!_stick[i]) return CGPointZero;
    CGPoint h = [self stickCentre:i]; CGFloat dx = _stickNow[i].x - h.x, dy = _stickNow[i].y - h.y, d = hypot(dx, dy), R = [self stickR:i];
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}

// ---- Touch ----
- (void)recompute {
    uint64_t face = 0; for (UITouch *t in _faceOf) face |= [_faceOf objectForKey:t].unsignedLongLongValue;
    uint64_t btn = 0, dpad = 0;
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff);
        if (c == C_BTN) btn |= 1ull << (v >> 8);
        else if (c == C_DPAD) dpad |= [self dpadAt:[t locationInView:self]]; }
    int32_t ax[4] = {0};
    for (int i = 0; i < 2; i++) {
        CGPoint o = [self knobOffset:i]; CGFloat R = [self stickR:i], d = hypot(o.x, o.y), dz = R * K_DEAD;
        if (d <= dz) continue;
        CGFloat m = fmin((d - dz) / (R * K_FULL - dz), 1) / d;   // outside the dead zone: 0 rising to full at the full-tilt radius
        ax[i * 2] = (int32_t)lrint(o.x * m * 32767); ax[i * 2 + 1] = (int32_t)lrint(-o.y * m * 32767);   // host: up is positive; rounded so full tilt is exactly 32767
    }
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits;
    uint64_t pressed = (face | dpad | btn) & ~(_faceBits | _dpadBits | _btnBits);
    unsigned gripping = (_stick[0] ? 1u : 0) | (_stick[1] ? 2u : 0);
    if (pressed || (gripping & ~_hapticSticks)) {
        [_touchFeedback impactOccurredWithIntensity:0.6]; [_touchFeedback prepare];
    }
    _hapticSticks = gripping;
    _faceBits = face; _dpadBits = dpad; _btnBits = btn;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = face | dpad | btn; g_touch_lx = ax[0]; g_touch_ly = ax[1]; g_touch_rx = ax[2]; g_touch_ry = ax[3];
    pthread_mutex_unlock(&g_mu);
    publish();
    BOOL stick = _stick[0] != nil;   // only the left stick is drawn: the right one needs no refresh
    if (changed || stick || _stickShown) [self refresh];   // also refresh on the stick release so the knob returns to the centre
    _stickShown = stick;
}
// Touches no control takes (all of them while a physical controller is connected) go to the game's touch screen, normalized on the 16:9 picture that front_ios.m
// centres in the screen: Super Mario Galaxy's pointer in handheld mode (profile op_mode). The host reports them only in handheld mode, as on the Switch (hle_hid.c touch_read)
- (void)pushGame {
    CGRect b = self.bounds; CGFloat w = b.size.width, h = b.size.height;
    if (w <= 0 || h <= 0) return;
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;
    CGFloat x0 = (b.size.width - w) / 2, y0 = (b.size.height - h) / 2;
    dm_touch t[16]; int n = 0;
    for (int i = 0; i < 16; i++) if (_game[i]) {
        CGPoint p = [_game[i] locationInView:self];
        t[n++] = (dm_touch){(uint32_t)i, (float)fmin(fmax((p.x - x0) / w, 0), 0.999), (float)fmin(fmax((p.y - y0) / h, 0), 0.999)};
    }
    dm_touch_set(t, n);
}
- (BOOL)gameBegin:(UITouch *)t {
    for (int i = 0; i < 16; i++) if (!_game[i]) { _game[i] = t; [_owner setObject:@(C_GAME | (uint64_t)i << 8) forKey:t]; return YES; }
    return NO;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (touchscreen_mode()) { [self tsBegan:ts]; return; }
    BOOL game = NO;
    for (UITouch *t in ts) {
        if (_padOff) { game |= [self gameBegin:t]; continue; }
        CGPoint p = [t locationInView:self];
        if (_gesture) continue;   // the view over the pad takes every touch
        int hit = _tap ? -1 : [self btnAt:p];
        if (hit >= 0) { [_owner setObject:@(C_BTN | (uint64_t)hit << 8) forKey:t]; continue; }
        if (_tap) { game |= [self gameBegin:t]; continue; }
        // diamond, D-pad, left stick: take the one with the smallest distance / grab radius, if it is <= 1
        CGFloat best = 1; int kind = C_NONE, idx = 0;
        CGFloat f = dist(p, self.faceCenter) / (self.faceGap + self.faceR * 1.6); if (f <= best) { best = f; kind = C_FACE; }
        if (_full) { CGFloat d = dist(p, self.dpadCenter) / (self.dpadR * K_DPAD_GRAB); if (d < best) { best = d; kind = C_DPAD; } }
        if (!_stick[0]) { CGFloat s = dist(p, self.stickHome) / ([self stickR:0] * K_STICK_GRAB); if (s < best) { best = s; kind = C_STICK; } }
        if (kind == C_NONE && _full && !_stick[1] && [self inRightArea:p]) { kind = C_STICK; idx = 1; _rCentre = p; }   // the right stick: centred where the touch lands
        if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD) forKey:t];
        else if (kind == C_STICK) { [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p; }
        else game |= [self gameBegin:t];
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (touchscreen_mode()) { [self tsMoved:ts]; return; }
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (c == C_FACE) [_faceOf setObject:@([self faceAt:p]) forKey:t];
        else if (c == C_STICK) { _stickNow[v >> 8] = p;
            if ((v >> 8) == 1) { CGFloat d = dist(p, _rCentre), R = [self stickR:1];   // the right stick's centre follows a finger past its radius, so turning back responds at once
                if (d > R) _rCentre = CGPointMake(p.x - (p.x - _rCentre.x) * R / d, p.y - (p.y - _rCentre.y) * R / d); } }
        else if (c == C_GAME) game = YES;
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts {
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if ((v & 0xff) == C_GAME && (v >> 8) < 16) { _game[v >> 8] = nil; game = YES; }
        [_owner removeObjectForKey:t]; [_faceOf removeObjectForKey:t]; for (int i = 0; i < 2; i++) if (t == _stick[i]) _stick[i] = nil;
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { if (touchscreen_mode()) [self tsEnded:ts cancelled:NO]; else [self endTouches:ts]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { if (touchscreen_mode()) [self tsEnded:ts cancelled:YES]; else [self endTouches:ts]; }

// ---- Touchscreen Mode: touchpad and keyboard ----
// Pointer Mode "Touch" (DM_POINTER_MODE=touch, pointer_touch) changes what one finger means, not the keys or the two-finger wheel: the cursor is put under the finger (dm_mouse_set) when it lands and follows it,
// a tap is a left click where it landed, a second tap soon after and close to the first (K_PT_DOUBLE, K_PT_DOUBLE_DIST) is a right click instead (so a lone tap is sent K_PT_DOUBLE late, once no second tap can come),
// and a finger held still for K_TP_HOLD holds the left button until it lifts (moving on then drags). A finger that moves before the hold clicks nothing.
// The touches that land on a key hold it (locked at touch-down, like the gamepad's keys): a modifier or Esc / Space, placed by the touchscreen layout (TouchscreenLayout.swift); every other touch is the touchpad. One finger: it drags the cursor once it has left the slop;
// lifting it unmoved is a left click, and holding it unmoved for K_TP_HOLD presses the right button until it lifts (moving on then drags with it). A second finger ends all of that and makes the pair a wheel: their mid point's vertical travel
// turns into notches (down = wheel up, as dragging a page down shows what is above), and the gesture stays over until every finger has lifted. Each click, each notch and each key press gives a haptic tap. A third finger does nothing.
- (CGRect)kbRect:(int)i { return _kbFrame[i]; }
- (int)kbAt:(CGPoint)p {   // the key whose hit area holds the point (nearest centre when two do): at least K_KB_HIT either way, and half the gap beyond that, so neighbouring hit areas touch but hardly overlap
    CGFloat m = K_KB_GAP * self.u / 2 - 0.5; int best = -1; CGFloat bd = CGFLOAT_MAX;
    for (int i = 0; i < TS_N; i++) {
        CGRect r = [self kbRect:i]; CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
        r = CGRectInset(r, -(MAX(K_KB_HIT - r.size.width, 0) / 2 + m), -(MAX(K_KB_HIT - r.size.height, 0) / 2 + m));
        if (!CGRectContainsPoint(r, p)) continue;
        CGFloat d = dist(p, c); if (d < bd) { bd = d; best = i; }
    }
    return best; }
- (void)refreshKeys {
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int i = 0; i < TS_N; i++) { BOOL on = _kbTouch[i] != nil;
        _kbKey[i].fillColor = (on ? k_kbOn : k_kbIdle).CGColor; _kbKey[i].strokeColor = (on ? k_kbLineOn : k_kbLine).CGColor; _kbLabel[i].foregroundColor = (on ? k_kbTextOn : k_kbText).CGColor; }
    [CATransaction commit];
}
- (CGRect)picture {   // the 16:9 picture that front_ios.m centres in the screen, as pushGame maps touches onto it
    CGRect b = self.bounds; CGFloat w = b.size.width, h = b.size.height;
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;
    return CGRectMake((b.size.width - w) / 2, (b.size.height - h) / 2, w, h);
}
- (void)padCancelHold { [_padTimer invalidate]; _padTimer = nil; }
- (void)padHold:(NSTimer *)timer {
    _padTimer = nil;
    if (_pad.count != 1 || _padMoved || _padDead || _padRight || _ptHold) return;
    if (pointer_touch()) {   // Touch pointer mode: the hold is the left button, held where the finger is
        _ptHold = YES; _ptSecond = NO; _lmbEpoch++; dm_mouse_button(DM_MOUSE_LEFT, 1);
        [_rightFeedback impactOccurred]; [_rightFeedback prepare];
        return;
    }
    _padRight = YES; dm_mouse_button(DM_MOUSE_RIGHT, 1);
    [_rightFeedback impactOccurred]; [_rightFeedback prepare];
}
- (void)padClick {
    dm_mouse_button(DM_MOUSE_LEFT, 1);
    [_clickFeedback impactOccurredWithIntensity:0.8]; [_clickFeedback prepare];
    NSUInteger epoch = ++_lmbEpoch;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ if (epoch == self->_lmbEpoch) dm_mouse_button(DM_MOUSE_LEFT, 0); });   // a press the game cannot miss
}
- (CGPoint)panelPoint:(CGPoint)p {   // a point of the view as a point of the game's 1280x720 panel (the picture centred in the screen), clamped to it
    CGRect pic = [self picture];
    CGFloat x = (p.x - pic.origin.x) / pic.size.width * 1279, y = (p.y - pic.origin.y) / pic.size.height * 719;
    return CGPointMake(MIN(MAX(x, 0), 1279), MIN(MAX(y, 0), 719));
}
- (void)ptPlaceCursor:(CGPoint)p { CGPoint q = [self panelPoint:p]; dm_mouse_set((float)q.x, (float)q.y); }
- (void)ptCancelClick { [_ptClickTimer invalidate]; _ptClickTimer = nil; }
- (void)ptSendPending {   // no second tap came (or another touch came first): the tap is a left click where it landed
    [self ptCancelClick];
    if (!_ptPending) return;
    _ptPending = NO;
    [self ptPlaceCursor:_ptPendingAt];
    [self padClick];
}
- (void)ptClickTimerFired:(NSTimer *)timer { _ptClickTimer = nil; [self ptSendPending]; }
- (void)padRightClick {
    dm_mouse_button(DM_MOUSE_RIGHT, 1);
    [_rightFeedback impactOccurred]; [_rightFeedback prepare];
    NSUInteger epoch = ++_rmbEpoch;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ if (epoch == self->_rmbEpoch) dm_mouse_button(DM_MOUSE_RIGHT, 0); });   // a press the game cannot miss
}
- (CGFloat)padMidY { return ([_pad[0] locationInView:self].y + [_pad[1] locationInView:self].y) / 2; }
- (void)tsBegan:(NSSet<UITouch *> *)ts {
    for (UITouch *t in ts) {
        int k = [self kbAt:[t locationInView:self]];
        if (k >= 0) {
            if (_kbTouch[k]) continue;
            _kbTouch[k] = t; ts_key(k, 1); [self refreshKeys];
            [_touchFeedback impactOccurredWithIntensity:0.6]; [_touchFeedback prepare];
            continue;
        }
        if (_pad.count >= 2) continue;
        [_pad addObject:t];
        if (_pad.count == 1) {
            _padStart = _padLast = [t locationInView:self]; _padMoved = _padDead = _padRight = NO;
            [self padCancelHold];
            if (pointer_touch()) {
                _ptHold = _ptSecond = NO;
                BOOL flushed = NO;
                if (_ptPending && hypot(_padStart.x - _ptPendingAt.x, _padStart.y - _ptPendingAt.y) <= K_PT_DOUBLE_DIST) { [self ptCancelClick]; _ptPending = NO; _ptSecond = YES; }   // the second tap of a double tap
                else if (_ptPending) { [self ptSendPending]; flushed = YES; }   // a tap elsewhere: the first one is a click now, then the cursor goes to the new finger
                if (flushed) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ if (self->_pad.count >= 1) [self ptPlaceCursor:[self->_pad[0] locationInView:self]]; });   // after the press has been read at the old place
                else [self ptPlaceCursor:_padStart];
            }
            _padTimer = [NSTimer scheduledTimerWithTimeInterval:K_TP_HOLD target:self selector:@selector(padHold:) userInfo:nil repeats:NO];
        } else {   // the second finger: no click or hold any more, a wheel instead
            [self padCancelHold];
            if (_padRight) { dm_mouse_button(DM_MOUSE_RIGHT, 0); _padRight = NO; }
            if (_ptHold) { _ptHold = NO; dm_mouse_button(DM_MOUSE_LEFT, 0); }
            _ptSecond = NO;
            _padDead = YES; _padScroll = 0; _padScrollY = [self padMidY];
        }
    }
}
- (void)tsMoved:(NSSet<UITouch *> *)ts {
    if (_pad.count == 1 && !_padDead && [ts containsObject:_pad[0]]) {
        CGPoint p = [_pad[0] locationInView:self];
        if (!_padMoved) {
            if (hypot(p.x - _padStart.x, p.y - _padStart.y) <= K_TP_SLOP) return;
            _padMoved = YES; [self padCancelHold]; _ptSecond = NO;
        }
        if (pointer_touch()) { [self ptPlaceCursor:p]; _padLast = p; return; }   // the cursor is under the finger
        CGFloat k = 1280.0 / [self picture].size.width * K_TP_GAIN * touchpad_speed();
        dm_mouse_move((p.x - _padLast.x) * k, (p.y - _padLast.y) * k); _padLast = p;
    } else if (_pad.count == 2 && ([ts containsObject:_pad[0]] || [ts containsObject:_pad[1]])) {
        CGFloat y = [self padMidY]; _padScroll += y - _padScrollY; _padScrollY = y;
        while (fabs(_padScroll) >= K_TP_STEP) {
            int n = _padScroll > 0 ? 1 : -1; _padScroll -= n * K_TP_STEP;
            dm_mouse_wheel(n);
            [_scrollFeedback selectionChanged]; [_scrollFeedback prepare];
        }
    }
}
- (void)tsEnded:(NSSet<UITouch *> *)ts cancelled:(BOOL)cancelled {
    for (UITouch *t in ts) {
        for (int k = 0; k < TS_N; k++) if (_kbTouch[k] == t) { _kbTouch[k] = nil; ts_key(k, 0); [self refreshKeys]; }
        if (![_pad containsObject:t]) continue;
        if (_pad.count == 1) {   // the last finger lifts
            [self padCancelHold];
            if (pointer_touch()) {
                if (_ptHold) { _ptHold = NO; dm_mouse_button(DM_MOUSE_LEFT, 0); }
                else if (!_padMoved && !_padDead && !cancelled) {
                    if (_ptSecond) [self padRightClick];   // the double tap
                    else {   // a tap: a left click unless a second one follows soon
                        _ptPending = YES; _ptPendingAt = _padStart;
                        [self ptCancelClick];
                        _ptClickTimer = [NSTimer scheduledTimerWithTimeInterval:K_PT_DOUBLE target:self selector:@selector(ptClickTimerFired:) userInfo:nil repeats:NO];
                    }
                }
                _ptSecond = NO;
            }
            else if (_padRight) { dm_mouse_button(DM_MOUSE_RIGHT, 0); _padRight = NO; }
            else if (!_padMoved && !_padDead && !cancelled) [self padClick];
            _padDead = NO;
        }
        [_pad removeObject:t];
    }
}
- (void)tsReset {   // lets go of everything the touchpad and the keys hold
    [self padCancelHold];
    for (int k = 0; k < TS_N; k++) if (_kbTouch[k]) { _kbTouch[k] = nil; ts_key(k, 0); }
    if (_padRight) { _padRight = NO; dm_mouse_button(DM_MOUSE_RIGHT, 0); }
    if (touchscreen_mode()) { _lmbEpoch++; dm_mouse_button(DM_MOUSE_LEFT, 0); }
    if (pointer_touch()) { [self ptCancelClick]; _ptPending = _ptHold = _ptSecond = NO; _rmbEpoch++; dm_mouse_button(DM_MOUSE_RIGHT, 0); }
    [_pad removeAllObjects]; _padMoved = _padDead = NO;
    [self refreshKeys];
}
- (void)reset { [self tsReset]; if (_gestureView) dm_gesture_view_release_inputs((__bridge void *)_gestureView); [_owner removeAllObjects]; [_faceOf removeAllObjects]; _stick[0] = _stick[1] = nil; for (int i = 0; i < 16; i++) _game[i] = nil; [self pushGame]; [self recompute]; }

// ---- Shapes ----
static CGPathRef circlePath(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
static CGPathRef dropPath(CGPoint c, CGFloat r, CGFloat tipAngle, CGFloat round) {   // teardrop: circle + two tangents meeting at the tip, tip slightly rounded
    CGFloat d = r * K_DROP_TIP, th = acos(r / d);
    CGPoint tip = CGPointMake(c.x + d * cos(tipAngle), c.y + d * sin(tipAngle));
    CGPoint p1 = CGPointMake(c.x + r * cos(tipAngle + th), c.y + r * sin(tipAngle + th)), p2 = CGPointMake(c.x + r * cos(tipAngle - th), c.y + r * sin(tipAngle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, round);
    CGPathAddArc(p, NULL, c.x, c.y, r, tipAngle + th, tipAngle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p); return p;
}
static CGPathRef armPath(CGPoint c, CGFloat R, CGFloat w, CGFloat in, CGFloat angle, CGFloat round) {   // one D-pad arm: an upward pentagon (tip toward the centre) rotated by angle around the centre
    CGPoint v[5] = {{-w, -R}, {w, -R}, {w, -(in + w)}, {0, -in}, {-w, -(in + w)}};
    CGFloat cs = cos(angle), sn = sin(angle);
    for (int i = 0; i < 5; i++) v[i] = CGPointMake(c.x + v[i].x * cs - v[i].y * sn, c.y + v[i].x * sn + v[i].y * cs);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[4].x + v[0].x) / 2, (v[4].y + v[0].y) / 2);
    for (int i = 0; i < 5; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 5].x, v[(i + 1) % 5].y, round);
    CGPathCloseSubpath(p); return p;
}
static void setPath(CAShapeLayer *l, CGPathRef p) { l.path = p; l.shadowPath = p; CGPathRelease(p); }
static void placeLabel(CATextLayer *t, CGPoint c, CGFloat fs) {
    CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fs, NULL);
    t.font = f; t.fontSize = fs;
    CGFloat h = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f), w = fs * 3;
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CFRelease(f);
}

static void placeKeyLabel(CATextLayer *t, CGPoint c, CGFloat fs) {   // medium weight, as the gamepad's outlined buttons (GesturePad.swift)
    CTFontRef base = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, fs, NULL), f = base;
    CTFontDescriptorRef d = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)@{(id)kCTFontTraitsAttribute: @{(id)kCTFontWeightTrait: @(UIFontWeightMedium)}});
    CTFontRef m = base && d ? CTFontCreateCopyWithAttributes(base, fs, NULL, d) : NULL; if (m) f = m;
    t.font = f; t.fontSize = fs;
    CGFloat h = f ? CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f) : fs * 1.2, w = fs * 4;
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    if (m) CFRelease(m); if (d) CFRelease(d); if (base) CFRelease(base);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIWindowScene *ws = self.window.windowScene; if (ws) atomic_store(&g_iface_orient, (int)ws.effectiveGeometry.interfaceOrientation);
    CGFloat u = self.u;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _controls.frame = self.layer.bounds;
    _tsLayer.frame = self.layer.bounds;
    for (int i = 0; i < TS_N; i++) {   // the squircle keys; Space is a thin bar with round ends
        CGRect rc = _kbFrame[i] = dm_ts_key_frame(i, self.bounds.size, u); CGFloat r = i == TS_SPACE ? rc.size.height / 2 : K_KB_R * u;
        setPath(_kbKey[i], CGPathCreateWithRoundedRect(rc, r, r, NULL)); _kbKey[i].opacity = (float)dm_ts_key_opacity(i);
        if (i != TS_SPACE) placeKeyLabel(_kbLabel[i], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), MAX(11, MIN(rc.size.height * 0.4, 24)));
    }
    for (int b = B_A; b <= B_Y; b++) { CGPoint c = [self facePos:b]; setPath(_key[b], circlePath(c, self.faceR)); placeLabel(_label[b], c, 20 * u); }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            setPath(_key[b], dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * u)); placeLabel(_label[b], c, 16 * u);   // tip toward the near top corner
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; setPath(_key[b], circlePath(c, K_CLICK_R * u)); placeLabel(_label[b], c, 13 * u);
        } else {
            CGRect rc = [self pillRect:b];
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 18 * u);
        }
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // the same arm in 90° steps
    for (int i = 0; i < 4; i++) setPath(_key[arms[i].b], armPath(self.dpadCenter, self.dpadR, K_ARM_W * u, K_ARM_IN * u, arms[i].angle, 6 * u));
    setPath(_ring, circlePath(self.stickHome, [self stickR:0]));
    CGFloat k = K_KNOB_R * u; _knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k);
    setPath(_knob, circlePath(CGPointMake(k, k), k));
    CAShapeLayer *in = (CAShapeLayer *)_knob.sublayers.firstObject; CGPathRef ip = circlePath(CGPointMake(k, k), k * 0.62);
    in.frame = _knob.bounds; in.path = ip; CGPathRelease(ip);
    [CATransaction commit];
    [self refresh];
    [self refreshKeys];
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
- (void)refresh {   // pressed state → fill, sticks → knob position
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) { BOOL on = (all >> b) & 1;
        _key[b].fillColor = (on ? k_on : k_idle).CGColor; _label[b].foregroundColor = (on ? k_textOn : k_text).CGColor; }
    CGPoint h = self.stickHome, o = [self knobOffset:0];
    _knob.position = CGPointMake(h.x + o.x, h.y + o.y); _knob.fillColor = (_stick[0] ? k_on : k_idle).CGColor;
    [CATransaction commit];
}

// ---- Physical controllers ----
// Each controller with an extended gamepad profile is a player of its own, as on the Mac (front_mac.m): it holds a slot (pad_slots.h: player 1 first, a reconnected controller
// gets its player back) and goes to dm_pad_set_player, and hle_hid.c reports player n on its own npad while the slot is held (dm_pad_players). Player 1's controller is ORed
// with the touch gamepad; a one-player game that supports only No1 / Handheld still sees every controller as player 1 (hle_hid.c). Each player has its controller's rumble and
// gyro; the phone's gyro is player 1's. With DM_PAD_MERGE=1 every controller is player 1, as before (the last one moved wins)
static pad_slots g_slots;
static GCController *g_held[DM_PLAYERS];   // the controller of each slot, kept alive while it holds it (the slot table keys on its pointer)
static int g_merge;
static int32_t axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
static void read_pad(GCExtendedGamepad *g) {
    int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)g.controller); if (p < 0) return;
    dm_haptics_apple_controller(p, g.controller);
    _Static_assert(DM_BTN_A == 1u << B_A && DM_BTN_B == 1u << B_B && DM_BTN_X == 1u << B_X && DM_BTN_Y == 1u << B_Y, "face button bits");
    uint64_t m = dm_pad_face(g);   // by position, a Nintendo pad by its labels
    #define K(btn, bit) if (btn.isPressed) m |= 1ull << bit
    K(g.leftShoulder, B_L); K(g.rightShoulder, B_R); K(g.leftTrigger, B_ZL); K(g.rightTrigger, B_ZR);
    K(g.buttonMenu, B_PLUS); if (g.buttonOptions) K(g.buttonOptions, B_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, B_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, B_RS);
    K(g.dpad.left, B_LEFT); K(g.dpad.up, B_UP); K(g.dpad.right, B_RIGHT); K(g.dpad.down, B_DOWN);
    #undef K
    dm_pad_set_player(p, m, axis(g.leftThumbstick.xAxis.value), axis(g.leftThumbstick.yAxis.value), axis(g.rightThumbstick.xAxis.value), axis(g.rightThumbstick.yAxis.value));
}
// Home and Capture: without this iOS takes them as system gestures (Home opens the Games overlay, Capture a screenshot); the app gives them no function
static void pad_keep_system_buttons(GCController *c) { for (NSString *b in @[GCInputButtonHome, GCInputButtonShare]) c.physicalInputProfile.buttons[b].preferredSystemGestureState = GCSystemGestureStateDisabled; }
static const char *pad_name(GCController *c) { return c.vendorName.UTF8String ?: "?"; }
static void npad_name(int p, char *out, size_t cap) { uint32_t id = dm_player_npad(p); if (id == 0x20) snprintf(out, cap, "handheld"); else snprintf(out, cap, "%u", id); }
static void pads_start(void) {
    const char *e = getenv("DM_PAD_MERGE"); g_merge = e && atoi(e);
    LOG("front end: %s", g_merge ? "every controller is player 1 (DM_PAD_MERGE)" : "each controller is a player of its own, the touch gamepad plays with player 1");
}
// Called at start and on every connect / disconnect (gone: the controller that was just removed, nil otherwise); returns whether a controller is in use
static BOOL pads_merged(GCController *gone) {
    if (gone) { gone.extendedGamepad.valueChangedHandler = nil; dm_motion_detach(gone, 0); }
    BOOL any = NO; int motion = 0;
    for (GCController *c in GCController.controllers) if (c != gone && c.extendedGamepad) {
        if (c.motion.hasRotationRate) motion = 1;
        any = YES; pad_keep_system_buttons(c); c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, 0);   // every controller is player 1: the last one moved drives its six-axis sensor
        read_pad(c.extendedGamepad);
    }
    if (!any || !motion) dm_motion_clear(0);   // the phone's gyro (if on) takes over from its next sample
    if (!any) { dm_haptics_apple_controller(0, nil); dm_pad_set(0, 0, 0, 0, 0); }
    return any;
}
static BOOL pads_slotted(GCController *gone) {
    NSArray<GCController *> *now = GCController.controllers; char nb[16];
    for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p] && (g_held[p] == gone || ![now containsObject:g_held[p]])) {
        npad_name(p, nb, sizeof nb); LOG("controller '%s' disconnected: player %d (npad %s) is free", pad_name(g_held[p]), p + 1, nb);
        g_held[p].extendedGamepad.valueChangedHandler = nil;
        dm_motion_detach(g_held[p], p);   // player 1's: the phone's gyro (if on) takes over from its next sample
        dm_haptics_apple_controller(p, nil);
        pad_slot_free(&g_slots, (__bridge const void *)g_held[p]); g_held[p] = nil;
        dm_pad_set_player(p, 0, 0, 0, 0, 0);   // nothing stays pressed
    }
    for (GCController *c in now) if (c.extendedGamepad && c != gone && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) {
        int p = pad_slot_take(&g_slots, (__bridge const void *)c, pad_name(c));
        if (p < 0) { LOG("controller '%s' connected: all %d players are taken, not used", pad_name(c), DM_PLAYERS); continue; }
        g_held[p] = c; pad_keep_system_buttons(c);
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, p);
        npad_name(p, nb, sizeof nb); LOG("controller '%s' connected: player %d (npad %s)%s", pad_name(c), p + 1, nb, c.motion.hasRotationRate ? ", with motion (gyro)" : "");
        read_pad(c.extendedGamepad);
    }
    dm_pad_players(pad_slot_mask(&g_slots));
    return pad_slot_mask(&g_slots) != 0;
}
- (void)padsChanged:(NSNotification *)note {
    GCController *c = note.object, *gone = [note.name isEqual:GCControllerDidDisconnectNotification] ? c : nil;
    if (c && (!c.extendedGamepad || g_merge)) LOG("controller %s: %s%s", gone ? "disconnected" : "connected", pad_name(c), c.extendedGamepad ? "" : " (no extended gamepad profile: not used)");
    BOOL any = g_merge ? pads_merged(gone) : pads_slotted(gone);
    BOOL off = any || touchscreen_mode();   // Touchscreen Mode (DM_TOUCHSCREEN=1): the touch gamepad stays hidden, controller or not, and the touchpad (tsBegan) takes the touches: the game gets them as the mouse and, for a click, a touch at the cursor
    dispatch_async(dispatch_get_main_queue(), ^{ self->_padOff = off; self->_controls.hidden = off; self->_gestureView.hidden = off; self->_gestureView.userInteractionEnabled = !off; [self reset]; });   // the touch gamepad hides while any controller is in use
}
@end

UIView *dm_gamepad_view(CGRect frame) { DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v; return v; }
void dm_gamepad_active(void) { dispatch_async(dispatch_get_main_queue(), ^{ for (GCController *c in GCController.controllers) dm_motion_rearm(c); }); }   // On become active: motion_apple.h
void dm_gamepad_reset(void) {   // On resign active: release everything (a key held while switching away and released in background gets no "release")
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; });
    pthread_mutex_lock(&g_mu); g_shake_btn = 0; pthread_mutex_unlock(&g_mu); publish();
    if (g_merge) dm_pad_set(0, 0, 0, 0, 0);
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
}
