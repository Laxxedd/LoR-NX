// Layout editor for Touchscreen Mode's keys (TouchscreenLayout.swift), opened from the launcher's Controls section (Launcher.swift) as the swipe gamepad's is (GestureLayoutEditor.swift).
// Drag a key to move it, tap it to change its size and opacity; changes are saved as they are made. The keys are drawn here as DmGamepad.m draws them in the game: outlined, squircle (Space: a thin bar).
import SwiftUI
import UIKit

// MARK: - Editor <-> view bridge

final class TouchscreenLayoutEditorModel: ObservableObject {
    static let snapDefaultsKey = "TouchscreenEditorSnapToGrid"

    @Published var selectedTitle: String?
    @Published var selectedIsBar = false
    @Published var scale: Double = 1.0
    @Published var opacity: Double = 1.0
    @Published var snapEnabled: Bool = (UserDefaults.standard.object(forKey: TouchscreenLayoutEditorModel.snapDefaultsKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(snapEnabled, forKey: Self.snapDefaultsKey)
            view?.snapEnabled = snapEnabled
        }
    }

    weak var view: TouchscreenLayoutUIView?

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

// MARK: - SwiftUI

struct TouchscreenLayoutView: UIViewRepresentable {
    let editorModel: TouchscreenLayoutEditorModel

    func makeUIView(context: Context) -> TouchscreenLayoutUIView {
        let view = TouchscreenLayoutUIView()
        let model = editorModel

        model.view = view
        view.snapEnabled = model.snapEnabled
        view.onSelectionChange = { [weak model] key, scale, opacity in
            DispatchQueue.main.async {
                model?.selectedTitle = key?.title
                model?.selectedIsBar = key?.isBar ?? false
                if let scale { model?.scale = Double(scale) }
                if let opacity { model?.opacity = Double(opacity) }
            }
        }

        return view
    }

    func updateUIView(_ uiView: TouchscreenLayoutUIView, context: Context) {}
}

struct TouchscreenLayoutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = TouchscreenLayoutEditorModel()

    @State private var panelAtTop = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TouchscreenLayoutView(editorModel: model)
                .ignoresSafeArea()

            VStack {
                if !panelAtTop { Spacer(minLength: 0) }
                panel
                if panelAtTop { Spacer(minLength: 0) }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .statusBarHidden(true)
        .defersSystemGestures(on: .all)
    }

    private var panel: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Reset") {
                    model.reset()
                }
                .foregroundColor(.red)

                Spacer()

                VStack(spacing: 2) {
                    Text("Touchscreen Layout")
                        .font(.subheadline.weight(.semibold))
                    Text("Used by Touchscreen Mode")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .font(.body.weight(.semibold))
            }

            if let selected = model.selectedTitle {
                VStack(spacing: 2) {
                    Text(selected)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.yellow)

                    sliderRow(
                        model.selectedIsBar ? "Length" : "Size",
                        value: Binding(get: { model.scale }, set: { model.setScale($0) }),
                        range: 0.5...2.0,
                        readout: String(format: "%.2f×", model.scale)
                    )

                    sliderRow(
                        "Opacity",
                        value: Binding(get: { model.opacity }, set: { model.setOpacity($0) }),
                        range: 0.1...1.0,
                        readout: "\(Int((model.opacity * 100).rounded()))%"
                    )
                }
            } else {
                Text("Drag a key to move it. Tap one to change its size and opacity.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Toggle("Snap to grid", isOn: $model.snapEnabled)
                    .font(.footnote)
                    .toggleStyle(.switch)
                    .fixedSize()

                Spacer()

                Button {
                    panelAtTop.toggle()
                } label: {
                    Image(systemName: panelAtTop ? "arrow.down.to.line" : "arrow.up.to.line")
                }
                .accessibilityLabel("Move panel")
            }
        }
        .padding(12)
        .frame(maxWidth: 360)
        .background(Color(white: 0.12, opacity: 0.94))
        .cornerRadius(14)
        .foregroundColor(.white)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, readout: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.footnote)
                .frame(width: 52, alignment: .leading)

            Slider(value: value, in: range)

            Text(readout)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

// MARK: - UIKit view

/// The five keys on a full-screen grid. Sizes follow DmGamepad.m's unit (1 = 430 points of height, at most 1.3), so a key here is the key in the game.
final class TouchscreenLayoutUIView: UIView {

    /// One key as the game draws it: the gamepad's outline look (a 1 point border, almost no fill), a squircle or, for Space, a bar.
    private final class KeyView: UIView {
        let key: TouchKey
        private let label = UILabel()

        init(key: TouchKey) {
            self.key = key
            super.init(frame: .zero)

            isUserInteractionEnabled = false
            backgroundColor = UIColor.white.withAlphaComponent(0.04)
            layer.borderWidth = 1
            layer.borderColor = UIColor.white.withAlphaComponent(0.42).cgColor
            layer.masksToBounds = true

            label.text = key.label
            label.textColor = UIColor.white.withAlphaComponent(0.55)
            label.textAlignment = .center
            label.isHidden = key.label == nil
            addSubview(label)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// The squircle's corner radius is the game's (8 units); the bar's ends are round.
        var unit: CGFloat = 1 { didSet { setNeedsLayout() } }

        override func layoutSubviews() {
            super.layoutSubviews()
            layer.cornerRadius = key.isBar ? bounds.height / 2 : 6 * unit
            label.frame = bounds
            label.font = UIFont(name: "Menlo-Regular", size: max(9, min(bounds.height * 0.34, 15))) ?? .monospacedSystemFont(ofSize: max(9, min(bounds.height * 0.34, 15)), weight: .regular)   // as DmGamepad.m's keys
        }
    }

