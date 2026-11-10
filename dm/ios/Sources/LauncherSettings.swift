// Launcher settings, validation and persistence. Shared by the iOS UI, the Mac app's settings window (dm/mac/Launcher.swift) and the native storage regression test.
import Foundation
import Combine

struct Setting: Decodable, Identifiable {
    let env, kind, label, note, def: String
    let section: String?   // heading on the settings screen; absent in older bundles
    let category: String?  // a mod's group on the iPhone's mods page (LauncherModel.modCategories); absent: Miscellaneous
    let needs: String?     // "<VAR>=<value>": a sub-setting, drawn only while that setting has that value
    let unless: String?    // "<VAR>=<value>": not drawn while that setting has that value
    let style: String?     // "segmented": a choice drawn as a segmented control instead of a menu (Pointer Mode)
    let forced: String?    // "<VAR>=<value>" (a mod's switch): the switch follows that setting, on while it has that value and off otherwise, and is not offered on the mods page (touch-ui follows Touchscreen Mode)
    let optionNotes: [String: String]?   // choice: the line under the label for each chosen value (Pointer Mode); a value without one shows note
    let level: String?     // "basic": shown first (the Mac window's Basic settings); any other or none: Advanced settings. The iPhone keeps one list
    let base: Base?        // render scale: the 3D views' size at 1.0, docked and handheld, for the size in pixels (the Mac window)
    struct Base: Decodable { let docked, handheld: [Int] }
    let options: [[String]]?   // choice: [value, label]
    let min, max, step: Double?   // range
    let on, off: String?   // toggle: the values the variable takes (1 / 0 when not given)
    let format: String?    // range: "multiplier" shows the value as x1.25 instead of a percentage
    var id: String { env }
    func noteText(_ v: String) -> String { optionNotes?[v] ?? note }   // the line under the label while v is chosen
    var sectionTitle: String { section ?? "Game" }
    var basic: Bool { level == "basic" }
    var onValue: String { on ?? "1" }
    var offValue: String { off ?? "0" }
    func isDefault(_ v: String) -> Bool {   // a range compares as numbers (a slider writes 1.00 for 1.0)
        kind == "range" ? abs((Double(v) ?? .nan) - (Double(def) ?? .nan)) < 1e-6 : v == def
    }
    func accepts(_ v: String) -> Bool {   // a saved choice the game still offers
        switch kind {
        case "choice": return options?.contains { $0[0] == v } ?? false
        case "range":
            guard !v.contains(where: { $0 == "x" || $0 == "X" }), let n = Double(v), n.isFinite, let lo = min, let hi = max else { return false }   // no hex: launcher.c's check agrees
            return n >= lo && n <= hi
        case "toggle": return v == onValue || v == offValue
        default: return true
        }
    }
    enum CodingKeys: String, CodingKey { case env, kind, label, note, def = "default", section, category, needs, unless, style, forced, optionNotes = "option_notes", level, base, options, min, max, step, on, off, format }
}
struct SettingsFile: Decodable { let settings: [Setting] }

final class LauncherModel: ObservableObject {
    let settings: [Setting]
    let fixed: Set<String>      // set by an env file or by the launch environment: shown, not changed
    let fromLaunch: Set<String>   // of those, the ones the launch environment set (a front end's launch overrides, Xcode; DM_ENV_LAUNCH_KEYS from launcher.c or main.m)
    let ignoreSaved: Bool   // DM_SAVED_CHOICES=0: start from the defaults, and leave the saved choices as they are
    @Published var values: [String: String] = [:] { didSet { enforce() } }   // a switch that follows a setting (Setting.forced) changes with that setting at once, whichever row changed

    private let defaults: UserDefaults

