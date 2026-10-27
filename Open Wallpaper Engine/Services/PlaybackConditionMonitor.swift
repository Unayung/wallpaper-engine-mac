//
//  PlaybackConditionMonitor.swift
//  Open Wallpaper Engine
//
//  Watches the playback conditions macOS has no single notification for — another
//  application covering a screen or playing sound, and the Mac running on battery — and
//  reports them to GlobalSettingsViewModel.setCondition, which decides what each one does.
//

import Cocoa
import IOKit.ps

final class PlaybackConditionMonitor {
    private let report: (PlaybackPolicy, Bool) -> Void
    private var powerSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var fullscreenPoll: Timer?
    /// An `OtherAppAudioMonitor` while the audio picker is set, else nil. Typed `AnyObject`
    /// because the class is macOS 14.2+ and a stored property cannot carry `@available`.
    private var audioMonitor: AnyObject?
    private var isOnBattery = false
    private var isFullscreen = false

    /// `report` is called with the current state at start, then on every change.
    init(report: @escaping (PlaybackPolicy, Bool) -> Void) {
        self.report = report
    }

    deinit {
        if let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        fullscreenPoll?.invalidate()
        if #available(macOS 14.2, *) { (audioMonitor as? OtherAppAudioMonitor)?.stop() }
    }

    func start() {
        startPowerSourceObserver()
        startFullscreenObservers()
    }

    // MARK: - Battery

    /// IOKit posts on every power-source change — including each percent of charge — so
    /// the callback re-reads the providing source and reports only actual transitions.
    private func startPowerSourceObserver() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            Unmanaged<PlaybackConditionMonitor>.fromOpaque(context).takeUnretainedValue().powerSourceDidChange()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        isOnBattery = Self.isOnBatteryPower()
        report(.laptopOnBattery, isOnBattery)
    }

    private func powerSourceDidChange() {
        let onBattery = Self.isOnBatteryPower()
        guard onBattery != isOnBattery else { return }
        isOnBattery = onBattery
        report(.laptopOnBattery, onBattery)
    }

    /// A desktop has no battery and reports AC, so this is simply false there.
    static func isOnBatteryPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    // MARK: - Other application playing audio

    /// Whether this Mac can tell. Core Audio's process objects arrived in macOS 14.2; before
    /// that there is no per-process signal short of a tap, which needs a capture permission.
    static var canDetectOtherApplicationAudio: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// Start or stop listening to Core Audio to match the `Other Application Playing Audio`
    /// picker. Off by default, so the listeners — one per process with a Core Audio client,
    /// 39 on an idle machine — cost nothing unless the rule is set. `stop()` reports the
    /// condition false if it had reported it true, so a picker switched back to Keep Running
    /// releases what it held.
    func setAudioMonitoring(_ enabled: Bool) {
        guard #available(macOS 14.2, *) else { return }
        if enabled, audioMonitor == nil {
            let monitor = OtherAppAudioMonitor { [weak self] playing in
                self?.report(.otherApplicationPlayingAudio, playing)
            }
            audioMonitor = monitor
            monitor.start()
        } else if !enabled, let monitor = audioMonitor as? OtherAppAudioMonitor {
            audioMonitor = nil
            monitor.stop()
        }
    }

    // MARK: - Fullscreen

    /// Native fullscreen moves the app to its own Space, so `activeSpaceDidChange` covers
    /// entering and leaving it; activation covers switching to an app that is already
    /// fullscreen. Neither fires for a game that resizes a borderless window to cover the
    /// screen after it has come forward, which is what the slow poll is for — it runs only
    /// while the `Fullscreen` picker is set to something, so it costs nothing by default.
    private func startFullscreenObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.checkFullscreen()
                // Space transitions animate; the window list settles about half a second
                // after the notification, so look again once it has.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.checkFullscreen() }
            })
        }
        checkFullscreen()
    }

    /// Start or stop the slow poll to match the `Fullscreen` picker.
    func setFullscreenPolling(_ enabled: Bool) {
        if enabled, fullscreenPoll == nil {
            fullscreenPoll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.checkFullscreen()
            }
            fullscreenPoll?.tolerance = 2
        } else if !enabled {
            fullscreenPoll?.invalidate()
            fullscreenPoll = nil
        }
    }

    func checkFullscreen() {
        let screens = Set(AppDelegate.shared.wallpaperViewModel.enabledScreens)
        let covered = NSScreen.screens.filter { screens.contains(WallpaperViewModel.screenId(for: $0)) }
        var fullscreen = false
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != getpid(),
           front.bundleIdentifier != "com.apple.finder" {
            fullscreen = Self.application(front.processIdentifier, coversAnyOf: covered)
        }
        guard fullscreen != isFullscreen else { return }
        isFullscreen = fullscreen
        report(.otherApplicationFullscreen, fullscreen)
    }

    /// Whether `pid` has an ordinary on-screen window spanning the whole of one of
    /// `screens`, menu bar included. That is what both native fullscreen and borderless
    /// "windowed fullscreen" look like, and what a merely zoomed window does not.
    ///
    /// Window bounds and owners are readable without Screen Recording permission; only
    /// titles are withheld. The screens are the ones showing a wallpaper (`enabledScreens`)
    /// rather than the ones with a window right now, because `Stop` closes those windows
    /// and the condition would then flip off and on forever.
    static func application(_ pid: pid_t, coversAnyOf screens: [NSScreen]) -> Bool {
        guard !screens.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]]
        else { return false }

        // CGWindow bounds are top-left origin, relative to the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let targets = screens.map {
            CGRect(x: $0.frame.minX, y: primaryHeight - $0.frame.maxY,
                   width: $0.frame.width, height: $0.frame.height)
        }

        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            let slack: CGFloat = 1
            if targets.contains(where: {
                bounds.minX <= $0.minX + slack && bounds.minY <= $0.minY + slack &&
                bounds.maxX >= $0.maxX - slack && bounds.maxY >= $0.maxY - slack
            }) {
                return true
            }
        }
        return false
    }
}
