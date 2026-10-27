//
//  OtherAppAudioMonitor.swift
//  Open Wallpaper Engine
//
//  Reports whether some *other* application is sending sound to an output device, from
//  Core Audio's process objects (macOS 14.2). Drives the "Other Application Playing Audio"
//  playback rule through PlaybackConditionMonitor.
//
//  Foundation, CoreAudio and Darwin only, so `Tools/audiocheck` can compile it on its own.
//

import CoreAudio
import Darwin
import Foundation

/// What Core Audio's per-process `IsRunningOutput` means, measured on macOS 27.0.1 with
/// `Tools/audiocheck` and a raw property probe — recorded because an earlier attempt concluded
/// it "reports incorrectly" and shipped the rule disabled:
///
/// - It is set while the process has an output IO running, which is not the same as audible
///   sound. `afplay` and `say` raise it within ~0.05 s of starting and drop out of the process
///   list when they exit. An `AVPlayer` raises it on `play()` and keeps it **for ~7.4 s after
///   `pause()`** (measured twice: 7.4 s both times; also after the player was released); a
///   `WKWebView` `<audio>` kept it ~8.7 s after `pause()`. So the rule releases several seconds
///   after the other app goes quiet. That lag is the OS powering the IO down, not a misreading.
/// - The false positives are processes that hold an output IO open for hours without
///   playing: every iOS Simulator audio server (`systemsoundserver-simd`, four of them, 3–5 h
///   uptime) and a simulator app. They are excluded by path below. The earlier note also named a
///   Discord renderer and a browser. Those particular apps read 0 while idle here, but the
///   mechanism is real and was reproduced in review: a page with an idle Web Audio context (an
///   oscillator stopped behind a gain of 0) or `<audio autoplay muted loop>` keeps WebKit's GPU
///   process at 1 for as long as the page is open, never making a sound. Any such tab or
///   web-based app holds the rule engaged; nothing permission-free distinguishes it, so the
///   Settings help text says so.
/// - **`IsRunningOutput` itself never notifies.** A listener on it registered on every process
///   object fired zero times across afplay, say, AVPlayer and WebKit runs; the change arrives as
///   `kAudioProcessPropertyIsRunning` ('pir?'). Both are listened to, and the value read is
///   always `IsRunningOutput`, so a process that only records is not counted. A process whose
///   input is already running when its output starts would not raise 'pir?' and would be missed
///   until the next list change; recording needs the microphone permission and that case was
///   not reproducible here.
/// - No permission is involved. Reading process objects is not an audio tap. No prompt appeared
///   during the harness run, and every TCC request tccd logged against it was coreaudiod's
///   `preflight=yes` check (Microphone, ScreenCapture, AudioCapture) — the same check it runs on
///   any new audio client, `systemsoundserverd` included, and one that never prompts.
@available(macOS 14.2, *)
final class OtherAppAudioMonitor {
    /// A process found playing, as reported to `onSourcesChange` for logging.
    struct Source: Equatable, CustomStringConvertible {
        let pid: pid_t
        let path: String
        var description: String { "\(pid) \((path as NSString).lastPathComponent)" }
    }

    private let report: (Bool) -> Void
    /// A rising edge must hold this long before it is reported. Alert sounds and other UI
    /// blips (a `beep` ran output for 0.11 s) would otherwise pause the wallpaper for a blink.
    /// Falling edges are reported at once: the OS already adds ~7 s of its own.
    private let settle: TimeInterval
    var onSourcesChange: (([Source]) -> Void)?

    private(set) var isPlaying = false
    private var sources: [Source] = []
    private var listListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var pendingRise: DispatchWorkItem?

    /// `report` is called on the main queue, only on transitions. `start()` reports nothing
    /// if nothing is playing: the caller starts from "not playing".
    init(settle: TimeInterval = 1, report: @escaping (Bool) -> Void) {
        self.settle = settle
        self.report = report
    }

    deinit { stop() }

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
    /// See the type comment: 'pir?' is the one that actually notifies.
    private static let runningSelectors = [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningOutput]

