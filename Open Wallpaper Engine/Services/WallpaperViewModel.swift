//
//  WallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/14.
//

import SwiftUI

/// Provide Wallpaper Database for WallpaperView and ContentView etc.
class WallpaperViewModel: ObservableObject {
    @Published var nextCurrentWallpaper: WEWallpaper =
    WEWallpaper(using: .invalid, where: Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!) {
        willSet {
            // Lowercased because Workshop authors write the type in either case (three
            // library wallpapers say "Web") and WallpaperView dispatches on
            // `type.lowercased()`. Comparing the raw string let a "Web" wallpaper skip this
            // gate and load straight into the WKWebView with universal file-URL access.
            if ["web", "application"].contains(newValue.project.type.lowercased()) {
                if let trustedWallpapers = UserDefaults.standard.array(forKey: "TrustedWallpapers") as? [String],
                   trustedWallpapers.contains(newValue.wallpaperDirectory.path(percentEncoded: false)) {
                    self.setWallpaper(newValue, for: selectedScreenId)
                } else {
                    AppDelegate.shared.contentViewModel.warningUnsafeWallpaperModal(which: newValue, for: selectedScreenId)
                }
            } else {
                self.setWallpaper(newValue, for: selectedScreenId)
            }
        }
    }

    /// Per-screen wallpaper assignments, keyed by CGDirectDisplayID as String.
    @Published var wallpapers: [String: WEWallpaper] = [:] {
        didSet { saveWallpapers() }
    }

