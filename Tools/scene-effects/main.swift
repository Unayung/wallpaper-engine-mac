// How much of the effect chain actually works? Builds every scene through the real view model,
// pulls out the SKShaders the rasterizer wired up, and compiles each one on its own with stderr
// captured, so a shader that fails is attributed to its scene rather than lost in the noise.
import Cocoa
import SpriteKit
import Metal
extension URL { func directoryTotalAllocatedSize(includingSubfolders: Bool = false) throws -> Int? { 0 } }

let lib = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Open Wallpaper Engine")

/// Where to write the translated source of every shader that fails, named by scene. Passing a
/// directory is what turns a failure count into something diagnosable: the histogram at the end
/// says *what* the compiler objected to, the dump says which line it was looking at.
let dumpDir: URL? = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
if let dumpDir {
    try? FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)
}

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "fxerr.txt")

let flat: SKTexture = {
    let img = NSImage(size: NSSize(width: 8, height: 8))
    img.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); img.unlockFocus()
    return SKTexture(image: img)
}()

/// Compile one shader by rendering a throwaway sprite with it. Returns the compiler's complaint,
/// or nil when it built cleanly.
func compileError(_ shader: SKShader) -> String? {
    try? FileManager.default.removeItem(at: tmp)
    let saved = dup(STDERR_FILENO)
    freopen(tmp.path, "w", stderr)

    let scene = SKScene(size: CGSize(width: 8, height: 8))
    let node = SKSpriteNode(texture: flat)
    node.size = CGSize(width: 8, height: 8); node.position = CGPoint(x: 4, y: 4)
    let effect = SKEffectNode()
    effect.shader = shader; effect.shouldEnableEffects = true; effect.shouldRasterize = false
    effect.addChild(node); scene.addChild(effect)

    let renderer = SKRenderer(device: device)
    renderer.scene = scene
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .managed
    let tex = device.makeTexture(descriptor: d)!
    let cmd = queue.makeCommandBuffer()!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = tex
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    pass.colorAttachments[0].storeAction = .store
    renderer.update(atTime: 0)
    renderer.render(withViewport: CGRect(x: 0, y: 0, width: 8, height: 8), commandBuffer: cmd, renderPassDescriptor: pass)
    cmd.commit(); cmd.waitUntilCompleted()

    fflush(stderr)
    dup2(saved, STDERR_FILENO); close(saved)
    let text = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
    guard text.contains("error:") || text.contains("Jet:") else { return nil }
    let line = text.split(separator: "\n").first { $0.contains("error:") } ?? text.split(separator: "\n").first ?? ""
    return String(line.suffix(150))
}

func shaders(in node: SKNode, _ out: inout [SKShader]) {
    if let e = node as? SKEffectNode, let s = e.shader { out.append(s) }
    for c in node.children { shaders(in: c, &out) }
}

let ids = ((try? FileManager.default.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil,
                                                         options: .skipsHiddenFiles)) ?? [])
    .filter { d in
        guard let pd = try? Data(contentsOf: d.appending(path: "project.json")),
              let p = (try? JSONSerialization.jsonObject(with: pd)) as? [String: Any]
        else { return false }
        return (p["type"] as? String)?.lowercased() == "scene"
    }.map(\.lastPathComponent).sorted()

var totEffects = 0, totPasses = 0, totBuilt = 0, totUnres = 0, totUntr = 0
var totCompiled = 0, totFailed = 0
var scenesWithWorkingFX = 0, scenesWithFX = 0
var errorKinds: [String: Int] = [:]

for id in ids {
    let dir = lib.appending(path: id)
    guard let pd = try? Data(contentsOf: dir.appending(path: "project.json")),
          let project = try? JSONDecoder().decode(WEProject.self, from: pd) else { continue }
    let vm = SceneWallpaperViewModel(wallpaper: WEWallpaper(using: project, where: dir))
    var scene: SKScene?
    for _ in 0..<600 { // the build is asynchronous now; 30 s covers Honkai on a loaded machine
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if let s = vm.skScene { scene = s; break }
    }
    guard let scene else { continue }
    let t = vm.lastEffectTally
    totEffects += t.effects; totPasses += t.passes; totBuilt += t.built
    totUnres += t.unresolved; totUntr += t.untranslatable
    if t.effects > 0 { scenesWithFX += 1 }

    var list: [SKShader] = []
    for c in scene.children { shaders(in: c, &list) }
    var ok = 0, bad = 0
    var n = 0
    for s in list {
        n += 1
        if let err = compileError(s) {
            bad += 1
            let dump = dumpDir?.appending(path: "\(id)-\(n).frag")
            if let dump { try? ("// \(err)\n" + (s.source ?? "")).write(to: dump, atomically: true, encoding: .utf8) }
            let key = err.components(separatedBy: "error: ").last ?? err
            errorKinds[String(key.prefix(70)), default: 0] += 1
        } else { ok += 1 }
    }
    totCompiled += ok; totFailed += bad
    if ok > 0 { scenesWithWorkingFX += 1 }
    if t.effects > 0 {
        print(String(format: "%@ %-32@ efectos=%3d pases=%3d traducidos=%3d compilan=%3d fallan=%3d",
                     id, String(project.title.prefix(32)), t.effects, t.passes, t.built, ok, bad))
    }
}

print("""

=== TOTALES ===
escenas con efectos            : \(scenesWithFX)
escenas con al menos uno vivo  : \(scenesWithWorkingFX)
instancias de efecto           : \(totEffects)
pases                          : \(totPasses)
  traducidos                   : \(totBuilt)
  efecto no resuelto           : \(totUnres)
  no traducibles               : \(totUntr)
shaders que compilan           : \(totCompiled)
shaders que fallan             : \(totFailed)
""")
print("=== errores de compilacion mas comunes ===")
for (k, n) in errorKinds.sorted(by: { $0.value > $1.value }).prefix(12) { print("  \(n)x  \(k)") }
