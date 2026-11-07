// LauncherAudio: the launcher's music and its Play sound (Launcher.swift). iOS only (the Mac settings window does not use it).
// The music loops while the launcher is up; Play rolls the dice, then fades the music out, and only then lets the game start (the host takes over the audio session when it boots).
// The audio session is left alone on purpose: main.m has already set it up for the game (front_ios_audio_session), and changing its category here would carry over into the game.
// Files (dm/ios/Resources, bundled by project.yml): LauncherBGM.m4a (the first 1:30 of the track) and LauncherDiceRoll.wav. A missing file just means no sound, never a stuck launcher.
import AVFoundation

final class LauncherAudio {
    /// How long the music takes to fade out once the dice sound has finished.
    static let fadeOutDuration: TimeInterval = 1.5
    /// Pause between the end of the dice sound and the start of the fade (0 = fade begins the moment the dice stop).
    static let fadeOutDelay: TimeInterval = 0
    static let musicVolume: Float = 1.0

    private var music: AVAudioPlayer?
    private var dice: AVAudioPlayer?
    private var leaving = false   // Play was pressed: the music is on its way out and must not be restarted

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

    /// Play was pressed: roll the dice, then fade the music out; `done` runs once both have finished.
    func rollThenFadeOut(done: @escaping () -> Void) {
        guard !leaving else { return }
        leaving = true
        dice = player("LauncherDiceRoll", "wav")
        dice?.currentTime = 0
        dice?.play()
        let diceLength = dice?.duration ?? 0
        let fadeStart = diceLength + Self.fadeOutDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeStart) { [weak self] in
            self?.music?.setVolume(0, fadeDuration: Self.fadeOutDuration)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeStart + Self.fadeOutDuration + 0.05) { [weak self] in
            self?.music?.stop()
            self?.music = nil
            self?.dice = nil
            done()
        }
    }
}
