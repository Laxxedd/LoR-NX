// The launcher's storage (LauncherSettings.swift LauncherModel), run by test_launcher_storage.py on macOS: only choices that differ from the game's default are
// stored, Reset to tested defaults followed by Play forgets the choices, an env file's values are kept. Arguments: the iOS and the Mac launcher.json of Breath of the Wild (settings.py, GFXAPI=nvn)
import Foundation
@main struct Check {
    static func main() {
        var failed = 0
        func expect(_ c: Bool, _ what: String) { print((c ? "PASS " : "FAIL ") + what); if !c { failed += 1 } }
        let file = try! JSONDecoder().decode(SettingsFile.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let suite = "nxnative.launcher-test." + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        d.set("1", forKey: "launcher.DM_PRESENT_SNAP")   // stored by the old launcher, equal to the default
        d.set("30", forKey: "launcher.DM_FPS_TARGET")    // a changed game setting
        d.set("0", forKey: "launcher.DM_PSO_MTL4")       // a changed performance setting
        d.set("1", forKey: "launcher.DM_FPS_HOLD")       // a value the toggle does not take (on / off): the default
        setenv("DM_ENV_FILE_KEYS", "DM_METAL_HUD", 1); setenv("DM_METAL_HUD", "1", 1)   // set by Documents/env.txt
        let m = LauncherModel(file.settings, defaults: d)
        let scale = file.settings.first { $0.env == "DM_RENDER_SCALE" }!
        expect(["nan", "inf", "-inf", "0.49", "1.01", "invalid", "0x1p-1", "0X1", " 0.75"].allSatisfy { !scale.accepts($0) } && scale.accepts("0.5") && scale.accepts("1.00"), "saved ranges reject nonfinite, out-of-range, hex and padded values, as launcher.c does")
        d.set("nan", forKey: "launcher.DM_RENDER_SCALE")
        expect(LauncherModel(file.settings, defaults: d).values["DM_RENDER_SCALE"] == scale.def, "an invalid saved range loads the default")
        expect(m.values["DM_FPS_TARGET"] == "30" && m.values["DM_PSO_MTL4"] == "0" && m.values["DM_FPS_HOLD"] == "on" && m.values["DM_METAL_HUD"] == "1", "stored choices and the env file are read")
        expect(m.changed, "Reset is offered with changed settings")
        m.values["DM_RENDER_SCALE"] = "1.00"   // the slider's format of the default
        m.apply()
        expect(d.string(forKey: "launcher.DM_PRESENT_SNAP") == nil, "a value equal to the default is not stored (and an old one is dropped)")
        expect(d.string(forKey: "launcher.DM_RENDER_SCALE") == nil && d.string(forKey: "launcher.DM_OPMODE") == nil && d.string(forKey: "launcher.DM_FPS_HOLD") == nil, "defaults are not stored")
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == "30" && d.string(forKey: "launcher.DM_PSO_MTL4") == "0", "changed choices are stored")
        expect(d.string(forKey: "launcher.DM_METAL_HUD") == nil && String(cString: getenv("DM_METAL_HUD")) == "1", "the env file's value is kept and not stored")
        expect(String(cString: getenv("DM_PSO_MTL4")) == "0" && String(cString: getenv("DM_PRESENT_SNAP")) == "1" && String(cString: getenv("DM_FPS_HOLD")) == "on", "the environment gets every value")
        m.reset()
        expect(m.values["DM_PSO_MTL4"] == "1" && m.values["DM_FPS_TARGET"] == file.settings.first { $0.env == "DM_FPS_TARGET" }!.def, "Reset shows the defaults")
        expect(d.string(forKey: "launcher.DM_PSO_MTL4") == "0" && d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "Reset alone forgets nothing: Quit after it keeps the choices")
        expect(m.values["DM_METAL_HUD"] == "1" && !m.changed, "Reset leaves the env file's value; nothing left to reset")
        m.apply()
        expect(d.string(forKey: "launcher.DM_PSO_MTL4") == nil && d.string(forKey: "launcher.DM_FPS_TARGET") == nil, "Play after Reset forgets the choices")
        d.set(30, forKey: "launcher.DM_FPS_TARGET"); d.set(false, forKey: "launcher.DM_TOUCH_HAPTICS")   // a number and a boolean, as defaults write -int / -bool stores them
        let typed = LauncherModel(file.settings, defaults: d)
        expect(typed.values["DM_FPS_TARGET"] == file.settings.first { $0.env == "DM_FPS_TARGET" }!.def && typed.values["DM_TOUCH_HAPTICS"] == "1", "a saved value that is not a string is ignored, as launcher.c ignores it")
        d.removeObject(forKey: "launcher.DM_FPS_TARGET"); d.removeObject(forKey: "launcher.DM_TOUCH_HAPTICS")
        // Sub-settings: a row with "needs" is drawn only while the setting it names has that value
        m.values["DM_PSO_MTL4"] = "1"
        expect(m.rows(in: "Performance").contains { $0.env == "DM_PSO_PREBUILD" }, "a sub-setting is drawn while its setting is on")
        m.values["DM_PSO_MTL4"] = "0"
        expect(!m.rows(in: "Performance").contains { $0.env == "DM_PSO_PREBUILD" }, "a sub-setting is hidden while its setting is off")
        expect(m.rows(in: "Performance").contains { $0.env == "DM_PSO_MTL4" }, "the setting it depends on stays drawn")
        m.values["DM_PSO_MTL4"] = "1"
        expect(["DM_HOLD_PLUS", "DM_DEDICATED_B"].allSatisfy { e in m.rows(in: "Controls").contains { $0.env == e && $0.def == "0" } } && !m.rows(in: "Controls").contains { $0.env.hasPrefix("DM_RUMBLE") }, "Controls has the two touch toggles, off by default, and no rumble rows")
        // "unless": the touch gamepad's rows stay drawn but greyed out while Touchscreen Mode is on; Touch feedback and Touchscreen Mode themselves never grey out
        func row(_ env: String) -> Setting { file.settings.first { $0.env == env }! }
        m.values["DM_TOUCHSCREEN"] = "0"
        expect(["DM_HOLD_PLUS", "DM_DEDICATED_B"].allSatisfy { !m.greyedOut(row($0)) }, "the gamepad's rows are enabled while Touchscreen Mode is off")
        m.values["DM_TOUCHSCREEN"] = "1"
        expect(["DM_HOLD_PLUS", "DM_DEDICATED_B"].allSatisfy { e in m.greyedOut(row(e)) && m.rows(in: "Controls").contains { $0.env == e } }, "the gamepad's rows are greyed out, not hidden, while Touchscreen Mode is on")
        expect(!m.greyedOut(row("DM_TOUCH_HAPTICS")) && !m.greyedOut(row("DM_TOUCHSCREEN")), "Touch feedback and Touchscreen Mode stay enabled")
        expect(Array(m.rows(in: "Controls").map(\.env).prefix(2)) == ["DM_TOUCH_HAPTICS", "DM_TOUCHSCREEN"], "Touchscreen Mode comes right under Touch feedback")
        m.values["DM_TOUCHSCREEN"] = "0"
        // "forced": a mod's switch (touch-ui) follows Touchscreen Mode: on while it is on, off as soon as it is off, and never offered on the mods page
        let forcedJSON = #"{"settings":[{"env":"DM_TOUCHSCREEN","kind":"toggle","section":"Controls","label":"Touchscreen Mode","note":"","default":"0","on":"1","off":"0"},{"env":"DM_MOD_TOUCHUI","kind":"toggle","section":"Mods","category":"Quality of Life","label":"Touch UI","note":"","default":"0","on":"1","off":"0","forced":"DM_TOUCHSCREEN=1"},{"env":"DM_MOD_OTHER","kind":"toggle","section":"Mods","category":"Quality of Life","label":"Other","note":"","default":"0","on":"1","off":"0"}]}"#
        let forcedRows = try! JSONDecoder().decode(SettingsFile.self, from: Data(forcedJSON.utf8)).settings
        let fm = LauncherModel(forcedRows, defaults: d)
        let touchUI = forcedRows[1]
        expect(fm.values["DM_MOD_TOUCHUI"] == "0" && fm.isManaged(touchUI), "the touch-ui switch is off while Touchscreen Mode is off")
        expect(!fm.mods(in: "Quality of Life").contains { $0.env == "DM_MOD_TOUCHUI" } && fm.mods(in: "Quality of Life").contains { $0.env == "DM_MOD_OTHER" }, "touch-ui is not on the mods page, an ordinary mod is")
        fm.values["DM_TOUCHSCREEN"] = "1"
        expect(fm.values["DM_MOD_TOUCHUI"] == "1" && fm.modsOn == 0, "Touchscreen Mode turns the touch-ui switch on; it is not counted among the mods the player turned on")
        fm.values["DM_MOD_TOUCHUI"] = "0"
        expect(fm.values["DM_MOD_TOUCHUI"] == "1", "the switch cannot be turned off while Touchscreen Mode is on")
        fm.values["DM_TOUCHSCREEN"] = "0"
        expect(fm.values["DM_MOD_TOUCHUI"] == "0", "turning Touchscreen Mode off turns the touch-ui switch off")
        fm.values["DM_TOUCHSCREEN"] = "1"; fm.apply()
        expect(String(cString: getenv("DM_MOD_TOUCHUI")) == "1", "Play with Touchscreen Mode on starts the game with the mod on")
        fm.values["DM_TOUCHSCREEN"] = "0"; fm.apply()
        expect(String(cString: getenv("DM_MOD_TOUCHUI")) == "0", "Play with Touchscreen Mode off starts the game with the mod off")
        d.set("1", forKey: "launcher.DM_MOD_TOUCHUI")
        expect(LauncherModel(forcedRows, defaults: d).values["DM_MOD_TOUCHUI"] == "0", "a touch-ui choice saved by an older build does not keep the mod on with Touchscreen Mode off")
        d.removeObject(forKey: "launcher.DM_MOD_TOUCHUI")
        d.set("1", forKey: "launcher.DM_TOUCHSCREEN")
        expect(LauncherModel(forcedRows, defaults: d).values["DM_MOD_TOUCHUI"] == "1", "a saved Touchscreen Mode turns the switch on at start")
        d.removeObject(forKey: "launcher.DM_TOUCHSCREEN")
        fm.values["DM_TOUCHSCREEN"] = "1"; fm.reset()
        expect(fm.values["DM_TOUCHSCREEN"] == "0" && fm.values["DM_MOD_TOUCHUI"] == "0", "Reset shows both at their defaults")
        let noController = Array(forcedRows.dropFirst())
        let nm = LauncherModel(noController, defaults: d)
        expect(!nm.isManaged(noController[0]) && nm.mods(in: "Quality of Life").contains { $0.env == "DM_MOD_TOUCHUI" }, "a game without Touchscreen Mode keeps touch-ui as an ordinary switch on the mods page")
        // option notes: a choice's line under the label follows the chosen value (Pointer Mode)
        let pointer = row("DM_POINTER_MODE")
        expect(pointer.noteText("trackpad") != pointer.noteText("touch") && pointer.noteText("trackpad").contains("trackpad") && pointer.noteText("touch").contains("Pinch"), "Pointer Mode describes the chosen mode, not both")
        expect(row("DM_TOUCHSCREEN").noteText("1") == row("DM_TOUCHSCREEN").note, "a row without option notes shows its note")
        // DM_LAUNCHER=0 skips the screen, not the saved choices; DM_SAVED_CHOICES=0 ignores them and leaves them stored
        let fps = file.settings.first { $0.env == "DM_FPS_TARGET" }!
        d.set("30", forKey: "launcher.DM_FPS_TARGET"); unsetenv("DM_FPS_TARGET")
        LauncherModel(file.settings, defaults: d).applySaved()
        expect(String(cString: getenv("DM_FPS_TARGET")) == "30" && d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "without the screen, a saved choice goes into the environment and stays saved")
        setenv("DM_SAVED_CHOICES", "0", 1); unsetenv("DM_FPS_TARGET")
        let plain = LauncherModel(file.settings, defaults: d)
        expect(plain.values["DM_FPS_TARGET"] == fps.def, "DM_SAVED_CHOICES=0 starts from the defaults")
        plain.applySaved()
        expect(getenv("DM_FPS_TARGET") == nil, "DM_SAVED_CHOICES=0: nothing saved goes into the environment")
        plain.apply()
        expect(String(cString: getenv("DM_FPS_TARGET")) == fps.def && d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "DM_SAVED_CHOICES=0: Play uses the screen's values and leaves the saved choices")
        plain.reset()
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "DM_SAVED_CHOICES=0: Reset leaves the saved choices too")
        unsetenv("DM_SAVED_CHOICES")
        // The Mac window's list (second argument): Basic first, then Advanced in the list's sections; Display mode; the render scale in pixels; values set at launch are fixed
        let mac = try! JSONDecoder().decode(SettingsFile.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        setenv("DM_ENV_FILE_KEYS", "", 1); unsetenv("DM_FULLSCREEN"); unsetenv("DM_OPMODE")
        let mm = LauncherModel(mac.settings, defaults: d)
        expect(mm.sections(basic: true) == ["Game"] && mm.sections(basic: false) == ["Game", "Performance"], "Basic and Advanced keep the list's sections")
        expect(mm.rows(in: "Game", basic: true).map(\.env) == ["DM_FPS_TARGET", "DM_RENDER_SCALE", "DM_OPMODE", "DM_LANG", "DM_FULLSCREEN"], "Basic rows in the list's order")
        expect(!file.settings.contains { $0.env == "DM_FULLSCREEN" } && mm.values["DM_FULLSCREEN"] == "0", "Display mode is the Mac's, Window by default")
        mm.values["DM_FULLSCREEN"] = "1"; mm.apply()
        expect(String(cString: getenv("DM_FULLSCREEN")) == "1" && d.string(forKey: "launcher.DM_FULLSCREEN") == "1", "Fullscreen goes into the environment and is saved")
        mm.values["DM_FULLSCREEN"] = "0"; mm.apply()
        expect(String(cString: getenv("DM_FULLSCREEN")) == "0" && d.string(forKey: "launcher.DM_FULLSCREEN") == nil, "Window is the default: set to 0, not saved")
        let macScale = mac.settings.first { $0.env == "DM_RENDER_SCALE" }!
        mm.values["DM_OPMODE"] = "1"
        expect(mm.rangeLabel(macScale, 1) == "1600 × 900 (100 %)" && mm.rangeLabel(macScale, 0.5) == "800 × 450 (50 %)", "docked size in pixels at 1.0 and 0.5")
        mm.values["DM_OPMODE"] = "0"
        expect(mm.rangeLabel(macScale, 0.75) == "960 × 540 (75 %)", "handheld size in pixels")
        let plainScale = try! JSONDecoder().decode(Setting.self, from: Data(#"{"env":"DM_X","kind":"range","label":"X","note":"","default":"1.0","min":0.5,"max":1.0,"step":0.05,"level":"expert"}"#.utf8))
        expect(mm.rangeLabel(plainScale, 0.5) == "50 %" && !plainScale.basic, "no base size: the percentage; an unknown level decodes as Advanced")
        d.set("1", forKey: "launcher.DM_OPMODE"); setenv("DM_ENV_LAUNCH_KEYS", "DM_OPMODE", 1); setenv("DM_OPMODE", "0", 1)   // a front end's launch override over a saved choice
        let launched = LauncherModel(mac.settings, defaults: d)
        expect(launched.values["DM_OPMODE"] == "0" && launched.fixed.contains("DM_OPMODE") && launched.fromLaunch.contains("DM_OPMODE"), "a variable set at launch is shown fixed, over the saved choice")
        launched.apply()
        expect(String(cString: getenv("DM_OPMODE")) == "0" && d.string(forKey: "launcher.DM_OPMODE") == "1", "Play keeps the launch value and leaves the saved choice")
        launched.reset(); launched.apply()
        expect(launched.values["DM_OPMODE"] == "0" && d.string(forKey: "launcher.DM_OPMODE") == "1", "Reset then Play keeps the saved choice of a setting fixed at launch")
        unsetenv("DM_OPMODE"); setenv("DM_ENV_LAUNCH_KEYS", "", 1); d.removeObject(forKey: "launcher.DM_OPMODE")
        failed += checkLauncherLayout(LauncherModel(mac.settings, defaults: d), defaults: d)
        print("launcher storage: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
