// Frame cost of the effect chain. Each effect is an offscreen SKEffectNode pass, so this is the
// number that decides whether effects can be on by default in something that runs all day.
import Cocoa
import SpriteKit
import Metal
extension URL { func directoryTotalAllocatedSize(includingSubfolders: Bool = false) throws -> Int? { 0 } }

let lib = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Open Wallpaper Engine")
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!

func build(_ id: String) -> (SKScene, WEProject, SceneEffectBuilder.Tally)? {
    let dir = lib.appending(path: id)
    guard let pd = try? Data(contentsOf: dir.appending(path: "project.json")),
          let project = try? JSONDecoder().decode(WEProject.self, from: pd) else { return nil }
    let vm = SceneWallpaperViewModel(wallpaper: WEWallpaper(using: project, where: dir))
    for _ in 0..<600 { // the build is asynchronous now; 30 s covers Honkai on a loaded machine
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if let s = vm.skScene { return (s, project, vm.lastEffectTally) }
    }
    return nil
}

/// Milliseconds per frame, averaged, rendering at the scene's own resolution.
func cost(_ scene: SKScene, frames: Int = 40) -> Double {
    let w = min(Int(scene.size.width), 3840), h = min(Int(scene.size.height), 2160)
    let renderer = SKRenderer(device: device)
    renderer.scene = scene
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
    let tex = device.makeTexture(descriptor: d)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = tex
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    pass.colorAttachments[0].storeAction = .store
    // warm-up: first frame compiles pipelines
    for _ in 0..<3 {
        let cmd = queue.makeCommandBuffer()!
        renderer.update(atTime: 0)
        renderer.render(withViewport: CGRect(x: 0, y: 0, width: w, height: h), commandBuffer: cmd, renderPassDescriptor: pass)
        cmd.commit(); cmd.waitUntilCompleted()
    }
    let start = DispatchTime.now().uptimeNanoseconds
    for i in 0..<frames {
        let cmd = queue.makeCommandBuffer()!
        (scene as? WallpaperSKScene)?.update(Double(i) / 60.0)
        renderer.render(withViewport: CGRect(x: 0, y: 0, width: w, height: h), commandBuffer: cmd, renderPassDescriptor: pass)
        cmd.commit(); cmd.waitUntilCompleted()
    }
    let ns = DispatchTime.now().uptimeNanoseconds - start
    return Double(ns) / Double(frames) / 1_000_000
}

let ids = Array(CommandLine.arguments.dropFirst())
print(String(format: "%-12@ %-30@ %6@ %6@ %9@ %9@", "id", "titulo", "capas", "fx", "ms/frame", "fps max"))
for id in ids {
    guard let (scene, project, tally) = build(id) else { print("\(id): no construye"); continue }
    var nodes = 0
    func count(_ n: SKNode) { nodes += 1; for c in n.children { count(c) } }
    for c in scene.children { count(c) }
    let ms = cost(scene)
    print(String(format: "%-12@ %-30@ %6d %6d %9.2f %9.0f",
                 id, String(project.title.prefix(30)), nodes, tally.built, ms, 1000.0 / max(ms, 0.001)))
}
