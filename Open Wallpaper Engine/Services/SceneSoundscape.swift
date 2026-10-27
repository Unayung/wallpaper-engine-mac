//
//  SceneSoundscape.swift
//  Open Wallpaper Engine
//
//  Plays a scene's `sound` objects. They were never read, so 28 scenes in the library
//  were silent at any volume, and Mute and the volume slider did nothing to scenes.
//

import AVFoundation
import Combine

/// The sound half of a scene wallpaper, owned by `SceneWallpaperView` beside
/// `SceneWallpaperViewModel`.
///
/// Kept out of `SceneWallpaperViewModel` on purpose: `Tools/scenecheck` compiles that file
/// standalone, without `AppDelegate`, and renders every scene in the library — it must
/// neither fail to link nor play 28 soundtracks while it measures. SpriteKit's pause does
/// not reach audio either, so this follows playRate/playVolume itself, the way
/// `VideoWallpaperViewModel` drives its `AVPlayer`.
final class SceneSoundViewModel: ObservableObject {
    private(set) var wallpaper: WEWallpaper
    private(set) var soundscape: SceneSoundscape?
    private var volume: Float = 1
    private var isPaused = false
    private var cancellables = Set<AnyCancellable>()

    /// Built by a SwiftUI view long after `AppDelegate.init` has returned, so reaching
    /// `AppDelegate.shared` here is safe, unlike in the three shared view models.
    init(wallpaper: WEWallpaper, screenId: String) {
        self.wallpaper = wallpaper
        let wvm = AppDelegate.shared.wallpaperViewModel
        volume = wvm.effectiveVolume(for: screenId)
        isPaused = wvm.playRate == 0
        load(wallpaper)

        wvm.$playRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                self?.isPaused = rate == 0
                self?.soundscape?.isPaused = rate == 0
            }
            .store(in: &cancellables)
        // Muted unless this is the screen that is heard; see WallpaperViewModel.audioScreenId.
        wvm.$playVolume.combineLatest(wvm.$audioScreenId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volume, audioScreenId in
                let heard = audioScreenId == screenId ? volume : 0
                self?.volume = heard
                self?.soundscape?.masterVolume = heard
            }
            .store(in: &cancellables)
    }

    deinit {
        soundscape?.stop()
    }

    /// Replace the current scene's sounds with `wallpaper`'s. Resolved like every other
    /// scene asset: the wallpaper's package first, then loose files beside it. The package
    /// is memory-mapped, so reading it a second time beside the scene loader costs page
    /// cache rather than another copy of a file that can run to tens of megabytes.
    ///
    /// The work runs on a utility queue: reading the package and opening the first track
    /// of every voice measured 0.5-1.3 s for the heavier scenes, all of which used to be
    /// main-thread time before the wallpaper appeared. Only `start` comes back to main.
    func load(_ wallpaper: WEWallpaper) {
        self.wallpaper = wallpaper
        soundscape?.stop()
        soundscape = nil
        generation += 1
        let generation = self.generation

        Self.loadQueue.async { [weak self] in
            guard let sounds = Self.makeSoundscape(for: wallpaper) else { return }
            sounds.prepare()
            DispatchQueue.main.async {
                // Superseded by a newer wallpaper while loading, or the view went away.
                guard let self = self, self.generation == generation else { return }
                sounds.masterVolume = self.volume
                sounds.isPaused = self.isPaused
                sounds.start()
                self.soundscape = sounds
            }
        }
    }

    private var generation = 0
    private static let loadQueue = DispatchQueue(label: "SceneSoundViewModel.load", qos: .utility)

    private static func makeSoundscape(for wallpaper: WEWallpaper) -> SceneSoundscape? {
        let dir = wallpaper.wallpaperDirectory
        let sceneFile = wallpaper.project.file
        let pkgURL = dir.appending(path: (sceneFile as NSString).deletingPathExtension + ".pkg")
        let parser = (try? Data(contentsOf: pkgURL, options: .alwaysMapped)).flatMap { try? PKGParser(data: $0) }
        guard let sceneJSON = parser?.extractFile(named: sceneFile)
                ?? (try? Data(contentsOf: dir.appending(path: sceneFile))) else { return nil }

        let sounds = SceneSoundscape(sceneJSON: sceneJSON) { path in
            parser?.extractFile(named: path) ?? (try? Data(contentsOf: dir.appending(path: path)))
        }
        return sounds.voiceCount > 0 ? sounds : nil
    }
}
/// One scene's sound objects, mixed under a master volume and a pause switch that the
/// owner mirrors from `WallpaperViewModel.playVolume` / `playRate`.
///
/// Read straight from the scene JSON rather than through `WEScene`, which models no
/// sound objects; the scene parser is left alone. Measured over the installed library:
/// 72 sound objects in 28 scenes, 59 `loop`, 8 `single`, 5 `random`; files are mp3 (97),
/// ogg (18), wav (9) and flac (2), and `AVAudioPlayer(data:)` opened a sample of each.
final class SceneSoundscape {
    private var voices: [Voice] = []

