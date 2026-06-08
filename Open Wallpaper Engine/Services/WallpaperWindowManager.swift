import Cocoa
import SwiftUI

final class WallpaperWindowManager {

    private(set) var windows: [String: NSWindow] = [:]
    private let viewModel: WallpaperViewModel
    private var screenChangeObserver: NSObjectProtocol?
    private var appActivateObserver: NSObjectProtocol?
    // Heartbeat: catches compositor freezes that no notification covers
    // (e.g. minimizing a window within the same Stage Manager group)
    private var redrawTimer: DispatchSourceTimer?
    private static let redrawInterval: DispatchTimeInterval = .seconds(2)

    init(viewModel: WallpaperViewModel) {
        self.viewModel = viewModel
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.screensChanged() }

        appActivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.forceCompositorRedraw() }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + WallpaperWindowManager.redrawInterval,
                       repeating: WallpaperWindowManager.redrawInterval)
        timer.setEventHandler { [weak self] in self?.forceCompositorRedraw() }
        timer.resume()
        redrawTimer = timer
    }

    deinit {
        redrawTimer?.cancel()
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
            guard let contentView = window.contentView else { continue }
            contentView.layer?.setNeedsDisplay()
            contentView.display()  // Unconditional — displayIfNeeded only works if dirty flag is set
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
