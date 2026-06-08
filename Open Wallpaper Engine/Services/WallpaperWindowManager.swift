import Cocoa
import SwiftUI

final class WallpaperWindowManager {

    private(set) var windows: [String: NSWindow] = [:]
    private let viewModel: WallpaperViewModel
    private var screenChangeObserver: NSObjectProtocol?
    private var appActivateObserver: NSObjectProtocol?

    init(viewModel: WallpaperViewModel) {
        self.viewModel = viewModel
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.screensChanged() }

        // Stage Manager switches app groups without changing Space — force compositor
        // to redraw wallpaper windows in case of visual-only (non-AVPlayer-level) freeze
        appActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.forceCompositorRedraw() }
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appActivateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

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

    private func forceCompositorRedraw() {
        for window in windows.values {
            window.contentView?.displayIfNeeded()
            window.update()
        }
    }

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
        // .fullScreenAuxiliary keeps the window visible during Stage Manager/full-screen transitions
        window.collectionBehavior    = [.stationary, .canJoinAllSpaces, .fullScreenAuxiliary]
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
