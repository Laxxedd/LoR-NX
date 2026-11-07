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
/// The folder picker is presented with UIKit from the top view controller, not as a SwiftUI .sheet on a row of the list: a sheet on a List row is dismissed by SwiftUI
/// whenever the list is rebuilt (the launcher re-renders every few seconds), which closed the picker about a second after it opened.
private struct CloudSavesSection: View {
    @State private var folder: String = ""
    @State private var note: String = ""

    var body: some View {
        Section {
            HStack {
                Text("Cloud saves")
                Spacer()
                Text(folder.isEmpty ? "Off" : (folder as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button(folder.isEmpty ? "Choose a folder in iCloud Drive…" : "Choose a different folder…") { pickFolder() }
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
        .onAppear(perform: refresh)
    }

    private func refresh() {
        var stale: ObjCBool = false
        folder = dm_cloud_saves_path(&stale) ?? ""
        if stale.boolValue && folder.isEmpty {
            note = "The folder you chose before is no longer readable (the app was signed differently). Please choose it again."
        }
    }

    private func pickFolder() {
        guard !FolderPicker.isShowing else { return }
        guard let top = FolderPicker.topViewController() else {
            note = "The folder picker could not be opened."
            fputs("launcher: cloud saves: no view controller to present the folder picker from\n", stderr)
            return
        }
        FolderPicker.present(from: top) { url in
            guard let url else { return }   // cancelled
            if dm_store_cloud_saves(url) {
                note = "Saved. The game uses this folder when you press Play."
                refresh()
            } else {
                note = "That folder could not be remembered — try a different one."
            }
        }
    }
}

/// UIDocumentPickerViewController for a folder, presented from UIKit. `done` gets the folder, or nil when the picker was cancelled; always on the main thread, once.
private enum FolderPicker {
    private static weak var current: UIDocumentPickerViewController?
    /// True while the picker is on screen (a picker the system took away without a callback does not count, so the button never stays dead).
    static var isShowing: Bool { current?.presentingViewController != nil }

    static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    static func present(from top: UIViewController, done: @escaping (URL?) -> Void) {
        // .open (not .import): the folder stays where it is and the bookmark keeps pointing at it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        let delegate = Delegate(done: done)
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)   // the picker's delegate is weak: the picker keeps it alive
        current = picker
        fputs("launcher: cloud saves: folder picker opening\n", stderr)
        top.present(picker, animated: true)
    }

    private static var delegateKey: UInt8 = 0

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let done: (URL?) -> Void
        init(done: @escaping (URL?) -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            fputs("launcher: cloud saves: folder picked (\(urls.count))\n", stderr)
            done(urls.first)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            fputs("launcher: cloud saves: folder picker cancelled\n", stderr)
            done(nil)
        }
    }
}

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var memory = os_proc_available_memory()
    private var audio: LauncherAudio { .shared }   // the launcher's music and the Play sound (LauncherAudio.swift); shared, so it plays on after the launcher is gone
    @State private var starting = false          // Play was pressed (a second tap does nothing)
    @Environment(\.scenePhase) private var scenePhase
    private let increasedLimit = dm_has_increased_memory_entitlement()   // fixed for the life of the process
    private let donorEmbedded = dm_ram_donor_embedded()
    private static let memorySection = "Memory"
    private enum LayoutEditor: String, Identifiable {   // the layout editor on screen: the swipe gamepad's or Touchscreen Mode's keys
        case swipe, touchscreen
        var id: String { rawValue }
    }
    @State private var layoutEditor: LayoutEditor?
    @State private var modPage: [String] = []   // the pages pushed on the list: the mods page (modsPage) and a mod's settings page (its env): the navigation stack's path
    private static let modsPage = "mods"   // not a DM_ name, so never a mod's env

    // Opens the layout editor of the Swipe touch layout (GestureLayoutEditor.swift).
    // Touchscreen Mode hides the swipe gamepad, so the button is not drawn while it is on
    private var swipeEditorButton: some View {
        Button { layoutEditor = .swipe } label: {
            HStack {
                Label("Edit swipe controls layout", systemImage: "formfitting.gamecontroller")
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }

    // Opens the layout editor of Touchscreen Mode's keys (TouchscreenLayoutEditor.swift). The keys exist only in that mode, so the button is not drawn while it is off
    private var touchscreenEditorButton: some View {
        Button { layoutEditor = .touchscreen } label: {
            HStack {
                Label("Edit touchscreen layout", systemImage: "keyboard")
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var layoutEditorButtons: some View {
        if m.values["DM_TOUCHSCREEN"] == "1" { touchscreenEditorButton } else { swipeEditorButton }
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
                                        if section == "Controls" { layoutEditorButtons }
                                    }
                                }
                            }
                        }
                        if m.rows(in: "Controls").isEmpty {   // a game with no controls settings still gets the editor
                            Section("Controls") { layoutEditorButtons }
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
        .fullScreenCover(item: $layoutEditor) { editor in
            switch editor {
            case .swipe: GestureLayoutEditorView(dedicatedB: m.values["DM_DEDICATED_B"] == "1")
            case .touchscreen: TouchscreenLayoutEditorView()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { audio.startMusic() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { audio.resumeMusic() } else { audio.pauseMusic() }
        }
        .task {
            while !Task.isCancelled {
                if !FolderPicker.isShowing { memory = os_proc_available_memory() }   // no re-render of the launcher under the folder picker
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder var playButton: some View {
        let button = Button(action: pressPlay) { Text("Play").font(.title3.weight(.semibold)).frame(maxWidth: 220) }.controlSize(.large).disabled(starting)
        if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
    }

    // Play: the dice sound starts and the music fades out after it, while the game starts at once (the audio does not hold it up)
    private func pressPlay() {
        guard !starting else { return }
        starting = true
        audio.rollThenFadeOut()
        play()
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
