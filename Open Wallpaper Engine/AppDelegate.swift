//
//  AppDelegate.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/6.
//

import Cocoa
import SwiftUI
import AVKit
import VideoToolbox
import WebKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow!
    
    var mainWindowController: MainWindowController!
    
    var wallpaperWindows: [String: NSWindow] = [:]

    /// Global settings currently holding the wallpapers in `Stop`; see `autoStop`.
    var stopReasons: Set<PlaybackPolicy> = []

    /// The status menu's two playback toggles; see `setStatusMenu`.
    lazy var pauseMenuItem = NSMenuItem(title: String(localized: "Pause"), systemImage: "pause.fill",
                                        action: #selector(pause), keyEquivalent: "p")
    lazy var muteMenuItem = NSMenuItem(title: String(localized: "Mute"), systemImage: "speaker.slash.fill",
                                       action: #selector(mute), keyEquivalent: "m")
    var statusMenuCancellables = Set<AnyCancellable>()

    var contentViewModel = ContentViewModel()
    var wallpaperViewModel = WallpaperViewModel()
    var globalSettingsViewModel = GlobalSettingsViewModel()
    
    var importOpenPanel: NSOpenPanel!
    
    var eventHandler: Any?
    
    static var shared = AppDelegate()
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // VP9 has a hardware decoder on Apple silicon, but VideoToolbox only offers it to
        // AVFoundation once a process asks. Without this call a VP9 .mp4 Workshop video reports
        // `isPlayable == false`, decodes no frame and falls back to its preview; with it, the
        // one VP9 wallpaper in the measured library (2560×1080, 60 fps) plays. A no-op on Macs
        // that lack the decoder.
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)

        // 创建设置视窗
        setSettingsWindow()
        
        // 创建桌面壁纸视窗
        syncWallpaperWindows(orderFront: false)

        // 监听显示器连接/断开
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        // A re-downloaded Workshop item replaces its files in place; screens showing it reload.
        NotificationCenter.default.addObserver(
            self, selector: #selector(workshopItemImported(_:)),
            name: .workshopItemImported, object: nil
        )

        // 监听显示器/系统休眠
        // Each sleep notification must be paired with its own wake counterpart:
        // screensDidSleep fires when the displays blank, which happens on its own
        // whenever the Mac is driving external displays and never suspends, and only
        // screensDidWake reports the return. Observing didWake alone leaves playback
        // stopped until the app is restarted.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspaceCenter.addObserver(
                self, selector: #selector(displaysDidSleep), name: name, object: nil)
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspaceCenter.addObserver(
                self, selector: #selector(displaysDidWake), name: name, object: nil)
        }

        // 创建化左上角菜单栏
        setMainMenu()
        
        // 创建化右上角常驻菜单栏
        setStatusMenu()
        
        // 创建主视窗
        self.mainWindowController = MainWindowController()
        
        // 将外部输入传递到壁纸窗口
        AppDelegate.shared.setEventHandler()
    }
    
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let dockMenu = self.statusItem.menu?.copy() as! NSMenu?
        dockMenu?.items.removeLast() // Remove `Quit` menu item
        return dockMenu
    }
    
