//
//  VideoWallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/14.
//

import AVKit
import SwiftUI
import Combine

class VideoWallpaperViewModel: ObservableObject {
    var currentWallpaper: WEWallpaper {
        didSet {
            load()
        }
    }

    var playRate: Float = 0 {
        didSet {
            self.player.rate = playRate
        }
    }

    var playVolume: Float = 0 {
        didSet {
            self.player.volume = playVolume
        }
    }

    /// Looping is done by `AVPlayerLooper`, which needs a queue player.
    ///
    /// The previous loop was end notification → `seek(to: .zero)` → set the rate again, with the
    /// player pausing at the end in between. Every loop point stalled for that round trip, with
    /// a matching gap in the audio — a visible hitch every few seconds in exactly the videos
    /// authored to loop seamlessly. The looper queues the next copy of the item ahead of time
    /// and switches to it without seeking. Measured as the wall-clock gap from the last frame to
    /// frame 0, it took the 3.9 s Bloody Valentine clip from 95–225 ms to a steady 33 ms (one
    /// frame), Wall of the Abyss from 67–82 to 17–35 and Snowfall 4K from 96 to 44. Most other
    /// clips are unchanged within noise. One is worse: cb4kF (Night City, 4K) went from ~120 ms
    /// to ~215 ms, consistently, and nothing in its track layout explains it — weighed against
    /// the rest, the looper stays.
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []

    /// The screen this player is on, to decide whether it is the one that is heard.
    let screenId: String

    init(wallpaper currentWallpaper: WEWallpaper, screenId: String) {
        self.currentWallpaper = currentWallpaper
        self.screenId = screenId
        // Display sleep is a policy decision, not a playback one: AppDelegate observes the
        // sleep/wake notifications and applies the `Display asleep` setting through playRate.
        load()

        // A failure to reach the end is treated as reaching it: the alternative is a wallpaper
        // frozen on whatever frame it failed on.
        observers.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let item = note.object as? AVPlayerItem,
                  item === self.player.currentItem else { return }
            self.restartFromTop()
        })
    }

    /// Mirror the shared control surface onto the player.
    ///
    /// Called by the view rather than done in `init`, so this model does not reach for
    /// `AppDelegate.shared` while it is being constructed.
    func bind(to wvm: WallpaperViewModel) {
        cancellables.removeAll()
        wvm.$playRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                self?.playRate = rate
            }
            .store(in: &cancellables)
        // Muted unless this is the screen that is heard; see WallpaperViewModel.audioScreenId.
        wvm.$playVolume.combineLatest(wvm.$audioScreenId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volume, audioScreenId in
                guard let self else { return }
                self.playVolume = audioScreenId == self.screenId ? volume : 0
            }
            .store(in: &cancellables)
    }

    deinit {
        looper?.disableLooping()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private var fileURL: URL {
        currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file)
    }

    /// Bumped on every load, so an inspection that finishes after the wallpaper has changed
    /// again is thrown away instead of installing the wrong video.
    private var loadGeneration = 0

    private func load() {
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        loadGeneration += 1
        let generation = loadGeneration
        let asset = AVURLAsset(url: fileURL)
        Task { @MainActor in
            let decodable = await Self.isDecodable(asset)
            let loopRange = decodable ? await Self.loopRange(of: asset) : nil
            guard self.loadGeneration == generation else { return }
            if decodable {
                self.fallbackImageURL = nil
                self.install(asset, loopRange: loopRange)
            } else {
                // Nothing is installed in the player, so there is no soundtrack either.
                self.fallbackImageURL = self.previewImageURL
                NSLog("[VideoVM] %@ cannot be decoded on this Mac; showing its preview instead",
                      self.fileURL.lastPathComponent)
            }
        }
    }

    /// Set when the video cannot be decoded here, to the wallpaper's own preview image, which
    /// the view shows in place of the player.
    @Published private(set) var fallbackImageURL: URL?

    private var previewImageURL: URL? {
        let dir = currentWallpaper.wallpaperDirectory
        let declared = currentWallpaper.project.preview
        let names = (declared.isEmpty ? [] : [declared]) + ["preview.gif", "preview.jpg", "preview.png"]
        return names.map { dir.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// Whether AVFoundation can actually show this video.
    ///
    /// Not something playback reports. A VP9 file (Tuner Scene, 2997998111 — the only codec among
    /// the 52 installed video wallpapers that is not H.264 or HEVC) reaches `readyToPlay` with no error and
    /// its clock advances, but no video frame is ever produced: the user got a black desktop
    /// with the soundtrack playing over it and no hint why. The asset says so up front —
    /// `isPlayable` is false — and a video track's `isDecodable` covers the case of a playable
    /// container holding an undecodable stream.
    private static func isDecodable(_ asset: AVAsset) async -> Bool {
        guard (try? await asset.load(.isPlayable)) == true else { return false }
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        for track in tracks where (try? await track.load(.isDecodable)) != true {
            return false
        }
        return true
    }

    private func install(_ asset: AVAsset, loopRange: CMTimeRange?) {
        let item = AVPlayerItem(asset: asset)
        if let loopRange {
            looper = AVPlayerLooper(player: player, templateItem: item, timeRange: loopRange)
        } else {
            looper = AVPlayerLooper(player: player, templateItem: item)
        }
        // Re-apply: a fresh queue is not playing until told to.
        player.rate = playRate
        player.volume = playVolume
    }

    /// The range to loop when the file's declared duration cannot be trusted, else nil.
    ///
    /// Some files carry a container duration that is simply wrong: frederick.mp4 holds 180.5 s
    /// of media but declares 16,242,000 s, in the movie header and on both tracks alike.
    /// Playback reached the real end, then sat on the last frame forever with `rate` still 1
    /// and no end notification — the clock itself runs on past the media (measured 177 → 184 s
    /// with no new frame after 180.4), so nothing time-based can see it, and `AVPlayerLooper`
    /// is fooled the same way since it loops on that duration too. The sample table is not
    /// wrong: a sample cursor puts the last video sample's end at 180.533 s. When that falls
    /// well short of the declared duration, it is what gets looped.
    private static func loopRange(of asset: AVAsset) async -> CMTimeRange? {
        guard let duration = try? await asset.load(.duration), duration.isNumeric,
              let tracks = try? await asset.loadTracks(withMediaType: .video) else { return nil }
        var mediaEnd = CMTime.zero
        for track in tracks {
            guard (try? await track.load(.canProvideSampleCursors)) == true,
                  let cursor = track.makeSampleCursorAtLastSampleInDecodeOrder() else { continue }
            // The last sample in decode order need not be the last one shown (B-frames), so
            // look back over a reorder window's worth of samples for the latest end.
            for _ in 0..<32 {
                mediaEnd = max(mediaEnd, cursor.presentationTimeStamp + cursor.currentSampleDuration)
                if cursor.stepInDecodeOrder(byCount: -1) == 0 { break }
            }
        }
        guard mediaEnd > .zero,
              (duration - mediaEnd).seconds > 1 else { return nil }
        NSLog("[VideoVM] declared duration %.1f s, media ends at %.3f s: looping the media",
              duration.seconds, mediaEnd.seconds)
        return CMTimeRange(start: .zero, end: mediaEnd)
    }

    private func restartFromTop() {
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.rate = playRate
    }
}
