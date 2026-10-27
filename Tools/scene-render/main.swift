// Offline renderer: builds the scene with the app's own SceneWallpaperViewModel and rasterises
// it through SKRenderer, so what lands in the PNG is what the wallpaper window would draw.
//
// Beyond the static composition check it now answers the two questions phases 1 and 2 raise:
// does the scene actually change over time, and does it actually shift with the cursor.
//
// Usage: scenerender <outDir> <wallpaperId ...|all>
import Cocoa
import SpriteKit
import Metal
import Foundation

// Provided by WallpaperPreview.swift in the app; stubbed here so WEProject compiles alone.
extension URL {
    func directoryTotalAllocatedSize(includingSubfolders: Bool = false) throws -> Int? { 0 }
}

let home = FileManager.default.homeDirectoryForCurrentUser
let lib = home.appending(path: "Documents/Open Wallpaper Engine")

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: scenerender <outDir> <id ...>")
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    print("no Metal device")
    exit(1)
}

/// `SKRenderer` never paints `SKScene.backgroundColor` — it only draws the node tree onto
/// whatever the render pass clears to. `SKView` covers for this by clearing to that colour itself
/// before every frame, so the two renderers only agree if this harness copies that step. Skipping
/// it made White GTR (R34), whose `clearcolor` is a near-white 0.996/0.996/0.992, come out with a
/// black background in the report and a white one in the real wallpaper window — not a rendering
/// bug, just an uninitialised clear colour standing in for one that was never applied.
func clearColor(for scene: SKScene) -> MTLClearColor {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    // backgroundColor defaults to a grayscale NSColor, which -getRed:green:blue:alpha: rejects
    // without an explicit RGB conversion first.
    (scene.backgroundColor.usingColorSpace(.deviceRGB) ?? scene.backgroundColor)
        .getRed(&r, green: &g, blue: &b, alpha: &a)
    // SKView always draws opaque, regardless of the background colour's own alpha.
    return MTLClearColorMake(Double(r), Double(g), Double(b), 1)
}

/// Every emitter in the tree, however deeply it hangs: each one sits under a per-layer holder,
/// and sometimes under a parent layer's holder as well.
func emitters(under node: SKNode) -> [SKEmitterNode] {
    node.children.flatMap { child -> [SKEmitterNode] in
        (child is SKEmitterNode ? [child as! SKEmitterNode] : []) + emitters(under: child)
    }
}

/// How a probe treats the scene's particles.
enum Particles {
    /// Run every emitter's own simulation forward to the probe's time.
    case simulate
    /// Hide them. For the parallax probe, which compares two *separate* builds of the scene:
    /// `SKEmitterNode` seeds itself, so two builds never lay their particles down in the same
    /// place, and with particles visible every emitter scene would report cursor parallax that is
    /// really just two different random draws.
    case hide
}

