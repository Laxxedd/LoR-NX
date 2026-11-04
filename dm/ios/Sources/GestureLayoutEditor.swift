// Layout editor for the swipe touch gamepad (GesturePad.swift), opened from the launcher's Controls section (Launcher.swift).
// Drag a control to move it, tap it to change its size and opacity; changes are saved as they are made. The grid behind the controls is drawn
// by the editing view itself so it always lines up with the snapping.
import SwiftUI

struct GestureLayoutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = GestureLayoutEditorModel()
    /// The launcher's current "Dedicated B button" choice: the B control is placed only while it is on.
    let dedicatedB: Bool

    @State private var panelAtTop = true

    init(dedicatedB: Bool) {
        self.dedicatedB = dedicatedB
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GestureControllerView(editorModel: model, dedicatedB: dedicatedB)
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
                    Text("Swipe Controls Layout")
                        .font(.subheadline.weight(.semibold))
                    Text("Used by the Swipe layout")
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
                        "Size",
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
                Text("Drag a control to move it. Tap one to change its size and opacity.")
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
