// Swipe-based touch gamepad (the "Swipe" layout of DmGamepad.m), ported from MeloNX's gesture controller.
//
//  Gestures (anywhere that is not a button):
//    - Swipe up / down / left / right -> D-pad press in that direction. By default ONE press per touch; with the swipe lock
//                                        open, one continuous swipe keeps firing a press every time the finger travels another step.
//    - Tap                            -> A (haptic)
//    - Touch and hold                 -> B (held until the finger lifts, haptic on press). Off while the dedicated B button is on (DM_DEDICATED_B)
//
//  Buttons (minimal outline style), placed by GestureLayout.defaults (the default layout) or by the player in the editor:
//    - L / R, ZL / ZR, X / Y, - / +, L3 / R3 (the stick clicks). R3 is the "special" button of the mods (mods/README.md): vanilla games do not use it, so a mod can claim it
//    - B               only with DM_DEDICATED_B=1, left of X; the touch-and-hold gesture is then off
//    - +               with DM_HOLD_PLUS=1 it presses only after being held for holdPlusDuration: it fills up while held and a success haptic plays when it fires
//    - Right stick     a scroller: while a finger holds it, moving that finger up or down tilts the right stick, and swipes made elsewhere with another finger move the stick instead of the D-pad
//    - Swipe lock      toggle. Locked = one D-pad press per swipe, unlocked = several presses per swipe
//
// Button positions, sizes and opacity are edited in GestureLayoutEditor.swift (Launcher > Controls > Edit swipe layout) and kept in UserDefaults. Touchscreen Mode has its own layout, for its keys (TouchscreenLayout.swift).
// Presses reach the host through dm_gesture_button / dm_gesture_stick (DmGamepad.m), which publish them next to the other touch controls.
import SwiftUI
import UIKit

// MARK: - Buttons

/// The buttons this layout presses. The raw values are the nn::hid::NpadButton bits of dm_input.h (DM_BTN_*).
enum PadButton: UInt64 {
    case a = 0x1, b = 0x2, x = 0x4, y = 0x8
    case leftStick = 0x10, rightStick = 0x20
    case leftShoulder = 0x40, rightShoulder = 0x80, leftTrigger = 0x100, rightTrigger = 0x200
    case plus = 0x400, minus = 0x800
    case dPadLeft = 0x1000, dPadUp = 0x2000, dPadRight = 0x4000, dPadDown = 0x8000

    static let all: [PadButton] = [.a, .b, .x, .y, .leftStick, .rightStick, .leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger, .plus, .minus,
                                   .dPadLeft, .dPadUp, .dPadRight, .dPadDown]
}

// MARK: - Layout model

enum GestureControlID: String, CaseIterable, Codable {
    case l, r, zl, zr, x, y, b, minus, plus, stick, lock, l3, r3

    var title: String {
        switch self {
        case .l: return "L"
        case .r: return "R"
        case .zl: return "ZL"
        case .zr: return "ZR"
        case .x: return "X"
        case .y: return "Y"
        case .b: return "B"
        case .minus: return "−"
        case .plus: return "+"
        case .stick: return "Right Stick"
        case .lock: return "Swipe Lock"
        case .l3: return "L3"
        case .r3: return "R3"
        }
    }
}

/// Custom button placements. Positions are fractions of the screen (0...1) so they survive rotation and other screen sizes;
/// a control that is missing falls back to the default layout.
struct GestureLayout: Codable, Equatable {
    struct Item: Codable, Equatable {
        var x: CGFloat
        var y: CGFloat
        var scale: CGFloat
        /// Optional so a layout saved before opacity existed still decodes. nil == fully opaque.
        var opacity: CGFloat?
    }

    var items: [String: Item] = [:]

    /// The default layout. The grid cell is 1/24 of the short side, so a row is n/24 of the height and a column n/51.91 of the width on the 2.16:1 phone it was made on.
    /// Every control sits on the editor grid there; a control the player has not moved or resized takes its entry from here.
    static let defaults: [GestureControlID: Item] = {
        let columns: CGFloat = 51.91
        func item(_ column: CGFloat, _ row: CGFloat, _ scale: CGFloat) -> Item {
            Item(x: (column / columns * 10000).rounded() / 10000, y: (row / 24 * 10000).rounded() / 10000, scale: scale, opacity: 0.75)
        }
        return [
            .zl: item(5, 2, 1.25), .zr: item(9, 2, 1.25),
            .l: item(5, 22, 1.25), .r: item(9, 22, 1.25),
            .r3: item(1, 4, 0.75), .l3: item(1, 6.5, 0.75),
            .lock: item(39, 2, 1.0), .stick: item(42, 2, 1.0),
            .minus: item(49, 2, 1.0), .plus: item(49, 4, 1.0),
            .b: item(30, 22, 1.25), .x: item(34, 22, 1.25), .y: item(38, 22, 1.25)
        ]
    }()

