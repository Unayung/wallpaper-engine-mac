// Whole-library check: every wallpaper the library grid would list, put through the same steps
// the app takes to show it, with a PASS/FAIL line each and a non-zero exit when anything fails.
//
// The scene tools answer "does this scene look right". This one answers the question before it —
// "would this wallpaper load at all" — for all three types, because video and web wallpapers had
// no instrument whatsoever: a broken one was found by applying it and looking at the desktop.
//
// Every step goes through the app's own code where the app has code for it: `WEProject` decodes
// the manifest, `FileManager.wallpapersDirectory` finds the library, `WEProject.renderer` decides
// the type, and `SceneWallpaperViewModel` builds the scene. Where the app hands the work to a
// system framework (AVPlayer, WKWebView, NSImageView), the check asks that same framework.
//
// Usage: appcheck [wallpaperId ...]      (no ids: the whole library)
import Cocoa
import AVFoundation
import VideoToolbox
import SpriteKit
import Foundation

// Provided by WallpaperPreview.swift in the app; stubbed here so WEProject compiles alone.
extension URL {
    func directoryTotalAllocatedSize(includingSubfolders: Bool = false) throws -> Int? { 0 }
}

// The app registers VideoToolbox's supplemental decoders at launch (see
// AppDelegate.applicationWillFinishLaunching); without the same call here a VP9 wallpaper the app
// plays would be reported as undecodable.
VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)

let fm = FileManager.default
let lib = fm.wallpapersDirectory

// MARK: - Result bookkeeping

/// One wallpaper's verdict. `failures` decide PASS/FAIL; `notes` are facts worth printing that do
/// not make the wallpaper unusable (a codec, a resolution, a remote font the page will miss offline).
struct Report {
    let id: String
    var title = ""
    var type = "?"
    var failures: [String] = []
    var notes: [String] = []
    var skipped: String?
}

func path(_ url: URL) -> String { url.path(percentEncoded: false) }
func exists(_ url: URL) -> Bool { fm.fileExists(atPath: path(url)) }

/// Run an async AVFoundation load to completion on this thread. The tool is a straight-line
/// script, and the main run loop has to keep turning meanwhile — `SceneWallpaperViewModel`
/// publishes its scene through `DispatchQueue.main`, so blocking it with a semaphore would also
/// block that.
func block<T>(_ body: @escaping () async throws -> T) -> Result<T, Error> {
    var result: Result<T, Error>?
    Task.detached {
        do { result = .success(try await body()) } catch { result = .failure(error) }
    }
    let deadline = Date().addingTimeInterval(30)
    while result == nil && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return result ?? .failure(NSError(domain: "appcheck", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "timed out after 30 s"]))
}

func fourCC(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
    let s = String(bytes: bytes, encoding: .ascii) ?? "?"
    return s.trimmingCharacters(in: .whitespaces).isEmpty ? String(code) : s
}

/// FourCCs AVFoundation has a decoder for on every Mac this app targets (13.0+). Anything outside
/// it is flagged by name even when it happens to decode here — `av01` decodes only on Apple
/// silicon with an AV1 block (M3 and later), so "it worked on my machine" is the wrong standard
/// for a codec. Whether it actually decoded is checked separately, by pulling a frame.
let portableCodecs: Set<String> = ["avc1", "avc3", "hvc1", "hev1", "mp4v", "jpeg", "apcn", "apch",
                                   "apcs", "apco", "ap4h", "ap4x", "dvh1", "dvhe"]

// MARK: - Checks shared by every type

func checkPreview(_ project: WEProject, dir: URL, into r: inout Report) {
    // ExplorerItem and WallpaperPreview both resolve the tile as `dir.appending(path: preview)`
    // and hand it to an NSImageView, so that is what has to succeed.
    guard !project.preview.isEmpty else { r.failures.append("project.json names no preview"); return }
    let url = dir.appending(path: project.preview)
    guard exists(url) else { r.failures.append("preview missing: \(project.preview)"); return }
    guard let image = NSImage(contentsOf: url),
          image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil else {
        r.failures.append("preview does not decode as an image: \(project.preview)"); return
    }
}

// MARK: - video

