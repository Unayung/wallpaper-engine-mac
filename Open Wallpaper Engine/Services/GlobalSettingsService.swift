//
//  GlobalSettingsService.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/9/2.
//

import Cocoa
import Combine
import SwiftUI
import ServiceManagement

/// The Performance page's presets. Each is a fixed set of the quality controls, and which one is
/// active is *derived* from the current settings (`GlobalSettings.activeQuality`) rather than
/// stored, so moving any one control afterwards shows the selection falling to "Custom" instead
/// of leaving a preset highlighted that no longer describes what is running.
enum GSQuality: CaseIterable, Hashable {
    case low, medium, high, ultra

    var postProcessing: GSPostProcessingQuality { self == .low ? .disabled : .enabled }

    var textureResolution: GSTextureResolutionQuality {
        switch self {
        case .low: return .highPerformance
        case .medium, .high: return .automatic
        case .ultra: return .highQuality
        }
    }

    /// nil where the preset does not decide it: Low switches effects off altogether, so whether
    /// a reflection pass would be built under them is moot, and Low leaves the choice as it was
    /// for when Post-Processing is switched back on.
    var reflections: Bool? {
        switch self {
        case .low: return nil
        case .medium: return false
        case .high, .ultra: return true
        }
    }

    /// 10 / 15 / 20 / 30, chosen so that every preset is a rate both a 60 Hz and a 120 Hz
    /// display pace exactly (each divides both; see `FrameRate.options`), and so that no two
    /// presets deliver the same rate on either. High used to ask for 25, which no 60 Hz display
    /// can pace: `FrameRate.deliverable` rounds it up to 30, so High and Ultra ran at the same
    /// rate and only differed in texture size.
    var fps: Double {
        switch self {
        case .low: return 10
        case .medium: return 15
        case .high: return 20
        case .ultra: return 30
        }
    }
}

enum GSPlayback: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case keepRunning, mute, pause, stop
}

/// The global settings that can take playback away from the user — one per `GSPlayback`
/// picker. Used as the *reason* a wallpaper is paused, muted or stopped, so each setting
/// can release exactly what it engaged and nothing else.
enum PlaybackPolicy: Hashable, CaseIterable {
    case otherApplicationFocused
    case otherApplicationFullscreen
    case otherApplicationPlayingAudio
    case displayAsleep
    case laptopOnBattery
}

enum GSAntiAliasingQuality: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case none, msaa_x2, msaa_x4, msaa_x8
}

/// There is no `ultra`. Upstream offered one, described as adding HDR bloom, and nothing ever
/// implemented it; bloom would need the composed frame as a render target, which a tree of
/// `SKEffectNode`s does not have. A saved `"ultra"` decodes as `.enabled`, which is what it
/// always delivered.
enum GSPostProcessingQuality: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case disabled, enabled

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == "disabled" ? .disabled : .enabled
    }
}

enum GSTextureResolutionQuality: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case highQuality, highPerformance, automatic
}

enum GSAppearance: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case light, dark, followSystem
}

enum GSLocalization: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case en_US, zh_CN, followSystem
}

enum GSVideoFramework: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case avkit
}

enum GSProcessPiority: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case normal, belowNormal
}

enum GSLogLevel: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case error, verbose, none
}

struct GlobalSettings: Codable, Equatable {
    
    // MARK: Playback
    var otherApplicationFocused = GSPlayback.keepRunning
    var otherApplicationFullscreen = GSPlayback.keepRunning
    var otherApplicationPlayingAudio = GSPlayback.keepRunning
    var displayAsleep = GSPlayback.keepRunning
    var laptopOnBattery = GSPlayback.keepRunning
    
