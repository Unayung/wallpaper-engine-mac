//
//  WallpaperWindowManager.swift
//  Open Wallpaper Engine
//
// Owns every wallpaper NSWindow (one per screen) and reacts to
// monitor connect/disconnect events. AppDelegate delegates all
// wallpaper-window concerns here instead of doing them itself.
//
// Pattern demonstrated:
//   - Single Responsibility: this class does one thing
//   - Dependency Injection: receives WallpaperViewModel in init,
//     does not reach into AppDelegate or any global singleton
//   - Encapsulation: callers only see `windows` (read-only) and
//     the three public methods below
//

import Cocoa
import SwiftUI

final class WallpaperWindowManager {

    private(set) var windows: [String: NSWindow] = [:]
    private let viewModel: WallpaperViewModel
    private var screenChangeObserver: NSObjectProtocol?

    // MARK: - Init / Deinit

    init(viewModel: WallpaperViewModel) {
        self.viewModel = viewModel
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.screensChanged() }
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    func setup() {
        for screen in NSScreen.screens {
            let screenId = WallpaperViewModel.screenId(for: screen)
            guard viewModel.isScreenEnabled(screenId) else { continue }
            windows[screenId] = makeWindow(for: screen, screenId: screenId)
        }
    }

    func showAll() {
        windows.values.forEach { $0.orderFront(nil) }
    }

    func rebuild() {
        windows.values.forEach { $0.close() }
        windows.removeAll()
        setup()
        showAll()
    }

    // MARK: - Private

    private func screensChanged() {
        let connectedIds = Set(NSScreen.screens.map { WallpaperViewModel.screenId(for: $0) })
        for id in connectedIds where !viewModel.enabledScreens.contains(id) {
            viewModel.enabledScreens.insert(id)
        }
        rebuild()
    }

    private func makeWindow(for screen: NSScreen, screenId: String) -> NSWindow {
        let window = WallpaperWindow()
        window.styleMask             = [.borderless, .fullSizeContentView]
        window.level                 = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior    = [.stationary, .canJoinAllSpaces]
        window.isMovable             = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility       = .hidden
        window.canHide               = false
        window.canBecomeVisibleWithoutLogin = true
        window.isReleasedWhenClosed  = false
        window.ignoresMouseEvents    = true
        window.setFrame(screen.frame, display: true)
        window.contentView = NSHostingView(
            rootView: WallpaperView(viewModel: viewModel, screenId: screenId)
        )
        return window
    }
}