// MARK: - delegate methods
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Safe here, not in the view model's init: setting playVolume touches
        // AppDelegate.shared, which is still being constructed at that point.
        wallpaperViewModel.restoreSavedVolume()

        // Before the windows are shown: a screen whose wallpaper folder is gone loses its
        // window here rather than flashing the "not found" placeholder first.
        if wallpaperViewModel.revalidateAssignments() {
            syncWallpaperWindows(orderFront: false)
        }

        refreshPlaceholders()

        // 显示桌面壁纸
        for (_, window) in self.wallpaperWindows {
            window.orderFront(nil)
        }
        
        if globalSettingsViewModel.isFirstLaunch {
            self.mainWindowController.window.center()
            self.mainWindowController.window.makeKeyAndOrderFront(nil)
        }
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !self.mainWindowController.window.isVisible && !settingsWindow.isVisible {
            self.mainWindowController.window?.makeKeyAndOrderFront(nil)
        }
        
        return true
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        restoreOSWallpapers()

        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        do {
            let filesURL = try FileManager.default.contentsOfDirectory(at: cacheDirectory,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: .skipsHiddenFiles)
            for url in filesURL {
                if url.lastPathComponent.contains("staticWP") {
                    try FileManager.default.removeItem(at: url)
                }
            }
        } catch {
            print(error)
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

// MARK: - misc methods
    @objc func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // The window is kept when closed, so SwiftUI's onAppear does not fire again on a reopen;
        // read the login-item state here, where it may have changed behind the app's back.
        globalSettingsViewModel.refreshLoginItemStatus()
        self.settingsWindow.center()
        self.settingsWindow.makeKeyAndOrderFront(nil)
    }
    
    @objc func openMainWindow() {
        self.mainWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @MainActor @objc func toggleFilter() {
        self.contentViewModel.isFilterReveal.toggle()
    }
    
// MARK: Set Settings Window
    func setSettingsWindow() {
        self.settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        self.settingsWindow.title = "Settings"
        self.settingsWindow.isReleasedWhenClosed = false
        self.settingsWindow.toolbarStyle = .preference
        
        // No window delegate: closing Settings used to call `GlobalSettingsViewModel.reset()`,
        // the second half of an OK/Cancel pair over settings that were already saved and applied
        // on every change, so it reverted nothing. Settings now apply instantly and closing the
        // window keeps them, as macOS settings windows do.
        
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        
        toolbar.selectedItemIdentifier = SettingsToolbarIdentifiers.performance
        
        self.settingsWindow.toolbar = toolbar
        self.settingsWindow.contentView = NSHostingView(rootView: SettingsView().environmentObject(self.globalSettingsViewModel))
    }
    
// MARK: Set Wallpaper Windows - One per screen
    private func makeWallpaperWindow(for screen: NSScreen, screenId: String) -> NSWindow {
        let window = WallpaperWindow()
        window.styleMask = [.borderless, .fullSizeContentView]
        // Just below the desktop icons, not at `.desktopWindow`. macOS 27's WindowManager
        // draws the system wallpaper in a window one level above `.desktopWindow`, so a
        // wallpaper window there is covered by it: the scene rendered, but the desktop
        // showed the system picture instead (a still, so it read as a frozen or grey
        // wallpaper). `desktopIconWindow - 1` is above every wallpaper layer and still
        // below the icons, ordinary windows and full-screen apps.
        window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.collectionBehavior = [.stationary, .canJoinAllSpaces]
        window.setFrame(screen.frame, display: true)
        window.isMovable = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.canHide = false
        window.canBecomeVisibleWithoutLogin = true
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        // Black, not the default `windowBackgroundColor`. Whatever a wallpaper has not drawn
        // yet — a web page still loading, a scene still being built off the main thread, a
        // video before its first frame — shows the window's own background, and in the light
        // appearance that is near-white: a wallpaper that is merely late read as "completely
        // white" across the whole desktop.
        window.backgroundColor = .black
        window.contentView = NSHostingView(rootView:
            WallpaperView(viewModel: self.wallpaperViewModel, screenId: screenId)
        )
        return window
    }

    /// Bring the wallpaper windows in line with the connected, enabled screens.
    ///
    /// Incremental on purpose. Closing and recreating every window on each change — as
    /// this used to on every `didChangeScreenParameters`, which also fires for a
    /// resolution change, a rearrangement or Sidecar starting — restarted every video
    /// from frame 0 and had every scene re-parse its package, on screens that had not
    /// changed at all. Now only a removed screen loses its window, only a new one gets
    /// one, and an existing window is just moved if its screen's frame changed.
    ///
    /// `orderFront` is false only at launch, where `applicationDidFinishLaunching`
    /// shows the windows once the placeholder desktop picture is in place.
    func syncWallpaperWindows(orderFront: Bool = true) {
        // The audio screen, or the one the UI is configuring, may have been the one that
        // went away.
        wallpaperViewModel.updateAudioScreen()
        wallpaperViewModel.revalidateSelectedScreen()

        var wanted: [String: NSScreen] = [:]
        // While a `Stop` setting holds there are no wallpaper windows at all; see autoStop.
        for screen in NSScreen.screens where stopReasons.isEmpty {
            let screenId = WallpaperViewModel.screenId(for: screen)
            if wallpaperViewModel.isScreenEnabled(screenId) { wanted[screenId] = screen }
        }

        for (screenId, window) in wallpaperWindows where wanted[screenId] == nil {
            window.close()
            wallpaperWindows[screenId] = nil
        }

        for (screenId, screen) in wanted {
            if let window = wallpaperWindows[screenId] {
                if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
            } else {
                let window = makeWallpaperWindow(for: screen, screenId: screenId)
                wallpaperWindows[screenId] = window
                if orderFront { window.orderFront(nil) }
            }
        }

        // A screen switched off gets its own picture back; one switched on gets its
        // placeholder. At launch this is left to applicationDidFinishLaunching.
        if orderFront { refreshPlaceholders() }
    }

    /// Called when monitors connect/disconnect or change mode.
    @objc func screensChanged() {
        for screen in NSScreen.screens {
            wallpaperViewModel.screenDidAppear(WallpaperViewModel.screenId(for: screen))
        }
        syncWallpaperWindows()
    }

    /// Reload every screen showing a wallpaper whose files were just replaced.
    ///
    /// The wallpaper views reload only when the resolved file URL changes, and an update keeps
    /// the same directory, so without this the screen kept playing the old version — a video
    /// from a file handle to a deleted inode, a scene from a stale parse — until the next launch.
    /// The project is re-read too, since an update can change `file` or `type`.
    @objc func workshopItemImported(_ notification: Notification) {
        guard let directory = notification.userInfo?["directory"] as? URL else { return }
        contentViewModel.refresh()

        let target = directory.standardizedFileURL
        let affected = wallpaperViewModel.wallpapers
            .filter { $0.value.wallpaperDirectory.standardizedFileURL == target }
            .map(\.key)
        guard !affected.isEmpty,
              let data = try? Data(contentsOf: directory.appending(path: "project.json")),
              let project = try? JSONDecoder().decode(WEProject.self, from: data)
        else { return }

        // The menu-bar still is cached per directory and reused while it exists, so without
        // this the updated wallpaper kept tinting the menu bar with the old version's frame.
        for screenId in affected {
            if let old = wallpaperViewModel.wallpapers[screenId] {
                try? FileManager.default.removeItem(at: placeholderURL(for: old.wallpaperDirectory))
            }
        }
        try? FileManager.default.removeItem(at: placeholderURL(for: directory))

        let updated = WEWallpaper(using: project, where: directory)
        for screenId in affected {
            wallpaperViewModel.wallpapers[screenId] = updated
            wallpaperWindows.removeValue(forKey: screenId)?.close()
        }
        syncWallpaperWindows()
    }

    @objc func displaysDidSleep() {
        globalSettingsViewModel.displayAsleepDidChange(asleep: true)
    }

    @objc func displaysDidWake() {
        globalSettingsViewModel.displayAsleepDidChange(asleep: false)
    }

    func setEventHandler() {
        // Only monitor event types we actually handle — .any causes main thread starvation
        let relevantEvents: NSEvent.EventTypeMask = [
            .scrollWheel, .mouseMoved, .mouseEntered, .mouseExited,
            .leftMouseUp, .rightMouseUp, .leftMouseDown,
            .leftMouseDragged, .rightMouseDragged
        ]
        self.eventHandler = NSEvent.addGlobalMonitorForEvents(matching: relevantEvents) { [weak self] event in
            guard let self = self,
                  let frontmostApplication = NSWorkspace.shared.frontmostApplication,
                  frontmostApplication.bundleIdentifier == "com.apple.finder" else { return }

            // Find the WKWebView in whichever wallpaper window the event lands on
            let mouseLocation = NSEvent.mouseLocation
            guard let targetWindow = self.wallpaperWindows.values.first(where: { $0.frame.contains(mouseLocation) }),
                  let webview = targetWindow.contentView?.subviews.first?.subviews.first?
                    .subviews.first(where: { $0 is WKWebView }) else { return }
            // NSHostingView → SwiftUI host → WebWallpaperContainerView → WKWebView. The web view
            // is hidden while paused; forwarding then would only queue input for a frozen page.
            guard !webview.isHidden else { return }
            let event = Self.event(event, relativeTo: targetWindow)

            switch event.type {
            case .scrollWheel:
                webview.scrollWheel(with: event)
            case .mouseMoved:
                webview.mouseMoved(with: event)
            case .mouseEntered:
                webview.mouseEntered(with: event)
            case .mouseExited:
                webview.mouseExited(with: event)
            case .leftMouseUp, .rightMouseUp:
                webview.mouseUp(with: event)
            case .leftMouseDown:
                webview.mouseDown(with: event)
            case .leftMouseDragged, .rightMouseDragged:
                webview.mouseDragged(with: event)
            default:
                break
            }
        }
    }

    /// The same event, expressed in `window`'s coordinates.
    ///
    /// A global monitor's events belong to no window, so their `locationInWindow` is in
    /// screen coordinates, and the web view reads it as window coordinates. The two agree only
    /// on a screen whose origin is (0, 0): on any other display every hover, click, drag and
    /// scroll landed offset by that screen's origin, usually outside the page entirely.
    ///
    /// `-[NSEvent _eventRelativeToWindow:]` is AppKit's own re-targeting call and is the only
    /// route that covers scroll events — NSEvent has no public scroll factory, and setting the
    /// window fields on a CGEvent copy does not attach the window (measured: still nil, still
    /// screen coordinates). Mouse events fall back to the public factory if it ever goes away;
    /// anything else is forwarded as it came.
    private static func event(_ event: NSEvent, relativeTo window: NSWindow) -> NSEvent {
        let selector = NSSelectorFromString("_eventRelativeToWindow:")
        if event.responds(to: selector),
           let relative = event.perform(selector, with: window)?.takeUnretainedValue() as? NSEvent {
            return relative
        }
        switch event.type {
        case .mouseMoved, .leftMouseUp, .rightMouseUp, .leftMouseDown, .leftMouseDragged, .rightMouseDragged:
            return NSEvent.mouseEvent(
                with: event.type,
                location: window.convertPoint(fromScreen: NSEvent.mouseLocation),
                modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: event.eventNumber, clickCount: event.clickCount,
                pressure: event.pressure) ?? event
        default:
            return event
        }
    }
    
    // MARK: - Desktop picture
    //
    // While a wallpaper plays, each screen's real desktop picture is replaced by a still
    // of it so the menu bar is tinted to match; DesktopPictureLedger remembers the user's
    // own picture per screen and decides what to put back.

    private var currentDesktopPictures: [String: URL?] {
        Dictionary(uniqueKeysWithValues: NSScreen.screens.map {
            (WallpaperViewModel.screenId(for: $0), NSWorkspace.shared.desktopImageURL(for: $0))
        })
    }

    /// Record each screen's current picture as the user's own, unless it is ours.
    func captureOSWallpapers() {
        let defaults = UserDefaults.standard
        let ledger = DesktopPictureLedger.capture(current: currentDesktopPictures,
                                                  into: DesktopPictureLedger.load(),
                                                  legacy: defaults.url(forKey: DesktopPictureLedger.legacyKey))
        DesktopPictureLedger.store(ledger)
        defaults.removeObject(forKey: DesktopPictureLedger.legacyKey)
    }

    /// Put the user's own picture back on `screen`, if ours is the one showing.
    func restoreOSWallpaper(on screen: NSScreen) {
        let screenId = WallpaperViewModel.screenId(for: screen)
        let plan = DesktopPictureLedger.restorations(
            current: [screenId: NSWorkspace.shared.desktopImageURL(for: screen)],
            ledger: DesktopPictureLedger.load())
        if let original = plan[screenId] {
            try? NSWorkspace.shared.setDesktopImageURL(original, for: screen)
        }
    }

    func restoreOSWallpapers() {
        NSScreen.screens.forEach(restoreOSWallpaper(on:))
    }

    /// Give every screen the placeholder for *its own* wallpaper, and give screens without
    /// one their own picture back. `wallpapers` lets the `$wallpapers` subscriber pass the
    /// incoming value: `@Published` emits before the property itself is updated.
    func refreshPlaceholders(with wallpapers: [String: WEWallpaper]? = nil) {
        let assignments = wallpapers ?? wallpaperViewModel.wallpapers
        captureOSWallpapers()
        // The tint toggle used to be consulted only by the toggle's own handler, so the
        // next wallpaper change or launch put the placeholder straight back.
        guard globalSettingsViewModel.settings.adjustMenuBarTint else {
            restoreOSWallpapers()
            return
        }
        for screen in NSScreen.screens {
            let screenId = WallpaperViewModel.screenId(for: screen)
            if wallpaperViewModel.isScreenEnabled(screenId), let wallpaper = assignments[screenId] {
                setPlaceholderWallpaper(with: wallpaper, on: screen)
            } else {
                restoreOSWallpaper(on: screen)
            }
        }
    }

    /// A video contributes a frame of itself; anything else — and a video that cannot be
    /// decoded — its preview image. Scenes used to contribute nothing, so after switching
    /// from a video to a scene the menu bar kept the old video's colours. The still is
    /// always written as a `staticWP_` file, never the preview set directly: that prefix
    /// is how the ledger tells our pictures from the user's.
    private func placeholderURL(for directory: URL) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "staticWP_\(directory.hashValue).tiff")
    }

    private func setPlaceholderWallpaper(with wallpaper: WEWallpaper, on screen: NSScreen) {
        let url = placeholderURL(for: wallpaper.wallpaperDirectory)
        // Two screens showing the same wallpaper share one still.
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen)
            return
        }

        // The video frame below arrives asynchronously, and a still for a wallpaper the
        // screen no longer shows must not land after the newer one: switching quickly from a
        // video to anything else left the menu bar tinted by the video. Checked on the main
        // queue at the moment of setting, against the assignment as it is by then. Only on
        // the asynchronous paths: the synchronous one runs from the `$wallpapers` subscriber,
        // which `@Published` calls before the new value is stored.
        let screenId = WallpaperViewModel.screenId(for: screen)
        let isStillWanted = { [weak self] () -> Bool in
            guard let self, self.globalSettingsViewModel.settings.adjustMenuBarTint,
                  self.wallpaperViewModel.isScreenEnabled(screenId) else { return false }
            return self.wallpaperViewModel.wallpapers[screenId]?.wallpaperDirectory == wallpaper.wallpaperDirectory
        }

        let showPreview = { [weak self] in
            let preview = wallpaper.wallpaperDirectory.appending(path: wallpaper.project.preview)
            if !wallpaper.project.preview.isEmpty,
               let data = NSImage(contentsOf: preview)?.tiffRepresentation,
               (try? data.write(to: url, options: .atomic)) != nil {
                try? NSWorkspace.shared.setDesktopImageURL(url, for: screen)
            } else {
                self?.restoreOSWallpaper(on: screen)
            }
        }

        // Lowercased: WEProject.type is the author's spelling ("Video" occurs).
        guard wallpaper.project.type.lowercased() == "video" else {
            showPreview()
            return
        }
        let asset = AVAsset(url: wallpaper.wallpaperDirectory.appending(component: wallpaper.project.file))
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true

        let time = CMTimeMake(value: 1, timescale: 1) // 第一帧的时间
        imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, error in
            guard let cgImage = cgImage,
                  let data = NSImage(cgImage: cgImage, size: .zero).tiffRepresentation,
                  (try? data.write(to: url, options: .atomic)) != nil else {
                if let error = error { print(error) }
                DispatchQueue.main.async { if isStillWanted() { showPreview() } }
                return
            }
            DispatchQueue.main.async {
                guard isStillWanted() else { return }
                try? NSWorkspace.shared.setDesktopImageURL(url, for: screen)
            }
        }
    }
}

/// Non-interactive window that stays behind all other windows.
class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum SettingsToolbarIdentifiers {
    static let performance = NSToolbarItem.Identifier(rawValue: "performance")
    static let general = NSToolbarItem.Identifier(rawValue: "general")
    static let about = NSToolbarItem.Identifier(rawValue: "about")
}