    // MARK: Quality
    /// Not acted on and not shown; kept so a saved value decodes. SpriteKit offers no way to ask
    /// for multisampling: SKView exposes no sample count, nor does SKRenderer, SKScene or
    /// SKEffectNode — checked against the runtime's own method lists, private selectors included,
    /// for anything matching "sample", "alias" or "msaa". MSAA would also buy little here: it
    /// smooths geometry edges, and a scene is axis-aligned textured rectangles whose edges are
    /// already the textures' own filtered alpha.
    var antiAliasing = GSAntiAliasingQuality.msaa_x2
    /// Effect chains on scene layers. On by default: that is how scenes have rendered all along.
    var postProcessing = GSPostProcessingQuality.enabled
    /// Full textures by default: it is what the app always drew, and what `Tools/scenecheck`
    /// measures. Automatic sizes each texture from its layer's own size and scale and cannot see
    /// a parent's scale, a scale track or parallax zoom, so a layer enlarged one of those ways
    /// would lose texels — acceptable as a choice the user makes, not as a silent default that
    /// older saved settings (whose quality fields decode to defaults) would inherit.
    var textureResolution = GSTextureResolutionQuality.highQuality
    /// Wallpaper Engine's layer-local "Reflection" effect, built as one more pass when
    /// Post-Processing is on. On by default: since effect shaders run in WE's top-down texture
    /// space the pass renders as its previews show, and it is part of how those scenes were
    /// authored. See `init(from:)` for why a stored `false` from an older build is not honoured.
    var reflections = true
    var fps: Double = 30

    /// Which revision of the quality controls these values were saved under; see `init(from:)`.
    var qualityRevision = GlobalSettings.currentQualityRevision
    static let currentQualityRevision = 2
    
    // MARK: Automatic Setup
    var autoStart = false
    var safeMode = false

    // `language`, the Audio, Video and Advanced fields and `logLevel` back controls that were
    // removed from Settings: each was shown disabled and bound to a constant, and together they
    // outnumbered the working ones. They stay so that saved settings keep the same shape, and so
    // a build that implements one starts from the stored value.

    // MARK: Basic Setup
    /// Never applied: the app follows the system language, and macOS offers a per-app language
    /// in System Settings → Language & Region, which General links to.
    var language = GSLocalization.followSystem

    // MARK: macOS
    var adjustMenuBarTint = true

    // MARK: Appearance
    var appearance = GSAppearance.followSystem

    // MARK: Audio
    /// Neither was ever acted on.
    var audioOutput = true
    var reloadWhenChangingOutputDevice = true

    // MARK: Video
    /// AVFoundation is the only video framework there is, so this never had anything to choose.
    var videoFramework = GSVideoFramework.avkit

    // MARK: Advanced
    /// Not implemented, because lowering priority is not reversible. An unprivileged process may
    /// raise its own nice value but never lower it again (measured: `setpriority` to 10 succeeds,
    /// back to 0 fails with EACCES), so "Below Normal" → "Normal" would silently fail until
    /// relaunch; and Darwin's reversible alternative, background policy, also throttles GPU and
    /// I/O, which a renderer cannot afford.
    var processPiority = GSProcessPiority.normal
    /// Not implemented: Metal reports no pressure signal to react to. Apple-silicon GPUs share
    /// system memory, and `MTLDevice.currentAllocatedSize` against `recommendedMaxWorkingSetSize`
    /// is the closest reading, which is not exhaustion.
    var pauseOnVRAMExhausted = false
    /// Not implemented: a crashed process cannot restart itself; it needs a launchd agent with
    /// KeepAlive, which is a packaging change, not a setting.
    var restartAfterCrashing = false

    // MARK: Developer
    /// Not implemented: the app logs through `print` and `NSLog` unconditionally and has no logger
    /// for a level to configure.
    var logLevel = GSLogLevel.none

    // MARK: Misc
    var autoRefresh = true
}