    var masterVolume: Float = 1 {
        didSet { voices.forEach { $0.masterVolume = masterVolume } }
    }

    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            voices.forEach { isPaused ? $0.pause() : $0.resume() }
        }
    }

    /// `sceneJSON` is the raw scene file; `load` resolves a sound path to its bytes.
    init(sceneJSON: Data, load: (String) -> Data?) {
        guard let root = try? JSONSerialization.jsonObject(with: sceneJSON) as? [String: Any],
              let objects = root["objects"] as? [[String: Any]] else { return }

        for object in objects {
            guard let paths = object["sound"] as? [String], !paths.isEmpty else { continue }
            // `startsilent` sounds are started by a script or a click, which nothing here
            // emulates; starting them on load would play cues out of context.
            if (object["startsilent"] as? Bool) == true { continue }
            if (object["visible"] as? Bool) == false { continue }

            let tracks = paths.compactMap { path -> Voice.Track? in
                guard let data = load(path) else {
                    NSLog("[SceneSound] not found: %@", path)
                    return nil
                }
                return Voice.Track(path: path, data: data)
            }
            guard !tracks.isEmpty else { continue }

            let voice = Voice(tracks: tracks,
                              mode: Voice.Mode(rawValue: object["playbackmode"] as? String ?? "loop") ?? .loop,
                              volume: Self.number(object["volume"]) ?? 1,
                              minDelay: Double(Self.number(object["mintime"]) ?? 1),
                              maxDelay: Double(Self.number(object["maxtime"]) ?? 5))
            voices.append(voice)
        }
    }

    var voiceCount: Int { voices.count }
    /// What is audible right now, as (playing, volume) per voice — for logs and checks.
    var state: [(playing: Bool, volume: Float)] { voices.map { ($0.isPlaying, $0.currentVolume) } }

    /// Open each voice's first track. This is the expensive part — measured in isolation,
    /// 400-760 ms for scenes with 3-6 voices, most of it AVFoundation opening files and
    /// warming up — so the owner runs it off the main thread and calls `start` after.
    func prepare() {
        voices.forEach { $0.prepare() }
    }

    func start() {
        voices.forEach {
            $0.masterVolume = masterVolume
            $0.start(paused: isPaused)
        }
    }

    func stop() {
        voices.forEach { $0.stop() }
        voices.removeAll()
    }

    /// `volume` is either a number or a user-property binding `{"user": .., "value": ..}`
    /// (44 of the 72 objects); the binding's `value` is the author's setting.
    private static func number(_ value: Any?) -> Float? {
        if let n = value as? NSNumber { return n.floatValue }
        if let dict = value as? [String: Any], let n = dict["value"] as? NSNumber { return n.floatValue }
        if let s = value as? String { return Float(s) }
        return nil
    }

    /// One sound object: a set of tracks played per Wallpaper Engine's playback mode.
    ///
    /// Only the track about to play has a player. Opening one is not free — an ogg is
    /// scanned to find its length — and one SpongeBob scene lists 16 ogg songs in a
    /// single `random` object: opening every track up front took 1.6 s on the main thread
    /// before the wallpaper appeared.
    private final class Voice: NSObject, AVAudioPlayerDelegate {
        struct Track {
            let path: String
            let data: Data
        }

        enum Mode: String {
            /// Play the tracks in order, forever.
            case loop
            /// Play a random track, wait `mintime...maxtime` seconds, repeat.
            case random
            /// Play the first track once.
            case single
        }

        private var tracks: [Track]
        private let mode: Mode
        private let volume: Float
        private let minDelay: Double
        private let maxDelay: Double
        private var trackIndex = 0
        private var player: AVAudioPlayer?
        private var delay: Timer?
        private var isPaused = false
        private var isFinished = false

        var masterVolume: Float = 1 {
            didSet { player?.volume = volume * masterVolume }
        }

        var isPlaying: Bool { player?.isPlaying == true }
        var currentVolume: Float { player?.volume ?? volume * masterVolume }

        init(tracks: [Track], mode: Mode, volume: Float, minDelay: Double, maxDelay: Double) {
            self.tracks = tracks
            self.mode = mode
            self.volume = max(0, min(1, volume))
            self.minDelay = max(0, min(minDelay, maxDelay))
            self.maxDelay = max(minDelay, maxDelay)
            super.init()
        }

        /// Open the first track. Safe off the main thread; see `SceneSoundscape.prepare`.
        func prepare() {
            trackIndex = mode == .random ? Int.random(in: 0..<tracks.count) : 0
            openCurrentTrack()
        }

        func start(paused: Bool) {
            isPaused = paused
            if !paused { playCurrentTrack() }
        }

        func pause() {
            isPaused = true
            player?.pause()
            // A pending gap is simply restarted on resume; its exact remainder is not
            // worth keeping for an ambience that is random anyway.
            delay?.invalidate()
            delay = nil
        }

        func resume() {
            isPaused = false
            guard !isFinished else { return }
            if let player = player {
                player.play()
            } else if mode == .random {
                scheduleNext()
            } else {
                playCurrentTrack()
            }
        }

        func stop() {
            delay?.invalidate()
            delay = nil
            player?.delegate = nil
            player?.stop()
            player = nil
        }

        /// Open `tracks[trackIndex]`. A track AVFoundation cannot read is dropped, so a
        /// voice with nothing playable ends instead of retrying forever.
        private func openCurrentTrack() {
            while !tracks.isEmpty {
                let track = tracks[trackIndex % tracks.count]
                do {
                    let player = try AVAudioPlayer(data: track.data)
                    player.delegate = self
                    // A lone looping track loops sample-accurately inside the player rather
                    // than with a gap at each delegate callback.
                    if mode == .loop && tracks.count == 1 { player.numberOfLoops = -1 }
                    player.prepareToPlay()
                    self.player = player
                    return
                } catch {
                    NSLog("[SceneSound] not playable: %@ (%@)", track.path, error.localizedDescription)
                    tracks.remove(at: trackIndex % tracks.count)
                    trackIndex = 0
                }
            }
            isFinished = true
        }

        private func playCurrentTrack() {
            if player == nil { openCurrentTrack() }
            player?.volume = volume * masterVolume
            player?.play()
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            self.player = nil
            switch mode {
            case .single:
                isFinished = true
            case .loop:
                trackIndex = (trackIndex + 1) % tracks.count
                if !isPaused { playCurrentTrack() }
            case .random:
                if !isPaused { scheduleNext() }
            }
        }

        private func scheduleNext() {
            let wait = Double.random(in: minDelay...maxDelay)
            delay = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
                guard let self = self, !self.isPaused, !self.tracks.isEmpty else { return }
                self.delay = nil
                self.trackIndex = Int.random(in: 0..<self.tracks.count)
                self.playCurrentTrack()
            }
        }
    }
}
