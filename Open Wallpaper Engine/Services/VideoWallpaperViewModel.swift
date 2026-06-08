import AVKit
import SwiftUI
import Combine

class VideoWallpaperViewModel: ObservableObject {
    var currentWallpaper: WEWallpaper {
        didSet {
            if let oldItem = self.player.currentItem {
                NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
            }
            let newItem = AVPlayerItem(url: currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file))
            self.player.replaceCurrentItem(with: newItem)
            NotificationCenter.default.addObserver(self, selector: #selector(playerDidFinishPlaying(_:)), name: .AVPlayerItemDidPlayToEndTime, object: newItem)
            // Force-apply rate and volume — replaceCurrentItem resets player to paused
            self.player.rate = self.playRate
            self.player.volume = self.playVolume
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

    var player = AVPlayer()
    private var cancellables = Set<AnyCancellable>()
    // Retry schedule (seconds) for unexpected pauses (e.g. Stage Manager animation)
    private static let resumeDelays: [Double] = [0.2, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0]

    init(wallpaper currentWallpaper: WEWallpaper) {
        self.currentWallpaper = currentWallpaper
        self.player = AVPlayer(url: currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file))
        self.player.automaticallyWaitsToMinimizeStalling = false
        NotificationCenter.default.addObserver(self, selector: #selector(playerDidFinishPlaying(_:)), name: .AVPlayerItemDidPlayToEndTime, object: self.player.currentItem)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceDidChange(_:)), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceDidChange(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)

        let wvm = AppDelegate.shared.wallpaperViewModel
        wvm.$playRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                self?.playRate = rate
            }
            .store(in: &cancellables)
        wvm.$playVolume
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volume in
                self?.playVolume = volume
            }
            .store(in: &cancellables)

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, status == .paused, self.playRate > 0 else { return }
                self.scheduleResume(attempt: 0)
            }
            .store(in: &cancellables)
    }

    // Keeps retrying until the player is actually playing or all delays are exhausted.
    // Each successful re-kick resets the schedule if the system pauses again (timeControlStatus fires).
    private func scheduleResume(attempt: Int) {
        let delays = VideoWallpaperViewModel.resumeDelays
        guard attempt < delays.count, playRate > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
            guard let self, self.playRate > 0 else { return }
            if self.player.timeControlStatus == .paused {
                self.player.rate = self.playRate
                self.scheduleResume(attempt: attempt + 1)
            }
            // If playing, stop — timeControlStatus publisher will re-trigger if paused again
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func playerDidFinishPlaying(_ notification: Notification) {
        self.player.seek(to: CMTime.zero)
        self.player.rate = self.playRate
    }

    @objc private func playerDidStopPlaying(_ notification: Notification) {
        self.player.rate = self.playRate
    }

    @objc func systemWillSleep(_ notification: Notification) {
        self.player.rate = 0
    }

    @objc func systemDidWake(_ notification: Notification) {
        self.player.rate = self.playRate
    }

    @objc func spaceDidChange(_ notification: Notification) {
        self.player.rate = self.playRate
    }
}