extension GlobalSettings {
    /// Decoded field by field, each falling back to its default.
    ///
    /// The synthesized decoder throws on the first missing or unreadable key, and `init()` of the
    /// view model answers a throw by starting from `GlobalSettings()` — so adding any field to
    /// this struct used to wipe every setting the user had saved, playback rules included, on the
    /// first launch of the build that added it. Being lenient per field is what lets the fields
    /// below be added at all.
    ///
    /// Settings saved before `qualityRevision` existed get the four quality controls reset to
    /// their defaults instead of keeping what was stored. None of the four did anything then, so
    /// a stored value is not a choice anyone saw the effect of — and honouring the old default
    /// would be actively wrong: `postProcessing` defaulted to `.disabled`, which now that it is
    /// wired would switch effects off on every install that never opened this page. What those
    /// installs actually saw was effects on; the reset keeps that. `fps` is left alone because it
    /// always worked.
    ///
    /// Revision 2 wired Reflections. Under revision 1 the toggle was shown disabled and bound to
    /// a constant, so every saved setting carries the `false` the struct defaulted to and nobody
    /// ever chose; honouring it would switch the effect off on every existing install. Settings
    /// saved before revision 2 take `reflections` from the default and keep everything else.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = GlobalSettings()
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let decoded = try? c.decodeIfPresent(T.self, forKey: key) { value = decoded }
        }
        read(.otherApplicationFocused, &s.otherApplicationFocused)
        read(.otherApplicationFullscreen, &s.otherApplicationFullscreen)
        read(.otherApplicationPlayingAudio, &s.otherApplicationPlayingAudio)
        read(.displayAsleep, &s.displayAsleep)
        read(.laptopOnBattery, &s.laptopOnBattery)
        read(.fps, &s.fps)
        read(.autoStart, &s.autoStart)
        read(.safeMode, &s.safeMode)
        read(.language, &s.language)
        read(.adjustMenuBarTint, &s.adjustMenuBarTint)
        read(.appearance, &s.appearance)
        read(.audioOutput, &s.audioOutput)
        read(.reloadWhenChangingOutputDevice, &s.reloadWhenChangingOutputDevice)
        read(.videoFramework, &s.videoFramework)
        read(.processPiority, &s.processPiority)
        read(.pauseOnVRAMExhausted, &s.pauseOnVRAMExhausted)
        read(.restartAfterCrashing, &s.restartAfterCrashing)
        read(.logLevel, &s.logLevel)
        read(.autoRefresh, &s.autoRefresh)

        let revision = (try? c.decodeIfPresent(Int.self, forKey: .qualityRevision)) ?? nil
        if let revision, revision >= 1 {
            read(.antiAliasing, &s.antiAliasing)
            read(.postProcessing, &s.postProcessing)
            read(.textureResolution, &s.textureResolution)
        }
        if let revision, revision >= 2 {
            read(.reflections, &s.reflections)
        }
        // Revision 1's High preset stored 25 fps, which a 60 Hz display delivers as Ultra's 30 and
        // which no preset asks for any more, so every install that clicked High would open
        // Settings to "Custom" without having touched a control. The stored trio is exactly what
        // that preset wrote (Medium and Ultra differ in fps and textures, and reflections were
        // reset just above), so it is read as the choice it was and becomes today's High — at
        // 20, a step down from the 30 those installs actually ran at, but that is what High now
        // means and the segment says so. A 25 with any other quality settings was set by hand
        // and is left alone.
        if revision == 1, s.fps == 25, s.postProcessing == .enabled,
           s.textureResolution == .automatic {
            s.fps = GSQuality.high.fps
        }
        s.qualityRevision = GlobalSettings.currentQualityRevision
        self = s
    }

    /// The quality controls as a scene on the screen `screenId` is built with.
    ///
    /// `SceneEffectsDisabled` still wins over Post-Processing: it is the documented way to tell a
    /// mis-translated effect from a mis-composed scene, and it should not depend on what the
    /// Settings window says.
    ///
    /// `scripts` and `assetsRoot` are not `GlobalSettings` fields but `UserDefaults` keys — they
    /// predate the Developer section as `defaults write` switches — and `SceneQuality()` reads
    /// them itself. A change to either reaches a running scene because
    /// `GlobalSettingsViewModel`'s setters for them publish a change, and `SceneWallpaperView`
    /// then finds its quality different and rebuilds.
    func sceneQuality(onScreen screenId: String) -> SceneQuality {
        var quality = SceneQuality()
        quality.effects = postProcessing == .enabled
            && !UserDefaults.standard.bool(forKey: "SceneEffectsDisabled")
        // Normalised while effects are off, where no reflection pass is built either way, so that
        // a preset changing only this field does not rebuild every scene for nothing.
        quality.reflections = quality.effects ? reflections : true
        quality.displayPoints = NSScreen.screens
            .first(where: { WallpaperViewModel.screenId(for: $0) == screenId })?.frame.size
        switch textureResolution {
        case .highQuality:
            quality.textures = .full
        case .highPerformance:
            quality.textures = .scaled(0.5)
        case .automatic:
            // Pixels, not points: a Retina display covers twice the texels its frame says.
            if let screen = NSScreen.screens.first(where: { WallpaperViewModel.screenId(for: $0) == screenId }) {
                let scale = screen.backingScaleFactor
                quality.textures = .display(CGSize(width: screen.frame.width * scale,
                                                   height: screen.frame.height * scale))
            } else {
                quality.textures = .full
            }
        }
        return quality
    }

    /// The preset these settings amount to, or nil ("Custom") when they match none. Frame rates
    /// are compared as delivered on the main display, so a saved 16 — paced at 15 — still reads
    /// as Medium.
    var activeQuality: GSQuality? {
        let delivered = FrameRate.deliverable(fps, on: nil)
        return GSQuality.allCases.first { preset in
            postProcessing == preset.postProcessing
                && textureResolution == preset.textureResolution
                && (preset.reflections == nil || preset.reflections == reflections)
                && delivered == FrameRate.deliverable(preset.fps, on: nil)
        }
    }
}

