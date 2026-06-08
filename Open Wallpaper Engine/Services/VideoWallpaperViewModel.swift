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
            // Remove observer for old item before replacing
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

    init(wallpaper currentWallpaper: WEWallpaper) {
        self.currentWallpaper = currentWallpaper
        self.player = AVPlayer(url: currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file))
        NotificationCenter.default.addObserver(self, selector: #selector(playerDidFinishPlaying(_:)), name: .AVPlayerItemDidPlayToEndTime, object: self.player.currentItem)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)

        // Directly observe playRate/playVolume changes from the shared WallpaperViewModel
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
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func playerDidFinishPlaying(_ notification: Notification) {
        // Replay video
        self.player.seek(to: CMTime.zero)
        self.player.rate = self.playRate
    }

    @objc private func playerDidStopPlaying(_ notification: Notification) {
        // Resume playback
        self.player.rate = self.playRate
    }

    @objc func systemWillSleep(_ notification: Notification) {
        self.player.rate = 0
    }

    @objc func systemDidWake(_ notification: Notification) {
        self.player.rate = self.playRate
    }
}