    /// What the control looks like now: the player's own entry, else the default one. A layout saved before opacity existed (nil) was fully opaque.
    func effective(_ id: GestureControlID) -> Item {
        if let saved = items[id.rawValue] {
            var item = saved
            if item.opacity == nil { item.opacity = 1 }
            return item
        }
        return Self.defaults[id] ?? Item(x: 0.5, y: 0.5, scale: 1, opacity: 1)
    }
}

/// Each game is its own app, so there is one layout per app.
enum GestureLayoutStore {
    private static let key = "GestureControllerLayout"

    static func load() -> GestureLayout {
        guard let data = UserDefaults.standard.data(forKey: key),
              let layout = try? JSONDecoder().decode(GestureLayout.self, from: data) else { return GestureLayout() }
        return layout
    }

    static func save(_ layout: GestureLayout) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Editor <-> view bridge

final class GestureLayoutEditorModel: ObservableObject {
    static let snapDefaultsKey = "GestureEditorSnapToGrid"

    @Published var selectedTitle: String?
    @Published var scale: Double = 1.0
    @Published var opacity: Double = 1.0
    @Published var snapEnabled: Bool = (UserDefaults.standard.object(forKey: GestureLayoutEditorModel.snapDefaultsKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(snapEnabled, forKey: Self.snapDefaultsKey)
            view?.snapEnabled = snapEnabled
        }
    }

    weak var view: GestureControllerUIView?

    func setScale(_ value: Double) {
        scale = value
        view?.setSelectedScale(CGFloat(value))
    }

    func setOpacity(_ value: Double) {
        opacity = value
        view?.setSelectedOpacity(CGFloat(value))
    }

    func reset() {
        view?.resetLayout()
    }
}

// MARK: - SwiftUI wrapper (the editor)

struct GestureControllerView: UIViewRepresentable {
    let editorModel: GestureLayoutEditorModel
    let dedicatedB: Bool

    func makeUIView(context: Context) -> GestureControllerUIView {
        let view = GestureControllerUIView(editing: true, dedicatedB: dedicatedB)
        let model = editorModel

        model.view = view
        view.snapEnabled = model.snapEnabled
        view.onSelectionChange = { [weak model] title, scale, opacity in
            DispatchQueue.main.async {
                model?.selectedTitle = title
                if let scale { model?.scale = Double(scale) }
                if let opacity { model?.opacity = Double(opacity) }
            }
        }

        return view
    }

    func updateUIView(_ uiView: GestureControllerUIView, context: Context) {}
}

// MARK: - Editor grid

/// Full-screen grid shown behind the controls while editing. It is drawn by the editing view itself so it always lines up with the snapping.
final class GestureGridView: UIView {   // also the touchscreen layout editor's grid (TouchscreenLayoutEditor.swift)
    /// Every this many cells a heavier line marks a block, so the fine grid stays readable.
    private let majorEvery = 8
    var cell: CGFloat = 16 { didSet { if oldValue != cell { setNeedsDisplay() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), cell > 4 else { return }

        let minor = UIBezierPath()
        let major = UIBezierPath()

        var column = 0
        var x: CGFloat = 0
        while x <= bounds.width + 0.5 {
            let path = column % majorEvery == 0 ? major : minor
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: bounds.height))
            x += cell
            column += 1
        }

        var row = 0
        var y: CGFloat = 0
        while y <= bounds.height + 0.5 {
            let path = row % majorEvery == 0 ? major : minor
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: bounds.width, y: y))
            y += cell
            row += 1
        }

        ctx.setLineWidth(0.5)
        UIColor.white.withAlphaComponent(0.08).setStroke()
        minor.lineWidth = 0.5
        minor.stroke()

        UIColor.white.withAlphaComponent(0.22).setStroke()
        major.lineWidth = 0.75
        major.stroke()
    }
}

// MARK: - UIKit view

final class GestureControllerUIView: UIView {

    // MARK: Tunables