class GlobalSettingsViewModel: ObservableObject {
    /// Applied the moment it changes, as macOS settings windows do: there is no OK or Cancel, and
    /// closing the window keeps what is shown. The window used to carry both, plus an "Edited"
    /// badge, over this same `didSet` — so the badge could never appear (it compared against a
    /// copy saved on every change) and Cancel re-read that copy and reverted nothing.
    @Published var settings: GlobalSettings
    {
        didSet {
            save(); validate()
            if settings != oldValue {
                applyAllPolicies()
                conditionMonitor?.setFullscreenPolling(settings.otherApplicationFullscreen != .keepRunning)
                conditionMonitor?.setAudioMonitoring(settings.otherApplicationPlayingAudio != .keepRunning)
            }
        }
    }
    
    @Published var selection = 0
    
    @Published var isFirstLaunch = UserDefaults.standard.value(forKey: "IsFirstLaunch") as? Bool ?? true

    /// What macOS says about launching this app at login. The system is the source of truth, not
    /// `settings.autoStart`: the user can remove the item in System Settings → Login Items, an
    /// approval can be pending there, and a copy launched from somewhere else may not be the one
    /// registered — in each case a stored bool went on showing "on" for something that was not
    /// going to happen. Re-read whenever Settings appears and whenever the app becomes active,
    /// which is how the user comes back from System Settings.
    @Published private(set) var loginItemStatus: SMAppService.Status = .notRegistered

    /// The last register/unregister failure, shown under the toggle until the next attempt.
    @Published private(set) var loginItemError: String?
    
    var didFinishLaunchingNotificationCancellable: Cancellable?
    var didActivateApplicationNotificationCancellable: Cancellable?
    var didCurrentWallpaperChangeCancellable: Cancellable?
    var didBecomeActiveCancellable: Cancellable?
    var didChangeAdjustMenuBarTintCancellable: Cancellable?
    private var conditionMonitor: PlaybackConditionMonitor?

