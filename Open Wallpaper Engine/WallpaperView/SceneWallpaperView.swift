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
    /// Observed so that moving the FPS slider reaches a running scene. Read through
    /// `AppDelegate.shared` only, the view was never told the setting changed, and the new rate
    /// waited for the next pause or wallpaper switch.
    @ObservedObject var globalSettings: GlobalSettingsViewModel
    @StateObject var viewModel: SceneWallpaperViewModel
    @StateObject var soundViewModel: SceneSoundViewModel
    let screenId: String

    init(wallpaperViewModel: WallpaperViewModel, globalSettings: GlobalSettingsViewModel, screenId: String) {
        self.wallpaperViewModel = wallpaperViewModel
        self.globalSettings = globalSettings
        self.screenId = screenId
        let wallpaper = wallpaperViewModel.wallpaper(for: screenId)
        let quality = globalSettings.settings.sceneQuality(onScreen: screenId)
        self._viewModel = StateObject(wrappedValue: SceneWallpaperViewModel(wallpaper: wallpaper,
                                                                            quality: quality))
        self._soundViewModel = StateObject(wrappedValue: SceneSoundViewModel(wallpaper: wallpaper, screenId: screenId))
    }

    func makeCoordinator() -> StillFrameGate { StillFrameGate() }

    func makeNSView(context: Context) -> SKView {
        let skView = SKView(frame: .zero)
        skView.ignoresSiblingOrder = true
        skView.allowsTransparency = false
        skView.preferredFramesPerSecond = FrameRate.deliverable(globalSettings.settings.fps, on: nil)
        skView.delegate = context.coordinator
        context.coordinator.observe(skView)

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
        // Quality controls apply live: a changed setting rebuilds the scene off the main thread,
        // and the new one is presented below once it lands, as on a wallpaper change.
        let quality = globalSettings.settings.sceneQuality(onScreen: screenId)
        if viewModel.quality != quality { viewModel.quality = quality }
        if selectedWallpaper.wallpaperDirectory.appending(path: selectedWallpaper.project.file)
            != soundViewModel.wallpaper.wallpaperDirectory.appending(path: soundViewModel.wallpaper.project.file) {
            soundViewModel.load(selectedWallpaper)
        }

        // Pause/resume based on play rate. `SKView.isPaused` is deliberately not used:
        // setting it stops the render loop before a scene that was just handed over has
        // drawn anything, and the wallpaper window then shows the `SKScene`'s own
        // background (a flat grey) for as long as that wallpaper stays up. A paused
        // wallpaper is the normal state on battery, so this was the common case. The
        // delegate below gates frames instead and lets the first ones through.
        let paused = wallpaperViewModel.playRate == 0

        // Present scene if available and not already presented
        if let scene = viewModel.skScene, skView.scene !== scene {
            context.coordinator.isStill = viewModel.isStill
            context.coordinator.isPaused = paused
            // A paused presentation still needs a frame; the full allowance exists for a
            // window that is still being ordered in and whose first frames find no drawable.
            context.coordinator.renderAgain(frames: paused ? 8 : StillFrameGate.framesPerInvalidation)
            skView.presentScene(scene)
        } else {
            context.coordinator.isPaused = paused
        }

        // Update FPS, as a rate this display can actually pace.
        let fps = FrameRate.deliverable(globalSettings.settings.fps, on: skView.window?.screen)
        if skView.preferredFramesPerSecond != fps { skView.preferredFramesPerSecond = fps }
    }

    /// Stops a still scene from being re-rendered once it is on screen.
    ///
    /// A scene with no motion of any kind still had SKView run its update and render loop at
    /// the full frame rate — measured at 31.5 updates a second at 30 fps — re-compositing a
    /// 4K texture into the desktop window all day to produce an identical frame. Returning
    /// false from `shouldRenderAtTime` skips the whole frame, update included.
    ///
    /// A few frames are let through after each presentation and each resize rather than one,
    /// because the first frame after `presentScene` can land before the drawable has its final
    /// size, and a gate that closed on it would freeze a blank or stretched picture.
    final class StillFrameGate: NSObject, SKViewDelegate {
        var isStill = false
        /// Playback is paused. Unlike `SKView.isPaused`, this lets the gate spend its
        /// remaining frames first, so a scene presented while paused still draws.
        var isPaused = false {
            didSet {
                // Resuming has to reopen the gate: a still scene that was presented while
                // paused may have spent its frames on draws that never happened.
                guard oldValue, !isPaused else { return }
                framesLeft = Self.framesPerInvalidation
            }
        }
        private var framesLeft = 0
        /// About a second at the usual rates, not three frames. A frame let through is not a
        /// frame drawn: SKView skips it when no drawable is available ("no drawables available
        /// for rendering", logged on the wallpaper window while it is still being ordered in),
        /// and a gate that spent its three frames on skipped renders closed on a view that had
        /// never drawn — the window's background, for as long as the scene stayed up.
        static let framesPerInvalidation = 60
        private var observers: [NSObjectProtocol] = []

        func renderAgain(frames: Int = StillFrameGate.framesPerInvalidation) { framesLeft = frames }

        /// Resizes, and the window coming back into view (after a Stop rule ordered it out, or a
        /// display woke), are when a held frame can go stale.
        func observe(_ view: SKView) {
            view.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: .main
            ) { [weak self] _ in self?.renderAgain() })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
            ) { [weak self, weak view] note in
                guard let window = view?.window, note.object as? NSWindow === window else { return }
                self?.renderAgain()
            })
        }

        func view(_ view: SKView, shouldRenderAtTime time: TimeInterval) -> Bool {
            // Consume the allowance before the still/paused check: those frames are what
            // gets a newly presented scene onto the screen at all.
            if framesLeft > 0 {
                framesLeft -= 1
                return true
            }
            return !(isStill || isPaused)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
