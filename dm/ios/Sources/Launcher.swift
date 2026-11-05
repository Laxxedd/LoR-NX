// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json, which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. All settings share one screen, grouped by section (rows: LauncherRow.swift). Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults shows the defaults, and Play then forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once with the saved choices; DM_SAVED_CHOICES=0 ignores them (and keeps them)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }


/// Cloud saves: an iCloud Drive folder shared with the Mac app (chosen in its settings window's
/// Cloud saves too). The host brings the save in from there when the game starts and
/// sends it there after each save (dm/host/save_sync.h); the folder is a bookmark (CloudSaves.m).
private struct CloudSavesSection: View {
    @State private var folder: String = ""
    @State private var note: String = ""
    @State private var picking = false

    var body: some View {
        Section {
            HStack {
                Text("Cloud saves")
                Spacer()
                Text(folder.isEmpty ? "Off" : (folder as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button(folder.isEmpty ? "Choose a folder in iCloud Drive…" : "Choose a different folder…") { picking = true }
            if !folder.isEmpty {
                Button("Turn off cloud saves", role: .destructive) {
                    dm_clear_cloud_saves(); refresh(); note = ""
                }
            }
        } footer: {
            Text(note.isEmpty
                 ? "Choose a folder in iCloud Drive, and the same one in the Mac app's Cloud saves. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in save-backups."
                 : note)
        }
        .sheet(isPresented: $picking) {
            DocumentPicker(types: [.folder]) { url in
                picking = false
                if dm_store_cloud_saves(url) {
                    note = "Saved. The game uses this folder when you press Play."
                    refresh()
                } else {
                    note = "That folder could not be remembered — try a different one."
                }
            } onCancel: { picking = false }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        var stale: ObjCBool = false
        folder = dm_cloud_saves_path(&stale) ?? ""
        if stale.boolValue && folder.isEmpty {
            note = "The folder you chose before is no longer readable (the app was signed differently). Please choose it again."
        }
    }
}

/// UIDocumentPickerViewController for a folder, in the two callbacks a SwiftUI sheet wants.
private struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.folder]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .open (not .import): the folder stays where it is and the bookmark keeps pointing at it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var memory = os_proc_available_memory()
    private let increasedLimit = dm_has_increased_memory_entitlement()   // fixed for the life of the process
    private let donorEmbedded = dm_ram_donor_embedded()
    private static let memorySection = "Memory"
    @State private var editingSwipeLayout = false
    @State private var modPage: [String] = []   // the pages pushed on the list: the mods page (modsPage) and a mod's settings page (its env): the navigation stack's path
    private static let modsPage = "mods"   // not a DM_ name, so never a mod's env

    // Opens the layout editor of the Swipe touch layout (GestureLayoutEditor.swift). It is the only touch layout
    private var swipeEditorButton: some View {
        Button { editingSwipeLayout = true } label: {
            HStack {
                Label("Edit swipe controls layout", systemImage: "formfitting.gamecontroller")
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }

    // The Mods section is one button: the mods themselves, grouped by category, are on the page it opens (ModsBrowserPage)
    private var modsSection: some View {
        Section(LauncherModel.modsSection) {
            Button { modPage.append(Self.modsPage) } label: {
                HStack {
                    Text("Browse mods")
                    Spacer()
                    if m.modsOn > 0 { Text("\(m.modsOn) on").foregroundStyle(.secondary) }
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // The sections in the order shown: the list's own, with Memory right above Mods (last when the game has no mods). Memory always draws its two readouts, even when the list has no rows for it
    private var sectionOrder: [String] {
        var order = m.sections.filter { $0 != Self.memorySection }
        order.insert(Self.memorySection, at: order.firstIndex(of: LauncherModel.modsSection) ?? order.count)
        return order
    }

    private var memorySection: some View {
        Section {
            HStack {
                Text("Memory available")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Increased memory limit")
                    Text("com.apple.developer.kernel.increased-memory-limit").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Text(increasedLimit ? "Yes" : "No").fontWeight(.semibold).foregroundStyle(increasedLimit ? Color.green : Color.red)
            }
            ForEach(m.topRows(in: Self.memorySection)) { s in SettingRow(s: s, m: m) }
        } header: {
            Text(Self.memorySection)
        } footer: {
            if !donorEmbedded { Text("This build has no LoRRamDonor extension, so Extend Memory Usage has no effect.") }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 16) {
                    if let thumbnail = launcherThumbnail() {   // the game's own picture (dm/ios/Resources/LauncherThumbnail.png), shown whole
                        Image(uiImage: thumbnail).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 150)
                            .accessibilityHidden(true)
                    } else if let icon = appIcon() {
                        Image(uiImage: icon).resizable().frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .accessibilityHidden(true)
                    }
                    Text((info("CFBundleDisplayName") as? String) ?? "Game")
                        .font(.title.weight(.bold)).multilineTextAlignment(.center)
                    Text("Version \((info("CFBundleShortVersionString") as? String) ?? "")")
                        .font(.callout).foregroundStyle(.secondary)
                    playButton
                }
                .padding(16)
                .frame(width: geometry.size.width / 3, height: geometry.size.height)
                NavigationStack(path: $modPage) {
                    List {
                        ForEach(sectionOrder, id: \.self) { section in
                            if section == Self.memorySection {
                                memorySection
                            } else if section == LauncherModel.modsSection {
                                if !m.topRows(in: section).isEmpty { modsSection }
                            } else {
                                let rows = m.topRows(in: section)
                                if !rows.isEmpty {
                                    Section(section) {
                                        ForEach(rows) { s in SettingRow(s: s, m: m) }
                                        if section == "Controls" { swipeEditorButton }
                                    }
                                }
                            }
                        }
                        if m.rows(in: "Controls").isEmpty {   // a game with no controls settings still gets the editor
                            Section("Controls") { swipeEditorButton }
                        }
                        Section {
                            Button("Reset to tested defaults") { m.reset() }
                                .disabled(!m.changed)
                        } footer: {
                            Text("Brings back all settings this game was tested with.")
                        }
                        CloudSavesSection()
                    }
                    .listStyle(.insetGrouped)
                    .contentMargins(.horizontal, 12, for: .scrollContent)
                    .navigationTitle("Settings")   // the back button of a mod's page reads this; the list itself has no navigation bar
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: String.self) { env in
                        if env == Self.modsPage { ModsBrowserPage(m: m) { modPage.append($0) } }
                        else if let mod = m.settings.first(where: { $0.env == env }) { ModSettingsPage(mod: mod, m: m) }
                    }
                }
                .frame(width: geometry.size.width * 2 / 3)
            }
        }
        .fullScreenCover(isPresented: $editingSwipeLayout) { GestureLayoutEditorView(dedicatedB: m.values["DM_DEDICATED_B"] == "1") }
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder var playButton: some View {
        let button = Button(action: play) { Text("Play").font(.title3.weight(.semibold)).frame(maxWidth: 220) }.controlSize(.large)
        if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
    }

    private func launcherThumbnail() -> UIImage? {
        guard let path = Bundle.main.path(forResource: "LauncherThumbnail", ofType: "png") else { return nil }
        return UIImage(contentsOfFile: path)
    }

    private func appIcon() -> UIImage? {
        if let i = UIImage(named: "AppIcon") { return i }
        guard let icons = info("CFBundleIcons") as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); LauncherModel(file.settings).applySaved(); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let model = LauncherModel(file.settings)
    var host: UIViewController?
    let view = LauncherView(m: model) {
        guard let h = host else { return }
        host = nil
        model.apply()
        h.dismiss(animated: false) { done() }
    }
    let h = UIHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
