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
    let screenId: String

    init(wallpaperViewModel: WallpaperViewModel, screenId: String) {
        self.wallpaperViewModel = wallpaperViewModel
        self.screenId = screenId
        self._viewModel = StateObject(wrappedValue: SceneWallpaperViewModel(wallpaper: wallpaperViewModel.wallpaper(for: screenId)))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> SKView {
        let skView = SKView(frame: .zero)
        skView.ignoresSiblingOrder = true
        skView.allowsTransparency = false
        skView.preferredFramesPerSecond = Int(AppDelegate.shared.globalSettingsViewModel.settings.fps)
        context.coordinator.attach(to: skView)

        if let scene = viewModel.skScene {
            skView.presentScene(scene)
        }

        return skView
    }

    func updateNSView(_ skView: SKView, context: Context) {
        let selectedWallpaper = wallpaperViewModel.wallpaper(for: screenId)
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
        skView.scene?.scaleMode = SceneWallpaperViewModel.spriteKitScaleMode()

        // Update FPS
        skView.preferredFramesPerSecond = Int(AppDelegate.shared.globalSettingsViewModel.settings.fps)

        // Pause/resume based on play rate
        skView.isPaused = wallpaperViewModel.playRate == 0

        context.coordinator.updateMousePosition()
    }

    class Coordinator {
        private weak var skView: SKView?
        private weak var viewModel: SceneWallpaperViewModel?
        private var localMonitor: Any?
        private var globalMonitor: Any?

        init(viewModel: SceneWallpaperViewModel) {
            self.viewModel = viewModel
        }

        deinit {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
            }
            if let globalMonitor {
                NSEvent.removeMonitor(globalMonitor)
            }
        }

        func attach(to skView: SKView) {
            self.skView = skView
            guard localMonitor == nil, globalMonitor == nil else { return }

            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.updateMousePosition()
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                self?.updateMousePosition()
            }
        }

        func updateMousePosition() {
            guard let skView, let viewModel, viewModel.hasParallaxNodes else { return }
            let mouseLocation = NSEvent.mouseLocation
            let frame = skView.window?.frame ?? skView.bounds
            guard frame.width > 0, frame.height > 0, frame.contains(mouseLocation) else { return }

            let x = ((mouseLocation.x - frame.minX) / frame.width) * 2 - 1
            let y = ((mouseLocation.y - frame.minY) / frame.height) * 2 - 1
            viewModel.updateParallax(normalizedMouse: CGPoint(x: x, y: y))
        }
    }
}
