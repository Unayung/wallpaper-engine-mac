//
//  SceneWallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/13.
//

import Cocoa
import SwiftUI
import SpriteKit

struct SceneWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @StateObject var viewModel: SceneWallpaperViewModel

    init(wallpaperViewModel: WallpaperViewModel) {
        self.wallpaperViewModel = wallpaperViewModel
        self._viewModel = StateObject(wrappedValue: SceneWallpaperViewModel(wallpaper: wallpaperViewModel.currentWallpaper))
    }

    func makeNSView(context: Context) -> SKView {
        let skView = SKView(frame: .zero)
        skView.ignoresSiblingOrder = true
        skView.allowsTransparency = false
        skView.preferredFramesPerSecond = Int(AppDelegate.shared.globalSettingsViewModel.settings.fps)

        if let scene = viewModel.skScene {
            skView.presentScene(scene)
        }

        return skView
    }

    func updateNSView(_ skView: SKView, context: Context) {
        let selectedWallpaper = wallpaperViewModel.currentWallpaper
        let currentWallpaper = viewModel.currentWallpaper

        // Update scene if wallpaper changed
        if selectedWallpaper.wallpaperDirectory.appending(path: selectedWallpaper.project.file)
            != currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file) {
            viewModel.currentWallpaper = selectedWallpaper
        }

        // Present scene if available and not already presented
        if let scene = viewModel.skScene, skView.scene !== scene {
            skView.presentScene(scene)
        }

        // Update FPS
        skView.preferredFramesPerSecond = Int(AppDelegate.shared.globalSettingsViewModel.settings.fps)

        // Pause/resume based on play rate
        skView.isPaused = wallpaperViewModel.playRate == 0
    }
}
