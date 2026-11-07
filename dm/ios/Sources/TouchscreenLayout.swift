// The keys of Touchscreen Mode (DM_TOUCHSCREEN=1) and where they sit: Esc, Space, Shift, Ctrl and Alt. The layout is kept in UserDefaults and edited in the launcher
// (Controls > Edit touchscreen layout, TouchscreenLayoutEditor.swift), as the swipe gamepad's is (GesturePad.swift, GestureLayoutEditor.swift).
// DmGamepad.m draws and presses the keys; it asks for each key's frame and opacity here, so the game and the editor always agree.
//
//  Defaults:  Esc at the top left, Space a thin (4 point) wide bar at the bottom middle, Shift / Ctrl / Alt side by side at the bottom left.
//  Shapes:    Esc, Shift, Ctrl and Alt are squircle keys (the shape belongs to the keyboard and is not used by the gamepad), Space is the bar. All of them are outlined
//             like the gamepad's buttons: a 1 point border and almost no fill, the fill coming up while a finger is on the key.
import CoreGraphics
import Foundation

/// The keys, in the order DmGamepad.m numbers them (TS_SHIFT ... TS_SPACE): `index` is that number.
enum TouchKey: String, CaseIterable, Codable {
    case shift, ctrl, alt, esc, space

    var index: Int32 {
        switch self {
        case .shift: return 0
        case .ctrl: return 1
        case .alt: return 2
        case .esc: return 3
        case .space: return 4
        }
    }

    var title: String {
        switch self {
        case .shift: return "Shift"
        case .ctrl: return "Ctrl"
        case .alt: return "Alt"
        case .esc: return "Esc"
        case .space: return "Space"
        }
    }

    /// The label drawn on the key. Space is a bar too thin to carry one.
    var label: String? { self == .space ? nil : title }

    var isBar: Bool { self == .space }

    /// How thick the Space bar is, in points, whatever the screen and the key's size: it is a hairline by design.
    static let barThickness: CGFloat = 4
    /// Keys are at least this big to hit however small they are drawn (DmGamepad.m K_KB_HIT); the thin Space bar is hit over a taller strip.
    static let minimumHitSize: CGFloat = 44

    /// The key's size in points. `unit` is DmGamepad.m's u (1 = 430 points of screen height, at most 1.3), `scale` the player's size choice.
    /// A squircle key is 62 x 30 units; Space is 300 units wide and `barThickness` thick, and its size choice changes only its length.
    func size(unit: CGFloat, scale: CGFloat) -> CGSize {
        if isBar { return CGSize(width: 300 * unit * scale, height: Self.barThickness) }
        return CGSize(width: 62 * unit * scale, height: 30 * unit * scale)
    }

    /// The area that takes a touch for the key: its frame, grown to the minimum hit size.
    static func hitRect(of frame: CGRect) -> CGRect {
        frame.insetBy(dx: -max(minimumHitSize - frame.width, 0) / 2, dy: -max(minimumHitSize - frame.height, 0) / 2)
    }
}

/// The player's key placements. Positions are fractions of the screen (0...1) so they survive other screen sizes; a key that is missing falls back to the default layout.
struct TouchscreenLayout: Codable, Equatable {
    struct Item: Codable, Equatable {
        var x: CGFloat
        var y: CGFloat
        var scale: CGFloat
        var opacity: CGFloat
    }

    var items: [String: Item] = [:]

    /// The default layout, on the grid of the swipe layout's defaults (a row is n/24 of the height, a column n/51.91 of the width on the 2.16:1 phone it was made on).
    /// The three modifiers sit where they always did, bottom left; Esc is in the top left corner and Space low at the bottom middle, above the home indicator.
    static let defaults: [TouchKey: Item] = {
        let columns: CGFloat = 51.91
        func item(_ column: CGFloat, _ row: CGFloat, _ scale: CGFloat = 1) -> Item {
            Item(x: (column / columns * 10000).rounded() / 10000, y: (row / 24 * 10000).rounded() / 10000, scale: scale, opacity: 0.75)
        }
        return [
            .esc: item(5, 2.5),
            .shift: item(4.5, 21.5), .ctrl: item(8.5, 21.5), .alt: item(12.5, 21.5),
            .space: Item(x: 0.5, y: (23 / 24 * 10000).rounded() / 10000, scale: 1, opacity: 0.75)
        ]
    }()

    /// What the key looks like now: the player's own entry, else the default one.
    func effective(_ key: TouchKey) -> Item {
        items[key.rawValue] ?? Self.defaults[key] ?? Item(x: 0.5, y: 0.5, scale: 1, opacity: 1)
    }

    /// The key's frame on a screen of this size: centred on its position and kept on the screen.
    func frame(of key: TouchKey, in screen: CGSize, unit: CGFloat) -> CGRect {
        let item = effective(key)
        let size = key.size(unit: unit, scale: item.scale)
        let x = min(max(item.x * screen.width, size.width / 2), max(screen.width - size.width / 2, size.width / 2))
        let y = min(max(item.y * screen.height, size.height / 2), max(screen.height - size.height / 2, size.height / 2))
        return CGRect(x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height)
    }
}

/// Each game is its own app, so there is one layout per app.
enum TouchscreenLayoutStore {
    private static let key = "TouchscreenKeyLayout"

    static func load() -> TouchscreenLayout {
        guard let data = UserDefaults.standard.data(forKey: key),
              let layout = try? JSONDecoder().decode(TouchscreenLayout.self, from: data) else { return TouchscreenLayout() }
        return layout
    }

    static func save(_ layout: TouchscreenLayout) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Entry points for DmGamepad.m

// DmGamepad.m declares these itself (as it does the swipe layout's). The layout is read when the game's pad is laid out, which is once the launcher is gone, so a layout edited there is what the game uses.
private func touchKey(_ index: Int32) -> TouchKey? { TouchKey.allCases.first { $0.index == index } }

@_cdecl("dm_ts_key_frame")
public func dmTsKeyFrame(_ index: Int32, _ screen: CGSize, _ unit: Double) -> CGRect {
    guard let key = touchKey(index) else { return .zero }
    return TouchscreenLayoutStore.load().frame(of: key, in: screen, unit: CGFloat(unit))
}

@_cdecl("dm_ts_key_opacity")
public func dmTsKeyOpacity(_ index: Int32) -> Double {
    guard let key = touchKey(index) else { return 1 }
    return Double(min(max(TouchscreenLayoutStore.load().effective(key).opacity, 0.1), 1))
}