/// Render one frame at `advanceTo` seconds.
///
/// `SKRenderer.update(atTime:)` forwards only its first call to the scene, so
/// `WallpaperSKScene.update(_:)` runs once, at t=0, no matter what time is asked for — keyframe
/// tracks are frozen and `mov` does not measure them. Parallax still reads correctly, because the
/// cursor is set before that single tick and one tick is all it needs. `scene-cost` drives the
/// scene by hand and does not have this problem; this tool never picked the workaround up. Fixing
/// it moves all 94 scenes at once, so it is its own change — see `Tools/README.md`.
///
/// Particles are a second, worse gap, and this one *is* made up for here. This function used to
/// tick `SKRenderer.update(atTime:)` from 0 to `seconds` in 1/15 s steps, on the theory that the
/// emitters at least would advance. They do not: any `update(atTime:)` with a time above zero
/// leaves `SKRenderer` drawing *no particles at all*. Measured on a bare scene holding one
/// emitter — 50/s, 10 s lifetime, 50 pt/s upwards, 8 px white sprite — the old loop to 2 s
/// rendered 0 lit pixels; `advanceSimulationTime(2)` followed by a single `update(atTime: 0)`
/// rendered 856, centred 50 pt above the emitter where 2 s of 50 pt/s puts them. A single
/// `update(atTime: t)` for any t from 0.01 to 20 renders 0 again, whatever came before it. So the
/// report had never seen a particle: `mov` was not "particles and `SKAction`s", it was nothing
/// on a scene without keyframes, and the PNG of every snow, rain and fog scene was the scene with
/// its particle layers missing. The one tick now goes in at t=0 and each emitter is then run
/// forward on its own clock, which is the call `SKEmitterNode` provides for exactly this.
func render(_ scene: SKScene, width: Int, height: Int,
            advanceTo seconds: Double, pointer: CGPoint?,
            particles: Particles = .simulate) -> CGImage? {
    let renderer = SKRenderer(device: device)
    renderer.scene = scene
    scene.size = CGSize(width: width, height: height)
    (scene as? WallpaperSKScene)?.pointerOverride = pointer

    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .managed
    guard let tex = device.makeTexture(descriptor: desc),
          let cmd = queue.makeCommandBuffer() else { return nil }

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = tex
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = clearColor(for: scene)
    pass.colorAttachments[0].storeAction = .store

    renderer.update(atTime: 0)
    for emitter in emitters(under: scene) {
        switch particles {
        case .simulate: emitter.advanceSimulationTime(seconds)
        case .hide: emitter.isHidden = true
        }
    }
    renderer.render(withViewport: CGRect(x: 0, y: 0, width: width, height: height),
                    commandBuffer: cmd, renderPassDescriptor: pass)
    if let blit = cmd.makeBlitCommandEncoder() {
        blit.synchronize(resource: tex)
        blit.endEncoding()
    }
    cmd.commit()
    cmd.waitUntilCompleted()

    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    tex.getBytes(&bytes, bytesPerRow: width * 4,
                 from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)
}

var ids = Array(args.dropFirst(2))
if ids == ["all"] {
    ids = ((try? FileManager.default.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil,
                                                         options: .skipsHiddenFiles)) ?? [])
        .filter { d in
            guard let pd = try? Data(contentsOf: d.appending(path: "project.json")),
                  let p = (try? JSONSerialization.jsonObject(with: pd)) as? [String: Any]
            else { return false }
            return (p["type"] as? String)?.lowercased() == "scene"
        }
        .map(\.lastPathComponent).sorted()
}

/// Downsampled RGB, for comparing two frames of the same scene.
func thumb(_ cg: CGImage, _ w: Int = 128, _ h: Int = 72) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return buf }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return buf
}

/// Mean absolute channel difference between two frames, 0–255.
func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var total = 0
    for i in stride(from: 0, to: a.count, by: 4) {
        total += abs(Int(a[i]) - Int(b[i]))
            + abs(Int(a[i + 1]) - Int(b[i + 1]))
            + abs(Int(a[i + 2]) - Int(b[i + 2]))
    }
    return Double(total) / Double(a.count / 4 * 3)
}

/// Fraction of the frame taken by its single most common colour, quantised. A scene that is
/// almost entirely one colour is either empty or covered by one runaway layer.
func dominantShare(_ cg: CGImage) -> Double {
    let px = thumb(cg, 96, 54)
    var counts: [Int: Int] = [:]
    for i in stride(from: 0, to: px.count, by: 4) {
        let key = (Int(px[i]) / 24) << 8 | (Int(px[i + 1]) / 24) << 4 | (Int(px[i + 2]) / 24)
        counts[key, default: 0] += 1
    }
    return Double(counts.values.max() ?? 0) / Double(96 * 54)
}

func writePNG(_ cg: CGImage, to url: URL, width: Int, height: Int) {
    let sw = 960, sh = max(height * 960 / max(width, 1), 1)
    let small = NSImage(size: NSSize(width: sw, height: sh))
    small.lockFocus()
    NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: sw, height: sh))
    small.unlockFocus()
    if let tiff = small.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: url)
    }
}