    init(_ settings: [Setting], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = settings
        let env = ProcessInfo.processInfo.environment
        fromLaunch = Set((env["DM_ENV_LAUNCH_KEYS"] ?? "").split(separator: " ").map(String.init))
        fixed = fromLaunch.union((env["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
        ignoreSaved = env["DM_SAVED_CHOICES"] == "0"
        if ignoreSaved { fputs("launcher: saved choices ignored (DM_SAVED_CHOICES=0)\n", stderr) }
        for s in settings {
            if fixed.contains(s.env), let v = env[s.env] { values[s.env] = v; continue }
            let saved = ignoreSaved ? nil : defaults.object(forKey: "launcher." + s.env) as? String   // a string, as launcher.c reads it: not string(forKey:), which turns a number into one
            values[s.env] = saved.flatMap { s.accepts($0) ? $0 : nil } ?? s.def   // a saved choice the game no longer offers: its default
        }
        enforce()   // the observer does not run inside init
    }

    var sections: [String] {
        settings.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    // A row with "needs" is a sub-setting of the row it names: drawn only while that setting has that value, so a
    // setting that cannot do anything is not offered (an upscaler's detail with the upscaler off, rumble strength
    // with rumble off). A row naming a setting this game does not have stays drawn, as it has nothing to hide behind
    // A row with "unless" is hidden while the setting it names has that value (the controller options while Touchscreen Mode is on)
    func visible(_ s: Setting) -> Bool {
        if isManaged(s) { return false }   // a switch that follows a setting is not the player's to flip: it is not on the mods page
        if let u = s.unless, holds(u) { return false }
        guard let n = s.needs, let eq = n.firstIndex(of: "=") else { return true }
        let key = String(n[n.startIndex..<eq]), want = String(n[n.index(after: eq)...])
        guard let v = values[key] else { return true }
        return v == want
    }
    func greyedOut(_ s: Setting) -> Bool { isForced(s) }
    // A row with "forced" follows the setting it names (the touch-ui mod follows Touchscreen Mode): it is switched on while that setting has that value and off as soon as it does not, and it is not drawn,
    // so the mods page never offers it. A row naming a setting this game does not have is not managed: it is drawn and the player's own switch.
    // A switch an env file or the launch environment sets is left as it is (and drawn, greyed out, as any fixed row)
    func isManaged(_ s: Setting) -> Bool {
        guard let n = s.forced, !fixed.contains(s.env), let eq = n.firstIndex(of: "=") else { return false }
        let key = String(n[n.startIndex..<eq])
        return settings.contains { $0.env == key }
    }
    func isForced(_ s: Setting) -> Bool { guard let n = s.forced else { return false }; return holds(n) }
    func forcedBy(_ s: Setting) -> String? {   // the label of the setting that forces the row now, for its note
        guard isForced(s), let n = s.forced, let eq = n.firstIndex(of: "=") else { return nil }
        let key = String(n[n.startIndex..<eq])
        return settings.first { $0.env == key }?.label
    }
    private func holds(_ n: String) -> Bool {
        guard let eq = n.firstIndex(of: "=") else { return false }
        return values[String(n[n.startIndex..<eq])] == String(n[n.index(after: eq)...])
    }
    private func enforce() {
        for s in settings where isManaged(s) {
            let want = isForced(s) ? s.onValue : s.offValue
            if values[s.env] != want { values[s.env] = want }
        }
    }
    func rows(in section: String) -> [Setting] { settings.filter { $0.sectionTitle == section && visible($0) } }

    // Mods with their own settings: a row of the Mods section that names another Mods row in "needs" (scripts/apply_mods.py: a mod's settings need its switch) is a setting of that mod.
    // The iPhone launcher keeps those on a page of their own, opened from the mod's row (LauncherView); the Mac window still lists them under the mod
    static let modsSection = "Mods"
    func modEnv(of s: Setting) -> String? {
        guard s.sectionTitle == Self.modsSection, let n = s.needs, let eq = n.firstIndex(of: "=") else { return nil }
        let key = String(n[n.startIndex..<eq])
        return settings.contains { $0.env == key && $0.sectionTitle == Self.modsSection } ? key : nil
    }
    static let modCategories = ["Performance", "Quality of Life", "Fixes", "Content", "Miscellaneous", "Cheats"]
    func mods(in category: String) -> [Setting] {   // the mods (not their settings) of one group of the mods page, in the list's order; a mod with no or an unknown category is Miscellaneous
        topRows(in: Self.modsSection).filter { s in
            let c = s.category.flatMap { Self.modCategories.contains($0) ? $0 : nil } ?? "Miscellaneous"
            return c == category
        }
    }
    var modsOn: Int { topRows(in: Self.modsSection).filter { (values[$0.env] ?? $0.def) == $0.onValue }.count }
    func modSettings(of mod: Setting) -> [Setting] { settings.filter { modEnv(of: $0) == mod.env } }   // all of them, shown or not
    func topRows(in section: String) -> [Setting] { rows(in: section).filter { modEnv(of: $0) == nil } }   // the list's rows without a mod's own settings
    // The Mac window: Basic settings first, then Advanced settings, each in the list's sections and order
    func sections(basic: Bool) -> [String] {
        settings.filter { $0.basic == basic }.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    func rows(in section: String, basic: Bool) -> [Setting] { rows(in: section).filter { $0.basic == basic } }
    // A range's label: its percentage, with the size in pixels for the chosen console mode when the list has the base size (the render scale)
    func rangeLabel(_ s: Setting, _ v: Double) -> String {
        if s.format == "multiplier" { return String(format: "x%.2f", v) }
        let p = "\(Int((v * 100).rounded())) %"
        guard let b = s.base else { return p }
        let size = (values["DM_OPMODE"] ?? "1") == "0" ? b.handheld : b.docked
        guard size.count == 2 else { return p }
        return "\(Int((Double(size[0]) * v).rounded())) × \(Int((Double(size[1]) * v).rounded())) (\(p))"
    }
    var changed: Bool { settings.contains { !fixed.contains($0.env) && !$0.isDefault(values[$0.env] ?? $0.def) } }

    // Reset every launcher choice to the game's defaults on the screen; values fixed by an env file or at launch stay. The saved choices are forgotten when Play applies
    // the defaults (apply() keeps no default), so Quit after Reset keeps them, and a choice a launch override hides is kept
    func reset() {
        var v = values
        for s in settings where !fixed.contains(s.env) { v[s.env] = s.def }
        values = v   // one change, so a forced switch sees the final state of the setting that forces it
        fputs("launcher: settings reset to the game's defaults\n", stderr)
    }

    // Before the game starts: every setting not set by an env file goes into the environment (DM_LANG replaces the packed language main.m set as a default). Only a choice that
    // differs from the game's default is stored: a setting the player left at its default follows the defaults of a later build (the settings it was tested with)
    func apply() {
        for s in settings {
            let v = values[s.env] ?? s.def
            if fixed.contains(s.env) { fputs("launcher: \(s.env) kept at \(v) (\(fromLaunch.contains(s.env) ? "launch environment" : "env file"))\n", stderr); continue }
            if !ignoreSaved { if s.isDefault(v) { defaults.removeObject(forKey: "launcher." + s.env) } else { defaults.set(v, forKey: "launcher." + s.env) } }
            setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v)\(s.isDefault(v) ? "" : " (changed)")\n", stderr)
        }
    }

    // DM_LAUNCHER=0: no screen, but the saved choices still apply (only DM_SAVED_CHOICES=0 ignores them); nothing is written
    func applySaved() {
        for s in settings where !fixed.contains(s.env) {
            let v = values[s.env] ?? s.def
            if !s.isDefault(v) { setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v) (saved choice)\n", stderr) }
        }
    }
}
