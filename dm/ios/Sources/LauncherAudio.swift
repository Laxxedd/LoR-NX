// LauncherAudio: the launcher's music and its Play sound (Launcher.swift). iOS only (the Mac settings window does not use it).
// The music loops while the launcher is up. Play stops the music at once and rolls the dice, which play out, while the game starts at once: nothing waits for the audio.
// So the audio outlives the launcher view (one shared instance), and its timer runs on its own queue, not the main one, which the game's start may keep busy.
// The audio session is left alone on purpose: main.m has already set it up for the game (front_ios_audio_session), and changing its category here would carry over into the game.
// Files (dm/ios/Resources, bundled by project.yml): LauncherBGM.m4a (the first 1:30 of the track) and LauncherDiceRoll.wav. A missing file just means no sound, never a stuck launcher.
import AVFoundation

final class LauncherAudio {
    static let shared = LauncherAudio()

    static let musicVolume: Float = 1.0

    private var music: AVAudioPlayer?
    private var dice: AVAudioPlayer?
    private var leaving = false   // Play was pressed: the music is stopped and must not be restarted
    private let timers = DispatchQueue(label: "launcher.audio.timers", qos: .userInitiated)   // the dice's release timer: not the main queue (the game's start may keep it busy)

    private func player(_ name: String, _ ext: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            fputs("launcher audio: \(name).\(ext) is not in the app\n", stderr)
            return nil
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            return p
        } catch {
            fputs("launcher audio: \(name).\(ext) cannot be played: \(error.localizedDescription)\n", stderr)
            return nil
        }
    }

    /// Starts the looping music (the launcher appeared).
    func startMusic() {
        guard !leaving else { return }
        if music == nil {
            music = player("LauncherBGM", "m4a")
            music?.numberOfLoops = -1   // forever
            music?.volume = Self.musicVolume
        }
        if music?.isPlaying == false { music?.play() }
    }

    /// Pauses / resumes the music with the app (background / foreground).
    func pauseMusic() { music?.pause() }
    func resumeMusic() { if !leaving, music?.isPlaying == false { music?.play() } }

    /// Play was pressed: stop the music at once and let the dice sound play out. Returns at once; the caller starts the game without waiting.
    func rollAndStopMusic() {
        guard !leaving else { return }
        leaving = true
        music?.stop()
        music = nil
        let roll = player("LauncherDiceRoll", "wav")
        roll?.play()
        dice = roll
        timers.asyncAfter(deadline: .now() + (roll?.duration ?? 0) + 0.05) { [self] in
            dice = nil
        }
    }
}
