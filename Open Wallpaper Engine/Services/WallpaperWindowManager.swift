import Cocoa
import SwiftUI

final class WallpaperWindowManager {

    private(set) var windows: [String: NSWindow] = [:]
    private let viewModel: WallpaperViewModel
    private var screenChangeObserver: NSObjectProtocol?
    private var appActivateObserver: NSObjectProtocol?
    private var occlusionObservers: [NSObjectProtocol] = []
    // Heartbeat: backstop for any case notifications miss
    private var redrawTimer: DispatchSourceTimer?
    private static let redrawInterval: DispatchTimeInterval = .milliseconds(500)

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
        ) { [weak self] _ in
            WELogger.shared.verbose("compositor redraw — app activation")
            self?.forceCompositorRedraw()
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + WallpaperWindowManager.redrawInterval,
                       repeating: WallpaperWindowManager.redrawInterval)
        timer.setEventHandler { [weak self] in
            WELogger.shared.verbose("compositor redraw — heartbeat")
            self?.forceCompositorRedraw()
        }
        timer.resume()
        redrawTimer = timer
    }

    deinit {
        redrawTimer?.cancel()
        occlusionObservers.forEach { NotificationCenter.default.removeObserver($0) }
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
            // orderFront forces WindowServer to re-evaluate this window's position
            // in the compositor z-stack, potentially breaking a Stage Manager snapshot cache
            window.orderFront(nil)
            guard let contentView = window.contentView else { continue }
            contentView.layer?.setNeedsDisplay()
            contentView.display()
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
        // Fire redraw the moment this window transitions back to visible after a
        // Stage Manager animation — more precise than the heartbeat timer alone
        let obs = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let window, window.occlusionState.contains(.visible) else { return }
            WELogger.shared.verbose("compositor redraw — occlusion became visible (\(screenId))")
            self?.forceCompositorRedraw()
        }
        occlusionObservers.append(obs)
        return window
    }
}