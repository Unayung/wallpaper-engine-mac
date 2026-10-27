//
//  Tools/audio-check/main.swift
//
//  Drives OtherAppAudioMonitor — the app's own source, compiled in by Tools/audiocheck —
//  through a fixed script of sounds and logs every transition it reports, so the "Other
//  Application Playing Audio" rule can be checked without launching the app.
//
//  Each step states what the rule should do. The "other application" is a child spawned
//  with its responsibility disclaimed, which makes it its own responsible process exactly as
//  an app launched from the Dock is; a child spawned normally is attributed to this harness
//  and must be ignored, which is the case of a web wallpaper's WebKit GPU process.
//

import AVFoundation
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let t0 = Date()
func log(_ s: String) { print(String(format: "[%6.2f] ", Date().timeIntervalSince(t0)) + s) }

guard #available(macOS 14.2, *) else {
    print("SKIP: Core Audio process objects need macOS 14.2; the rule is shown disabled there")
    exit(0)
}

// MARK: Spawning

typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
let disclaim: Disclaim? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
    .map { unsafeBitCast($0, to: Disclaim.self) }

@discardableResult
func spawn(_ path: String, _ args: [String], asOtherApp: Bool) -> pid_t {
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    if asOtherApp {
        guard let disclaim else { fatalError("responsibility_spawnattrs_setdisclaim not found") }
        _ = disclaim(&attr, 1)
    }
    let argv = ([path] + args).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, path, nil, &attr, argv, environ)
    precondition(status == 0, "posix_spawn \(path): \(status)")
    log("spawned \((path as NSString).lastPathComponent) pid \(pid) responsible=\(OtherAppAudioMonitor.responsiblePID(pid).map(String.init) ?? "?")\(asOtherApp ? " (as another app)" : " (attributed to this harness)")")
    return pid
}

func wait(_ pid: pid_t) {
    var status: Int32 = 0
    DispatchQueue.global().async {
        waitpid(pid, &status, 0)
        DispatchQueue.main.async { log("pid \(pid) exited") }
    }
}

// MARK: Monitor

var transitions: [(TimeInterval, Bool)] = []
let monitor = OtherAppAudioMonitor { playing in
    transitions.append((Date().timeIntervalSince(t0), playing))
    log(">>> report(\(playing))")
}
monitor.onSourcesChange = { log("sources: \($0.isEmpty ? "none" : $0.map(\.description).joined(separator: ", "))") }

// What is running output right now, excluded or not, so a baseline false positive is visible.
for object in OtherAppAudioMonitor.processObjects() {
    var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var running: UInt32 = 0, size = UInt32(4)
    var pidAddress = address
    pidAddress.mSelector = kAudioProcessPropertyPID
    var pid: pid_t = 0, pidSize = UInt32(4)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr, running == 1,
          AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { continue }
    let path = OtherAppAudioMonitor.executablePath(pid)
    log("baseline output running: \(pid) \((path as NSString).lastPathComponent) excluded=\(OtherAppAudioMonitor.isExcluded(pid: pid, path: path))")
}

monitor.start()
log("started; isPlaying=\(monitor.isPlaying)")

// MARK: Script

let speech = "/tmp/audiocheck-speech.aiff"
var steps: [(TimeInterval, String, () -> Void)] = []
func at(_ t: TimeInterval, _ label: String, _ action: @escaping () -> Void) { steps.append((t, label, action)) }

at(2, "afplay Ping as another app — expect true after the 1 s settle, false at exit") {
    wait(spawn("/usr/bin/afplay", ["/System/Library/Sounds/Ping.aiff"], asOtherApp: true))
}
at(7, "osascript beep — systemsoundserverd plays it; expect no report") {
    wait(spawn("/usr/bin/osascript", ["-e", "beep"], asOtherApp: true))
}
at(10, "say a long sentence as another app — expect true, then false when it finishes") {
    wait(spawn("/usr/bin/say", ["This sentence is long enough to keep the speech synthesizer talking for several seconds, which is the long loop case."], asOtherApp: true))
}
at(24, "afplay attributed to this harness (the WebKit GPU case) — expect no report") {
    wait(spawn("/usr/bin/afplay", ["/System/Library/Sounds/Submarine.aiff"], asOtherApp: false))
}
var player: AVPlayer?
at(28, "AVPlayer in this process for 4 s (the video/scene case) — expect no report") {
    _ = spawn("/usr/bin/say", ["-o", speech, "one two three four five six seven eight nine ten"], asOtherApp: false)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        player = AVPlayer(url: URL(fileURLWithPath: speech)); player?.play()
        log("AVPlayer play")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { player?.pause(); player = nil; log("AVPlayer paused") }
    }
}
at(36, "afplay looped as another app, then stop() mid-sound — expect true, then false from stop()") {
    wait(spawn("/usr/bin/afplay", [speech], asOtherApp: true))
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        log("monitor.stop()")
        monitor.stop()
    }
}
at(44, "done") {
    let rises = transitions.filter { $0.1 }.count, falls = transitions.filter { !$0.1 }.count
    log("transitions: \(transitions.map { String(format: "%.2f:%@", $0.0, $0.1 ? "on" : "off") }.joined(separator: " "))")
    // Two other-app sounds plus the stop(): exactly three rises and three falls.
    let pass = rises == 3 && falls == 3 && !monitor.isPlaying
    print(pass ? "PASS" : "FAIL: expected 3 rises and 3 falls, got \(rises) and \(falls)")
    try? FileManager.default.removeItem(atPath: speech)
    exit(pass ? 0 : 1)
}

for (t, label, action) in steps {
    DispatchQueue.main.asyncAfter(deadline: .now() + t) { log("--- \(label)"); action() }
}
RunLoop.main.run()