func checkVideo(_ url: URL, into r: inout Report) {
    let asset = AVURLAsset(url: url)
    let loaded = block { () -> (Bool, CMTime, [AVAssetTrack]) in
        let (playable, duration) = try await asset.load(.isPlayable, .duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        return (playable, duration, tracks)
    }
    guard case .success(let (playable, duration, tracks)) = loaded else {
        if case .failure(let e) = loaded { r.failures.append("AVFoundation cannot open it: \(e.localizedDescription)") }
        return
    }
    guard let track = tracks.first else { r.failures.append("no video track"); return }

    let info = block { () -> (CGSize, CGAffineTransform, [CMFormatDescription], Float) in
        try await track.load(.naturalSize, .preferredTransform, .formatDescriptions, .nominalFrameRate)
    }
    if case .success(let (size, transform, formats, fps)) = info {
        let shown = size.applying(transform)
        let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
        r.notes.append(String(format: "%@ %dx%d %.0ffps %.1fs", codec,
                              Int(abs(shown.width)), Int(abs(shown.height)), fps, duration.seconds))
        // A portability warning, not a failure: whether it plays *here* is decided by the frame
        // pulled below, with the same supplemental decoders the app registers at launch.
        if !portableCodecs.contains(codec) {
            r.notes.append("⚠ codec \(codec) needs a decoder not every supported Mac has")
        }
    }
    if !(duration.seconds > 0) { r.failures.append("duration is \(duration.seconds) s") }
    if !playable { r.failures.append("AVAsset.isPlayable is false") }

    // The decisive test: a frame. This is exactly what AppDelegate.setPlacehoderWallpaper asks for
    // to tint the menu bar, and the first thing an AVPlayerLayer would draw.
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 320, height: 320)
    let frame = block { try await generator.image(at: .zero).image }
    if case .failure(let e) = frame { r.failures.append("first frame does not decode: \(e.localizedDescription)") }
}

// MARK: - web

/// Pull every value of `src=`, `href=`, `data=` and CSS `url(...)` out of a document. A regex
/// rather than a parser on purpose: the question is only "which addresses does this page name",
/// and Workshop HTML is not reliably well-formed enough for XMLDocument.
func references(in text: String) -> [String] {
    let patterns = [#"(?i)\b(?:src|href|data)\s*=\s*["']([^"'<>]+)["']"#,
                    #"(?i)url\(\s*["']?([^"')]+)["']?\s*\)"#]
    var out: [String] = []
    for p in patterns {
        guard let re = try? NSRegularExpression(pattern: p) else { continue }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces))
        }
    }
    return out
}

/// Remote addresses in script code: `fetch`, XHR and dynamic `src` assignments all end up as a
/// string literal beginning with a scheme. Namespace URIs (`http://www.w3.org/2000/svg`) look the
/// same and are never fetched, so they are dropped.
func remoteLiterals(in text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: #"["'`]((?:https?:|wss?:)?//[A-Za-z0-9.-]+\.[A-Za-z]{2,}[^"'`\s]*)["'`]"#)
    else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range(at: 1)) }
        .filter { !$0.contains("www.w3.org/") && !$0.contains("ns.adobe.com") }
}

func host(of ref: String) -> String {
    let normalised = ref.hasPrefix("//") ? "https:" + ref : ref
    return URL(string: normalised)?.host ?? ref
}