    /// Movement below this still counts as a tap / hold.
    private let tapSlop: CGFloat = 16
    /// A swipe must travel at least this far before it registers (the dead zone). With the swipe lock open this is also the distance between repeated presses.
    private let swipeDeadzone: CGFloat = 40
    /// The winning axis must beat the other by this factor, so diagonals do not misfire.
    private let swipeDominance: CGFloat = 1.3
    /// How long a stationary finger must stay down to count as a "B" hold.
    private let holdDelay: TimeInterval = 0.35
    /// Finger travel (points) that maps to full right-stick deflection.
    private let stickRadius: CGFloat = 70
    /// How long a tap / swipe press keeps the button down.
    private let pulseDuration: TimeInterval = 0.07
    /// A held button stays down at least this long, so a very quick tap is never shorter than the game's input polling and gets dropped.
    private let minimumPress: TimeInterval = 0.07
    /// Buttons are always at least this big to hit, however small they are drawn.
    private let minimumHitSize: CGFloat = 54
    /// The editor grid has this many cells along the short side of the screen. Twice as many as the second version, so each of its sections is split in four.
    private let gridDivisions: CGFloat = 48
    /// The + button, with DM_HOLD_PLUS on, fires after being held this long.
    private let holdPlusDuration: TimeInterval = 0.75
    /// Finger travel (points) before the right-stick scroller starts to tilt, and the travel that tilts it fully after that.
    private let scrollDeadzone: CGFloat = 8

    private static let multiSwipeDefaultsKey = "GestureMultiSwipeEnabled"

    /// Touch haptics follow the same switch as DmGamepad.m's (DM_TOUCH_HAPTICS=0 turns them off).
    private let hapticsOn: Bool = {
        guard let value = getenv("DM_TOUCH_HAPTICS") else { return true }
        return atoi(value) != 0
    }()

    private let holdPlusOn: Bool = {
        guard let value = getenv("DM_HOLD_PLUS") else { return false }
        return atoi(value) != 0
    }()

    /// The B button is a control of its own and the touch-and-hold gesture is off. The editor passes the launcher's current choice, as the environment is not set yet there.
    private let dedicatedB: Bool

    // MARK: Controls

    private enum Kind: Equatable {
        case button(PadButton)
        case stickScroll
        case swipeLockToggle
    }

    private final class ControlView: UIView {
        let id: GestureControlID
        let kind: Kind
        let isCircle: Bool
        private let label = UILabel()
        private let icon = UIImageView()
        private let symbol: String?
        private let activeSymbol: String?
        /// Fills the control from its left edge while a hold-to-confirm press builds up (the + button, DM_HOLD_PLUS).
        private let fillLayer = CALayer()

        var isActive = false { didSet { refresh() } }

        init(id: GestureControlID, kind: Kind, title: String, circle: Bool, symbol: String? = nil, activeSymbol: String? = nil) {
            self.id = id
            self.kind = kind
            self.isCircle = circle
            self.symbol = symbol
            self.activeSymbol = activeSymbol
            super.init(frame: .zero)

            isUserInteractionEnabled = false
            layer.borderWidth = 1
            layer.masksToBounds = true

            fillLayer.backgroundColor = UIColor.white.withAlphaComponent(0.4).cgColor
            fillLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
            fillLayer.transform = Self.emptyFill
            layer.insertSublayer(fillLayer, at: 0)

            label.text = title
            label.textColor = .white
            label.textAlignment = .center
            addSubview(label)

            if symbol != nil {
                icon.tintColor = .white
                icon.contentMode = .scaleAspectFit
                addSubview(icon)
                label.isHidden = true
            }

            refresh()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = isCircle ? min(bounds.width, bounds.height) / 2 : bounds.height / 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fillLayer.bounds = CGRect(origin: .zero, size: bounds.size)
            fillLayer.position = CGPoint(x: 0, y: bounds.midY)
            CATransaction.commit()
            label.frame = bounds
            label.font = .systemFont(ofSize: max(11, min(bounds.height * 0.4, 24)), weight: .medium)
            icon.frame = bounds.insetBy(dx: bounds.width * 0.28, dy: bounds.height * 0.28)
        }

        private static let emptyFill = CATransform3DMakeScale(0.0001, 1, 1)

        /// Fills the control from empty to full in `duration`, evenly.
        func startFill(duration: TimeInterval) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fillLayer.removeAllAnimations()
            fillLayer.transform = CATransform3DIdentity
            CATransaction.commit()

            let animation = CABasicAnimation(keyPath: "transform.scale.x")
            animation.fromValue = 0.0001
            animation.toValue = 1
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            fillLayer.add(animation, forKey: "fill")
        }

        /// Empties the fill from wherever it has got to, quickly.
        func drainFill() {
            let current = (fillLayer.presentation()?.value(forKeyPath: "transform.scale.x") as? NSNumber)?.doubleValue ?? 0

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fillLayer.removeAllAnimations()
            fillLayer.transform = Self.emptyFill
            CATransaction.commit()

            guard current > 0.01 else { return }
            let animation = CABasicAnimation(keyPath: "transform.scale.x")
            animation.fromValue = current
            animation.toValue = 0.0001
            animation.duration = 0.15 * current
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fillLayer.add(animation, forKey: "drain")
        }