    var onSelectionChange: ((TouchKey?, CGFloat?, CGFloat?) -> Void)?
    var snapEnabled = true

    private var layout = TouchscreenLayoutStore.load()
    private let keys = TouchKey.allCases.map { KeyView(key: $0) }
    private var selected: TouchKey?
    private var drags: [ObjectIdentifier: (key: KeyView, offset: CGPoint)] = [:]
    private let gridView = GestureGridView()
    private let selectionRing = UIView()
    private let gridHaptic = UISelectionFeedbackGenerator()

    /// DmGamepad.m's unit.
    private var unit: CGFloat { min(bounds.height / 430, 1.3) }

    /// The grid has the same cells as the swipe layout's editor: 48 along the short side.
    private var gridCell: CGFloat { max(min(bounds.width, bounds.height) / 48, 6) }

    init() {
        super.init(frame: .zero)

        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isExclusiveTouch = false

        addSubview(gridView)
        keys.forEach(addSubview)

        selectionRing.isUserInteractionEnabled = false
        selectionRing.layer.borderColor = UIColor.systemYellow.cgColor
        selectionRing.layer.borderWidth = 2
        selectionRing.isHidden = true
        addSubview(selectionRing)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }

        gridView.frame = bounds
        gridView.cell = gridCell

        for view in keys {
            // Do not fight an in-progress drag
            if drags.values.contains(where: { $0.key === view }) { continue }

            let item = layout.effective(view.key)
            view.alpha = min(max(item.opacity, 0.1), 1)
            view.unit = unit
            view.frame = layout.frame(of: view.key, in: bounds.size, unit: unit)
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

    // MARK: Touches

    /// The key whose hit area (the thin Space bar is hit over a taller strip) holds the point, the nearest centre if several do.
    private func keyAt(_ point: CGPoint) -> KeyView? {
        var best: (view: KeyView, distance: CGFloat)?

        for view in keys where TouchKey.hitRect(of: view.frame).contains(point) {
            let distance = hypot(point.x - view.center.x, point.y - view.center.y)
            if best == nil || distance < best!.distance { best = (view, distance) }
        }

        return best?.view
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        gridHaptic.prepare()

        for touch in touches {
            let point = touch.location(in: self)

            if let view = keyAt(point) {
                select(view.key)
                drags[ObjectIdentifier(touch)] = (view, CGPoint(x: view.center.x - point.x, y: view.center.y - point.y))
            } else {
                select(nil)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let drag = drags[ObjectIdentifier(touch)] else { continue }
            let point = touch.location(in: self)

            let raw = CGPoint(x: point.x + drag.offset.x, y: point.y + drag.offset.y)
            let target = clamped(snapped(raw), size: drag.key.bounds.size)

            if target != drag.key.center {
                drag.key.center = target
                if snapEnabled { gridHaptic.selectionChanged() }
                updateSelectionRing()
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let drag = drags.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            updateItem(drag.key.key) { _ in }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    // MARK: Layout editing

    /// Writes the key's current centre (plus any change in `mutate`) into the layout and saves it.
    private func updateItem(_ key: TouchKey, _ mutate: (inout TouchscreenLayout.Item) -> Void) {
        guard let view = keys.first(where: { $0.key == key }), bounds.width > 0, bounds.height > 0 else { return }

        var item = layout.effective(key)
        item.x = view.center.x / bounds.width
        item.y = view.center.y / bounds.height
        mutate(&item)

        layout.items[key.rawValue] = item
        TouchscreenLayoutStore.save(layout)
    }

    private func select(_ key: TouchKey?) {
        selected = key
        updateSelectionRing()

        if let key {
            let item = layout.effective(key)
            onSelectionChange?(key, item.scale, item.opacity)
        } else {
            onSelectionChange?(nil, nil, nil)
        }
    }

    private func updateSelectionRing() {
        guard let key = selected, let view = keys.first(where: { $0.key == key }) else {
            selectionRing.isHidden = true
            return
        }

        let frame = TouchKey.hitRect(of: view.frame).insetBy(dx: -5, dy: -5)
        selectionRing.frame = frame
        selectionRing.layer.cornerRadius = key.isBar ? frame.height / 2 : min(6 * unit + 5, frame.height / 2)
        selectionRing.isHidden = false
    }

    func setSelectedScale(_ value: CGFloat) {
        guard let key = selected else { return }
        let clampedScale = min(max(value, 0.5), 2.0)

        updateItem(key) { $0.scale = clampedScale }
        setNeedsLayout()
    }

    func setSelectedOpacity(_ value: CGFloat) {
        guard let key = selected else { return }
        let clampedOpacity = min(max(value, 0.1), 1.0)

        updateItem(key) { $0.opacity = clampedOpacity }
        setNeedsLayout()
    }

    func resetLayout() {
        TouchscreenLayoutStore.reset()
        layout = TouchscreenLayoutStore.load()

        if let key = selected {
            let item = layout.effective(key)
            onSelectionChange?(key, item.scale, item.opacity)
        }

        setNeedsLayout()
    }
}