    func start() {
        guard listListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.processListDidChange() }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        guard AudioObjectAddPropertyListenerBlock(Self.system, &address, .main, block) == noErr else { return }
        listListener = block
        processListDidChange()
    }

    /// Removes every listener and reports `false` if it had reported `true`.
    func stop() {
        pendingRise?.cancel()
        pendingRise = nil
        if let block = listListener {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(Self.system, &address, .main, block)
            listListener = nil
        }
        for (object, block) in processListeners { Self.removeListeners(object, block) }
        processListeners = [:]
        sources = []
        if isPlaying {
            isPlaying = false
            report(false)
        }
    }

    // MARK: - Process objects

    /// A process object exists for every process with a Core Audio client, playing or not
    /// (39 on the measuring machine at idle), so each gets a listener when it appears and
    /// loses it when it goes.
    private func processListDidChange() {
        guard listListener != nil else { return }
        let current = Set(Self.processObjects())
        for (object, block) in processListeners where !current.contains(object) {
            Self.removeListeners(object, block)
            processListeners[object] = nil
        }
        for object in current where processListeners[object] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.evaluate() }
            for selector in Self.runningSelectors {
                var address = Self.address(selector)
                AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
            }
            processListeners[object] = block
        }
        evaluate()
    }

    private static func removeListeners(_ object: AudioObjectID, _ block: @escaping AudioObjectPropertyListenerBlock) {
        // Fails harmlessly for an object that has already gone away.
        for selector in runningSelectors {
            var address = address(selector)
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
    }

    private func evaluate() {
        guard listListener != nil else { return }
        let playing = Self.playingSources()
        if playing != sources {
            sources = playing
            onSourcesChange?(playing)
        }
        if playing.isEmpty {
            pendingRise?.cancel()
            pendingRise = nil
            if isPlaying {
                isPlaying = false
                report(false)
            }
        } else if !isPlaying, pendingRise == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingRise = nil
                guard !self.sources.isEmpty, !self.isPlaying, self.listListener != nil else { return }
                self.isPlaying = true
                self.report(true)
            }
            pendingRise = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
        }
    }

    static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func pid(_ object: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// Every process with its output running that is not excluded.
    static func playingSources() -> [Source] {
        processObjects().compactMap { object in
            guard uint32(object, kAudioProcessPropertyIsRunningOutput) == 1,
                  let pid = pid(object), pid > 0 else { return nil }
            let path = executablePath(pid)
            return isExcluded(pid: pid, path: path) ? nil : Source(pid: pid, path: path)
        }
        .sorted { $0.pid < $1.pid }
    }

    // MARK: - Exclusions

    /// This app's own sound, and the processes that hold an output open without playing.
    ///
    /// Own sound is not just this PID. Video and scene audio play in-process, but a web
    /// wallpaper's sound is produced by WebKit's GPU process — measured, a `WKWebView`
    /// `<audio>` raised `IsRunningOutput` on `com.apple.WebKit.GPU`, a separate PID whose
    /// parent is launchd, and never on the host. Counting it would let a web wallpaper with
    /// sound pause itself, go quiet, resume ~8 s later and pause again forever. What ties that
    /// helper to this app is the kernel's *responsible process*, the same attribution TCC
    /// uses, so anything whose responsible process is ours is ours. Launched from Finder or as
    /// a login item the app is its own responsible process; launched from Xcode or a terminal
    /// the responsible process is that host, and its other children are then excluded too —
    /// acceptable in a development run, and why `Tools/audiocheck` starts its "other app"
    /// through launchd.
    static func isExcluded(pid: pid_t, path: String) -> Bool {
        let me = getpid()
        if pid == me { return true }
        if let responsible = responsiblePID(pid), responsible == me || responsible == ownResponsiblePID {
            return true
        }
        // Simulator audio servers and simulator apps hold an output IO open for as long as the
        // simulator runs — measured at 3–5 hours on idle simulators, with nothing audible.
        if path.contains("/Developer/CoreSimulator/") { return true }
        // Alert and UI sounds, played on behalf of whichever app asked. Not "an application
        // playing audio", and short anyway.
        if path == "/usr/sbin/systemsoundserverd" { return true }
        return false
    }

    static let ownResponsiblePID: pid_t? = responsiblePID(getpid())

    /// `responsibility_get_pid_responsible_for_pid` is exported by libSystem but has no
    /// header, so it is looked up rather than linked; without it only this PID is excluded.
    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    private static let responsibleFunction: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let function = responsibleFunction else { return nil }
        let responsible = function(pid)
        return responsible > 0 ? responsible : nil
    }

    static func executablePath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }
}