    init() {
        if let data = UserDefaults.standard.data(forKey: "GlobalSettings"),
           let settings = try? JSONDecoder().decode(GlobalSettings.self, from: data) {
            self.settings = settings
        } else {
            self.settings = GlobalSettings()
        }
        
        // Add observers
        self.didFinishLaunchingNotificationCancellable =
        NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)
            .sink { [weak self] _ in self?.didFinishLaunchingNotification() }
    }
    
    deinit {
        didActivateApplicationNotificationCancellable?.cancel()
        didFinishLaunchingNotificationCancellable?.cancel()
        didCurrentWallpaperChangeCancellable?.cancel()
        didBecomeActiveCancellable?.cancel()
        didChangeAdjustMenuBarTintCancellable?.cancel()
    }
    
    func didFinishLaunchingNotification() {
        self.didActivateApplicationNotificationCancellable =
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in self?.activateApplicationDidChange() }
        // The notification only reports *changes*. Launched as a login item, or from a
        // terminal, the app comes up with some other application already frontmost and
        // nothing activating, so "Other application focused" stayed unenforced until the
        // user next switched apps. Evaluate it once for the state we start in; if we are
        // about to become active ourselves, that activation clears it again.
        activateApplicationDidChange()

        self.didCurrentWallpaperChangeCancellable =
        AppDelegate.shared.wallpaperViewModel.$wallpapers
            // Every screen, not just the main one: each gets the still of its own
            // wallpaper. dropFirst because applicationDidFinishLaunching has just done so.
            .dropFirst()
            .sink { [weak self] wallpapers in
                self?.didCurrentWallpaperChange(wallpapers)
            }
        
        // Adopt the system's login-item state rather than impose the stored one. This used to be
        // a sink on `$settings.autoStart` that fired at launch and called register() or
        // unregister() every time, overwriting a removal the user made in System Settings. Now
        // only the toggle registers (`setLaunchAtLogin`), and every other path just reads.
        refreshLoginItemStatus()
        self.didBecomeActiveCancellable =
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshLoginItemStatus() }
        
        self.didChangeAdjustMenuBarTintCancellable =
        self.$settings
            .removeDuplicates { $0.adjustMenuBarTint == $1.adjustMenuBarTint }
            .map { $0.adjustMenuBarTint }
            .sink { [weak self] in self?.didChangeAdjustMenuBarTint($0) }

        // Started here rather than in init: it reports straight into setCondition, which
        // reaches AppDelegate.shared.
        let monitor = PlaybackConditionMonitor { [weak self] policy, active in
            self?.setCondition(policy, active: active)
        }
        self.conditionMonitor = monitor
        monitor.start()
        monitor.setFullscreenPolling(settings.otherApplicationFullscreen != .keepRunning)
        monitor.setAudioMonitoring(settings.otherApplicationPlayingAudio != .keepRunning)

        self.validate()
    }
    
    // MARK: - Launch at login

    /// Whether the toggle should read as on. A pending approval counts: the item is registered
    /// and will launch once the user allows it, which the note under the toggle says.
    var launchesAtLogin: Bool {
        loginItemStatus == .enabled || loginItemStatus == .requiresApproval
    }

    /// Reads the system's status and mirrors it into `settings.autoStart`. Nothing observes that
    /// field any more, so writing it cannot loop back into a register call; it is kept only so
    /// the saved settings say what the system says.
    func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        if loginItemStatus != status { loginItemStatus = status }
        let adopted = launchesAtLogin
        if settings.autoStart != adopted { settings.autoStart = adopted }
    }

    /// The toggle's action — the only place the app registers or unregisters itself.
    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItemStatus()
    }
    
    func didChangeAdjustMenuBarTint(_ newValue: Bool) {
        if newValue {
            AppDelegate.shared.refreshPlaceholders()
        } else {
            AppDelegate.shared.restoreOSWallpapers()
        }
    }

    func didCurrentWallpaperChange(_ wallpapers: [String: WEWallpaper]) {
        AppDelegate.shared.refreshPlaceholders(with: wallpapers)
    }

    /// Settings → General → Reset, after the user has confirmed it. Launch at login is the
    /// system's state, not a setting, so it is carried over rather than reset: a fresh
    /// `GlobalSettings()` says off, and writing that would leave the saved copy disagreeing with
    /// System Settings until the next refresh.
    func resetToDefaults() {
        var fresh = GlobalSettings()
        fresh.autoStart = settings.autoStart
        settings = fresh
    }

    // MARK: - Developer switches and folders
    //
    // These three are `UserDefaults` keys of their own rather than `GlobalSettings` fields: two of
    // them were `defaults write` switches long before Settings showed them, and existing
    // `defaults write` habits (and the offline tools' `-Key value` arguments) must keep working.
    // Reset leaves all three alone, as its confirmation says it leaves the library alone. Each
    // setter publishes a change by hand, since nothing `@Published` holds the value: that is what
    // makes `SceneWallpaperView.updateNSView` run, compute a `SceneQuality` that now differs, and
    // rebuild — the same path a quality control takes.

    var sceneScriptsDisabled: Bool {
        UserDefaults.standard.bool(forKey: WEAssetLibrary.scriptsDisabledKey)
    }

    func setSceneScriptsDisabled(_ disabled: Bool) {
        objectWillChange.send()
        // Removed rather than written false, so the domain looks as it did before the switch was
        // ever touched.
        if disabled {
            UserDefaults.standard.set(true, forKey: WEAssetLibrary.scriptsDisabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: WEAssetLibrary.scriptsDisabledKey)
        }
    }

    /// nil resets to the default locations.
    func setWallpaperEngineAssetsPath(_ url: URL?) {
        objectWillChange.send()
        if let url {
            UserDefaults.standard.set(url.path(percentEncoded: false), forKey: WEAssetLibrary.pathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: WEAssetLibrary.pathKey)
        }
    }

    /// Points the library at another folder; nil goes back to `~/Documents/Open Wallpaper Engine`.
    ///
    /// Nothing is moved, copied or deleted — both folders stay exactly as they were. What follows
    /// from that, chosen as the least surprising behaviour:
    /// - The grid lists the new folder at once (`ContentViewModel.libraryDirectoryDidChange`).
    /// - A screen showing a wallpaper from the old folder keeps showing it. `ScreenWallpapers`
    ///   stores each assignment's absolute directory, and those files are still there, so the
    ///   desktop does not change under the user just because the library did; the wallpaper is
    ///   simply no longer listed, and is replaced when they choose another. (Were the old folder
    ///   later deleted, that screen would fail to load it, as it would for any wallpaper deleted
    ///   in Finder.) Recents behave the same way.
    /// - Workshop downloads go to the folder that is current when the copy starts:
    ///   `SteamCmdService.importItem` reads `wallpapersDirectory` itself, so a download finishing
    ///   after the change lands in the new folder. An item that was only ever downloaded into the
    ///   old folder is not in the new library until it is downloaded again (the Workshop tab's
    ///   "Downloaded" badge is per session and says nothing about either folder).
    /// - Approvals in `TrustedWallpapers` are by path, so a web wallpaper copied into the new
    ///   folder asks again.
    /// Choosing the default folder itself clears the override rather than storing a path equal to
    /// it, so the setting reads "default" again.
    func setWallpapersDirectory(_ url: URL?) {
        objectWillChange.send()
        let fm = FileManager.default
        if let url, url.standardizedFileURL.resolvingSymlinksInPath()
            != fm.defaultWallpapersDirectory.standardizedFileURL.resolvingSymlinksInPath() {
            UserDefaults.standard.set(url.path(percentEncoded: false),
                                      forKey: FileManager.wallpapersDirectoryOverrideKey)
        } else {
            UserDefaults.standard.removeObject(forKey: FileManager.wallpapersDirectoryOverrideKey)
        }
        AppDelegate.shared.contentViewModel.libraryDirectoryDidChange()
    }

    /// Runs on every change. An encoding failure is logged and the previous saved copy kept,
    /// rather than trapping: these are plain enums and numbers, so it should never happen, but
    /// a `try!` here would take every wallpaper down with it if a future field ever made it so.
    func save() {
        do {
            let data = try JSONEncoder().encode(settings)
            UserDefaults.standard.set(data, forKey: "GlobalSettings")
        } catch {
            NSLog("GlobalSettings not saved: %@", String(describing: error))
        }
    }
    
    func setQuality(_ quality: GSQuality) {
        // One assignment, so `settings.didSet` — save, policies, and every scene rebuilding for
        // its new quality — runs once per preset rather than once per field.
        // What each preset sets, and why its frame rate, is on `GSQuality`. Anti-aliasing is not
        // touched: it is not implemented (see `PerformancePage`).
        var s = settings
        s.postProcessing = quality.postProcessing
        s.textureResolution = quality.textureResolution
        if let reflections = quality.reflections { s.reflections = reflections }
        s.fps = quality.fps
        settings = s
    }
    
    private func validate() {
        switch settings.appearance {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .followSystem:
            NSApp.appearance = nil
        }
    }
    
    // MARK: - Playback policy

    /// The conditions currently true, as last reported by their observers. Kept apart
    /// from what was done about them, so changing a picker while its condition holds
    /// takes effect at once (`settings.didSet` re-applies all of them).
    private var activeConditions: Set<PlaybackPolicy> = []

    func choice(for policy: PlaybackPolicy) -> GSPlayback {
        switch policy {
        case .otherApplicationFocused: return settings.otherApplicationFocused
        case .otherApplicationFullscreen: return settings.otherApplicationFullscreen
        case .otherApplicationPlayingAudio:
            // Below 14.2 the picker is shown disabled at Keep Running, and a value saved on a
            // newer system must not be acted on as if it were in force. Nothing reports the
            // condition there anyway; this keeps the two in agreement.
            return PlaybackConditionMonitor.canDetectOtherApplicationAudio
                ? settings.otherApplicationPlayingAudio : .keepRunning
        case .displayAsleep: return settings.displayAsleep
        case .laptopOnBattery: return settings.laptopOnBattery
        }
    }

    /// Record whether `policy`'s condition holds and bring playback in line with it.
    func setCondition(_ policy: PlaybackPolicy, active: Bool) {
        if active {
            activeConditions.insert(policy)
        } else {
            activeConditions.remove(policy)
        }
        apply(policy)
    }

    /// Every verb is idempotent and keyed by `policy`, so this only has to state which
    /// of pause/mute/stop the policy should be holding right now. A policy switched from
    /// `Pause` to `Mute` mid-condition releases the one and engages the other.
    private func apply(_ policy: PlaybackPolicy) {
        let app = AppDelegate.shared
        let action = activeConditions.contains(policy) ? choice(for: policy) : .keepRunning
        if action == .mute { app.autoMute(policy) } else { app.autoUnmute(policy) }
        if action == .pause || action == .stop { app.autoPause(policy) } else { app.autoResume(policy) }
        if action == .stop { app.autoStop(policy) } else { app.autoUnstop(policy) }
    }

    private func applyAllPolicies() {
        PlaybackPolicy.allCases.forEach(apply)
    }

    func activateApplicationDidChange() {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return }

        switch frontmostApplication.bundleIdentifier {
        case "com.apple.finder", Bundle.main.bundleIdentifier:
            setCondition(.otherApplicationFocused, active: false)
        default:
            setCondition(.otherApplicationFocused, active: true)
        }
    }

    /// Applies the `Display asleep` preference when the screens blank or come back.
    ///
    /// Screens sleeping and the system suspending are independent events. With external
    /// displays attached the Mac routinely blanks the screens without ever suspending, so
    /// only the `screens*` pair fires — see the observers in `AppDelegate`. When both
    /// pairs do fire, the second of each is a no-op: the condition is a set membership,
    /// not a counter, so a double "pause" can no longer clobber the rate to resume to.
    func displayAsleepDidChange(asleep: Bool) {
        setCondition(.displayAsleep, active: asleep)
    }

    private func saveAndValidate() {
        save()
        validate()
    }
}