func checkWeb(_ entry: URL, dir: URL, into r: inout Report) {
    guard let data = try? Data(contentsOf: entry) else { r.failures.append("entry html unreadable"); return }
    let html = String(decoding: data, as: UTF8.self)

    // WebWallpaperView.loadWallpaper switches to loadHTMLString with an https://localhost base when
    // the page mentions YouTube or Vimeo, and every relative reference then resolves against a
    // server that does not exist.
    let htmlStringMode = html.contains("youtube.com") || html.contains("vimeo.com")
    if htmlStringMode { r.notes.append("loaded as HTML string (youtube/vimeo) — relative refs will not resolve") }

    var remote = Set<String>()
    var missing: [String] = []
    var rooted: [String] = []
    for ref in references(in: html) {
        let lower = ref.lowercased()
        if lower.hasPrefix("data:") || lower.hasPrefix("javascript:") || lower.hasPrefix("#")
            || lower.hasPrefix("mailto:") || lower.hasPrefix("blob:") || ref.contains("{") || ref.contains("+") {
            continue
        }
        if lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("//") {
            remote.insert(host(of: ref)); continue
        }
        if lower.hasPrefix("file:") || ref.hasPrefix("/") {
            // loadFileURL resolves "/x.js" against the filesystem root, not the wallpaper.
            rooted.append(ref); continue
        }
        let local = String(ref.split(separator: "?").first ?? "").split(separator: "#").first.map(String.init) ?? ""
        guard !local.isEmpty else { continue }
        let decoded = local.removingPercentEncoding ?? local
        if !exists(entry.deletingLastPathComponent().appending(path: decoded)) { missing.append(local) }
    }

    // Scripts and stylesheets the page ships, for addresses it fetches at run time.
    if let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
        for case let file as URL in walker where ["js", "css", "html", "htm"].contains(file.pathExtension.lowercased()) {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 8_000_000,
                  let d = try? Data(contentsOf: file) else { continue }
            remoteLiterals(in: String(decoding: d, as: UTF8.self)).forEach { remote.insert(host(of: $0)) }
        }
    }

    if !missing.isEmpty { r.failures.append("local references missing: \(missing.prefix(6).joined(separator: ", "))") }
    if !rooted.isEmpty { r.failures.append("root-absolute references (resolve outside the wallpaper): \(rooted.prefix(6).joined(separator: ", "))") }
    if !remote.isEmpty { r.notes.append("offline-dependent hosts: \(remote.sorted().joined(separator: ", "))") }
}

// MARK: - scene

func checkScene(_ project: WEProject, dir: URL, into r: inout Report) {
    // Mirror SceneWallpaperViewModel.loadScene's own lookup to say *which* source it used.
    let pkg = dir.appending(path: (project.file as NSString).deletingPathExtension + ".pkg")
    let loose = dir.appending(path: project.file)
    if exists(pkg) { r.notes.append(pkg.lastPathComponent) }
    else if exists(loose) { r.notes.append("loose \(project.file)") }
    else { r.failures.append("neither \(pkg.lastPathComponent) nor \(project.file) exists"); return }

    let vm = SceneWallpaperViewModel(wallpaper: WEWallpaper(using: project, where: dir))
    var built: SKScene?
    // Scenes are built off the main thread and published back to it, so this has to wait as
    // long as the slowest real build: 2 s reported Honkai (3.9 s to build) as "produced no
    // scene" on a loaded machine. The scenecheck tools wait 30 s for the same reason.
    for _ in 0..<1200 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        if let s = vm.skScene { built = s; break }
    }
    guard let scene = built else { r.failures.append("SceneWallpaperViewModel produced no scene"); return }
    var nodes = 0
    func count(_ n: SKNode) { nodes += 1; n.children.forEach(count) }
    scene.children.forEach(count)
    // A plain SKScene rather than WallpaperSKScene is the 3D fallback: the preview, alone.
    if scene.name == SceneWallpaperViewModel.PreviewReason.unreadable.rawValue {
        r.failures.append("scene.json could not be read; the window shows the preview instead")
        return
    }
    r.notes.append(scene is WallpaperSKScene ? "\(nodes) nodes" : "\(nodes) nodes (3D: preview only)")
    if nodes == 0 { r.failures.append("scene built with no nodes — the wallpaper window would be blank") }
}

// MARK: - Driver