    /// Screens where wallpaper display is enabled.
    @Published var enabledScreens: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(enabledScreens), forKey: "EnabledScreens")
            updateAudioScreen()
        }
    }

    /// Screens the user explicitly switched off in Display Settings. Kept apart from
    /// `enabledScreens` because "off" has two meanings — turned off on purpose, or simply
    /// never configured — and only the second may be switched on automatically.
    @Published var userDisabledScreens: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(userDisabledScreens), forKey: Self.disabledScreensKey)
        }
    }
    static let disabledScreensKey = "DisabledScreens"

    /// The one screen whose wallpaper is heard.
    ///
    /// Every wallpaper window used to play its own audio at `playVolume`: the same video
    /// on two displays played its soundtrack twice, slightly out of step, at about double
    /// loudness, and two different videos mixed both soundtracks (41 of the library's 52
    /// videos carry an audio track). Wallpaper Engine's own answer is one audio source,
    /// and the menu-bar display is the stable choice for it; failing that, the first
    /// enabled display that is connected. The rest play muted.
    @Published private(set) var audioScreenId: String?

    func updateAudioScreen() {
        let connected = NSScreen.screens.map { Self.screenId(for: $0) }
        let id = connected.first(where: { enabledScreens.contains($0) })
        if id != audioScreenId { audioScreenId = id }
    }

    /// The volume a wallpaper on `screenId` should play at.
    func effectiveVolume(for screenId: String) -> Float {
        screenId == audioScreenId ? playVolume : 0
    }

    /// The screen currently selected in the UI for configuration.
    @Published var selectedScreenId: String = ""

    /// Point the UI back at the main screen when the selected one has been disconnected.
    ///
    /// Only set at launch and by the Display Settings picker, so unplugging the selected
    /// display left every later pick — the grid, the Recent menu, the preview pane's edits —
    /// assigned to a screen that was not there: nothing changed on any desktop, and the
    /// wallpaper turned up on that display whenever it was next plugged in.
    func revalidateSelectedScreen() {
        let connected = NSScreen.screens.map { Self.screenId(for: $0) }
        guard !connected.isEmpty, !connected.contains(selectedScreenId) else { return }
        selectedScreenId = Self.mainScreenId()
    }

    static let defaultWallpaper = WEWallpaper(using: .invalid, where: Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!)

    // MARK: - Recent wallpapers

    private static let maxRecents = 10
    private static let recentsKey = "RecentWallpapers"

    @Published var recentWallpapers: [WEWallpaper] = []

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: Self.recentsKey),
              let saved = try? JSONDecoder().decode([WEWallpaper].self, from: data) else { return }
        recentWallpapers = saved.filter { $0.project != .invalid && Self.stillExists($0) }
    }

    /// False once the wallpaper's folder (or its project.json) is gone, e.g. deleted in
    /// Finder or by a previous version that did not prune recents on unsubscribe. Choosing
    /// such an entry would assign a missing directory to the screen.
    static func stillExists(_ wallpaper: WEWallpaper) -> Bool {
        FileManager.default.fileExists(
            atPath: wallpaper.wallpaperDirectory.appending(path: "project.json").path(percentEncoded: false)
        )
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recentWallpapers) {
            UserDefaults.standard.set(data, forKey: Self.recentsKey)
        }
    }

    func addToRecents(_ wallpaper: WEWallpaper) {
        guard wallpaper.project != .invalid else { return }
        recentWallpapers.removeAll { $0.wallpaperDirectory == wallpaper.wallpaperDirectory }
        recentWallpapers.insert(wallpaper, at: 0)
        if recentWallpapers.count > Self.maxRecents {
            recentWallpapers = Array(recentWallpapers.prefix(Self.maxRecents))
        }
        saveRecents()
    }

    // MARK: - Wallpaper access

    /// Convenience: wallpaper for the currently selected screen in the UI.
    var currentWallpaper: WEWallpaper {
        get {
            wallpapers[selectedScreenId] ?? Self.defaultWallpaper
        }
        set {
            // The unsafe-wallpaper sheet's Proceed lands here, possibly long after the choice
            // was made; it goes to the screen it was chosen for. See warningUnsafeWallpaperModal.
            let target = AppDelegate.shared.contentViewModel.unsafeTargetScreen(for: newValue)
            setWallpaper(newValue, for: target ?? selectedScreenId)
        }
    }

    /// Get wallpaper for a specific screen.
    func wallpaper(for screenId: String) -> WEWallpaper {
        wallpapers[screenId] ?? Self.defaultWallpaper
    }

    /// Set wallpaper for a specific screen.
    func setWallpaper(_ wallpaper: WEWallpaper, for screenId: String) {
        // A tile whose project.json did not decode has no type to dispatch on, so
        // assigning it would only swap a working wallpaper for the "not found" placeholder
        // (and switch an untouched display on to show it). The preview pane already
        // refused; this is the one place every other path — the grid's double-click, the
        // Recent menu, an edit in the preview pane — goes through.
        guard wallpaper.project != .invalid else { return }
        wallpapers[screenId] = wallpaper
        addToRecents(wallpaper)
        // Choosing a wallpaper for a display nobody has turned off is reason enough to
        // show it there; this is how a newly connected display gets switched on now that
        // connecting one no longer does so by itself.
        if !enabledScreens.contains(screenId), !userDisabledScreens.contains(screenId) {
            enabledScreens.insert(screenId)
            AppDelegate.shared.syncWallpaperWindows()
        }
    }

    func isScreenEnabled(_ screenId: String) -> Bool {
        enabledScreens.contains(screenId)
    }

    func toggleScreen(_ screenId: String) {
        if enabledScreens.contains(screenId) {
            enabledScreens.remove(screenId)
            userDisabledScreens.insert(screenId)
        } else {
            enabledScreens.insert(screenId)
            userDisabledScreens.remove(screenId)
        }
        AppDelegate.shared.syncWallpaperWindows()
    }

    /// Decide whether a display that has just appeared should show a wallpaper.
    ///
    /// Only when it has one assigned and the user has not switched it off. Enabling every
    /// connected display undid the user's own toggle on every resolution change, hot-plug
    /// or Sidecar session, and a display with no assignment was given the bundled
    /// `WallpaperNotFound.mp4` over its desktop — `EnabledScreens` on the machine this was
    /// found on held ten display ids against three assignments.
    func screenDidAppear(_ screenId: String) {
        guard !enabledScreens.contains(screenId),
              !userDisabledScreens.contains(screenId),
              wallpapers[screenId] != nil else { return }
        enabledScreens.insert(screenId)
    }

    /// Bring the saved per-screen assignments up to date with the library on disk.
    ///
    /// `ScreenWallpapers` stores a whole `WEProject` snapshot per screen, taken when the
    /// wallpaper was chosen, and nothing re-read it: a Workshop update that changed `file`
    /// or `type` while the app was not running went on loading the old file name, and a
    /// folder deleted in Finder came back as the "not found" placeholder over the desktop on
    /// every launch. The snapshot is refreshed from the current `project.json`; an assignment
    /// whose folder or manifest is gone is dropped — the same test the recents use — and its
    /// screen given back to the desktop picture (it switches on again when a wallpaper is
    /// chosen for it). A manifest that is there but no longer decodes keeps its snapshot,
    /// since that is more likely a half-finished write than a deletion.
    ///
    /// Called from applicationDidFinishLaunching, not `init()`, like `restoreSavedVolume`.
    /// Returns true when anything changed.
    @discardableResult
    func revalidateAssignments() -> Bool {
        var updated = wallpapers
        var dropped: [String] = []
        var refreshed = false
        for (screenId, wallpaper) in wallpapers {
            guard wallpaper.project != .invalid, Self.stillExists(wallpaper) else {
                updated[screenId] = nil
                dropped.append(screenId)
                continue
            }
            if let data = try? Data(contentsOf: wallpaper.wallpaperDirectory.appending(path: "project.json")),
               let project = try? JSONDecoder().decode(WEProject.self, from: data),
               project != wallpaper.project {
                updated[screenId] = WEWallpaper(using: project, where: wallpaper.wallpaperDirectory)
                refreshed = true
            }
        }
        // One assignment, and none when nothing changed: every write is a save and a
        // `$wallpapers` emission, which re-derives every screen's menu-bar still.
        guard refreshed || !dropped.isEmpty else { return false }
        wallpapers = updated
        // Not a user decision, so not recorded in `userDisabledScreens`.
        if !dropped.isEmpty { enabledScreens.subtract(dropped) }
        return true
    }

    /// Remove a wallpaper from all screens and from the recents (e.g., when unsubscribing).
    /// Recents used to keep it, so the status-bar menu went on offering a deleted folder.
    func removeWallpaperFromAllScreens(directory: URL) {
        for (key, wp) in wallpapers {
            if wp.wallpaperDirectory == directory {
                wallpapers[key] = Self.defaultWallpaper
            }
        }
        let before = recentWallpapers.count
        recentWallpapers.removeAll { $0.wallpaperDirectory == directory }
        if recentWallpapers.count != before { saveRecents() }
    }

    // MARK: - Playback state
    //
    // `playRate` and `playVolume` are the effective values every wallpaper mirrors. They
    // are *derived*: the user's own choice, overridden by whichever global settings are
    // currently in force. Each setting only ever adds or removes its own entry in the
    // sets below, so two settings cannot undo each other and neither can undo the user —
    // previously the focus rule's "resume" fired on every click on the desktop and
    // un-paused a wallpaper the user had paused, and waking the displays resumed one the
    // focus rule had paused behind Safari.

    /// The rate the user chose with the slider. Never 0: pausing is `isUserPaused`.
    private(set) var userPlayRate: Float = 1.0
    /// The user paused from the menu or by dragging the speed slider to 0.
    private(set) var isUserPaused = false
    /// Global settings currently pausing playback (the `Pause` and `Stop` choices).
    private(set) var autoPauseReasons: Set<PlaybackPolicy> = []
    /// Global settings currently silencing playback (the `Mute` choice).
    private(set) var autoMuteReasons: Set<PlaybackPolicy> = []

    /// Set while `playRate`/`playVolume` are being written as the *result* of the state
    /// above, so their observers can tell that from the user moving a slider.
    private var isApplyingDerivedValue = false

    var isPaused: Bool { isUserPaused || !autoPauseReasons.isEmpty }

    private func applyPlayRate() {
        let rate = isPaused ? 0 : userPlayRate
        guard rate != playRate else { return }
        isApplyingDerivedValue = true
        playRate = rate
        isApplyingDerivedValue = false
    }

    /// The user's own pause. Survives every global setting coming and going.
    func userPause() {
        isUserPaused = true
        applyPlayRate()
    }

    /// The user's own resume. Overrides the global settings too, the way `Unmute`
    /// overrides an automatic mute: the menu shows `Resume` whenever nothing is playing,
    /// and choosing it must do something. A setting re-engages on its next trigger.
    /// A no-op when already playing, so it can never disturb a non-1× rate.
    func userResume() {
        guard isPaused else { return }
        isUserPaused = false
        autoPauseReasons.removeAll()
        applyPlayRate()
    }

    func autoPause(_ reason: PlaybackPolicy) {
        guard autoPauseReasons.insert(reason).inserted else { return }
        applyPlayRate()
    }

    func autoResume(_ reason: PlaybackPolicy) {
        guard autoPauseReasons.remove(reason) != nil else { return }
        applyPlayRate()
    }

    func autoMute(_ reason: PlaybackPolicy) {
        let wasMuted = isAutoMuted
        guard autoMuteReasons.insert(reason).inserted, !wasMuted else { return }
        volumeBeforeAutoMute = playVolume
        isApplyingDerivedValue = true
        playVolume = 0
        isApplyingDerivedValue = false
    }

    func autoUnmute(_ reason: PlaybackPolicy) {
        guard autoMuteReasons.remove(reason) != nil, !isAutoMuted else { return }
        isApplyingDerivedValue = true
        playVolume = volumeBeforeAutoMute
        isApplyingDerivedValue = false
    }

    /// The user taking the volume into their own hands ends every automatic mute.
    func clearAutoMute() {
        autoMuteReasons.removeAll()
    }

    @Published public var playRate: Float = 1.0 {
        didSet {
            // Anything other than applyPlayRate writing here is the speed slider in the
            // main window: a user decision, which wins over the global settings exactly
            // as `Resume` does.
            guard !isApplyingDerivedValue, playRate != oldValue else { return }
            if playRate == 0 {
                isUserPaused = true
            } else {
                userPlayRate = playRate
                isUserPaused = false
                autoPauseReasons.removeAll()
            }
        }
    }

    static let volumeKey = "PlayVolume"

    /// True while the volume was silenced by a global setting (app focus, battery, …)
    /// rather than by the user, so it can be put back exactly as the user left it.
    var isAutoMuted: Bool { !autoMuteReasons.isEmpty }
    var volumeBeforeAutoMute: Float = 1.0

    /// Last volume the user could actually hear. Never 0, so "Unmute" has something
    /// to go back to after an explicit mute.
    var lastPlayVolume: Float = 1.0
    @Published public var playVolume: Float = 1.0 {
        didSet {
            // The volume slider moving while a setting has the sound off: the user wins.
            if !isApplyingDerivedValue && isAutoMuted && playVolume != oldValue {
                autoMuteReasons.removeAll()
            }
            // Only remember audible volumes, so Unmute never restores silence.
            if oldValue != 0 { self.lastPlayVolume = oldValue }
            // Only the user's own volume is worth restoring next launch. Persisting the 0
            // an automatic mute writes meant that quitting while another app had focus —
            // from the status menu, which does not activate us, or by logging out — came
            // back permanently silent: the next launch has no record that the 0 was
            // automatic, so no autoUnmute ever lifts it.
            if !isAutoMuted {
                UserDefaults.standard.set(playVolume, forKey: Self.volumeKey)
            }
        }
    }

    init() {
        // Load per-screen wallpapers
        if let data = UserDefaults.standard.data(forKey: "ScreenWallpapers"),
           let saved = try? JSONDecoder().decode([String: WEWallpaper].self, from: data) {
            // Filter out any compound keys (screenId_spaceId) from previous per-space experiment
            self.wallpapers = saved.filter { !$0.key.contains("_") }
        }
        // Migrate legacy single wallpaper
        else if let json = UserDefaults.standard.data(forKey: "CurrentWallpaper"),
                let wallpaper = try? JSONDecoder().decode(WEWallpaper.self, from: json) {
            let mainId = Self.mainScreenId()
            self.wallpapers = [mainId: wallpaper]
        }

        // Load enabled screens (default: all connected screens enabled)
        if let saved = UserDefaults.standard.array(forKey: "EnabledScreens") as? [String] {
            self.enabledScreens = Set(saved)
        } else {
            self.enabledScreens = Set(NSScreen.screens.map { Self.screenId(for: $0) })
        }

        if let saved = UserDefaults.standard.array(forKey: Self.disabledScreensKey) as? [String] {
            self.userDisabledScreens = Set(saved)
        } else {
            // First run with the distinction. Every display that ever connected used to be
            // force-enabled, so a connected one that is off now was turned off by hand.
            // Enabled ids that are neither assigned nor connected are leftovers of that
            // force-enabling; dropping them keeps those displays from coming back with the
            // "not found" placeholder the next time they are plugged in.
            let connected = Set(NSScreen.screens.map { Self.screenId(for: $0) })
            self.userDisabledScreens = connected.subtracting(enabledScreens)
            self.enabledScreens = enabledScreens.filter { wallpapers[$0] != nil || connected.contains($0) }
        }

        // Default selected screen to main
        self.selectedScreenId = Self.mainScreenId()

        // Load recent wallpapers
        loadRecents()

        updateAudioScreen()
    }

    /// Put back the volume the user left last session.
    ///
    /// Called from applicationDidFinishLaunching rather than `init()`. Assigning
    /// `playVolume` used to fire a `willSet` that edited the status menu through
    /// `AppDelegate.shared`, and this view model is built *by* `AppDelegate.init()`, so
    /// that re-entered the `dispatch_once` for `shared` and trapped. The menu now observes
    /// `$playVolume` itself, but keep AppDelegate-dependent work out of `init` all the same.
    ///
    /// By the time this runs a policy may already hold an automatic mute: the
    /// `didFinishLaunching` observer of `GlobalSettingsViewModel` is registered while
    /// `AppDelegate` is being built, before the delegate is set, so it runs first and its
    /// condition monitor reports battery power (or a focused app) straight away. Writing
    /// `playVolume` here as a plain assignment then read as the user moving the slider and
    /// cleared every auto-mute reason — a laptop launched on battery played aloud. And with
    /// no saved key the old branch stashed the *current* volume, the auto-mute's 0, as the
    /// one to come back to, so the first launch on battery stayed silent for good (and
    /// persisted that 0 once the mute lifted). So: the saved volume (1.0 when there is
    /// none) becomes what an auto-mute restores, and it is only applied now if nothing is
    /// holding the sound off, as a derived write rather than a user one.
    func restoreSavedVolume() {
        let restored: Float = UserDefaults.standard.object(forKey: Self.volumeKey) != nil
            ? UserDefaults.standard.float(forKey: Self.volumeKey) : 1.0
        volumeBeforeAutoMute = restored
        if !isAutoMuted {
            isApplyingDerivedValue = true
            playVolume = restored
            isApplyingDerivedValue = false
        }
        // After the write: `playVolume.didSet` records the value it replaced, which is the
        // 1.0 default, not anything the user chose.
        if restored != 0 { lastPlayVolume = restored }
    }

    // MARK: - Screen ID helpers

    static func screenId(for screen: NSScreen) -> String {
        let displayId = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        return String(displayId)
    }

    static func mainScreenId() -> String {
        guard let main = NSScreen.main else { return "0" }
        return screenId(for: main)
    }

    static func screenName(for screen: NSScreen) -> String {
        screen.localizedName
    }

    // MARK: - Persistence

    private func saveWallpapers() {
        if let data = try? JSONEncoder().encode(wallpapers) {
            UserDefaults.standard.set(data, forKey: "ScreenWallpapers")
        }
        // Keep legacy key updated for backward compat
        if let data = try? JSONEncoder().encode(currentWallpaper) {
            UserDefaults.standard.set(data, forKey: "CurrentWallpaper")
        }
    }
}