        private func refresh() {
            // Outline only: almost no fill until pressed.
            backgroundColor = UIColor.white.withAlphaComponent(isActive ? 0.30 : 0.04)
            layer.borderColor = UIColor.white.withAlphaComponent(isActive ? 0.95 : 0.42).cgColor
            label.textColor = UIColor.white.withAlphaComponent(isActive ? 1 : 0.85)
            icon.tintColor = UIColor.white.withAlphaComponent(isActive ? 1 : 0.85)

            if let symbol {
                let name = (isActive ? activeSymbol : nil) ?? symbol
                let config = UIImage.SymbolConfiguration(weight: .light)
                icon.image = UIImage(systemName: name, withConfiguration: config)
            }
        }
    }

    private let isEditing: Bool

    fileprivate(set) var layout: GestureLayout

    private let lockControl = ControlView(id: .lock, kind: .swipeLockToggle, title: "", circle: true, symbol: "lock", activeSymbol: "lock.open")

    private lazy var controls: [ControlView] = {
        var list = [
            ControlView(id: .l, kind: .button(.leftShoulder), title: "L", circle: false),
            ControlView(id: .r, kind: .button(.rightShoulder), title: "R", circle: false),
            ControlView(id: .zl, kind: .button(.leftTrigger), title: "ZL", circle: false),
            ControlView(id: .zr, kind: .button(.rightTrigger), title: "ZR", circle: false),
            ControlView(id: .x, kind: .button(.x), title: "X", circle: true),
            ControlView(id: .y, kind: .button(.y), title: "Y", circle: true),
            ControlView(id: .minus, kind: .button(.minus), title: "−", circle: false),
            ControlView(id: .plus, kind: .button(.plus), title: "+", circle: false),
            ControlView(id: .l3, kind: .button(.leftStick), title: "L3", circle: true),
            ControlView(id: .r3, kind: .button(.rightStick), title: "R3", circle: true),
            ControlView(id: .stick, kind: .stickScroll, title: "RS", circle: true, symbol: "r.joystick"),
            lockControl
        ]
        if self.dedicatedB { list.append(ControlView(id: .b, kind: .button(.b), title: "B", circle: true)) }
        return list
    }()

    // MARK: Haptics

    private let buttonHaptic = UIImpactFeedbackGenerator(style: .light)
    private let swipeHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let tapHaptic = UIImpactFeedbackGenerator(style: .medium)   // A
    private let holdHaptic = UIImpactFeedbackGenerator(style: .heavy)   // B
    private let gridHaptic = UISelectionFeedbackGenerator()
    private let confirmHaptic = UINotificationFeedbackGenerator()   // the + button fired (hold to confirm)

    // MARK: Gameplay touch tracking

    private final class GestureTouch {
        enum Phase {
            /// Within the tap slop; may still become a tap, hold, swipe or stick drag.
            case undecided
            /// Stationary long enough: B is held.
            case holding
            /// Moved too far to be a tap but never became a swipe (or already fired one).
            case spent
            /// Driving the right stick.
            case stick
        }

        let start: CGPoint
        /// Where the next swipe step is measured from. Advances after every press when the swipe lock is open.
        var anchor: CGPoint
        var phase: Phase = .undecided
        var holdWork: DispatchWorkItem?
        /// Set once this touch has produced a D-pad press.
        var swipeFired = false

        init(start: CGPoint) {
            self.start = start
            self.anchor = start
        }
    }

    private var gestureTouches: [ObjectIdentifier: GestureTouch] = [:]
    private var buttonTouches: [ObjectIdentifier: ControlView] = [:]

    /// Where each finger holding the right stick button went down: moving it up or down tilts the stick from there.
    private var stickScrollStarts: [ObjectIdentifier: CGPoint] = [:]
    /// A finger is holding the right stick button: swipes made elsewhere move the stick instead of the D-pad.
    private var stickHeld: Bool { buttonTouches.values.contains { $0.kind == .stickScroll } }
    /// The + button is being held and has not fired yet.
    private var plusHoldWork: DispatchWorkItem?
    /// Swipe lock open: one swipe can fire several D-pad presses.
    private var multiSwipeEnabled = UserDefaults.standard.bool(forKey: GestureControllerUIView.multiSwipeDefaultsKey)

    private var pulseQueue: [PadButton: Int] = [:]
    private var pulseRunning: Set<PadButton> = []

    private var pressStart: [PadButton: CFTimeInterval] = [:]
    private var pendingRelease: [PadButton: DispatchWorkItem] = [:]

    /// A rectangle whose touches fall through to the views below (DmGamepad.m's layout button, which this layout keeps).
    var passthrough: CGRect = .zero

    // MARK: Editing state

    var onSelectionChange: ((String?, CGFloat?, CGFloat?) -> Void)?
    var snapEnabled = true
    private var selectedID: GestureControlID?
    private var dragTouches: [ObjectIdentifier: (control: ControlView, offset: CGPoint)] = [:]
    private let gridView = GestureGridView()
    private let selectionRing = UIView()

    // MARK: Init

    init(editing: Bool, dedicatedB: Bool? = nil) {
        self.layout = GestureLayoutStore.load()
        self.isEditing = editing
        if let dedicatedB {
            self.dedicatedB = dedicatedB
        } else if let value = getenv("DM_DEDICATED_B") {
            self.dedicatedB = atoi(value) != 0
        } else {
            self.dedicatedB = false
        }
        super.init(frame: .zero)

        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isExclusiveTouch = false

        if editing {
            addSubview(gridView)
        }

        controls.forEach(addSubview)
        lockControl.isActive = multiSwipeEnabled

        if editing {
            selectionRing.isUserInteractionEnabled = false
            selectionRing.layer.borderColor = UIColor.systemYellow.cgColor
            selectionRing.layer.borderWidth = 2
            selectionRing.isHidden = true
            addSubview(selectionRing)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    /// Same unit as DmGamepad.m's: 1 = 430 points tall, at most 1.3.
    private var scale: CGFloat { min(max(bounds.height / 430, 0.6), 1.3) }
    private var pillSize: CGSize { CGSize(width: 50 * scale, height: 32 * scale) }
    private var circleSize: CGSize { CGSize(width: 48 * scale, height: 48 * scale) }

    /// Editor grid cell, in points. Square cells sized from the short side of the screen.
    private var gridCell: CGFloat {
        max(min(bounds.width, bounds.height) / gridDivisions, 6)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        if isEditing {
            gridView.frame = bounds
            gridView.cell = gridCell
        }

        for control in controls {
            let item = layout.effective(control.id)
            let base = control.isCircle ? circleSize : pillSize
            let size = CGSize(width: base.width * item.scale, height: base.height * item.scale)

            control.alpha = min(max(item.opacity ?? 1, 0.05), 1)

            let center = clamped(CGPoint(x: item.x * w, y: item.y * h), size: size)

            // Do not fight an in-progress drag
            if isEditing, dragTouches.values.contains(where: { $0.control === control }) {
                continue
            }

            control.bounds = CGRect(origin: .zero, size: size)
            control.center = center
        }

        updateSelectionRing()
    }

    private func clamped(_ center: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(center.x, size.width / 2), max(bounds.width - size.width / 2, size.width / 2)),
            y: min(max(center.y, size.height / 2), max(bounds.height - size.height / 2, size.height / 2))
        )
    }

    private func snapped(_ point: CGPoint) -> CGPoint {
        guard snapEnabled else { return point }
        let cell = gridCell
        return CGPoint(x: (point.x / cell).rounded() * cell, y: (point.y / cell).rounded() * cell)
    }

    /// Touches on the layout button reach DmGamepad.m underneath, so the layout can always be switched.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if !isEditing, passthrough.contains(point) {
            return controlAt(point) != nil
        }
        return super.point(inside: point, with: event)
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isEditing {
            editTouchesBegan(touches)
            return
        }

        if hapticsOn {
            buttonHaptic.prepare()
            swipeHaptic.prepare()
            tapHaptic.prepare()
            holdHaptic.prepare()
        }

        for touch in touches {
            let point = touch.location(in: self)
            let id = ObjectIdentifier(touch)

            if let control = controlAt(point) {
                buttonTouches[id] = control
                if control.kind == .stickScroll { stickScrollStarts[id] = point }
                controlDown(control)
                continue
            }

            let gesture = GestureTouch(start: point)
            gestureTouches[id] = gesture

            // With the dedicated B button the touch-and-hold gesture is off: a finger that stays down just waits to become a tap or a swipe.
            if !dedicatedB {
                let work = DispatchWorkItem { [weak self] in self?.holdFired(id) }
                gesture.holdWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isEditing {
            editTouchesMoved(touches)
            return
        }

        for touch in touches {
            let point = touch.location(in: self)

            if let start = stickScrollStarts[ObjectIdentifier(touch)] {
                scrollStick(from: start, to: point)
                continue
            }

            guard let gesture = gestureTouches[ObjectIdentifier(touch)] else { continue }

            switch gesture.phase {
            case .undecided:
                let dx = point.x - gesture.start.x
                let dy = point.y - gesture.start.y
                let distance = hypot(dx, dy)

                guard distance > tapSlop else { continue }

                // Moving cancels any pending hold.
                gesture.holdWork?.cancel()
                gesture.holdWork = nil

                if stickHeld {
                    gesture.phase = .stick
                    handleStick(gesture, to: point)
                } else {
                    gesture.phase = .spent
                    evaluateSwipe(gesture, at: point)
                }

            case .spent:
                // Locked: one press per touch. Unlocked: keep going while the finger keeps moving.
                guard !gesture.swipeFired || multiSwipeEnabled else { continue }
                evaluateSwipe(gesture, at: point)

            case .stick:
                handleStick(gesture, to: point)

            case .holding:
                break
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isEditing {
            editTouchesEnded(touches)
            return
        }
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isEditing {
            editTouchesEnded(touches)
            return
        }
        finish(touches, cancelled: true)
    }

    /// Nearest control whose (enlarged) hit area contains the point.
    private func controlAt(_ point: CGPoint) -> ControlView? {
        var best: (control: ControlView, distance: CGFloat)?

        for control in controls {
            let width = max(control.bounds.width, minimumHitSize) + 12
            let height = max(control.bounds.height, minimumHitSize) + 12
            let hitRect = CGRect(x: control.center.x - width / 2, y: control.center.y - height / 2, width: width, height: height)

            guard hitRect.contains(point) else { continue }

            let distance = hypot(point.x - control.center.x, point.y - control.center.y)
            if best == nil || distance < best!.distance {
                best = (control, distance)
            }
        }

        return best?.control
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        for touch in touches {
            let id = ObjectIdentifier(touch)

            if let control = buttonTouches.removeValue(forKey: id) {
                stickScrollStarts.removeValue(forKey: id)
                controlUp(control)
                continue
            }

            guard let gesture = gestureTouches.removeValue(forKey: id) else { continue }
            gesture.holdWork?.cancel()
            gesture.holdWork = nil

            switch gesture.phase {
            case .undecided:
                // Never left the tap slop and was not held: a tap.
                if !cancelled {
                    if hapticsOn { tapHaptic.impactOccurred() }
                    pulse(.a)
                }
            case .holding:
                setButton(.b, pressed: false)
            case .stick:
                setStick(x: 0, y: 0)
            case .spent:
                break
            }
        }
    }

    private func holdFired(_ id: ObjectIdentifier) {
        guard let gesture = gestureTouches[id], gesture.phase == .undecided else { return }
        gesture.phase = .holding
        gesture.holdWork = nil
        if hapticsOn { holdHaptic.impactOccurred() }
        setButton(.b, pressed: true)
    }

    // MARK: - Swipe

    /// Measures travel from the touch's anchor. Locked mode fires once; with the lock open the anchor advances by one step after each press
    /// so a long swipe keeps repeating.
    private func evaluateSwipe(_ gesture: GestureTouch, at point: CGPoint) {
        let dx = point.x - gesture.anchor.x
        let dy = point.y - gesture.anchor.y
        let ax = abs(dx)
        let ay = abs(dy)

        // Still inside the dead zone
        guard max(ax, ay) >= swipeDeadzone else { return }
        // Too diagonal to call yet; keep waiting for one axis to win
        guard max(ax, ay) >= min(ax, ay) * swipeDominance else { return }

        let button: PadButton
        if ax > ay {
            button = dx > 0 ? .dPadRight : .dPadLeft
            if multiSwipeEnabled {
                gesture.anchor.x += dx > 0 ? swipeDeadzone : -swipeDeadzone
                gesture.anchor.y = point.y
            }
        } else {
            button = dy > 0 ? .dPadDown : .dPadUp
            if multiSwipeEnabled {
                gesture.anchor.y += dy > 0 ? swipeDeadzone : -swipeDeadzone
                gesture.anchor.x = point.x
            }
        }

        let repeated = gesture.swipeFired
        gesture.swipeFired = true

        if hapticsOn { swipeHaptic.impactOccurred(intensity: repeated ? 0.55 : 1) }
        pulse(button)
    }

    // MARK: - Right stick

    private func handleStick(_ gesture: GestureTouch, to point: CGPoint) {
        var x = (point.x - gesture.start.x) / stickRadius
        var y = (point.y - gesture.start.y) / stickRadius

        let magnitude = hypot(x, y)
        if magnitude > 1 {
            x /= magnitude
            y /= magnitude
        }

        setStick(x: x, y: y)
    }

    /// The right stick button as a scroller: moving the finger holding it up or down tilts the stick that way, further from where it went down meaning more.
    private func scrollStick(from start: CGPoint, to point: CGPoint) {
        let dy = point.y - start.y
        let travel = max(abs(dy) - scrollDeadzone, 0)
        let tilt = min(travel / max(stickRadius - scrollDeadzone, 1), 1)
        setStick(x: 0, y: dy < 0 ? -tilt : tilt)
    }

    /// x and y are in screen coordinates (down = positive); the host takes up as positive, so y is flipped here.
    private func setStick(x: CGFloat, y: CGFloat) {
        dm_gesture_stick(Int32((x * 32767).rounded()), Int32((-y * 32767).rounded()))
    }

    // MARK: - Buttons

    private func controlDown(_ control: ControlView) {
        if hapticsOn { buttonHaptic.impactOccurred() }

        switch control.kind {
        case .button(let button):
            if button == .plus, holdPlusOn {
                beginPlusHold(control)
            } else {
                control.isActive = true
                pressButton(button)
            }
        case .stickScroll:
            control.isActive = true
        case .swipeLockToggle:
            multiSwipeEnabled.toggle()
            control.isActive = multiSwipeEnabled
            UserDefaults.standard.set(multiSwipeEnabled, forKey: Self.multiSwipeDefaultsKey)
        }
    }

    private func controlUp(_ control: ControlView) {
        switch control.kind {
        case .button(let button):
            control.isActive = false
            if button == .plus, holdPlusOn {
                endPlusHold(control)
            } else {
                releaseButton(button)
            }
        case .stickScroll:
            control.isActive = false
            setStick(x: 0, y: 0)
            // Fingers already moving the stick with a swipe are done.
            for gesture in gestureTouches.values where gesture.phase == .stick {
                gesture.phase = .spent
                gesture.swipeFired = true
            }
        case .swipeLockToggle:
            break
        }
    }

    // MARK: - Hold to confirm (+)

    /// The + button fills up while it is held. After `holdPlusDuration` a success haptic plays and + is pressed once; letting go sooner presses nothing.
    private func beginPlusHold(_ control: ControlView) {
        plusHoldWork?.cancel()
        control.startFill(duration: holdPlusDuration)
        if hapticsOn { confirmHaptic.prepare() }

        let work = DispatchWorkItem { [weak self, weak control] in
            guard let self else { return }
            self.plusHoldWork = nil
            control?.isActive = true
            if self.hapticsOn { self.confirmHaptic.notificationOccurred(.success) }
            self.pulse(.plus)
        }
        plusHoldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdPlusDuration, execute: work)
    }

    private func endPlusHold(_ control: ControlView) {
        plusHoldWork?.cancel()
        plusHoldWork = nil
        control.drainFill()
    }

    /// Presses a held button. If the same button is still waiting out its minimum press time from a previous tap, release it first so the game sees a fresh press.
    private func pressButton(_ button: PadButton) {
        if let pending = pendingRelease.removeValue(forKey: button) {
            pending.cancel()
            setButton(button, pressed: false)
            pressStart[button] = CACurrentMediaTime() + 0.03
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.setButton(button, pressed: true)
            }
            return
        }

        pressStart[button] = CACurrentMediaTime()
        setButton(button, pressed: true)
    }

    /// Releases a held button, but never sooner than `minimumPress` after it went down.
    private func releaseButton(_ button: PadButton) {
        let elapsed = CACurrentMediaTime() - (pressStart[button] ?? 0)
        let remaining = minimumPress - elapsed

        guard remaining > 0.001 else {
            setButton(button, pressed: false)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.pendingRelease.removeValue(forKey: button)
            self?.setButton(button, pressed: false)
        }
        pendingRelease[button] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    // MARK: - Output

    private func setButton(_ button: PadButton, pressed: Bool) {
        dm_gesture_button(button.rawValue, pressed ? 1 : 0)
    }

    /// Taps / swipes: press briefly, then release. Rapid repeats are queued so the game always sees a clean release between presses.
    private func pulse(_ button: PadButton) {
        let queued = pulseQueue[button, default: 0]
        guard queued < 3 else { return }
        pulseQueue[button] = queued + 1

        if !pulseRunning.contains(button) {
            runPulse(button)
        }
    }

    private func runPulse(_ button: PadButton) {
        guard let queued = pulseQueue[button], queued > 0 else {
            pulseRunning.remove(button)
            return
        }

        pulseQueue[button] = queued - 1
        pulseRunning.insert(button)
        setButton(button, pressed: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + pulseDuration) { [weak self] in
            guard let self else { return }
            self.setButton(button, pressed: false)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.runPulse(button)
            }
        }
    }

    /// Releases everything: when the layout is left, a controller connects, or the app resigns active.
    func releaseAll() {
        guard !isEditing else { return }

        gestureTouches.values.forEach { $0.holdWork?.cancel() }
        gestureTouches.removeAll()
        buttonTouches.removeAll()
        pulseQueue.removeAll()
        pulseRunning.removeAll()
        pendingRelease.values.forEach { $0.cancel() }
        pendingRelease.removeAll()
        stickScrollStarts.removeAll()
        plusHoldWork?.cancel()
        plusHoldWork = nil
        controls.first(where: { $0.id == .plus })?.drainFill()
        controls.forEach { $0.isActive = false }
        controls.first(where: { $0.id == .lock })?.isActive = multiSwipeEnabled

        PadButton.all.forEach { setButton($0, pressed: false) }
        setStick(x: 0, y: 0)
    }

    // MARK: - Layout editing

    private func editTouchesBegan(_ touches: Set<UITouch>) {
        gridHaptic.prepare()

        for touch in touches {
            let point = touch.location(in: self)

            if let control = controlAt(point) {
                select(control.id)
                dragTouches[ObjectIdentifier(touch)] = (
                    control,
                    CGPoint(x: control.center.x - point.x, y: control.center.y - point.y)
                )
            } else {
                select(nil)
            }
        }
    }

    private func editTouchesMoved(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let drag = dragTouches[ObjectIdentifier(touch)] else { continue }
            let point = touch.location(in: self)

            let raw = CGPoint(x: point.x + drag.offset.x, y: point.y + drag.offset.y)
            let target = clamped(snapped(raw), size: drag.control.bounds.size)

            if target != drag.control.center {
                drag.control.center = target
                if snapEnabled { gridHaptic.selectionChanged() }
                updateSelectionRing()
            }
        }
    }

    private func editTouchesEnded(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let drag = dragTouches.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            updateItem(drag.control.id) { _ in }
        }
    }

    /// Writes the control's current centre (plus any change in `mutate`) into the layout and saves it.
    private func updateItem(_ id: GestureControlID, _ mutate: (inout GestureLayout.Item) -> Void) {
        guard let control = controls.first(where: { $0.id == id }),
              bounds.width > 0, bounds.height > 0 else { return }

        var item = layout.effective(id)
        item.x = control.center.x / bounds.width
        item.y = control.center.y / bounds.height
        mutate(&item)

        layout.items[id.rawValue] = item
        GestureLayoutStore.save(layout)
    }

    private func select(_ id: GestureControlID?) {
        selectedID = id
        updateSelectionRing()

        if let id {
            let item = layout.effective(id)
            onSelectionChange?(id.title, item.scale, item.opacity ?? 1)
        } else {
            onSelectionChange?(nil, nil, nil)
        }
    }

    private func updateSelectionRing() {
        guard isEditing else { return }

        guard let id = selectedID, let control = controls.first(where: { $0.id == id }) else {
            selectionRing.isHidden = true
            return
        }

        let frame = control.frame.insetBy(dx: -5, dy: -5)
        selectionRing.frame = frame
        selectionRing.layer.cornerRadius = control.isCircle ? frame.height / 2 : min(frame.height / 2, 24)
        selectionRing.isHidden = false
    }

    func setSelectedScale(_ value: CGFloat) {
        guard let id = selectedID else { return }
        let clampedScale = min(max(value, 0.5), 2.0)

        updateItem(id) { $0.scale = clampedScale }
        setNeedsLayout()
    }

    func setSelectedOpacity(_ value: CGFloat) {
        guard let id = selectedID else { return }
        let clampedOpacity = min(max(value, 0.1), 1.0)

        updateItem(id) { $0.opacity = clampedOpacity }
        setNeedsLayout()
    }

    func resetLayout() {
        GestureLayoutStore.reset()
        layout = GestureLayoutStore.load()

        if let id = selectedID {
            let item = layout.effective(id)
            onSelectionChange?(id.title, item.scale, item.opacity ?? 1)
        }

        setNeedsLayout()
    }
}

// MARK: - Entry points for DmGamepad.m

// DmGamepad.m declares these itself, as front_ios.m does for dm_show_launcher. The view is returned retained: the caller takes it with __bridge_transfer.
@_cdecl("dm_gesture_view_make")
public func dmGestureViewMake() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(GestureControllerUIView(editing: false)).toOpaque()
}

@_cdecl("dm_gesture_view_release_inputs")
public func dmGestureViewReleaseInputs(_ view: UnsafeMutableRawPointer) {
    Unmanaged<GestureControllerUIView>.fromOpaque(view).takeUnretainedValue().releaseAll()
}

@_cdecl("dm_gesture_view_set_passthrough")
public func dmGestureViewSetPassthrough(_ view: UnsafeMutableRawPointer, _ rect: CGRect) {
    Unmanaged<GestureControllerUIView>.fromOpaque(view).takeUnretainedValue().passthrough = rect
}
