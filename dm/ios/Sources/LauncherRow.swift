// One launcher setting as a row (a menu, a slider with its percentage, a toggle), shared by the iOS launcher (Launcher.swift) and the Mac app's settings window (dm/mac/Launcher.swift).
// A row whose setting is fixed by an env file or by the launch environment is shown but disabled.
import SwiftUI

extension LauncherModel {
    func binding(_ s: Setting) -> Binding<String> { Binding(get: { self.values[s.env] ?? s.def }, set: { self.values[s.env] = $0 }) }
}

struct SettingRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel

    private var locked: Bool { m.fixed.contains(s.env) }
    private var note: String {
        guard locked else { return s.note }
        return (s.note.isEmpty ? "" : s.note + " · ") + (m.fromLaunch.contains(s.env) ? "Set at launch" : "Set by an env file")
    }
    private var rangeValue: Binding<Double> {
        Binding(get: { Double(m.values[s.env] ?? s.def) ?? s.max ?? 1 },
                set: { m.values[s.env] = String(format: "%.2f", $0) })
    }
    private var percentage: String { m.rangeLabel(s, rangeValue.wrappedValue) }

    private var settingLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.label)
            if !note.isEmpty { Text(LocalizedStringKey(note)).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    var body: some View {
        Group {
            switch s.kind {
            case "choice":
                Picker(selection: m.binding(s)) {
                    ForEach(s.options ?? [], id: \.[0]) { Text($0[1]).tag($0[0]) }
                } label: {
                    settingLabel
                }
                .pickerStyle(.menu)
            case "range":
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        settingLabel
                        Spacer()
                        Text(percentage).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: rangeValue, in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.05)
                        .accessibilityLabel(s.label)
                        .accessibilityValue(percentage)
                }
            default:
                Toggle(isOn: Binding(get: { (m.values[s.env] ?? s.def) == s.onValue }, set: { m.values[s.env] = $0 ? s.onValue : s.offValue })) {
                    settingLabel
                }
            }
        }
        .disabled(locked)
    }
}

#if os(iOS)   // the iPhone launcher only: the Mac window lists a mod's settings under it
// A mod with settings of its own, on the mods page: its switch, and a chevron that opens its settings page (ModSettingsPage). Tapping the switch only turns the mod on or off;
// tapping anywhere else on the row (the chevron included) opens the page. A tap gesture, not a Button: the mod's note holds a link to the original mod, which must still open.
// The chevron is drawn in the row's trailing inset, outside the layout, so the switch stays where the switches of the rows without settings are
struct ModEntryRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel
    let open: () -> Void

    private static let chevronWidth: CGFloat = 8, chevronGap: CGFloat = 6
    private var locked: Bool { m.fixed.contains(s.env) }
    private var note: String {
        guard locked else { return s.note }
        return (s.note.isEmpty ? "" : s.note + " · ") + (m.fromLaunch.contains(s.env) ? "Set at launch" : "Set by an env file")
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.label)
                if !note.isEmpty { Text(LocalizedStringKey(note)).font(.footnote).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            Toggle(s.label, isOn: Binding(get: { (m.values[s.env] ?? s.def) == s.onValue }, set: { m.values[s.env] = $0 ? s.onValue : s.offValue }))
                .labelsHidden()
                .disabled(locked)
        }
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                .frame(width: Self.chevronWidth, height: 44)
                .contentShape(Rectangle())
                .onTapGesture(perform: open)
                .offset(x: Self.chevronWidth + Self.chevronGap)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open settings", open)
    }
}

// The mods page, pushed from the Mods section's Browse mods button: every mod in its group (LauncherModel.modCategories), a group with no mods says so. A mod with settings of its own opens them
// through open (the launcher's navigation path), as it did from the list
struct ModsBrowserPage: View {
    @ObservedObject var m: LauncherModel
    let open: (String) -> Void

    var body: some View {
        List {
            ForEach(LauncherModel.modCategories, id: \.self) { category in
                let mods = m.mods(in: category)
                Section(category) {
                    if mods.isEmpty {
                        Text("No mods yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(mods) { s in
                            if m.modSettings(of: s).isEmpty { SettingRow(s: s, m: m) }
                            else { ModEntryRow(s: s, m: m) { open(s.env) } }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.horizontal, 12, for: .scrollContent)
        .navigationTitle("Mods")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// The page of one mod's settings, pushed from its row; the navigation bar's back button returns to the list. The settings can be changed while the mod is off (they apply once it is on)
struct ModSettingsPage: View {
    let mod: Setting
    @ObservedObject var m: LauncherModel

    private var on: Bool { (m.values[mod.env] ?? mod.def) == mod.onValue }

    var body: some View {
        List {
            Section {
                ForEach(m.modSettings(of: mod)) { SettingRow(s: $0, m: m) }
            } footer: {
                if !on { Text("\(mod.label) is off. These settings apply once you turn it on.") }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.horizontal, 12, for: .scrollContent)
        .navigationTitle(mod.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
