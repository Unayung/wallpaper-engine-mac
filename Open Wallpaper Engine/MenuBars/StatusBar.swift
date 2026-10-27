//
//  Status.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/8.
//

import Cocoa
import Combine

extension AppDelegate {
    /// Menu-bar action: the user deliberately silencing the wallpaper.
    @objc func mute() {
        self.wallpaperViewModel.clearAutoMute()
        self.wallpaperViewModel.playVolume = 0
    }

    /// Menu-bar action: the user deliberately bringing the sound back.
    @objc func unmute() {
        let last = self.wallpaperViewModel.lastPlayVolume
        self.wallpaperViewModel.clearAutoMute()
        self.wallpaperViewModel.playVolume = last == 0 ? 1 : last
    }

    /// Mute driven by a global setting (another app focused, running on battery, …).
    /// Puts the user's own volume back once the last such setting lets go, so a wallpaper
    /// the user muted on purpose does not return with sound.
    func autoMute(_ reason: PlaybackPolicy) {
        self.wallpaperViewModel.autoMute(reason)
    }

    func autoUnmute(_ reason: PlaybackPolicy) {
        self.wallpaperViewModel.autoUnmute(reason)
    }

    /// Menu-bar action: the user's own pause, which no global setting will undo.
    @objc func pause() {
        self.wallpaperViewModel.userPause()
    }

    /// Menu-bar action: the user's own resume.
    @objc func resume() {
        self.wallpaperViewModel.userResume()
        // Resume clears every pause reason because it must visibly do something; a `Stop`
        // rule is a pause that also closed the windows, so it has to be lifted with them or
        // Resume would report playing over an empty desktop.
        if !stopReasons.isEmpty {
            stopReasons.removeAll()
            syncWallpaperWindows()
        }
    }

    /// Pause driven by a global setting. Never call `pause()` from a policy path: that
    /// records a user decision, which the setting's own release would then not undo.
    func autoPause(_ reason: PlaybackPolicy) {
        self.wallpaperViewModel.autoPause(reason)
    }

    func autoResume(_ reason: PlaybackPolicy) {
        self.wallpaperViewModel.autoResume(reason)
    }

    /// `Stop (free memory)` from a global setting. Always paired with `autoPause` by the
    /// caller.
    ///
    /// The windows are closed and dropped, not merely ordered out: an ordered-out window
    /// keeps its hosting view, and with it the AVPlayer and its decoded frames, the scene's
    /// textures or the web content process, so "free memory" freed nothing. The desktop
    /// shows the placeholder still meanwhile, and the windows are rebuilt from the
    /// assignments when the last `Stop` lets go.
    func autoStop(_ reason: PlaybackPolicy) {
        let wasStopped = !stopReasons.isEmpty
        guard stopReasons.insert(reason).inserted, !wasStopped else { return }
        syncWallpaperWindows()
    }

    func autoUnstop(_ reason: PlaybackPolicy) {
        guard stopReasons.remove(reason) != nil, stopReasons.isEmpty else { return }
        syncWallpaperWindows()
    }

    @objc func takeScreenshot() {
        try! Process.run(URL(filePath: "/usr/sbin/screencapture"), arguments: ["-Cmup", "~/Picturesscreenshot.png"])
    }

    @objc func browseWorkshop() {
        // Change tab selection to `Workshop`
        self.contentViewModel.topTabBarSelection = 1
        openMainWindow()
    }

