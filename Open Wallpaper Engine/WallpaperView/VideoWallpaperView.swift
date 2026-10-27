//
//  VideoWallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/13.
//

import Cocoa
import SwiftUI
import AVKit

struct VideoWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @StateObject var viewModel: VideoWallpaperViewModel
    let screenId: String

    init(wallpaperViewModel: WallpaperViewModel, screenId: String) {
        self.wallpaperViewModel = wallpaperViewModel
        self.screenId = screenId
        self._viewModel = StateObject(wrappedValue: VideoWallpaperViewModel(wallpaper: wallpaperViewModel.wallpaper(for: screenId), screenId: screenId))
    }

    func makeNSView(context: Context) -> VideoWallpaperContainerView {
        let container = VideoWallpaperContainerView()
        let view = container.playerView

        view.player = viewModel.player
        viewModel.bind(to: wallpaperViewModel)

        // make the video boundary extends to fit the full screen without black background border
        view.videoGravity = .resizeAspectFill

        // hide any unneeded ui component, we want just the video output
        view.controlsStyle = .none

        // make sure this video player won't show any info in the system control center
        view.updatesNowPlayingInfoCenter = false

        // mark the flag as unneeded, improve performance and reduce power drain
        view.allowsVideoFrameAnalysis = false

        container.showFallback(viewModel.fallbackImageURL)
        return container
    }

    func updateNSView(_ container: VideoWallpaperContainerView, context: Context) {
        let selectedWallpaper = wallpaperViewModel.wallpaper(for: screenId)
        let currentWallpaper = viewModel.currentWallpaper

        if selectedWallpaper.wallpaperDirectory.appending(path: selectedWallpaper.project.file) != currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file) {
            viewModel.currentWallpaper = selectedWallpaper
        }

        viewModel.playRate = wallpaperViewModel.playRate
        viewModel.playVolume = wallpaperViewModel.effectiveVolume(for: screenId)
        container.showFallback(viewModel.fallbackImageURL)
    }
}

/// The player, plus the preview image that replaces it when the video cannot be decoded.
final class VideoWallpaperContainerView: NSView {
    let playerView = AVPlayerView()
    private let fallbackView = NSImageView()
    private var fallbackURL: URL?

    init() {
        super.init(frame: .zero)
        for view in [playerView, fallbackView] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        fallbackView.imageScaling = .scaleProportionallyUpOrDown
        // A preview.gif is the closest thing the package has to the motion it promised.
        fallbackView.animates = true
        fallbackView.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showFallback(_ url: URL?) {
        guard url != fallbackURL else { return }
        fallbackURL = url
        fallbackView.image = url.flatMap { NSImage(contentsOf: $0) }
        fallbackView.isHidden = url == nil
        playerView.isHidden = url != nil
    }
}