func check(_ dir: URL, explicit: Bool) -> Report? {
    var r = Report(id: dir.lastPathComponent)
    let manifest = dir.appending(path: "project.json")
    // ContentViewModel.allWallpapers drops a folder with no project.json outright: not a wallpaper.
    // Asked for by name, though, a missing manifest is the answer to the question.
    guard exists(manifest) else {
        if explicit { r.failures.append("no project.json at \(path(dir))"); return r }
        return nil
    }
    guard let data = try? Data(contentsOf: manifest) else { r.failures.append("project.json unreadable"); return r }

    let project: WEProject
    do {
        project = try JSONDecoder().decode(WEProject.self, from: data)
    } catch {
        // allWallpapers also drops a manifest with no `type` at all — a Workshop preset, which is
        // a settings override for another item and has nothing of its own to render. Mirror that
        // so the tally counts what the grid shows.
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if raw?["type"] == nil {
            r.title = raw?["title"] as? String ?? ""
            r.skipped = "no type (Workshop preset; the library hides it)"
            return r
        }
        r.failures.append("WEProject does not decode: \(error)")
        return r
    }
    r.title = project.title
    r.type = project.type

    checkPreview(project, dir: dir, into: &r)

    guard let renderer = project.renderer else {
        r.failures.append("type \"\(project.type)\" has no renderer — WallpaperView would draw nothing")
        return r
    }
    if project.type != renderer.rawValue { r.notes.append("type spelt \"\(project.type)\"") }
    // A page that renders but is not gated would run Workshop JavaScript with no warning. The gate
    // used to compare `type` verbatim, which is exactly how the three `"Web"` pages slipped by.
    if renderer == .web && !project.runsUntrustedCode {
        r.failures.append("web page is not gated by the unsafe-wallpaper warning (type \"\(project.type)\")")
    }

    guard !project.file.isEmpty else { r.failures.append("project.json names no file"); return r }
    let file = dir.appending(path: project.file)
    // A scene's `file` names the scene.json *inside* its .pkg, which is normally the only copy on
    // disk — checkScene resolves it the way the loader does, so only the other two types need the
    // file to exist loose.
    if renderer != .scene, !exists(file) { r.failures.append("file missing: \(project.file)"); return r }

    switch renderer {
    case .video: checkVideo(file, into: &r)
    case .web: checkWeb(file, dir: dir, into: &r)
    case .scene: checkScene(project, dir: dir, into: &r)
    }
    return r
}

let requested = Array(CommandLine.arguments.dropFirst())
let dirs: [URL] = requested.isEmpty
    ? ((try? fm.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
        // No directory filter: most of a library is symlinks into steamcmd's workshop/content
        // folder, which `.isDirectoryKey` reports as not directories. Filtering on it checked 32
        // of 163 entries. ContentViewModel does not filter either — check() drops what has no
        // project.json, exactly as allWallpapers does.
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    : requested.map { lib.appending(path: $0) }

var reports: [Report] = []
var notWallpapers: [String] = []
for dir in dirs {
    guard let r = check(dir, explicit: !requested.isEmpty) else {
        notWallpapers.append(dir.lastPathComponent); continue
    }
    reports.append(r)
    let verdict = r.skipped != nil ? "SKIP" : (r.failures.isEmpty ? "PASS" : "FAIL")
    var line = String(format: "%@  %-12@ %-6@ %-34@", verdict, r.id, r.type.lowercased(),
                      String(r.title.prefix(34)))
    if let s = r.skipped { line += "  " + s }
    if !r.notes.isEmpty { line += "  " + r.notes.joined(separator: "; ") }
    print(line)
    for f in r.failures { print("        ✗ \(f)") }
    fflush(stdout)
}

let checked = reports.filter { $0.skipped == nil }
let failed = checked.filter { !$0.failures.isEmpty }
print("\n=== \(checked.count) wallpapers checked: \(checked.count - failed.count) PASS, \(failed.count) FAIL, "
      + "\(reports.count - checked.count) SKIP ===")
if !notWallpapers.isEmpty {
    print("  (\(notWallpapers.count) entries without a project.json, not listed by the app: "
          + "\(notWallpapers.joined(separator: ", ")))")
}
for t in ["video", "web", "scene"] {
    let of = checked.filter { $0.type.lowercased() == t }
    print("  \(t): \(of.count - of.filter { !$0.failures.isEmpty }.count)/\(of.count) pass")
}
let other = checked.filter { !["video", "web", "scene"].contains($0.type.lowercased()) }
if !other.isEmpty { print("  other: \(other.count - other.filter { !$0.failures.isEmpty }.count)/\(other.count) pass") }
if !failed.isEmpty {
    print("\nFAIL:")
    for r in failed { print("  \(r.id) \(r.title): \(r.failures.joined(separator: " | "))") }
}
exit(failed.isEmpty ? 0 : 1)
