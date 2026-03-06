//
//  AppDelegate.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/6.
//

import Cocoa
import SwiftUI
import AVKit
import WebKit

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow!
    
    var mainWindowController: MainWindowController!
    
    var wallpaperWindows: [String: NSWindow] = [:]
    
    var contentViewModel = ContentViewModel()
    var wallpaperViewModel = WallpaperViewModel()
    var globalSettingsViewModel = GlobalSettingsViewModel()
    
    var importOpenPanel: NSOpenPanel!
    
    var eventHandler: Any?
    
    static var shared = AppDelegate()
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 创建设置视窗
        setSettingsWindow()
        
        // 创建桌面壁纸视窗
        setWallpaperWindows()

        // 监听显示器连接/断开
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        
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
        saveCurrentWallpaper()
        AppDelegate.shared.setPlacehoderWallpaper(with: wallpaperViewModel.currentWallpaper)

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
        if let wallpaper = UserDefaults.standard.url(forKey: "OSWallpaper") {
            for screen in NSScreen.screens {
                try? NSWorkspace.shared.setDesktopImageURL(wallpaper, for: screen)
            }
        }
        
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
        
        self.settingsWindow.delegate = self
        
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        
        toolbar.selectedItemIdentifier = SettingsToolbarIdentifiers.performance
        
        self.settingsWindow.toolbar = toolbar
        self.settingsWindow.contentView = NSHostingView(rootView: SettingsView().environmentObject(self.globalSettingsViewModel))
    }
    
// MARK: Set Wallpaper Windows - One per screen
    func setWallpaperWindows() {
        for screen in NSScreen.screens {
            let screenId = WallpaperViewModel.screenId(for: screen)
            guard wallpaperViewModel.isScreenEnabled(screenId) else { continue }

            let window = NSWindow()
            window.styleMask = [.borderless, .fullSizeContentView]
            window.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.stationary, .canJoinAllSpaces]
            window.setFrame(screen.frame, display: true)
            window.isMovable = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.canHide = false
            window.canBecomeVisibleWithoutLogin = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView:
                WallpaperView(viewModel: self.wallpaperViewModel, screenId: screenId)
            )
            wallpaperWindows[screenId] = window
        }
    }

    /// Rebuild wallpaper windows without changing enabled state.
    func rebuildWallpaperWindows() {
        for (_, window) in wallpaperWindows { window.close() }
        wallpaperWindows.removeAll()
        setWallpaperWindows()
        for (_, window) in wallpaperWindows { window.orderFront(nil) }
    }

    /// Called when monitors connect/disconnect — auto-enables newly connected screens.
    @objc func screensChanged() {
        let connectedIds = Set(NSScreen.screens.map { WallpaperViewModel.screenId(for: $0) })
        for id in connectedIds where !wallpaperViewModel.enabledScreens.contains(id) {
            wallpaperViewModel.enabledScreens.insert(id)
        }
        rebuildWallpaperWindows()
    }
    
    func windowWillClose(_ notification: Notification) {
        globalSettingsViewModel.reset()
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
                  let webview = targetWindow.contentView?.subviews.first?.subviews.first,
                  webview is WKWebView else { return }

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
    
    func saveCurrentWallpaper() {
        guard let mainScreen = NSScreen.main else { return }
        var wallpaper: URL {
            var osWallpaper: URL { NSWorkspace.shared.desktopImageURL(for: mainScreen)! }
            if let wallpaper = UserDefaults.standard.url(forKey: "OSWallpaper") {
                if wallpaper != osWallpaper {
                    if !wallpaper.lastPathComponent.contains("staticWP") {
                        return wallpaper
                    }
                }
            }
            return osWallpaper
        }
        UserDefaults.standard.set(wallpaper, forKey: "OSWallpaper")
    }
    
    func setPlacehoderWallpaper(with wallpaper: WEWallpaper) {
        switch wallpaper.project.type {
        case "video":
            let asset = AVAsset(url: wallpaper.wallpaperDirectory.appending(component: wallpaper.project.file))
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            
            let time = CMTimeMake(value: 1, timescale: 1) // 第一帧的时间
            imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, error in
                if let error = error {
                    print(error)
                } else if let cgImage = cgImage {
                    let nsImage = NSImage(cgImage: cgImage, size: .zero)
                    if let data = nsImage.tiffRepresentation {
                        do {
                            let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "staticWP_\(wallpaper.wallpaperDirectory.hashValue).tiff")
                            try data.write(to: url, options: .atomic)
                            for screen in NSScreen.screens {
                                try NSWorkspace.shared.setDesktopImageURL(url, for: screen)
                            }
                        } catch {
                            print(error)
                        }
                    }
                }
            }
        default:
            return
        }
    }
}

enum SettingsToolbarIdentifiers {
    static let performance = NSToolbarItem.Identifier(rawValue: "performance")
    static let general = NSToolbarItem.Identifier(rawValue: "general")
    static let plugins = NSToolbarItem.Identifier(rawValue: "plugins")
    static let about = NSToolbarItem.Identifier(rawValue: "about")
}
