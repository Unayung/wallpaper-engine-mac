import Cocoa

extension AppDelegate {
    @objc func mute() {
        self.wallpaperViewModel.playVolume = 0
    }

    @objc func unmute() {
        self.wallpaperViewModel.playVolume = self.wallpaperViewModel.lastPlayVolume == 0 ? 1 : self.wallpaperViewModel.lastPlayVolume
    }

    @objc func pause() {
        self.wallpaperViewModel.playRate = 0
    }

    @objc func resume() {
        self.wallpaperViewModel.playRate = self.wallpaperViewModel.lastPlayRate == 0 ? 1 : self.wallpaperViewModel.lastPlayRate
    }

    @objc func takeScreenshot() {
        try! Process.run(URL(filePath: "/usr/sbin/screencapture"), arguments: ["-Cmup", "~/Picturesscreenshot.png"])
    }

    @objc func browseWorkshop() {
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
        let recents = wallpaperViewModel.recentWallpapers

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
        let recentWallpapersMenuItem = NSMenuItem(title: String(localized: "Recent Wallpapers"), action: nil, keyEquivalent: "")
        recentWallpapersMenuItem.submenu = buildRecentWallpapersMenu()

        let menu = NSMenu()
        menu.delegate = self
        let isMuted = wallpaperViewModel.playVolume == 0
        let isPaused = wallpaperViewModel.playRate == 0

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

            isMuted
                ? .init(title: String(localized: "Unmute"), systemImage: "speaker.fill", action: #selector(AppDelegate.shared.unmute), keyEquivalent: "m")
                : .init(title: String(localized: "Mute"), systemImage: "speaker.slash.fill", action: #selector(AppDelegate.shared.mute), keyEquivalent: "m"),

            isPaused
                ? .init(title: String(localized: "Resume"), systemImage: "play.fill", action: #selector(resume), keyEquivalent: "p")
                : .init(title: String(localized: "Pause"), systemImage: "pause.fill", action: #selector(pause), keyEquivalent: "p"),

            .init(title: String(localized: "Quit"),
                  systemImage: "power",
                  action: #selector(NSApplication.terminate(_:)),
                  keyEquivalent: "q")
        ]

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.menu = menu

        if let button = self.statusItem.button {
            if let image = NSImage(named: "we.logo") {
                image.isTemplate = true
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "play.desktopcomputer", accessibilityDescription: nil)
            }
        }

        bindMenuLabels()
    }

    // Keep Mute/Unmute and Pause/Resume labels in sync with ViewModel state.
    // The ViewModel only publishes new values; this layer decides what to show.
    private func bindMenuLabels() {
        wallpaperViewModel.$playVolume
            .removeDuplicates { ($0 == 0) == ($1 == 0) } // only react to muted ↔ unmuted transitions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volume in
                guard let menu = self?.statusItem.menu else { return }
                let isMuted = volume == 0
                if let idx = menu.items.firstIndex(where: { $0.title == String(localized: "Mute") || $0.title == String(localized: "Unmute") }) {
                    menu.items[idx] = isMuted
                        ? .init(title: String(localized: "Unmute"), systemImage: "speaker.fill",       action: #selector(AppDelegate.shared.unmute), keyEquivalent: "m")
                        : .init(title: String(localized: "Mute"),   systemImage: "speaker.slash.fill", action: #selector(AppDelegate.shared.mute),   keyEquivalent: "m")
                }
            }
            .store(in: &cancellables)

        wallpaperViewModel.$playRate
            .removeDuplicates { ($0 == 0) == ($1 == 0) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                guard let menu = self?.statusItem.menu else { return }
                let isPaused = rate == 0
                if let idx = menu.items.firstIndex(where: { $0.title == "Pause" || $0.title == "Resume" }) {
                    menu.items[idx] = isPaused
                        ? .init(title: "Resume", systemImage: "play.fill",  action: #selector(AppDelegate.shared.resume), keyEquivalent: "p")
                        : .init(title: "Pause",  systemImage: "pause.fill", action: #selector(AppDelegate.shared.pause),  keyEquivalent: "p")
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: - NSMenuDelegate — refresh Recent Wallpapers on menu open

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if let recentItem = menu.items.first(where: { $0.title == String(localized: "Recent Wallpapers") }) {
            recentItem.submenu = buildRecentWallpapersMenu()
        }
    }
}