/// Rebuilding the view model per probe is deliberate: the scene carries accumulated playback
/// time, so each probe has to start from a fresh one to be comparable.
func scene(for id: String) -> (SKScene, WEProject)? {
    let dir = lib.appending(path: id)
    guard let pd = try? Data(contentsOf: dir.appending(path: "project.json")),
          let project = try? JSONDecoder().decode(WEProject.self, from: pd) else { return nil }
    let vm = SceneWallpaperViewModel(wallpaper: WEWallpaper(using: project, where: dir))
    for _ in 0..<600 { // the build is asynchronous now; 30 s covers Honkai on a loaded machine
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if let s = vm.skScene { return (s, project) }
    }
    return nil
}

var suspicious: [String] = []
var moving: [String] = []
var parallaxing: [String] = []
var rendered = 0

/// The base frame is taken two seconds in, not at zero. At zero every emitter has just been
/// created and holds nothing, and the few particles a first tick might show are newborn — at
/// keyframe 0 of the `alphafade` sequence nearly every preset installs, which is alpha 0. A frame
/// measured there reports a snow scene as the same scene without its snow. Two seconds is past
/// the fade-in of the short-lived presets (rain, snow, embers); the long-lived fog and light-shaft
/// systems are brought up to their steady state by the app itself, from `starttime`.
let baseTime = 2.0

for id in ids {
    guard let (s0, project) = scene(for: id) else { print("\(id): sin SKScene"); continue }
    let w = Int(s0.size.width), h = Int(s0.size.height)
    guard let base = render(s0, width: w, height: h, advanceTo: baseTime, pointer: .zero) else {
        print("\(id): render fallo"); continue
    }
    rendered += 1
    let share = dominantShare(base)
    if share > 0.90 { suspicious.append("\(id) \(project.title) share=\(Int(share * 100))%") }
    writePNG(base, to: outDir.appending(path: "\(id).png"), width: w, height: h)

    // Does it move on its own? Same cursor, five seconds later.
    var motion = 0.0
    if let (s1, _) = scene(for: id),
       let later = render(s1, width: w, height: h, advanceTo: baseTime + 5, pointer: .zero) {
        motion = diff(thumb(base), thumb(later))
        if motion > 0.5 {
            moving.append("\(id) \(project.title) d=\(String(format: "%.2f", motion))")
            writePNG(later, to: outDir.appending(path: "\(id)-t5.png"), width: w, height: h)
        }
    }

    // Does it shift with the cursor? Same instant, opposite corners — and particles hidden, so
    // that two builds' different random draws are not reported as parallax.
    var shift = 0.0
    if let (sa, _) = scene(for: id), let (sb, _) = scene(for: id),
       let left = render(sa, width: w, height: h, advanceTo: 1.0, pointer: CGPoint(x: -1, y: -1),
                         particles: .hide),
       let right = render(sb, width: w, height: h, advanceTo: 1.0, pointer: CGPoint(x: 1, y: 1),
                          particles: .hide) {
        shift = diff(thumb(left), thumb(right))
        if shift > 0.5 {
            parallaxing.append("\(id) \(project.title) d=\(String(format: "%.2f", shift))")
            writePNG(right, to: outDir.appending(path: "\(id)-pan.png"), width: w, height: h)
        }
    }

    // `nodos` counts top-level layers, one per scene object, so it cannot see anything a layer
    // builds *inside* its own holder — a particle system's child emitters hang beside the parent
    // emitter, not beside the layer. `emis` counts every emitter in the tree, which is the number
    // that moves when a child system is added or lost.
    print(String(format: "%@: %-30@ nodos=%3d emis=%3d dom=%3d%% mov=%6.2f parallax=%6.2f%@",
                 id, String(project.title.prefix(30)), s0.children.count,
                 emitters(under: s0).count,
                 Int(share * 100), motion, shift, share > 0.90 ? "  <-- SOSPECHOSO" : ""))
}

print("\n=== \(rendered) escenas renderizadas ===")
print("\nCON MOVIMIENTO PROPIO (\(moving.count)):")
for m in moving { print("  \(m)") }
print("\nCON PARALLAX DE CURSOR (\(parallaxing.count)):")
for p in parallaxing { print("  \(p)") }
print("\nSOSPECHOSAS (\(suspicious.count)):")
for s in suspicious { print("  \(s)") }