    @objc func openSupportWebpage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/haren724/open-wallpaper-engine-mac/wiki")!)
    }

    @objc func selectRecentWallpaper(_ sender: NSMenuItem) {
        guard let wallpaper = sender.representedObject as? WEWallpaper else { return }
        wallpaperViewModel.nextCurrentWallpaper = wallpaper
    }

    func buildRecentWallpapersMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Recent Wallpapers"))
        // Checked again here, not only at load: a folder can vanish while the app runs.
        let recents = wallpaperViewModel.recentWallpapers.filter(WallpaperViewModel.stillExists)

        if recents.isEmpty {
            menu.addItem(NSMenuItem(title: String(localized: "No recent wallpapers"), action: nil, keyEquivalent: ""))
        } else {
            for wallpaper in recents {
                let title = wallpaper.project.title.isEmpty ? "Untitled" : wallpaper.project.title
                let typeLabel = wallpaper.project.type.isEmpty ? "" : " (\(wallpaper.project.type.capitalized))"
                let item = NSMenuItem(title: "\(title)\(typeLabel)", action: #selector(selectRecentWallpaper(_:)), keyEquivalent: "")
                item.representedObject = wallpaper
                item.target = self
                menu.addItem(item)
            }
        }

        return menu
    }

    func setStatusMenu() {
        // Recent Wallpapers Submenu
        let recentWallpapersMenuItem = NSMenuItem(title: String(localized: "Recent Wallpapers"), action: nil, keyEquivalent: "")
        recentWallpapersMenuItem.submenu = buildRecentWallpapersMenu()

        let menu = NSMenu()
        menu.delegate = self
        menu.items = [
            .init(title: String(localized: "Show Open Wallpaper Engine"),
                  systemImage: "photo",
                  action: #selector(openMainWindow),
                  keyEquivalent: "o"),

            recentWallpapersMenuItem,

            .separator(),

            .init(title: String(localized: "Browse Workshop"),
                  systemImage: "globe",
                  action: #selector(browseWorkshop),
                  keyEquivalent: "w"),

            .init(title: String(localized: "Settings"),
                  systemImage: "gearshape.fill",
                  action: #selector(openSettingsWindow),
                  keyEquivalent: ","),

            .separator(),

            .init(title: String(localized: "Support & FAQ"),
                  systemImage: "person.fill.questionmark",
                  action: #selector(openSupportWebpage),
                  keyEquivalent: "i"),

            .separator(),

            muteMenuItem,

            pauseMenuItem,

            .init(title: String(localized: "Quit"),
                  systemImage: "power",
                  action: #selector(NSApplication.terminate(_:)),
                  keyEquivalent: "q")
        ]

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.menu = menu

        // The two toggles are kept by reference and edited in place. They used to be
        // found by comparing titles against the English literals "Pause" and "Mute",
        // which never matched under zh-Hans (暂停, 静音), so the menu could not resume;
        // and the replacement items were built without their key equivalents.
        wallpaperViewModel.$playRate
            .sink { [weak self] rate in self?.updatePauseMenuItem(paused: rate == 0) }
            .store(in: &statusMenuCancellables)
        wallpaperViewModel.$playVolume
            .sink { [weak self] volume in self?.updateMuteMenuItem(muted: volume == 0) }
            .store(in: &statusMenuCancellables)

        if let button = self.statusItem.button {
            if let image = NSImage(named: "we.logo") {
                image.isTemplate = true
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "play.desktopcomputer", accessibilityDescription: nil)
            }
        }
    }
}

extension AppDelegate {
    func updatePauseMenuItem(paused: Bool) {
        pauseMenuItem.title = paused ? String(localized: "Resume") : String(localized: "Pause")
        pauseMenuItem.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                      accessibilityDescription: nil)
        pauseMenuItem.action = paused ? #selector(resume) : #selector(pause)
    }

    func updateMuteMenuItem(muted: Bool) {
        muteMenuItem.title = muted ? String(localized: "Unmute") : String(localized: "Mute")
        muteMenuItem.image = NSImage(systemSymbolName: muted ? "speaker.fill" : "speaker.slash.fill",
                                     accessibilityDescription: nil)
        muteMenuItem.action = muted ? #selector(unmute) : #selector(mute)
    }
}

// MARK: - NSMenuDelegate — refresh Recent Wallpapers on menu open

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Update the Recent Wallpapers submenu each time the status bar menu opens
        if let recentItem = menu.items.first(where: { $0.title == String(localized: "Recent Wallpapers") }) {
            recentItem.submenu = buildRecentWallpapersMenu()
        }
    }
}
