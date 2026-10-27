//
//  SceneWallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Loads and renders Wallpaper Engine scene wallpapers using SpriteKit.
//  Follows the same ViewModel pattern as VideoWallpaperViewModel.
//

import Metal
import os
import SpriteKit
import SwiftUI

/// The Settings → Performance → Quality controls, as the scene builder reads them.
///
/// Plain values rather than a reference to `GlobalSettings`, for two reasons. The offline tools in
/// `Tools/scenecheck` compile this file without `GlobalSettingsService.swift`, and they have to be
/// able to build a scene at each setting to measure it. And `SceneWallpaperView` creates this
/// model from its own `init`, where reaching for `AppDelegate.shared` is the re-entrancy trap
/// CLAUDE.md describes; the view already holds the settings and hands them in.
///
/// Every field is consumed at build time, so a change is applied by rebuilding the scene — see
/// `quality`'s `didSet`. That is the difference from the `SceneEffectsDisabled` default, which is
/// read once per launch.
struct SceneQuality: Equatable {
    /// Settings → Post-Processing. Off builds every layer without its effect chain, the same
    /// composite `SceneEffectsDisabled` produces.
    var effects = true
    /// Settings → Reflections. Off skips every pass whose shader is Wallpaper Engine's
    /// `reflection` (`SceneEffectBuilder.reflections`); the rest of the chain is built as usual.
    /// Meaningless while `effects` is off, where no pass is built at all.
    var reflections = true
    /// Settings → Texture Resolution.
    var textures = TextureBudget.full
    /// Settings → General → Developer → Disable scene scripts, inverted. Off builds no
    /// `SceneScriptRuntime`, so every scripted layer keeps the string or value Wallpaper Engine
    /// baked into the scene — which is how a scripted layer is told apart from a mis-rendered one.
    var scripts = !UserDefaults.standard.bool(forKey: WEAssetLibrary.scriptsDisabledKey)
    /// The shared Wallpaper Engine asset library this build resolves `models/util`,
    /// `materials/util`, `particles/presets` and shaders against; nil when none is found. Part of
    /// the quality only so that changing it in Settings rebuilds a scene that is already showing,
    /// by the same comparison that rebuilds it for a quality control.
    var assetsRoot: URL? = WEAssetLibrary.resolvedRoot()
    /// The display the scene is shown on, in points; nil offline, where scenes render at their
    /// authored size. `renderEffectsAtDrawnSize` needs it: an effect's offscreen follows the
    /// window's backing scale but not the aspect-fill magnification from scene to view, so a
    /// 1080p scene on a 1440p screen is magnified 1.33× *after* its effects are shaded.
    var displayPoints: CGSize?

    enum TextureBudget: Equatable {
        /// Every image layer at the resolution it was authored at.
        case full
        /// Every image layer above `SceneQuality.minimumScaledSide` scaled by this factor per
        /// axis. "High Performance" is 0.5: a quarter of the texels, at a visible loss.
        case scaled(CGFloat)
        /// Each image layer reduced to the pixels it actually covers on a display of this many
        /// pixels — "Automatic". Nothing smaller than the display can show is thrown away, so on
        /// a display at or above the scene's resolution this changes nothing.
        case display(CGSize)
    }

    /// Below this, scaling a texture saves too little memory to be worth its blur. Over the
    /// installed library 75 of the 362 textured image layers are this small; the other 287 hold
    /// essentially all of the 973.5 M texels. Particle and text textures never pass through the
    /// budget at all.
    static let minimumScaledSide = 256

    /// The quality the offline tools build at: the defaults, unless overridden on the command
    /// line through `UserDefaults`' argument domain — `-SceneEffectsDisabled YES`,
    /// `-SceneReflections NO`, `-SceneTextureScale 0.5`, `-SceneTextureDisplay 2560x1440`.
    /// The app never builds at this value: it builds at what Settings say. Only
    /// `SceneEffectsDisabled` is read there too, as the escape hatch it always was.
    static var fromDefaults: SceneQuality {
        let defaults = UserDefaults.standard
        // `scripts` (`-SceneScriptsDisabled YES`) and `assetsRoot` (`-WallpaperEngineAssetsPath
        // …`) are read by the property defaults themselves.
        var quality = SceneQuality()
        quality.effects = !defaults.bool(forKey: "SceneEffectsDisabled")
        // Read as an object, not `bool(forKey:)`, so that absent means the default (on) rather
        // than false.
        if defaults.object(forKey: "SceneReflections") != nil {
            quality.reflections = defaults.bool(forKey: "SceneReflections")
        }
        let scale = defaults.double(forKey: "SceneTextureScale")
        if scale > 0, scale < 1 { quality.textures = .scaled(CGFloat(scale)) }
        if let display = defaults.string(forKey: "SceneTextureDisplay") {
            let parts = display.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, parts[0] > 0, parts[1] > 0 {
                quality.textures = .display(CGSize(width: parts[0], height: parts[1]))
            }
        }
        return quality
    }
}

/// Where the shared Wallpaper Engine asset library is, and the developer switch stored beside it.
///
/// Scenes reference a shared asset library — `models/util`, `materials/util`,
/// `particles/presets`, shaders, fonts — that they never bundle in their own `.pkg`. It ships only
/// inside a Wallpaper Engine install, so without it those layers silently fail to resolve.
///
/// This used to be a `static let` on the view model, resolved once per launch, as was
/// `SceneScriptRuntime`'s `SceneScriptsDisabled`. Both are now Settings controls (General →
/// Developer), and a value frozen at launch would have made a changed path or switch do nothing
/// until a restart, so they are read for every build and carried in `SceneQuality`.
enum WEAssetLibrary {
    /// A path the user chose, in Settings or with `defaults write`. Used only while it exists; a
    /// path on an unmounted volume falls back to the default locations rather than leaving every
    /// scene without its shared assets.
    static let pathKey = "WallpaperEngineAssetsPath"
    /// Freezes every scripted layer at its baked value; see `SceneQuality.scripts`.
    static let scriptsDisabledKey = "SceneScriptsDisabled"

    /// Where Steam installs Wallpaper Engine, in the order they are tried.
    static var defaultCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets"),
            home.appending(path: "Steam/steamapps/common/wallpaper_engine/assets"),
        ]
    }

    /// The user's override, when one is set (whether or not it exists).
    static var customPath: String? {
        guard let path = UserDefaults.standard.string(forKey: pathKey), !path.isEmpty else { return nil }
        return path
    }

    /// The library scenes are built against: the override when it exists, else the first default
    /// location that does, else nil.
    static func resolvedRoot() -> URL? {
        let fm = FileManager.default
        if let custom = customPath, fm.fileExists(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        return defaultCandidates.first { fm.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
}

class SceneWallpaperViewModel: ObservableObject {
    static func log(_ msg: String) {
        let line = "[SceneVM] \(msg)"
        NSLog("%@", line)
    }

    var currentWallpaper: WEWallpaper {
        willSet {
            loadScene(from: newValue)
        }
    }

    @Published var skScene: SKScene?

    /// True when the published scene draws the same frame forever: nothing the evaluator moves,
    /// no emitters, no pass that reads the clock, no script feeding a text layer. 9 of the 91
    /// scenes in the library are; SceneWallpaperView stops re-rendering them after the first
    /// frames. Published together with `skScene`, before it.
    @Published private(set) var isStill = false

    /// The open package of the scene being built. Build state, owned by `loadQueue`, and only
    /// while a build runs: `PKGParser` holds the whole `.pkg` in memory — tens to hundreds of MB
    /// of textures — and nothing reads it once the scene is built, so `loadScene` drops it
    /// afterwards rather than keep a second copy of every texture alive for as long as the
    /// wallpaper shows. A rebuild (a quality change, a new wallpaper) opens the package again.
    private var pkgParser: PKGParser?

    /// The wallpaper's user property values, read from its `project.json` for each build. Build
    /// state like `pkgParser`, owned by `loadQueue`. See `SceneUserProperties`.
    private var userProperties = SceneUserProperties()

    /// Additive layers (glows, light overlays) are composited with `.add`, which is how
    /// Wallpaper Engine draws them. Set to `true` to restore the old behaviour of dropping them.
    private static let skipAdditiveLayers = false

    /// Where a shared asset path may live inside the WE asset library.
    /// The library is the one this build was asked for (`building.assetsRoot`; see
    /// `WEAssetLibrary`), so this runs on `loadQueue` only.
    private func sharedAssetURLs(for path: String) -> [URL] {
        guard let root = building.assetsRoot else { return [] }
        var urls = [root.appending(path: path)]
        // Particle presets are stored per theme: "particles/presets/snow.json"
        // actually lives at "presets/snow/particles/presets/snow.json".
        if path.hasPrefix("particles/presets/") {
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            if !name.isEmpty {
                urls.append(root.appending(path: "presets/\(name)/\(path)"))
            }
        }
        return urls
    }

    /// What the next build honours. Set on the main thread only; a change rebuilds the scene, so
    /// moving a quality control reaches a wallpaper that is already showing.
    var quality: SceneQuality {
        didSet {
            if quality != oldValue { loadScene(from: currentWallpaper) }
        }
    }

    /// The quality the scene being built was asked for. Build state, owned by `loadQueue`: it is
    /// copied out of `quality` on the main thread when the load is queued, so a build never reads
    /// a value the main thread is writing.
    private var building = SceneQuality()

    init(wallpaper: WEWallpaper, quality: SceneQuality = .fromDefaults) {
        self.quality = quality
        self.currentWallpaper = wallpaper
        Self.log("init: wallpaper=\(wallpaper.project.title) dir=\(wallpaper.wallpaperDirectory.path)")
        // Display sleep is a policy decision, not a playback one: AppDelegate observes the
        // sleep/wake notifications and applies the `Display asleep` setting through playRate,
        // which SceneWallpaperView already mirrors onto the view's isPaused.
        loadScene(from: wallpaper)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Scene Loading

    /// Where scenes are parsed and built. Never the main thread: a build is PKG parsing, LZ4 and
    /// texture decoding, MP4 first-frame extraction and shader compilation, and measured over the
    /// library it took a median of 116 ms and up to 2.3 s (Honkai). It used to run inline — from
    /// this model's init, which SwiftUI calls on main, and again on every
    /// `rebuildWallpaperWindows()` — so the whole app beachballed for the length of every scene on
    /// every screen whenever a display woke or was rearranged.
    ///
    /// Serial and per instance, which is what keeps the build state below (`pkgParser`,
    /// `tintShaders`, …) single-threaded without a lock: two loads of one model never overlap,
    /// and nothing on the main thread reads that state. Two screens still build in parallel.
    /// Building `SKNode`s off the main thread is fine as long as nothing has presented them yet.
    private let loadQueue = DispatchQueue(label: "scene.load", qos: .userInitiated)

    /// Bumped on the main thread for every load, so a slow build of a wallpaper the user has
    /// already switched away from cannot land on top of the newer one.
    private var loadGeneration = 0

    /// `loadGeneration` as the load queue sees it. The main-thread counter alone only kept a stale
    /// build from being *published*: every superseded build still ran to completion first, and on
    /// a serial queue that is time the wanted one waits behind. Dragging the quality slider, or a
    /// screen reconfiguring twice, queued a full rebuild per step — Honkai's 2.3 s each — before
    /// the last one could start. A lock rather than reading `loadGeneration` from the queue,
    /// because that property is written on main.
    private let latestGeneration = OSAllocatedUnfairLock(initialState: 0)

    /// The generation the build in progress belongs to. Build state, owned by `loadQueue`.
    private var buildingGeneration = 0

    /// Whether a newer load has been asked for since this build started, so the rest of it is
    /// wasted work. Checked on `loadQueue` at the start of a build and between layers.
    private var buildIsSuperseded: Bool {
        latestGeneration.withLock { $0 } != buildingGeneration
    }

    func loadScene(from wallpaper: WEWallpaper) {
        loadGeneration += 1
        let generation = loadGeneration
        latestGeneration.withLock { $0 = generation }
        let quality = self.quality
        loadQueue.async { [weak self] in
            guard let self else { return }
            self.buildingGeneration = generation
            guard !self.buildIsSuperseded else {
                Self.log("build \(generation) superseded before it started, skipped")
                return
            }
            self.building = quality
            if let root = quality.assetsRoot {
                Self.log("WE asset library: \(root.path(percentEncoded: false))")
            } else {
                Self.log("WE asset library not found — util models/materials and particle presets will not resolve")
            }
            let built = self.buildScene(from: wallpaper)
            // Build-only state. The package and the per-build tables are not read after this
            // point — the scene keeps its own references to everything it draws — so they go
            // now instead of when the next build happens to overwrite them.
            self.pkgParser = nil
            self.builtEffectNodes = [:]
            self.builtSpriteAnimations = []
            self.builtScriptedMotions = []
            self.lastSheetTextures = []
            self.tintShaders.removeAll()
            guard let built else {
                Self.log("build \(generation) superseded, abandoned")
                return
            }
            let still = self.builtSceneIsStill
            DispatchQueue.main.async {
                // Still checked here: a load asked for after the build finished must win too.
                guard generation == self.loadGeneration else { return }
                self.isStill = still
                self.skScene = built
            }
        }
    }

    /// Whether the scene the last build produced is still — see `isStill`. Build state, owned by
    /// `loadQueue` like the rest of it.
    private var builtSceneIsStill = false
    private var builtTimeVaryingPass = false
    /// Image layers whose texture is a sprite sheet that plays. Build state, like the above.
    private var builtSpriteAnimations: [WallpaperSKScene.SpriteAnimation] = []
    /// Objects whose sprite-sheet frame a script chooses — see `scriptedTextureAnimations`.
    private var scriptedFrameLayers: Set<Int> = []
    /// The frames of the sprite sheet the last `buildImageNode` call drew, if it had one.
    private var lastSheetTextures: [SKTexture] = []
    /// Layers moved by upstream's recognised script shapes — see `WallpaperSKScene.ScriptedMotion`.
    private var builtScriptedMotions: [WallpaperSKScene.ScriptedMotion] = []

    /// The native stand-in for a moving origin script, when it is one of the shapes upstream's
    /// 0.9.0 recognises: a MapleStory `shared.Mob`, the `MotionItem` helper, or a hand-rolled
    /// step-and-wrap. Tried in that order, as upstream does. The controllers start from the
    /// holder as built, so a script that only drifts a layer starts it where the author put it.
    static func scriptedMotion(_ source: String, holder: SKNode, artwork: SKSpriteNode,
                               sheet: [SKTexture], canvas: CGSize,
                               constants: [String: Double]) -> WallpaperSKScene.ScriptedMotion? {
        let start = MotionItemPosition(x: holder.position.x, y: holder.position.y)
        if let config = MobScriptParser.parse(source) {
            return .init(holder: holder, driver: .mob(
                MobController(configuration: config, initialX: start.x),
                artwork: artwork, textures: sheet, baseXScale: artwork.xScale))
        }
        if let config = MotionItemScriptParser.parse(source) {
            // The item's extent as drawn: the holder carries the layer's scale.
            let size = MotionItemSize(width: artwork.size.width * abs(holder.xScale),
                                      height: artwork.size.height * abs(holder.yScale))
            return .init(holder: holder, driver: .item(MotionItemController(
                configuration: config,
                canvasSize: MotionItemSize(width: canvas.width, height: canvas.height),
                itemSize: size, initialPosition: start)))
        }
        if let config = ScriptedOriginMotionParser.parse(source, constants: constants) {
            return .init(holder: holder, driver: .origin(
                ScriptedOriginMotionController(configuration: config, initialPosition: start)))
        }
        return nil
    }

    /// The objects whose texture frame is chosen by a script rather than by the clock.
    ///
    /// Not every sprite sheet is an animation. Some are a set of states a script switches
    /// between through `getTextureAnimation().setFrame(n)`: a shuffle button's on and off
    /// (2847470774), an AM/PM indicator that is two frames of one texture (Lonely Cat), a
    /// day/night switch the user clicks through (Lost Landscape). Played on the clock they
    /// flicker between their states — Lonely Cat's clock read AM and PM in turn, a second each.
    /// Measured over the library: 6 layers in 5 scenes have a sheet that comes through whole,
    /// and 4 of them are reached by a script — those three plus 2847470774's play/pause morph,
    /// which its player script steps on a click. The other 2, Retro Room's arcade screen and the
    /// Samurai's walk, are the real animations, and they play. The script runtime offers no
    /// texture animation (`thisScene.getLayer` handles hold plain values only), so such a layer
    /// keeps frame 0, as it always did.
    ///
    /// A script reaches a layer two ways: bound to one of the layer's own fields (`thisLayer`),
    /// or from another layer by name, `thisScene.getLayer('name')`. Every field's script is
    /// searched (`WESceneObject.allScripts`), not just the five this model runs: the day/night
    /// switch's sits on `angles`, and reading only the known fields played it.
    static func scriptedTextureAnimations(in objects: [WESceneObject]) -> Set<Int> {
        func scripts(of obj: WESceneObject) -> [String] { obj.allScripts }
        let controlling = objects.flatMap(scripts).filter { $0.contains("getTextureAnimation") }
        guard !controlling.isEmpty else { return [] }
        var out: Set<Int> = []
        for obj in objects {
            guard let id = obj.id else { continue }
            if scripts(of: obj).contains(where: { $0.contains("getTextureAnimation") }) {
                out.insert(id)
                continue
            }
            if let name = obj.name, !name.isEmpty,
               controlling.contains(where: { $0.contains("'\(name)'") || $0.contains("\"\(name)\"") }) {
                out.insert(id)
            }
        }
        return out
    }

    /// Parse and build one wallpaper's scene. Runs on `loadQueue` only. Nil only when the build
    /// was superseded partway; an unreadable scene still returns its preview.
    private func buildScene(from wallpaper: WEWallpaper) -> SKScene? {
        let dir = wallpaper.wallpaperDirectory
        let sceneFile = wallpaper.project.file  // e.g. "scene.json" or "gifscene.json"

        // Derive PKG name from scene file: "scene.json" → "scene.pkg", "gifscene.json" → "gifscene.pkg"
        let pkgName = (sceneFile as NSString).deletingPathExtension + ".pkg"
        let pkgURL = dir.appending(path: pkgName)
        let looseSceneURL = dir.appending(path: sceneFile)

        var scene: WEScene?

        // Fields bound to a user property resolve to the project's value while decoding, which
        // is why only the scene file gets this decoder: presets and models carry no bindings.
        // Re-read every build so a property changed on disk is picked up by the next load.
        userProperties = SceneUserProperties(wallpaperDirectory: dir)
        let decoder = JSONDecoder()
        decoder.userInfo[SceneUserProperties.userInfoKey] = userProperties

        // Cleared first, so a package that fails to open cannot leave the previous wallpaper's
        // parser answering this one's asset lookups.
        self.pkgParser = nil
        if FileManager.default.fileExists(atPath: pkgURL.path(percentEncoded: false)) {
            do {
                let parser = try PKGParser(url: pkgURL)
                self.pkgParser = parser
                scene = try parser.extractJSON(named: sceneFile, as: WEScene.self, decoder: decoder)
                if scene == nil { Self.log("\(pkgName) has no \(sceneFile)") }
            } catch {
                Self.log("Failed to read \(sceneFile) from \(pkgName): \(error)")
            }
        }
        // Loose files: a wallpaper with no package, and also one whose package is there but
        // unreadable, truncated, or missing the scene file. That used to be an `else if`, so a
        // present-but-broken `.pkg` went straight to the preview even with a good `scene.json`
        // beside it. A package that did open stays in place for asset lookups, behind which the
        // loose files are tried anyway.
        if scene == nil, FileManager.default.fileExists(atPath: looseSceneURL.path(percentEncoded: false)) {
            do {
                let data = try Data(contentsOf: looseSceneURL)
                scene = try decoder.decode(WEScene.self, from: data)
            } catch {
                Self.log("Failed to parse loose \(sceneFile): \(error)")
            }
        }

        guard let scene = scene else {
            // Publish the preview rather than nothing. Returning without a scene left the
            // previous wallpaper rendering on this screen while the UI listed the new one as
            // current (or a black SKView on first load), and the preview fallback inside
            // buildSKScene is never reached on this path.
            Self.log("No scene data found, showing the preview")
            builtSceneIsStill = true
            return previewOnlyScene(wallpaperDir: dir, reason: .unreadable)
        }

        Self.log("Scene loaded: \(scene.objects.count) objects from \(sceneFile)")
        guard let skScene = buildSKScene(from: scene, wallpaperDir: dir) else { return nil }
        Self.log("SKScene built: \(skScene.children.count) children")
        guard !buildIsSuperseded else { return nil }
        Self.warmShaders(of: skScene)
        return skScene
    }

    // MARK: - Shader warm-up

    private static let warmDevice = MTLCreateSystemDefaultDevice()
    private static let warmQueue = warmDevice?.makeCommandQueue()

    /// Compile every `SKShader` the finished scene uses here, on `loadQueue`, rather than in the
    /// `SKView`'s first frame on the main thread.
    ///
    /// `SKShader` compiles lazily, on the first render that needs it, and the first render of a
    /// freshly presented scene is the `SKView` frame on main. Measured with shader sources Metal
    /// had not seen before: one distinct pass held the main thread 302 ms, ten 1.9 s, thirty
    /// 5.7 s — the app beachballing on exactly the loads that moving the build off main was
    /// meant to free: a new wallpaper, a quality change that alters the combos, a tint colour or
    /// backdrop map no earlier build produced. The compiled result is keyed by source, not by
    /// `SKShader` object — a fresh scene with new shader objects of the same sources drew its
    /// first frame in 2.8 ms, and Metal keeps it on disk, so a second process is warm too — and
    /// a throwaway render through `SKRenderer` here is therefore enough to warm the `SKView`'s.
    /// Measured on Dark Magic with every shader source made unique (9 passes, a real `SKView`
    /// in an off-screen window, 3 interleaved runs): the longest main-thread gap after
    /// `presentScene` went 1045–1051 ms → 31–44 ms, the same as with a warm cache, for 1.0 s
    /// more on this queue; once cached the warm-up costs 19 ms (Angel, 16 shaders).
    ///
    /// What is rendered is a stand-in, never the scene itself: one small node per distinct
    /// shader, carrying a copy of it with the blend mode and texture it is drawn with. Rendering
    /// the real tree was tried first, and in the harness that measured it the `SKView`'s first
    /// frame then blocked for good in `jet_buffer::wait` under
    /// `SKCParticleSystemNode::generateRenderData_Quads` — an emitter's particle buffers, once
    /// drawn by an `SKRenderer`, waiting on that renderer. A stand-in also cannot touch anything
    /// the scene keeps between frames — rasterization caches, pre-simulated particles, alpha —
    /// so there is nothing to reset afterwards. Scenes without a single shader skip it.
    private static func warmShaders(of scene: SKScene) {
        var seen = Set<ObjectIdentifier>()
        let standIn = SKScene(size: CGSize(width: 64, height: 64))
        func copy(_ shader: SKShader) -> SKShader? {
            guard seen.insert(ObjectIdentifier(shader)).inserted, let source = shader.source else {
                return nil
            }
            // Fresh uniforms of the same types: the generated declarations come from them, and
            // they are what makes this the same program as the scene's.
            return SKShader(source: source,
                            uniforms: shader.uniforms.compactMap { $0.copy() as? SKUniform })
        }
        func visit(_ node: SKNode) {
            if let effect = node as? SKEffectNode, !(effect is SKScene),
               let shader = effect.shader, let copied = copy(shader) {
                let pass = SKEffectNode()
                pass.shader = copied
                pass.blendMode = effect.blendMode
                pass.shouldEnableEffects = true
                pass.addChild(SKSpriteNode(color: .white, size: CGSize(width: 16, height: 16)))
                pass.position = CGPoint(x: 32, y: 32)
                standIn.addChild(pass)
            } else if let sprite = node as? SKSpriteNode,
                      let shader = sprite.shader, let copied = copy(shader) {
                let probe = SKSpriteNode(texture: sprite.texture, size: CGSize(width: 16, height: 16))
                if sprite.texture == nil { probe.color = sprite.color }
                probe.shader = copied
                probe.blendMode = sprite.blendMode
                probe.position = CGPoint(x: 32, y: 32)
                standIn.addChild(probe)
            }
            node.children.forEach(visit)
        }
        visit(scene)
        guard !standIn.children.isEmpty, let device = warmDevice, let queue = warmQueue else { return }
        let start = DispatchTime.now().uptimeNanoseconds

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        desc.usage = [.renderTarget]
        desc.storageMode = .private
        guard let target = device.makeTexture(descriptor: desc),
              let cmd = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .dontCare

        let renderer = SKRenderer(device: device)
        renderer.scene = standIn
        renderer.render(withViewport: CGRect(x: 0, y: 0, width: 64, height: 64),
                        commandBuffer: cmd, renderPassDescriptor: pass)
        cmd.commit()
        cmd.waitUntilCompleted()
        renderer.scene = nil

        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        log("shader warm-up: \(standIn.children.count) shaders in " + String(format: "%.0f ms", ms))
    }

    // MARK: - SpriteKit Scene Building

    /// A scene object once it has been built: the nodes that draw it, and the binding the
    /// evaluator moves it with. The two are kept side by side so their orders cannot drift —
    /// `WallpaperSKScene` addresses layers by index.
    private struct BuiltLayer {
        let object: WESceneObject
        let binding: SceneLayerBinding
        /// Carries the transform.
        let holder: SKNode
        /// Carries the pixels and the alpha, when the layer draws anything.
        let artwork: SKNode?
        /// Whether an effect pass wrapped around the artwork reads the clock.
        var readsClock = false
        /// Whether a running script rewrites the layer's text.
        var scripted = false
    }

    /// Nil only when a newer load superseded this one partway; see `buildIsSuperseded`.
    private func buildSKScene(from scene: WEScene, wallpaperDir: URL) -> SKScene? {
        // Wallpaper Engine gives an orthographic projection only to flat, layered scenes. Without
        // one the objects live in a perspective camera's world space — origins read like
        // "17.52525 5.47357 2.671", metres rather than pixels — and a 2D compositor has nothing
        // useful to do with them. Showing the wallpaper's own preview beats scattering sprites.
        guard let projection = scene.general.orthogonalprojection else {
            Self.log("no orthogonal projection: 3D scene, falling back to preview")
            builtSceneIsStill = true
            return previewOnlyScene(wallpaperDir: wallpaperDir, reason: .perspective)
        }
        let skScene = WallpaperSKScene(size: CGSize(width: projection.width, height: projection.height))
        skScene.scaleMode = .aspectFill
        buildingSceneSize = skScene.size
        textureStats = TextureStats()
        tintShaders.removeAll()
        tintedLayers = 0
        builtTimeVaryingPass = false
        builtSpriteAnimations = []
        builtScriptedMotions = []

        // Background color from clearcolor
        if let colorStr = scene.general.clearcolor {
            let c = colorStr.parseColor()
            skScene.backgroundColor = NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1.0)
        }

        // Every layer — image, text and emitter alike — is built in scene order, which is the
        // painter's order; `attach` turns that order into zPosition.
        var hasImage = false
        var built: [BuiltLayer] = []
        var emitterCount = 0
        var effectTally = SceneEffectBuilder.Tally()
        let effects = effectBuilder(wallpaperDir: wallpaperDir)
        let scripts = building.scripts
            ? SceneScriptRuntime(userProperties: userProperties, canvasSize: skScene.size) : nil
        var scriptedText: [WallpaperSKScene.ScriptedText] = []
        var texts: [(id: Int?, layer: WallpaperSKScene.TextLayer)] = []
        var textLayers = 0
        var scriptedLayers = 0
        builtEffectNodes = [:]

        scriptedFrameLayers = Self.scriptedTextureAnimations(in: scene.objects)
        // Upstream's scripted-origin shapes name scene-wide constants (`const SPEED = 2`) that
        // any layer's script may declare, so they are gathered from every script first.
        let scriptConstants = SceneScriptConstantsParser.parse(
            scene.objects.flatMap { [$0.originScript, $0.scaleScript, $0.visibleScript, $0.alphaScript] }
                .compactMap { $0 })
        let mediaHidden = Self.hiddenWithNoMedia(scene.objects, scripts: scripts)
        let hidden = Self.hiddenObjectIds(in: scene.objects, alsoHidden: mediaHidden)
        var originScripts = 0

        // Handles on every layer, then the property scripts that run on the clock, brought to
        // rest before anything is built. See `SceneScriptRuntime.declareLayers` and
        // `liveProperties`.
        scripts?.declareLayers(Self.layerStates(scene.objects, mediaHidden: mediaHidden))
        let liveScripts = scripts == nil ? []
            : SceneScriptRuntime.liveProperties(in: scene.objects, skipping: hidden)
        let registeredLive = liveScripts.filter { scripts?.registerProperty($0) == true }
        let liveLayers = scripts?.settleProperties() ?? []
        let scriptedScale = Set(registeredLive.filter { $0.property == "scale" }.map(\.layer))
        // Layers whose subtree is live: some script in it runs, and none that was meant to failed
        // to load or was abandoned while settling.
        let failedLive = Set(liveScripts.map(\.layer)).subtracting(liveLayers)
        let liveRoots = Self.ancestorsAndSelf(of: liveLayers, in: scene.objects)
            .subtracting(Self.ancestorsAndSelf(of: failedLive, in: scene.objects))

        for var obj in scene.objects {
            // Per layer, because that is where a build spends its time — texture decoding, LZ4,
            // MP4 first frames, shader translation — and a superseded build has nothing to show.
            if buildIsSuperseded { return nil }
            guard obj.visible != false else { continue }
            if let id = obj.id, mediaHidden.contains(id) { continue }
            if let parent = obj.parent, hidden.contains(parent) { continue }

            // A top-level layer the author saved off the canvas is not brought onto it unless
            // what it carries is live. That is how Fujiyama ships its calendar: baked at
            // y = -668, out of frame, while its slider script places it at the top of the screen.
            // Before the calendar's own scripts ran, bringing it on showed a stale "2027", "26"
            // and a marker on the wrong weekday — revealing content nobody had seen render. Now
            // they do run, and the guard is lifted for exactly the layers whose subtree carries a
            // live script that came through `settleProperties`; it is the only off-canvas
            // scripted origin in this library, so nothing else moves.
            if let source = obj.originScript,
               !Self.isOffCanvas(obj, canvas: skScene.size) || obj.id.map(liveRoots.contains) == true,
               let origin = scripts?.staticOrigin(source, properties: obj.originScriptProperties,
                                                  authored: obj.origin) {
                obj.origin = origin
                originScripts += 1
            }

            // Every object becomes a transform holder, and its artwork hangs off that holder as
            // a separate child.
            //
            // The indirection exists because `parent` in Wallpaper Engine is a transform
            // relationship only, while SKNode.alpha multiplies down the tree. Parents are
            // routinely invisible anchor sprites — a wallpaper will park an `alpha: 0` marker
            // named "light on/off" and hang the visible artwork off it — so letting alpha
            // inherit blanked whole scenes. Keeping the holder opaque and putting alpha on the
            // artwork alone reproduces Wallpaper Engine's compositing.
            //
            // It also gives the evaluator one node per layer to write a transform onto, without
            // having to know whether the layer draws a sprite, an emitter, or nothing at all.
            var binding = SceneLayerBinding(object: obj)
            if obj.particle != nil {
                // Roll stays off emitters. SKEmitterNode's emission angle is already a rough
                // reading of Wallpaper Engine's velocity initialisers, and turning the emitter by
                // the object's own angle on top of that compounds one approximation with another
                // — several scenes carry emitters rolled 70° or more, which would send their
                // snow and embers sideways on nothing better than a guess. Position and scale
                // still apply, as they always did.
                binding.rotation = 0
                binding.anglesTrack = nil
            }
            let holder = SKNode()
            apply(binding, to: holder)

            if obj.particle != nil {
                guard let emitter = buildParticleNode(obj, wallpaperDir: wallpaperDir,
                                                      sceneSize: skScene.size) else { continue }
                holder.addChild(emitter)
                // Appended to `built` in scene order like every other layer, so it draws where
                // the author put it and nests under its parent. Emitters used to be held back and
                // lifted to the root above every image layer, which put rain and smoke authored
                // *behind* a figure or a room in front of it: 33 scenes of this library place a
                // visible image after an emitter — Hacker Apartment's rain falls outside its
                // window, not across the room, The Batman's lightning, rain and a smoke cloud
                // sit behind the figure — and 70 emitters carry a `parent`, whose parent-relative
                // origin was being read as a scene position. Rendered, Hacker Apartment's rain
                // went from covering the whole frame to falling past the window only, and Dark
                // Magic's rock emitters stopped burying the figure they frame.
                emitterCount += 1
                built.append(BuiltLayer(object: obj, binding: binding,
                                        holder: holder, artwork: emitter))
                continue
            }

            var artwork: SKNode?
            var readsClock = false, scripted = false
            if obj.image != nil,
               let sprite = buildImageNode(obj, wallpaperDir: wallpaperDir, effects: effects,
                                           layerScale: binding.scale) {
                if Self.skipAdditiveLayers && sprite.blendMode == .add { continue }
                // Multiply and subtract are only meaningful against artwork beneath. On the
                // bottom image there is nothing beneath but the clear colour, and blending into
                // that is not what the author saw: Transformer - Arrival to Earth's full-frame
                // base is mode 20, and subtracting it from its 0.7 grey clear colour inverted the
                // whole wallpaper; 1944_Normandie's mode-2 base came out visibly darker than its
                // preview. Those are the only two such layers in the library, and both are the
                // first image of their scene. Screen and add over a dark clear colour are close
                // to a no-op either way, so they keep their mode.
                if !hasImage, sprite.blendMode == .multiplyAlpha || sprite.blendMode == .subtract {
                    sprite.blendMode = .alpha
                }
                sprite.alpha = binding.alpha
                holder.addChild(composite(effectChain(for: obj, around: sprite, using: effects,
                                                      tally: &effectTally),
                                          artwork: sprite))
                artwork = sprite
                readsClock = lastChainReadsClock
                hasImage = true
                if let source = obj.originScript,
                   let motion = Self.scriptedMotion(source, holder: holder, artwork: sprite,
                                                    sheet: lastSheetTextures, canvas: skScene.size,
                                                    constants: scriptConstants) {
                    if case .mob = motion.driver {
                        builtSpriteAnimations.removeAll { $0.node === sprite }
                    }
                    builtScriptedMotions.append(motion)
                }
            } else if obj.text != nil,
                      let (sprite, style) = buildTextNode(obj, wallpaperDir: wallpaperDir) {
                sprite.alpha = binding.alpha
                holder.addChild(composite(effectChain(for: obj, around: sprite, using: effects,
                                                      tally: &effectTally),
                                          artwork: sprite))
                artwork = sprite
                readsClock = lastChainReadsClock
                // Any text layer can be rewritten while the scene runs — by its own script, or by
                // name from another layer's (Fujiyama's calendar writes its year, day and month
                // that way) — so none is ever treated as a static backdrop.
                scripted = scripts != nil
                texts.append((obj.id, WallpaperSKScene.TextLayer(node: sprite, style: style,
                                                                 shown: obj.text ?? "")))
                if let source = obj.textScript {
                    scriptedLayers += 1
                    if let handle = scripts?.register(source, properties: obj.textScriptProperties,
                                                      layer: obj.id) {
                        scriptedText.append(WallpaperSKScene.ScriptedText(handle: handle,
                                                                          text: texts.count - 1))
                    }
                }
                textLayers += 1
                // Deliberately not counted as an image: a wallpaper whose only surviving layers
                // are labels has still lost its artwork, and the preview fallback is the right
                // answer for it.
            } else if obj.id == nil {
                // Nothing to draw and nothing can hang off it.
                continue
            }

            built.append(BuiltLayer(object: obj, binding: binding, holder: holder, artwork: artwork,
                                    readsClock: readsClock, scripted: scripted))
        }

        attach(built, to: skScene)
        renderEffectsAtDrawnSize(built, scriptedScale: scriptedScale)
        let remap = blendAgainstStaticBackdrops(built, in: skScene, general: scene.general)
        for index in texts.indices {
            texts[index].layer.resized = remap[ObjectIdentifier(texts[index].layer.node)]
        }

        // Fallback: use preview image
        if !hasImage {
            let previewImage = loadPreviewImage(wallpaperDir: wallpaperDir)
            if let img = previewImage {
                let node = SKSpriteNode(texture: SKTexture(image: img))
                node.size = skScene.size
                node.position = CGPoint(x: skScene.size.width / 2, y: skScene.size.height / 2)
                skScene.addChild(node)
            }
        }

        let layers = built
        let evaluator = SceneEvaluator(layers: layers.map(\.binding),
                                       general: scene.general,
                                       projection: skScene.size)
        skScene.bind(evaluator: evaluator,
                     holders: layers.map(\.holder),
                     artwork: layers.map(\.artwork),
                     ids: layers.map(\.object.id))
        skScene.bind(scripts: scripts, texts: texts, scripted: scriptedText,
                     effects: builtEffectNodes)
        skScene.bind(spriteAnimations: builtSpriteAnimations)
        skScene.bind(scriptedMotions: builtScriptedMotions)
        // A live property script is a clock like any other: a scene carrying one is not still,
        // or its calendar would never turn over at midnight.
        builtSceneIsStill = evaluator.isStatic && emitterCount == 0 && scriptedText.isEmpty
            && !builtTimeVaryingPass && !(scripts?.hasLiveProperties ?? false)
            && builtSpriteAnimations.isEmpty && builtScriptedMotions.isEmpty

        Self.log("Built \(skScene.children.count) nodes, \(emitterCount) particle emitters, "
                 + "\(evaluator.isStatic ? "static" : "animated"); effects "
                 + "\(effectTally.built)/\(effectTally.passes) passes from \(effectTally.effects) "
                 + "(unresolved \(effectTally.unresolved), untranslatable \(effectTally.untranslatable))"
                 + "; sprite sheets \(builtSpriteAnimations.count) playing"
                 + "; scripted movers \(builtScriptedMotions.count)"
                 + "; text \(textLayers) layers, \(scriptedText.count)/\(scriptedLayers) scripts running"
                 + "; media-hidden \(mediaHidden.count) layers; scripted origins \(originScripts)"
                 + "; live properties \(registeredLive.count)/\(liveScripts.count) on "
                 + "\(liveLayers.count) layers"
                 + "; tint \(tintedLayers) layers over \(tintShaders.count) colours"
                 + (builtSceneIsStill ? "; still" : ""))
        lastEffectTally = effectTally
        lastTextureStats = textureStats
        if textureStats.scaled > 0 {
            Self.log("Texture budget: \(textureStats.scaled)/\(textureStats.layers) layers reduced, "
                     + "\(textureStats.authoredTexels) → \(textureStats.builtTexels) texels")
        }

        return skScene
    }

    // MARK: - Effects

    /// Last scene's effect statistics, for the offline verification harness.
    private(set) var lastEffectTally = SceneEffectBuilder.Tally()

    /// Wrap a layer's artwork in one `SKEffectNode` per effect pass.
    ///
    /// Nesting is the chain: the innermost node renders the sprite to a texture and runs the
    /// first pass over it, the next runs over that result, and so on. `shouldRasterize` is on
    /// only where nothing beneath the pass reads the clock — it caches what the pass is handed,
    /// which would freeze every animated pass inside it, and those are most of them.
    ///
    /// Whether this build runs effect chains at all — Settings → Post-Processing, and under it the
    /// `SceneEffectsDisabled` escape hatch.
    ///
    /// Effects are on by default because they are right far more often than not, but the
    /// translation is a reconstruction of another engine's shader pipeline and at least one
    /// wallpaper is still rendered worse by it. Turning Post-Processing off, or
    /// `defaults write com.winddog.wallpaper-engine SceneEffectsDisabled -bool YES`, restores the
    /// plain composite; the setting does it live, the default at the next launch.
    private var effectsDisabled: Bool { !building.effects }

    /// The `SceneEffectsDisabled` debug switch alone, as distinct from the user's
    /// Post-Processing setting. Declined audio-visualiser canvases are kept only under the debug
    /// switch, whose point is to show the plain composite unedited; a user who turns
    /// Post-Processing off has asked for less work, not for seven flat white rectangles.
    private var effectsEscapeHatch: Bool { UserDefaults.standard.bool(forKey: "SceneEffectsDisabled") }

    /// Whether the chain `effectChain` built last has a pass that reads the clock. Build state.
    private var lastChainReadsClock = false

    private func effectChain(for object: WESceneObject,
                             around sprite: SKNode,
                             using effectBuilder: SceneEffectBuilder,
                             tally: inout SceneEffectBuilder.Tally) -> SKNode {
        lastChainReadsClock = false
        guard !effectsDisabled else { return sprite }
        let shaders = effectBuilder.chain(for: object, tally: &tally)
        guard !shaders.isEmpty else { return sprite }

        var node: SKNode = sprite
        // Whether everything beneath the next pass — the sprite, its opacity, and every pass
        // already wrapped around it — is free of the clock.
        var inputIsStill = object.alphaTrack == nil
        for pass in shaders {
            let effect = SKEffectNode()
            effect.shader = pass.shader
            effect.shouldEnableEffects = true
            // Cache a pass whose *input* cannot change: the layer's own opacity is fixed and no
            // pass inside it reads the clock, so what it is handed is a still image.
            //
            // What `shouldRasterize` caches is the node's rendered children, not its shaded
            // result: the shader still runs on every draw, over the cached texture. Measured in a
            // real `SKView`, a cached node whose own shader was `sin(u_time)` brightness animated
            // exactly as an uncached one (128 → 170 → 89 → 19 → 1 …). So the pass's own clock
            // does not matter, and a ripple straight over a sprite is cached as surely as a tint
            // is — which saves re-rendering the sprite into the offscreen texture every frame.
            // For a 3840×2160 layer that copy is most of the pass: one pass cost 4.43 ms a frame
            // in a 3840×2160 viewport where the bare sprite cost 2.24 and the same shader run on
            // the sprite directly 2.76.
            //
            // The inner passes have to be asked, because the cache is *not* invalidated when a
            // shader beneath it animates through `u_time`: nothing about the subtree changes as
            // far as the node graph can tell. A cached pass-through over a `sin(u_time)` pass
            // read 128 at the centre on every frame for 1.6 s, against 255 → 1 → 132 uncached. So
            // a tint over a water ripple froze the water at its first frame: 19 passes in 10
            // scenes of this library did this — Angel's sea and cloud bank, Honkai's figure and
            // every cloth layer hung off it among them. Replacing a child's texture does
            // invalidate it — a cached pass over a sprite swapped white → red → black followed
            // every swap — which is why a scripted text layer can still be cached.
            effect.shouldRasterize = inputIsStill
            if !pass.isTimeInvariant {
                builtTimeVaryingPass = true
                lastChainReadsClock = true
                inputIsStill = false
            }
            effect.addChild(node)
            node = effect
            if let id = object.id, let name = pass.effect {
                builtEffectNodes[id, default: [:]][name, default: []].append(effect)
            }
        }
        return node
    }

    /// Every pass built for the scene in progress, by layer and effect name, for the scripts that
    /// switch an effect — Fujiyama tints its date block on weekends with
    /// `getEffect("周六日").visible`. Build state, like `tintShaders`.
    private var builtEffectNodes: [Int: [String: [SKEffectNode]]] = [:]

    /// Bound to the directory being built rather than read off `currentWallpaper`: a load
    /// triggered by `currentWallpaper`'s willSet still sees the *old* value there, and the build
    /// now runs off the main thread where reading that property would race the next assignment.
    private func effectBuilder(wallpaperDir dir: URL) -> SceneEffectBuilder {
        return SceneEffectBuilder(
            read: { [weak self] path, bundle in self?.readAsset(path, bundle: bundle, wallpaperDir: dir) },
            readTexture: { [weak self] path, bundle in
                self?.readEffectTexture(path, bundle: bundle, wallpaperDir: dir)
            },
            reflections: building.reflections)
    }

    /// An effect's own files are relative to its bundle directory; a wallpaper's are relative to
    /// its package. Both roots are tried, bundle first, through the same three lookup layers the
    /// rest of the scene loader uses.
    ///
    /// Each name is tried against the wallpaper and then the shared library before the next name
    /// is tried, so a shader the library carries under the effect's bundle path wins over the
    /// copy a wallpaper bundles at the bare path. Reversing that was tried and measured: Falling
    /// Sakura's bundled legacy foliage sway took over, but 47 fewer passes compiled library-wide,
    /// four bundled shaders failed on an ambiguous `max`, 1990 Miata's bundled `reflection`
    /// painted a fifth of the frame flat white (its offset assumes a top-down texture space), and
    /// nothing that changed came out closer to its preview. Until the translator can run the
    /// legacy shaders, the library's current ones are the better reading.
    private func readAsset(_ path: String, bundle: String?, wallpaperDir: URL) -> Data? {
        var candidates: [String] = []
        if let bundle, !bundle.isEmpty { candidates.append("\(bundle)/\(path)") }
        candidates.append(path)

        for candidate in candidates {
            if let parser = pkgParser, let data = parser.extractFile(named: candidate) {
                return Data(data)
            }
            if let data = try? Data(contentsOf: wallpaperDir.appending(path: candidate)) {
                return data
            }
            for url in self.sharedAssetURLs(for: candidate) {
                if let data = try? Data(contentsOf: url) { return data }
            }
        }
        return nil
    }

    private func readEffectTexture(_ path: String, bundle: String?, wallpaperDir: URL) -> NSImage? {
        guard !path.isEmpty else { return nil }
        // Effect textures are named the way material textures are — "masks/foo" resolves under
        // materials/ — so try both that and the bare path, as .tex and as a plain image.
        for base in ["materials/\(path)", path] {
            if let data = readAsset("\(base).tex", bundle: bundle, wallpaperDir: wallpaperDir),
               let image = TEXParser(data: data, rawChannels: true).extractImage() {
                return image
            }
            for ext in ["png", "jpg", "jpeg", "gif"] {
                if let data = readAsset("\(base).\(ext)", bundle: bundle, wallpaperDir: wallpaperDir),
                   let image = NSImage(data: data) {
                    return image
                }
            }
        }
        return nil
    }

    /// Ids of every object that Wallpaper Engine would not draw: the ones authored
    /// `visible: false`, and everything hung beneath one of them, however deep.
    ///
    /// Visibility inherits in Wallpaper Engine — hiding a parent hides its subtree — and authors
    /// rely on that to ship switchable variants. Lonely Cat carries its clock, date and
    /// visualiser once per language (`LonelyCAT ENG`, `VIE`, `RUS`, `CN`, `Spa`, `Fren`), with
    /// every variant but one hidden at the root and the children themselves left visible. Only
    /// checking an object's own flag built all six; and because `attach` cannot find a skipped
    /// parent, each orphan went to the scene root with its parent-relative origin read as a
    /// scene position, so the wallpaper showed a stack of offset duplicate clocks and black
    /// slabs. Space Pamper's stray black bar across the top is the same thing: a solid layer
    /// hung off another solid layer the author had switched off. Measured over the installed library, 236 objects across 11 scenes are
    /// hidden only by inheritance.
    ///
    /// Iterated to a fixpoint so a parent listed after its child still hides it. No scene in
    /// this library needs more than the first pass, but the order is not something the format
    /// promises, and the loop costs nothing when it converges at once.
    static func hiddenObjectIds(in objects: [WESceneObject],
                                alsoHidden: Set<Int> = []) -> Set<Int> {
        var hidden: Set<Int> = []
        var changed = true
        while changed {
            changed = false
            for obj in objects {
                guard let id = obj.id, !hidden.contains(id) else { continue }
                if obj.visible == false || alsoHidden.contains(id)
                    || obj.parent.map(hidden.contains) == true {
                    hidden.insert(id)
                    changed = true
                }
            }
        }
        return hidden
    }

    /// What scripts see of each layer through its handle — see `SceneScriptRuntime.declareLayers`.
    /// Every object is declared, hidden or not: a script may read a layer it cannot show.
    static func layerStates(_ objects: [WESceneObject],
                            mediaHidden: Set<Int>) -> [SceneScriptRuntime.LayerState] {
        objects.compactMap { obj in
            guard let id = obj.id else { return nil }
            let vector: (String?, (Double, Double, Double)) -> (Double, Double, Double) = { raw, fallback in
                guard let raw else { return fallback }
                return raw.parseVector3()
            }
            var effects: [String: Bool] = [:]
            for effect in obj.effects ?? [] {
                if let name = effect.name, effects[name] == nil { effects[name] = effect.visible ?? true }
            }
            return SceneScriptRuntime.LayerState(
                id: id, name: obj.name, text: obj.text,
                visible: obj.visible != false && !mediaHidden.contains(id),
                alpha: obj.alpha ?? 1,
                origin: vector(obj.origin, (0, 0, 0)),
                scale: vector(obj.scale, (1, 1, 1)),
                angles: vector(obj.angles, (0, 0, 0)),
                effects: effects)
        }
    }

    /// `ids`, and every object any of them hangs beneath.
    static func ancestorsAndSelf(of ids: Set<Int>, in objects: [WESceneObject]) -> Set<Int> {
        var parentOf: [Int: Int] = [:]
        for obj in objects { if let id = obj.id, let parent = obj.parent { parentOf[id] = parent } }
        var out: Set<Int> = []
        for id in ids {
            var current: Int? = id
            // Bounded by the object count, so a malformed parent cycle cannot hang the build.
            var steps = 0
            while let node = current, steps <= objects.count, out.insert(node).inserted || node == id {
                current = parentOf[node]
                steps += 1
            }
        }
        return out
    }

    /// Whether a top-level layer's authored origin lies outside the scene's canvas. Children are
    /// placed relative to their parent, so for them the answer is always no.
    static func isOffCanvas(_ obj: WESceneObject, canvas: CGSize) -> Bool {
        guard obj.parent == nil, let origin = obj.origin else { return false }
        let (x, y, _) = origin.parseVector3()
        return x < 0 || y < 0 || x > canvas.width || y > canvas.height
    }

    /// Ids of the layers a media-integration script hides when nothing is playing — which is
    /// always, here: this app has no media integration, so the state those scripts see is the
    /// one Wallpaper Engine shows with no player open. See `SceneScriptRuntime.hiddenWithNoMedia`.
    ///
    /// A layer hidden this way hides its subtree, like any other hidden layer — Lost Landscape's
    /// album cover takes its track title and artist with it. A layer hidden *by name*, through
    /// `thisScene.getLayer`, is the first layer of that name, which is what a lookup by name can
    /// find. Nil runtime (scripts disabled) hides nothing.
    static func hiddenWithNoMedia(_ objects: [WESceneObject],
                                  scripts: SceneScriptRuntime?) -> Set<Int> {
        guard let scripts else { return [] }
        var hidden: Set<Int> = []
        var names: [String] = []
        // Layers already hidden — by their own flag or an ancestor's — are not asked: their
        // scripts never run in Wallpaper Engine, so their by-name hides must not reach anything.
        let alreadyHidden = hiddenObjectIds(in: objects)
        for obj in objects {
            guard let id = obj.id, obj.visible != false, !alreadyHidden.contains(id) else { continue }
            let candidates: [(String, String?, Any, [String: WEScriptPropertyValue]?)] = [
                ("visible", obj.visibleScript, obj.visible ?? true, obj.visibleScriptProperties),
                ("alpha", obj.alphaScript, obj.alpha ?? 1.0, obj.alphaScriptProperties),
            ]
            for (property, source, authored, properties) in candidates {
                guard let source,
                      let outcome = scripts.hiddenWithNoMedia(source, property: property,
                                                              authored: authored,
                                                              properties: properties) else { continue }
                if outcome.hidesSelf { hidden.insert(id) }
                names.append(contentsOf: outcome.hiddenNames)
            }
        }
        for name in names {
            if let id = objects.first(where: { $0.name == name })?.id { hidden.insert(id) }
        }
        return hidden
    }

    /// Hand a layer's compositing mode to the node that actually composites into the frame.
    ///
    /// `blendMode` on a sprite says how it is drawn into whatever it is drawn into. Inside an
    /// `SKEffectNode` that is the effect's own offscreen buffer, cleared to transparent — so a
    /// screen or additive layer wrapped in an effect chain would screen against nothing, and the
    /// chain's result would then go into the frame as plain alpha, exactly the opaque look the
    /// mode exists to avoid. The outermost node is the one that meets the layers beneath; the
    /// sprite inside reverts to `.alpha` so the offscreen buffer receives the artwork as is.
    private func composite(_ outer: SKNode, artwork sprite: SKSpriteNode) -> SKNode {
        if let effect = outer as? SKEffectNode {
            effect.blendMode = sprite.blendMode
            sprite.blendMode = .alpha
        }
        return outer
    }

    /// Wire the built nodes into the scene graph, honouring `parent` relationships.
    ///
    /// A child's `origin`, `scale` and `angles` are all relative to its parent, so nesting the
    /// SKNodes is what makes them compose. `zPosition` is stated explicitly because
    /// `SKView.ignoresSiblingOrder` lets SpriteKit reorder siblings for batching — scene order is
    /// the painter's order — and a child's z is an offset from its parent's, so it is written as
    /// the difference between the two indices to keep the global order intact.
    private func attach(_ built: [BuiltLayer], to skScene: SKScene) {
        var nodeById: [Int: SKNode] = [:]
        var indexById: [Int: Int] = [:]
        for (index, entry) in built.enumerated() {
            if let id = entry.object.id {
                nodeById[id] = entry.holder
                indexById[id] = index
            }
        }

        for (index, entry) in built.enumerated() {
            // Only ever attach to a parent that came earlier, which also makes a malformed
            // parent cycle impossible to build.
            if let parentId = entry.object.parent,
               let parentIndex = indexById[parentId], parentIndex < index,
               let parentNode = nodeById[parentId] {
                entry.holder.zPosition = CGFloat(index - parentIndex)
                parentNode.addChild(entry.holder)
            } else {
                entry.holder.zPosition = CGFloat(index)
                skScene.addChild(entry.holder)
            }
        }
    }

    /// Run each shrunken layer's effect chain at the size the layer is drawn, not the size it is
    /// authored.
    ///
    /// An `SKEffectNode` sizes its offscreen texture in its *own* coordinate space and ignores
    /// every scale above it. A layer authored at 2812×1381 and placed at scale 0.05 is drawn
    /// 141 pixels wide, but each of its passes still renders and shades 2812×1381 — measured on a
    /// 3840×2160 sprite under a 0.05 parent, one pass cost 3.67 ms a frame against 4.43 at scale
    /// 1, with the bare sprite at 1.10. So the drawn-size scale is moved inside the chain: a plain
    /// node just above the sprite shrinks it, which shrinks every offscreen texture above it, and
    /// a plain node outside the outermost pass scales the result back up. Placement on screen is
    /// the product of the two, which cancel exactly, so geometry cannot change however rough the
    /// estimate of the drawn size is — only the offscreen resolution does. Measured the same way
    /// on a busier machine: 6.23 ms as authored, 1.29 at drawn size, 1.28 for the bare sprite.
    ///
    /// Only downwards. A layer drawn larger than authored already gets an offscreen smaller than
    /// its footprint, and growing that to the drawn size would cost more, not less. And only on
    /// layers no scale track can grow later: the scale is read once, here, so a layer animated up
    /// from a small start would be shaded at its smallest size and then magnified.
    ///
    /// The translated shaders address the layer in `v_tex_coord`, which spans the layer whatever
    /// its pixel size, and their resolution uniforms are bound to a constant (see
    /// `SceneEffectBuilder.bind`), so nothing they compute depends on how many pixels the
    /// offscreen has: they draw the same picture from fewer samples.
    ///
    /// A layer whose scale a live script drives (`scriptedScale`, by object id) counts as
    /// animated for the same reason a scale track does: the scale read here is not the one it
    /// will be drawn at.
    private func renderEffectsAtDrawnSize(_ built: [BuiltLayer], scriptedScale: Set<Int> = []) {
        var bindingFor: [ObjectIdentifier: SceneLayerBinding] = [:]
        var scriptScaled: Set<ObjectIdentifier> = []
        for entry in built {
            bindingFor[ObjectIdentifier(entry.holder)] = entry.binding
            if let id = entry.object.id, scriptedScale.contains(id) {
                scriptScaled.insert(ObjectIdentifier(entry.holder))
            }
        }

        for entry in built {
            guard let sprite = entry.artwork as? SKSpriteNode else { continue }
            // The chain's root is whatever hangs between the artwork and its holder.
            var root: SKNode = sprite
            while let parent = root.parent, parent !== entry.holder { root = parent }
            guard root !== sprite, let chain = root as? SKEffectNode else { continue }

            // Drawn size relative to authored size, through every holder up to the scene.
            var kx: CGFloat = 1, ky: CGFloat = 1
            var animated = false
            var node: SKNode? = entry.holder
            while let holder = node, !(holder is SKScene) {
                if let binding = bindingFor[ObjectIdentifier(holder)], binding.scaleTrack != nil {
                    animated = true
                }
                if scriptScaled.contains(ObjectIdentifier(holder)) { animated = true }
                kx *= abs(holder.xScale)
                ky *= abs(holder.yScale)
                node = holder.parent
            }
            // Then through the aspect-fill magnification from scene to view, which happens after
            // the offscreen is rendered: shading a layer at its scene-space size on a display
            // larger than the scene would blur it by that factor.
            if let display = building.displayPoints, let scene = entry.holder.scene,
               scene.size.width > 0, scene.size.height > 0 {
                let magnification = max(display.width / scene.size.width,
                                        display.height / scene.size.height)
                kx *= max(magnification, 1)
                ky *= max(magnification, 1)
            }
            kx = min(kx, 1); ky = min(ky, 1)
            // Only where it at least halves the shaded area. Shading at fewer samples is the same
            // picture but not the same pixels — fine-grained artwork resamples differently, a
            // few levels here and there — so a layer drawn at 0.8 is not worth that for a fifth
            // off; Dark Magic's two 3000×2000 layers, drawn at 0.54 and 0.67 of that, are.
            guard !animated, kx > 0, ky > 0, kx * ky < 0.5 else { continue }

            let wrapper = SKNode()
            wrapper.xScale = 1 / kx
            wrapper.yScale = 1 / ky
            wrapper.zPosition = chain.zPosition
            chain.zPosition = 0
            let index = entry.holder.children.firstIndex(of: chain) ?? 0
            chain.removeFromParent()
            wrapper.addChild(chain)
            entry.holder.insertChild(wrapper, at: index)

            // The shrink goes on a node of its own between the sprite and the innermost pass,
            // not on the sprite. A scripted text layer re-sets its sprite's `size` on every new
            // string, and `size` on an `SKSpriteNode` includes its scale — scaling the sprite
            // itself drew Hacker Apartment's clock at full size the moment it first ticked.
            guard let innermost = sprite.parent else { continue }
            let shrink = SKNode()
            shrink.xScale = kx
            shrink.yScale = ky
            sprite.removeFromParent()
            shrink.addChild(sprite)
            innermost.addChild(shrink)
        }
    }

    // MARK: - Framebuffer blend modes

    /// What `blendAgainstStaticBackdrops` did with the last build's layers, by mode: how many
    /// layers asked for a mode only the backdrop path can do, how many got it, and why the rest
    /// did not. For the build log and the offline tools.
    struct BlendStats: Equatable {
        var requested: [Int: Int] = [:]
        var applied: [Int: Int] = [:]
        var declined: [String: Int] = [:]
    }
    private(set) var lastBlendStats = BlendStats()

    /// Give every layer whose `colorBlendMode` needs the framebuffer — overlay, soft light,
    /// lighten, colour dodge, tint, … — that framebuffer, where it is a constant. See
    /// `SceneBackdropBlend` for the shader and why the result is exact.
    ///
    /// "A constant" means nothing drawn beneath the layer, in painter's order, can change, and
    /// neither can the layer's own placement — the backdrop is sampled through a map fixed at
    /// load. Concretely the layer is declined when:
    ///
    /// - it, or any holder above it, has an origin, scale or angle track, or parallax that
    ///   applies (the map would drift off the backdrop);
    /// - any emitter is beneath it, anywhere — particles are not bounded by their emitter's frame;
    /// - any layer beneath it moves, anywhere, for the same reason as the first rule: a moving
    ///   layer's frame at load says nothing about where it will be;
    /// - a layer beneath it that stays put but changes its pixels — an effect pass reading the
    ///   clock, an alpha track, a running text script — overlaps the layer's rectangle. Only
    ///   these are tested for overlap, because only these have a frame that holds still;
    /// - it composites with anything but normal alpha (an additive material), or a script
    ///   rewrites a layer that is also wrapped in an effect chain.
    ///
    /// A layer's own pixels may change — its opacity track and its own effect passes reach the
    /// shader every frame through `SKDefaultShading()` — because only the backdrop is frozen.
    /// Layers are done in scene order, so one blended layer above another sees the lower one
    /// already blended in its backdrop, as Wallpaper Engine's framebuffer would show it.
    ///
    /// Measured over the installed library: 18 built layers in 6 scenes ask for one of these
    /// modes — 14 overlay, 1 soft light, 1 lighten, 1 colour dodge, 1 tint — and two of them
    /// (Honkai's audio bars, Razer Quartz Lair's tint compose) draw nothing. 4 qualify: Porsche
    /// 911's overlay clock, Angel's colour-dodge water, two overlays in Mitsubishi Lancer X.
    /// Razer's other nine all sit over its animated wave, Valley's lighten flare moves, and two
    /// of Lancer's sit by a date script. Snapshots cost 30–60 ms per scene at load, and nothing
    /// per frame except Angel's one extra pass: 53.8 → 60.1 ms a frame at 4K.
    ///
    /// Returns, for each blended layer whose text a script rewrites, what to call when the script
    /// resizes its sprite — see the note on scripted layers below.
    private func blendAgainstStaticBackdrops(_ built: [BuiltLayer], in skScene: SKScene,
                                             general: WESceneGeneral)
        -> [ObjectIdentifier: (SKSpriteNode) -> Void] {
        var stats = BlendStats()
        var remap: [ObjectIdentifier: (SKSpriteNode) -> Void] = [:]
        defer { lastBlendStats = stats }
        guard built.contains(where: { SceneBackdropBlend.needsBackdrop($0.object.colorBlendMode) })
        else { return remap }

        // The same test `SceneEvaluator` applies: parallax that is switched on but has no
        // amount or no mouse influence moves nothing.
        let parallax = SceneEvaluator.ParallaxSettings(general: general)
        let parallaxApplies = parallax.enabled && abs(parallax.amount) > 1e-6
            && abs(parallax.mouseInfluence) > 1e-6

        // Whether each layer's placement can change: its own tracks, its parallax, or any holder
        // it hangs from. Parents always come earlier (see `attach`), so one pass resolves it.
        var indexOfHolder: [ObjectIdentifier: Int] = [:]
        for (index, entry) in built.enumerated() { indexOfHolder[ObjectIdentifier(entry.holder)] = index }
        var moves = [Bool](repeating: false, count: built.count)
        for (index, entry) in built.enumerated() {
            let b = entry.binding
            var m = b.originTrack != nil || b.scaleTrack != nil || b.anglesTrack != nil
                || (parallaxApplies && b.hasParallax)
            if let parent = entry.holder.parent, let p = indexOfHolder[ObjectIdentifier(parent)] {
                m = m || moves[p]
            }
            moves[index] = m
        }

        /// A node's drawn rectangle in scene coordinates, as of now.
        func sceneFrame(_ node: SKNode) -> CGRect {
            let f = node.calculateAccumulatedFrame()
            guard let parent = node.parent else { return f }
            let corners = [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY),
                           CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.maxX, y: f.maxY)]
                .map { parent.convert($0, to: skScene) }
            let xs = corners.map(\.x), ys = corners.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!,
                          width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }

        var snapshots = 0
        var snapshotSeconds = 0.0
        let sceneRect = CGRect(origin: .zero, size: skScene.size)
        for (index, entry) in built.enumerated() {
            let mode = entry.object.colorBlendMode
            guard SceneBackdropBlend.needsBackdrop(mode), let mode else { continue }
            stats.requested[mode, default: 0] += 1
            func decline(_ why: String) {
                stats.declined[why, default: 0] += 1
                Self.log("blend mode \(mode) on '\(entry.object.name ?? "?")' kept as normal alpha: \(why)")
            }

            guard let sprite = entry.artwork as? SKSpriteNode else { decline("no sprite"); continue }
            // The node that composites the layer into the frame: the sprite, or the outermost
            // pass of its effect chain (see `composite`).
            var chain: SKEffectNode?
            var node: SKNode = sprite
            while let parent = node.parent, parent !== entry.holder {
                if let effect = parent as? SKEffectNode { chain = effect }
                node = parent
            }
            if chain != nil, entry.scripted { decline("scripted effect chain"); continue }
            guard (chain?.blendMode ?? sprite.blendMode) == .alpha else {
                decline("material blending"); continue
            }
            guard sprite.xScale == 1, sprite.yScale == 1, sprite.zRotation == 0 else {
                decline("scaled sprite"); continue
            }
            guard !moves[index] else { decline("layer moves"); continue }

            let frame = sceneFrame(sprite).intersection(sceneRect)
            guard !frame.isNull, frame.width >= 1, frame.height >= 1 else {
                decline("off canvas"); continue
            }
            // A scripted layer — Porsche 911's overlay clock — changes its own size every time its
            // string does, and the map below is fixed to the size it has now. So its backdrop is
            // taken wider than the layer: the canvas's full width, over the layer's band of rows
            // with its own height to spare above and below, and the map is recomputed whenever
            // the script resizes the sprite. A string that outgrows even that samples the
            // backdrop's edge rows, which is a smear at worst, never the wrong picture.
            let crop = entry.scripted
                ? CGRect(x: 0, y: frame.minY - frame.height, width: skScene.size.width,
                         height: frame.height * 3).intersection(sceneRect)
                : frame
            var blocker: String?
            for (i, below) in built[..<index].enumerated() where below.artwork != nil {
                if below.object.particle != nil { blocker = "particles beneath"; break }
                if moves[i] { blocker = "motion beneath"; break }
                let live = below.readsClock || below.scripted || below.binding.alphaTrack != nil
                guard live, let art = below.artwork else { continue }
                // A script's next string can be wider or taller than the one it was built with,
                // so a scripted layer beneath is given room to grow before the overlap test.
                var reach = sceneFrame(art)
                if below.scripted { reach = reach.insetBy(dx: -reach.width, dy: -reach.height / 2) }
                if reach.intersects(frame) {
                    blocker = below.scripted ? "script beneath" : "animated pixels beneath"
                    break
                }
            }
            if let blocker { decline(blocker); continue }

            // Everything from this layer up is hidden for the snapshot — including the layer's
            // own children, which come later in painter's order and are not beneath it.
            let above = built[index...].map(\.holder).filter { !$0.isHidden }
            above.forEach { $0.isHidden = true }
            let started = Date()
            let snap = SceneBackdropBlend.snapshot(skScene, crop: crop)
            snapshotSeconds += Date().timeIntervalSince(started)
            above.forEach { $0.isHidden = false }
            snapshots += 1
            guard let (backdrop, covered) = snap else { decline("snapshot failed"); continue }

            if let chain {
                // A layer with an effect chain is blended by one more pass around the chain: an
                // `SKEffectNode` whose shader reads the chain's finished result, which is the
                // layer as Wallpaper Engine would hand it to `ApplyBlending`. The sprite inside
                // keeps its tint shader, so the blend's own tint is white. The pass's texture
                // spans its children's accumulated frame, which is what the map is built from.
                //
                // It costs an offscreen pass the size of the layer, which is why only this case
                // pays it. Cached like the passes inside it, under the same rule: only when
                // nothing beneath it reads the clock.
                let blend = SKEffectNode()
                blend.shouldEnableEffects = true
                blend.shouldRasterize = !entry.readsClock && entry.binding.alphaTrack == nil
                blend.zPosition = chain.zPosition
                chain.zPosition = 0
                guard let host = chain.parent, let at = host.children.firstIndex(of: chain) else {
                    decline("effect chain detached"); continue
                }
                chain.removeFromParent()
                blend.addChild(chain)
                host.insertChild(blend, at: at)
                let f = chain.calculateAccumulatedFrame()
                func uv(_ p: CGPoint) -> SIMD2<Float> {
                    let q = blend.convert(p, to: skScene)
                    return SIMD2(Float((q.x - covered.minX) / covered.width),
                                 Float((q.y - covered.minY) / covered.height))
                }
                let o = uv(CGPoint(x: f.minX, y: f.minY))
                guard let shader = SceneBackdropBlend.shader(
                    mode: mode, tint: SIMD3(1, 1, 1), backdrop: backdrop, map0: o,
                    mapU: uv(CGPoint(x: f.maxX, y: f.minY)) - o,
                    mapV: uv(CGPoint(x: f.minX, y: f.maxY)) - o)
                else { decline("no formula"); continue }
                blend.shader = shader
                stats.applied[mode, default: 0] += 1
                continue
            }

            // The blend shader replaces the sprite's tint shader, so it takes that shader's tint
            // over — and only that. A text layer's colour is already baked into its raster and a
            // solid's into its fill; tinting either again took Porsche 911's clock from its
            // authored grey (41) to near black (5) in the first build of this.
            let tint = sprite.shader?.uniformNamed("u_tint")?.vectorFloat3Value ?? SIMD3(1, 1, 1)
            let map = Self.backdropMap(of: sprite, in: skScene, covering: covered)
            guard let shader = SceneBackdropBlend.shader(
                mode: mode, tint: tint, backdrop: backdrop,
                map0: map.0, mapU: map.1, mapV: map.2)
            else { decline("no formula"); continue }
            sprite.shader = shader
            stats.applied[mode, default: 0] += 1
            if entry.scripted {
                remap[ObjectIdentifier(sprite)] = { [weak skScene, weak shader] sprite in
                    guard let skScene, let shader else { return }
                    let map = Self.backdropMap(of: sprite, in: skScene, covering: covered)
                    shader.uniformNamed("u_map0")?.vectorFloat2Value = map.0
                    shader.uniformNamed("u_mapU")?.vectorFloat2Value = map.1
                    shader.uniformNamed("u_mapV")?.vectorFloat2Value = map.2
                }
            }
        }

        // An `SKEffectNode` that rasterizes caches its children at whatever scale it was first
        // drawn at, and the snapshots drew them at the scene's own. Turning the cache off and on
        // drops it, so the first real frame in the `SKView` builds it at the display's scale.
        if snapshots > 0 { Self.resetRasterCaches(under: skScene) }
        Self.log("blend modes: requested \(stats.requested), applied \(stats.applied), "
                 + "declined \(stats.declined); \(snapshots) snapshots in "
                 + String(format: "%.0f ms", snapshotSeconds * 1000))
        return remap
    }

    /// The affine map from a sprite's texture space to a backdrop covering `covered` (scene
    /// coordinates), through every transform above the sprite: the backdrop UV at texture (0, 0),
    /// and its steps along the texture's two axes. The sprite's local rectangle is its size about
    /// its anchor point; `blendAgainstStaticBackdrops` only blends sprites with no scale or
    /// rotation of their own, which is what makes that true.
    private static func backdropMap(of sprite: SKSpriteNode, in scene: SKScene,
                                    covering covered: CGRect) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
        let size = sprite.size, anchor = sprite.anchorPoint
        func uv(_ t: CGPoint) -> SIMD2<Float> {
            let local = CGPoint(x: (t.x - anchor.x) * size.width, y: (t.y - anchor.y) * size.height)
            let p = sprite.convert(local, to: scene)
            return SIMD2(Float((p.x - covered.minX) / covered.width),
                         Float((p.y - covered.minY) / covered.height))
        }
        let o = uv(.zero)
        return (o, uv(CGPoint(x: 1, y: 0)) - o, uv(CGPoint(x: 0, y: 1)) - o)
    }

    private static func resetRasterCaches(under node: SKNode) {
        if let effect = node as? SKEffectNode, !(effect is SKScene), effect.shouldRasterize {
            effect.shouldRasterize = false
            effect.shouldRasterize = true
        }
        for child in node.children { resetRasterCaches(under: child) }
    }

    /// Why a wallpaper is showing its preview instead of its scene. Carried in the scene's
    /// `name` so a harness can tell a deliberate reduction from a load that failed: both look
    /// the same on screen, and `Tools/appcheck` counting either as a pass hid broken packages.
    enum PreviewReason: String {
        /// A 3D scene: there is nothing honest to composite in 2D.
        case perspective = "preview-only:perspective"
        /// No scene.json could be read or decoded at all.
        case unreadable = "preview-only:unreadable"
    }

    /// Scene containing nothing but the wallpaper's preview image, used when the scene itself
    /// cannot be composited in 2D.
    private func previewOnlyScene(wallpaperDir: URL, reason: PreviewReason) -> SKScene {
        let image = loadPreviewImage(wallpaperDir: wallpaperDir)
        let size = image?.size ?? CGSize(width: 1920, height: 1080)
        let skScene = SKScene(size: size)
        skScene.name = reason.rawValue
        skScene.scaleMode = .aspectFill
        if let image {
            let node = SKSpriteNode(texture: SKTexture(image: image))
            node.size = size
            node.position = CGPoint(x: size.width / 2, y: size.height / 2)
            skScene.addChild(node)
        }
        return skScene
    }

    private func loadPreviewImage(wallpaperDir: URL) -> NSImage? {
        for name in ["preview.jpg", "preview.png", "preview.gif"] {
            let url = wallpaperDir.appending(path: name)
            if let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }

    // MARK: - Transforms

    /// Seat a layer's holder at its authored placement.
    ///
    /// Wallpaper Engine's orthographic scene coordinates line up with SpriteKit's: origin at the
    /// bottom-left, Y increasing upwards, and an object's origin is its centre. Scale multiplies
    /// the layer's authored size — ignoring it is what made small props render at their full
    /// source resolution, an alarm clock authored 2812x1381 at scale 0.05 covering a third of the
    /// screen — and a negative component is how Wallpaper Engine mirrors a layer, which
    /// xScale/yScale reproduce directly.
    ///
    /// This is the same placement `SceneEvaluator` returns at t = 0 with the cursor centred, so a
    /// scene that never animates looks identical whether or not the evaluator ever runs.
    /// Alpha deliberately stays off the holder — see the holder/artwork split in buildSKScene.
    private func apply(_ binding: SceneLayerBinding, to node: SKNode) {
        node.position = binding.position
        node.xScale = binding.scale.dx
        node.yScale = binding.scale.dy
        node.zRotation = binding.rotation
    }

    // MARK: - Image Objects

    private func buildImageNode(_ obj: WESceneObject, wallpaperDir: URL,
                                effects: SceneEffectBuilder,
                                layerScale: CGVector) -> SKSpriteNode? {
        guard let imagePath = obj.image else { return nil }

        // Load model JSON → material JSON → texture
        let model: WEModel? = loadJSON(path: imagePath, wallpaperDir: wallpaperDir)
        guard let materialPath = model?.material else {
            print("[SceneVM] No material for image object '\(obj.name ?? "")' (model path: \(imagePath))")
            return nil
        }

        let material: WEMaterial? = loadJSON(path: materialPath, wallpaperDir: wallpaperDir)
        // An instanced model (`"instanced": true`, the `solid_instance_model_*` files) takes its
        // texture from the object, not the material: the shared `solidlayer_instance` material
        // carries none, and `instance.textures` names what this one layer draws. 53 layers across
        // 9 of this library's 2D scenes set one; 20 name `util/white` — a white texture under the
        // layer's own colour, which is exactly what the solid fill below already draws, so those
        // stay on that path untouched. The rest are the placeholder a user texture shows until
        // something fills it: Sunset on Station's album slot (`$mediaThumbnail`, with nothing
        // playing) is backed by a stock picture the author picked and was drawn as a flat white
        // square; Fujiyama's six visible dock launchers carry a link icon, also drawn white.
        let instanceTexture = obj.instanceTexture.flatMap { $0 == "util/white" ? nil : $0 }
        guard let textureName = instanceTexture ?? (material?.passes?.first?.textures?.first ?? nil),
              !textureName.isEmpty else {
            // Wallpaper Engine's solid layer has no texture: the object's own `color` fills its
            // rectangle. Entire wallpapers are assembled from them — window frames, title bars,
            // borders, backgrounds — and skipping them rendered those scenes as a blank clear
            // colour. Keyed off the model path so no other untextured material is affected.
            if imagePath.contains("solid") {
                // ...unless the solid is only the canvas of an audio visualiser whose generator
                // is declined: then the rectangle is the one thing Wallpaper Engine would not
                // show. See `SceneEffectBuilder.isDeclinedAudioCanvas`. Left drawn under
                // `SceneEffectsDisabled`, so that switch still restores the plain composite and
                // the two can be told apart.
                if !effectsEscapeHatch, effects.isDeclinedAudioCanvas(obj) {
                    Self.log("Audio visualiser canvas '\(obj.name ?? "")' not drawn: its generator is declined")
                    return nil
                }
                return buildSolidNode(obj, material: material)
            }
            print("[SceneVM] No texture in material '\(materialPath)' (material decoded: \(material != nil))")
            return nil
        }

        // `_rt_*` names are render targets — the frame buffer rendered so far, sampled by a
        // post-processing pass. There is no such file, and looking for one produced a "FAILED to
        // load texture" line for every effect layer in the scene. Skipping them quietly is the
        // correct treatment until there is a real render pipeline to feed them.
        guard !textureName.hasPrefix("_rt_") else { return nil }

        // Load texture: try .tex file first, then common image formats
        Self.log("Loading texture '\(textureName)' for '\(obj.name ?? "")'")
        var sheet: TEXParser?
        let image = loadTexture(named: textureName, materialDir: materialPath, wallpaperDir: wallpaperDir,
                                resolved: { sheet = $0 })
        guard let image = image else {
            Self.log("FAILED to load texture '\(textureName)' from material dir '\(materialPath)'")
            return nil
        }
        Self.log("Texture loaded: \(image.size)")

        // A texture that is one flat colour is a placeholder, not artwork, and on a layer whose
        // audio visualiser is declined it is the same blank canvas a solid layer is — Apple
        // Music's two white rounded squares, drawn where its bars should be. The generator is
        // asked first because it is the rarer condition, so the pixel scan is skipped for almost
        // every layer; it reads effect manifests and shaders, but only at load time.
        if !effectsEscapeHatch, obj.effects?.isEmpty == false,
           effects.isDeclinedAudioCanvas(obj), Self.isFlatColour(image) {
            Self.log("Audio visualiser canvas '\(obj.name ?? "")' not drawn: flat texture, generator declined")
            return nil
        }

        // Size from object, or use pixel dimensions (not point size, which is halved on Retina).
        // Read off the image as authored, before the texture budget below can shrink it: the
        // layer's size in the scene must not depend on how many texels it is drawn with.
        let layerSize: CGSize
        if let sizeStr = obj.size {
            let (w, h) = sizeStr.parseVector2()
            layerSize = CGSize(width: w, height: h)
        } else {
            let pixelW = image.representations.first?.pixelsWide ?? Int(image.size.width)
            let pixelH = image.representations.first?.pixelsHigh ?? Int(image.size.height)
            layerSize = CGSize(width: pixelW, height: pixelH)
        }

        let texture = SKTexture(image: budgeted(image, layerSize: layerSize, layerScale: layerScale))
        let node = SKSpriteNode(texture: texture)
        node.size = layerSize

        // A sprite sheet plays. Until upstream showed the frame times were usable this layer
        // drew frame 0 for good — the Samurai's walk cycle stood still, converted GIFs were a
        // single picture. Each frame goes through the same texture budget as a still layer.
        // Frame 0 is already `image`, so the node starts on the same picture it always did.
        lastSheetTextures = []
        if let frames = sheet?.extractFrames(), frames.count > 1 {
            let textures = frames.map { SKTexture(image: budgeted($0.image, layerSize: layerSize,
                                                                  layerScale: layerScale)) }
            // Kept for a mob, which picks its own frames from the same sheet — see the build loop.
            lastSheetTextures = textures
            if let id = obj.id, scriptedFrameLayers.contains(id) {
                Self.log("Sprite sheet '\(obj.name ?? "")' held at frame 0: a script picks its frame")
            } else {
                builtSpriteAnimations.append(WallpaperSKScene.SpriteAnimation(
                    node: node, textures: textures, durations: frames.map(\.duration)))
                Self.log("Sprite sheet '\(obj.name ?? "")' plays \(frames.count) frames, "
                         + String(format: "%.2f s a cycle", frames.map(\.duration).reduce(0, +)))
            }
        }

        // Colour and brightness multiply the texture — see `tintShader`.
        node.shader = tintShader(for: obj)

        // Blend mode from material
        if let blending = material?.passes?.first?.blending {
            switch blending {
            case "additive": node.blendMode = .add
            case "translucent": node.blendMode = .alpha
            default: node.blendMode = .alpha
            }
        }
        // The layer's own compositing mode, where SpriteKit has it, wins over the material's.
        if let mode = Self.blendMode(forColorBlendMode: obj.colorBlendMode) { node.blendMode = mode }

        return node
    }

    /// `colorBlendMode` translated to the `SKBlendMode` that does the same thing, for the modes
    /// SpriteKit can do with fixed-function blending. `nil` means "leave the layer as it is".
    ///
    /// The numbering is the table in Wallpaper Engine's `shaders/common_blending.h` (see
    /// `tintShader`). Before this, every layer composited as normal alpha whatever it asked for,
    /// and screen and additive layers are almost always artwork painted *on black* precisely
    /// because the black disappears under those modes: Valley's fog and Lonely Cat's glow rings
    /// came out as opaque black slabs, and Road Infinite's and Honkai's cloud bands as dark
    /// strips across the sky. Over the installed library's visible layers: 7 screen, 2 add,
    /// 4 plain additive, 2 multiply, 1 subtract.
    ///
    /// Multiply is `.multiplyAlpha`, not `.multiply`, measured: over a 50% grey frame, SpriteKit's
    /// `.multiply` turned a fully transparent texel black (127 → 0) — it multiplies by the
    /// premultiplied colour and ignores coverage, so every transparent pixel of the layer's
    /// rectangle would blank the frame. `.multiplyAlpha` left it at 127 and gave 64 for an
    /// opaque 50% texel, which is the multiply. Screen (191), add (255) and subtract (0) behaved
    /// on the same probe, and passed transparent texels through.
    ///
    /// Everything else — lighten 6, colour dodge 8, overlay 11, soft light 12, tint 30, … —
    /// needs to read the pixel beneath the layer, which is `_rt_FullFrameBuffer` in Wallpaper
    /// Engine and nothing at all in SpriteKit. Those keep normal alpha here, and
    /// `blendAgainstStaticBackdrops` then does them exactly wherever that pixel is a constant.
    static func blendMode(forColorBlendMode mode: Int?) -> SKBlendMode? {
        switch mode {
        case 2: return .multiplyAlpha
        case 7: return .screen
        // 9 is add proper, 31 is `A + B * opacity`; with the layer's alpha already premultiplied
        // into its colour, both are SpriteKit's `.add`.
        case 9, 31: return .add
        case 20: return .subtract
        default: return nil
        }
    }

    // MARK: - Texture budget

    /// What the texture budget did to the last build, for the log and the offline tools.
    struct TextureStats: Equatable {
        var layers = 0
        var scaled = 0
        var authoredTexels = 0
        var builtTexels = 0
    }

    /// Build state, owned by `loadQueue`.
    private var buildingSceneSize = CGSize.zero
    private var textureStats = TextureStats()
    private(set) var lastTextureStats = TextureStats()

    /// An image layer's artwork at Settings → Texture Resolution.
    ///
    /// Done on the decoded image, once, at load: the GPU texture `SKTexture` uploads is then the
    /// smaller one, which is the memory the setting exists to save. The sprite's size is set from
    /// the authored dimensions by the caller, so the layer occupies the same rectangle at any
    /// budget and only its texel density changes. UVs are normalised, so effect passes and masks
    /// sample the reduced texture exactly where they sampled the full one.
    ///
    /// For `.display`, "what the layer covers" is its authored size times its own scale times the
    /// factor `.aspectFill` maps the scene onto the display with. A parent's scale and a scale
    /// track are not counted: a layer enlarged by either is drawn with fewer texels than it
    /// covers, which is the one way Automatic can lose detail. Below a 10% saving the image is
    /// left alone, because resampling it would blur it for nothing.
    ///
    /// Measured over the 93 scenes installed, one process per scene: High Performance takes the
    /// textured layers from 973.5 M texels to 244.2 M and the process footprint down by 60 MB a
    /// scene on average; Automatic for a 2560×1440 display reduces 180 layers, to 554.5 M texels,
    /// 33 MB a scene. Rendered at 2560×1440 with emitters hidden, Automatic differs from full
    /// resolution by a mean 0.28–0.36 of 255 per channel (resampling, CG's against the GPU's), High
    /// Performance by 0.57–1.24.
    private func budgeted(_ image: NSImage, layerSize: CGSize, layerScale: CGVector) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let w = cg.width, h = cg.height
        textureStats.layers += 1
        textureStats.authoredTexels += w * h

        let factor: CGFloat
        switch building.textures {
        case .full:
            factor = 1
        case .scaled(let scale):
            factor = scale
        case .display(let display):
            let scene = buildingSceneSize
            guard scene.width > 0, scene.height > 0, w > 0, h > 0 else { factor = 1; break }
            let sceneToDisplay = max(display.width / scene.width, display.height / scene.height)
            let coveredW = layerSize.width * abs(layerScale.dx) * sceneToDisplay
            let coveredH = layerSize.height * abs(layerScale.dy) * sceneToDisplay
            factor = max(coveredW / CGFloat(w), coveredH / CGFloat(h))
        }

        guard factor < 0.9, max(w, h) > SceneQuality.minimumScaledSide else {
            textureStats.builtTexels += w * h
            return image
        }
        let newW = max(1, Int((CGFloat(w) * factor).rounded()))
        let newH = max(1, Int((CGFloat(h) * factor).rounded()))
        // The image's own space where it is an RGB one, so reducing it never also recolours it.
        let space = cg.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: newW, height: newH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            textureStats.builtTexels += w * h
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let reduced = ctx.makeImage() else {
            textureStats.builtTexels += w * h
            return image
        }
        textureStats.scaled += 1
        textureStats.builtTexels += newW * newH
        return NSImage(cgImage: reduced, size: NSSize(width: newW, height: newH))
    }

    // MARK: - Layer tint

    /// `texel.rgb *= colour * brightness`, which is the whole of what Wallpaper Engine does with
    /// a layer's `color` and `brightness`: its own image shaders read
    /// `color *= g_Color4` (genericimage2/3/4.frag, with the layer's colour, brightness and alpha
    /// folded into that one uniform), and the older path spells it `color.rgb *= g_Brightness`.
    ///
    /// It must go through `SKDefaultShading()` rather than sampling `u_texture` directly.
    /// SpriteKit hands a custom fragment shader the raw texel and nothing else: sampling it by
    /// hand drops the node's `alpha`, which `WallpaperSKScene` writes on every frame, and a layer
    /// authored at 0.5 came out fully opaque. Measured side by side over a white sprite at
    /// alpha 0.5 on black — `SKDefaultShading()` gave 127, `texture2D(u_texture, v_tex_coord)`
    /// gave 255. `SKDefaultShading()` returns exactly what SpriteKit would have drawn, so
    /// multiplying its rgb leaves everything else alone.
    ///
    /// No `uniform` declaration here: `SKShader` emits one per entry in its `uniforms` array, and
    /// declaring it in the source as well fails the compile with a duplicate.
    private static let tintShaderSource = """
    void main() {
        vec4 texel = SKDefaultShading();
        gl_FragColor = vec4(texel.rgb * u_tint, texel.a);
    }
    """

    /// One shader per distinct tint rather than per layer. Pixels alone tints 73 layers and they
    /// share a handful of colours between them, and a shared `SKShader` is also what lets
    /// SpriteKit keep batching the sprites that use it.
    private var tintShaders: [SIMD3<Float>: SKShader] = [:]

    /// How many sprites the last build actually hung one on. Reported in the build log because a
    /// tint that quietly reaches nothing looks exactly like a tint that changes nothing: several
    /// of the scenes whose JSON carries a colour turn out to draw it through a solid layer, a
    /// 3D scene that falls back to its preview, or a texture that never resolves.
    private var tintedLayers = 0

    /// The multiply for a layer, or `nil` when there is nothing to multiply by.
    ///
    /// Returning `nil` is the common case and it matters: 543 of this library's 736 visible image
    /// layers are authored at plain white with brightness 1, and hanging a shader on those would
    /// cost them a per-pixel multiply and a break in SpriteKit's batching for an operation that
    /// cannot change a single pixel.
    ///
    /// `colorBlendMode` is deliberately not consulted *here*. It was read here as a boolean "is this
    /// layer tinted", which is not what it is: it is the layer's *compositing* mode against the
    /// frame behind it, indexed into the table in the engine's own `shaders/common_blending.h` —
    /// 2 multiply, 6 lighten, 7 screen, 8 colour dodge, 9 add, 11 overlay, 12 soft light,
    /// 20 subtract, 30 tint, 31 plain additive (`A + B * opacity`), with 0 and absent both
    /// meaning normal alpha. `genericimage2.frag` only reaches for it *after* the colour
    /// multiply, guarded by `#if BLENDMODE`, and it needs the framebuffer underneath the layer
    /// (`_rt_FullFrameBuffer`) to do its work — which a sprite in SpriteKit does not get. So it
    /// says nothing about tinting, and reading it as a switch cut both ways: of the 487 image
    /// layers carrying a colour, the 428 with 0 or nothing were never tinted at all, while the 59
    /// with a real mode had `colorBlendFactor` set to 1 — which does not multiply, it
    /// *interpolates*, so their artwork was replaced outright by a flat colour rectangle.
    ///
    /// The compositing half is handled on the node instead: the modes `SKBlendMode` has natively
    /// — multiply, screen, add, subtract — are mapped by `blendMode(forColorBlendMode:)` and set
    /// on whichever node composites the layer into the frame. The rest need the framebuffer this
    /// sprite does not get, and are done by `blendAgainstStaticBackdrops` where it is static.
    private func tintShader(for obj: WESceneObject) -> SKShader? {
        let tint = Self.tint(for: obj)
        guard tint != SIMD3<Float>(1, 1, 1) else { return nil }
        tintedLayers += 1

        if let cached = tintShaders[tint] { return cached }
        let shader = SKShader(source: Self.tintShaderSource)
        shader.uniforms = [SKUniform(name: "u_tint", vectorFloat3: tint)]
        tintShaders[tint] = shader
        return shader
    }

    /// The layer's `color` times its `brightness`: what `tintShader` multiplies by.
    static func tint(for obj: WESceneObject) -> SIMD3<Float> {
        let c = obj.color?.parseColor() ?? (r: 1.0, g: 1.0, b: 1.0)
        // Brightness runs past 1 in this library — 2.0 on Lonely Cat's clock digits — so it is a
        // gain, not a fade, and is not clamped here. Only a negative would be nonsense.
        let brightness = max(0, obj.brightness ?? 1.0)
        return SIMD3<Float>(Float(c.r * brightness), Float(c.g * brightness), Float(c.b * brightness))
    }

    /// Whether every visible texel of an image is the same colour, so that the image carries a
    /// shape at most and no picture.
    ///
    /// Read at 32×32: downsampling averages neighbouring texels, so any real artwork comes out
    /// with variance to spare while a flat placeholder stays flat. Only texels at least half
    /// covered are compared — the anti-aliased rim of a rounded placeholder blends towards
    /// transparent and would otherwise read as a second colour. Tolerance is 8/255 per channel.
    static func isFlatColour(_ image: NSImage) -> Bool {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        let side = 32
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }

        var reference: (Int, Int, Int)?
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Int(px[i + 3])
            guard a >= 128 else { continue }
            // Un-premultiply, so a half-covered texel compares by colour rather than coverage.
            let c = (Int(px[i]) * 255 / a, Int(px[i + 1]) * 255 / a, Int(px[i + 2]) * 255 / a)
            guard let r = reference else { reference = c; continue }
            if abs(c.0 - r.0) > 8 || abs(c.1 - r.1) > 8 || abs(c.2 - r.2) > 8 { return false }
        }
        return reference != nil
    }

    /// A flat rectangle filled with the object's colour, for textureless solid layers.
    private func buildSolidNode(_ obj: WESceneObject, material: WEMaterial?) -> SKSpriteNode? {
        guard let sizeStr = obj.size else { return nil }
        let (w, h) = sizeStr.parseVector2()
        guard w > 0, h > 0 else { return nil }

        let c = obj.color?.parseColor() ?? (r: 1.0, g: 1.0, b: 1.0)
        let node = SKSpriteNode(color: NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1.0),
                                size: CGSize(width: w, height: h))
        if material?.passes?.first?.blending == "additive" { node.blendMode = .add }
        if let mode = Self.blendMode(forColorBlendMode: obj.colorBlendMode) { node.blendMode = mode }
        return node
    }

    // MARK: - Text Objects

    /// A text layer, drawn to an image and hung on a sprite like any other artwork.
    ///
    /// The string is whatever Wallpaper Engine baked into the object. Where the author bound a
    /// script to it — 259 of the 386 text objects in this library, two thirds of them clocks —
    /// that baked value is the last string the script produced in the editor, and it is what
    /// shows until `SceneScriptRuntime` takes the layer over.
    private func buildTextNode(_ obj: WESceneObject,
                               wallpaperDir: URL) -> (SKSpriteNode, SceneTextLayer.Style)? {
        guard let text = obj.text, !text.isEmpty,
              let style = SceneTextLayer.style(for: obj, read: { path in
                  self.readAsset(path, bundle: nil, wallpaperDir: wallpaperDir)
              }),
              let (image, size) = SceneTextLayer.image(text, style: style) else { return nil }

        let node = SKSpriteNode(texture: SKTexture(image: image))
        node.size = size
        // The text's alignment decides which of its edges sits on the origin. Set on the sprite
        // rather than baked into its position so that a script's next string, drawn wider or
        // narrower, keeps that edge where it is. See `SceneTextLayer.Style.anchorPoint`.
        node.anchorPoint = style.anchorPoint
        // Text layers carry `colorBlendMode` too — one plain-additive readout in this library.
        if let mode = Self.blendMode(forColorBlendMode: obj.colorBlendMode) { node.blendMode = mode }
        return (node, style)
    }

    // MARK: - Particle Objects

    /// A particle layer: the object's own system, and the `static` children it carries.
    ///
    /// Returned as the bare emitter when the system has no child to draw, so that the 400-odd
    /// particle layers without one build exactly the node they always did, and as a group of
    /// emitters otherwise. Either way it is the layer's artwork, so the layer's alpha track fades
    /// a child with its parent — an ember's glow does not outlive the ember.
    private func buildParticleNode(_ obj: WESceneObject, wallpaperDir: URL, sceneSize: CGSize) -> SKNode? {
        guard let particlePath = obj.particle else { return nil }

        let particleSystem: WEParticleSystem? = loadJSON(path: particlePath, wallpaperDir: wallpaperDir)
        guard let ps = particleSystem else {
            print("[SceneVM] Failed to load particle system '\(particlePath)'")
            return nil
        }
        let label = obj.name ?? "?"
        // An `eventfollow` child that is only a second sprite on each parent particle is drawn
        // as part of the parent's own texture; see `mergeRider`. Done inside `buildEmitter`,
        // before its pre-simulation, so the particles that warm-up spawns are already the merged
        // sprite at the merged size. Every child it has looked at, merged or declined with its
        // reason, is then kept from `childSystems`, which would only log it a second time.
        var examined: Set<String> = []
        let emitter = buildEmitter(ps, over: obj.instanceoverride, maxcount: nil,
                                   label: label, wallpaperDir: wallpaperDir) { emitter in
            for child in ps.children?.entries ?? [] where child.type == "eventfollow" {
                guard let path = child.name, !examined.contains(path) else { continue }
                examined.insert(path)
                _ = mergeRider(child, into: emitter, parent: ps, over: obj.instanceoverride,
                               label: label, wallpaperDir: wallpaperDir)
            }
        }
        let children = childSystems(of: ps, over: obj.instanceoverride, label: label,
                                    wallpaperDir: wallpaperDir, lineage: [particlePath],
                                    examined: examined)
        guard !children.isEmpty else { return emitter }

        // A parent that is itself declined — a refracting system — keeps the children that are
        // not: they are separate systems with their own materials, and Wallpaper Engine draws
        // them whether or not anything is drawn for the parent.
        let group = SKNode()
        for child in children { group.addChild(child) }
        if let emitter { group.addChild(emitter) }
        return group
    }

    /// The `static` children of a system, each placed by its own `origin`/`scale` and built as an
    /// emitter of its own — and their children in turn, since a child is a whole system and may
    /// carry more (`rain_screen_fast_4k` does).
    ///
    /// What the library actually holds, over the visible particle objects of every installed
    /// scene: 137 children in 35 scenes — 50 `static` in 21 scenes, 56 `eventfollow` in 16, 31
    /// `eventspawn` in 13, and no `eventdeath`. Only the first kind is built:
    ///
    /// - **`static` is a second system placed with the parent**, sharing its transform — the glow
    ///   under an ember (`ember` → `emberglow`, 18 of them counting the small and workshop
    ///   copies), the sparks over a torch or a wildfire (`torchembers`, `wildfireembers`, 18), the
    ///   second species of leaf (`leaves2b`…`leaves4b`, 7). SpriteKit can draw that exactly as it
    ///   draws the parent: another `SKEmitterNode` in the same holder.
    /// - **The event kinds attach a system to every particle of the parent**: a trail emitter
    ///   that rides each shooting star or firefly (`eventfollow`), a burst of droplets or a flash
    ///   wherever a parent particle is born (`eventspawn`). `SKEmitterNode` gives no access to
    ///   its particles — they are not nodes, `particleAction` can only move, scale, fade and
    ///   colour them, and `targetNode` only says which node *new* particles are added to. Nothing
    ///   can be hung off a particle, so the only things buildable are a child emitter at the
    ///   *system's* origin, which is not where any of these are drawn, or a guess at the parent's
    ///   paths. Declined: a missing trail or splash costs a detail, while 56 trail emitters
    ///   parked on their systems' centres would draw glowing blobs no author put there. The one
    ///   exception is an `eventfollow` child that is no more than a second sprite on the parent
    ///   particle, which `mergeRider` folds into the parent's texture before this runs — 3 of
    ///   the 56, the shooting-star glow in Toyota Supra, Transformer and Berserk.
    ///
    ///   The 31 `eventspawn` children stay declined, each class for a measured reason. All but
    ///   one are tied to the instant and the spot a parent particle is born: `sparktrails`
    ///   throws 100 sparks at once from each `spark` flash, `lightning2glow` lights a 300–3000
    ///   unit halo for 0.1 s where each bolt strikes, the rain-splash droplets leave 7 or 8 at
    ///   a time from each ripple. `SKEmitterNode` emits at a steady rate from places it picks
    ///   itself, so a stand-in at the parent's rate × burst size turns Japanese Street's
    ///   occasional fireworks into a fountain that never stops, and puts the lightning flashes
    ///   anywhere within the bolts' 512–1200 unit spread rather than on a bolt. Scattering the
    ///   droplets uniformly over the parent's box at the matching rate keeps their density but
    ///   breaks each crown into hops nowhere near a ripple, and no installed preview is sharp
    ///   enough (all are 250–256 px GIFs or crops) to show that this reads closer rather than
    ///   further from the wallpaper. The glow on `Star_04` would merge as `mergeRider` does,
    ///   but lives 3 s on a 4–8 s star — the lifetime mismatch documented there.
    ///
    /// Each child inherits the parent object's `instanceoverride`. The override belongs to the
    /// *object*, and the children are part of what that object draws: Trump's ember is tinted
    /// `colorn 1 0 0` and Lost Landscape's leaves `0 0 0` at `alpha 0.2`, and an author choosing
    /// red embers or black leaves has not chosen a cream glow or a second flight of bright green
    /// leaves. It goes through the same `buildEmitter` as the parent, so the order that
    /// function documents — lifetime before the budget, alpha before `alphafade`, pre-simulation
    /// last — holds for the child too.
    private func childSystems(of ps: WEParticleSystem, over: WEInstanceOverride?, label: String,
                              wallpaperDir: URL, lineage: Set<String>,
                              examined: Set<String> = []) -> [SKNode] {
        // A child naming one of its own ancestors would recurse forever. Four levels is far past
        // anything in the library, which nests at most two.
        guard lineage.count < 4 else { return [] }
        var nodes: [SKNode] = []
        for child in ps.children?.entries ?? [] {
            guard let path = child.name, !path.isEmpty, !lineage.contains(path) else { continue }
            let kind = child.type ?? "static"
            if kind == "eventfollow" && examined.contains(path) { continue }
            guard kind == "static" else {
                Self.log("particle '\(label)': '\(kind)' child '\(path)' declined")
                continue
            }
            guard let system: WEParticleSystem = loadJSON(path: path, wallpaperDir: wallpaperDir) else {
                print("[SceneVM] Failed to load child particle system '\(path)'")
                continue
            }

            // The child's own placement, relative to the parent system. A separate node rather
            // than written onto the emitter, because the emitter's `position` already carries its
            // own emitter `origin` (see `buildEmitter`), and the two compose: the child system
            // sits at `origin`, and its particles are born at its emitter's offset from there.
            // Particle space is Y-up, as in `buildEmitter`, so neither is flipped.
            //
            // `angles` is read and not applied, for the reason the parent layer's roll is not
            // (see `buildSKScene`): the parent's emission is drawn unturned, and turning only
            // the child would set the two at an angle to each other that the author never saw
            // between them. None of the 50 static children writes an angle, or any placement.
            let placement = SKNode()
            if let origin = child.origin {
                let (x, y, _) = origin.parseVector3()
                placement.position = CGPoint(x: x, y: y)
            }
            if let scale = child.scale {
                let (sx, sy, _) = scale.parseVector3()
                placement.xScale = CGFloat(sx)
                placement.yScale = CGFloat(sy)
            }

            for grandchild in childSystems(of: system, over: over, label: label,
                                           wallpaperDir: wallpaperDir,
                                           lineage: lineage.union([path])) {
                placement.addChild(grandchild)
            }
            if let emitter = buildEmitter(system, over: over, maxcount: child.maxcount,
                                          label: label, wallpaperDir: wallpaperDir) {
                placement.addChild(emitter)
            }
            guard !placement.children.isEmpty else { continue }

            // Beneath the parent. `SKView.ignoresSiblingOrder` is on in the app, so insertion
            // order says nothing about drawing order and it has to be stated as a z. A quarter of
            // a unit per level keeps the whole group between this layer's neighbours in scene
            // order — `attach` spaces layers a whole unit apart, and `lineage` stops the nesting
            // at three levels, -0.75 at the deepest. Beneath, because what a static child is
            // mostly for is the glow behind an ember and the halo behind a flame. 39 of the 50
            // are additive, and additive light composes the same in either order; the 7 leaves
            // are the only translucent ones drawn (the 4 rain-screen children refract, and are
            // declined in `buildEmitter` like any refracting system).
            placement.zPosition = -0.25
            nodes.append(placement)
        }
        return nodes
    }

    /// Draws an `eventfollow` child as part of its parent's sprite, for the one shape of child
    /// where that is exact rather than an approximation. Returns whether it did.
    ///
    /// `shootingstarglow` is the case. It writes `"instantaneous": 1, "rate": 0`, no distance,
    /// no velocity and zero gravity, so under `eventfollow` it puts one sprite on each shooting
    /// star at the instant the star is born and carries it there; with the same three-second
    /// life and the same `alphafade` as the star, the two are born, move, fade and die as one.
    /// That is a second texture on the same particle, which an `SKEmitterNode` *can* draw:
    /// both sprites additive, so their sum painted into one texture is what the frame would
    /// have held, at their true proportion — a 100–150 unit halo at 0.55 around a 2–5 unit
    /// star. A separate emitter cannot do it, because `SKEmitterNode` seeds itself and two
    /// emitters never lay a particle down in the same place.
    ///
    /// Every condition below is one that makes the merge stop being exact, and each declines
    /// rather than approximates. Measured over the installed library, they leave exactly the
    /// preset `shootingstar` → `shootingstarglow` pair, in Toyota Supra, Transformer and
    /// Berserk. The rest of the 56 `eventfollow` children, and why:
    ///
    /// - **A glow that outlives or dies before its parent** — the workshop `Shooting_Star_01`
    ///   (4–5 s) and `Star_06` (5–7 s) carrying a 3 s glow, 2914579837's 4 s star with the same.
    ///   Merged, the glow would last the parent's whole life, up to 2.3× what the author set,
    ///   and on `Star_06` that is 85 glows at a time across Lonely Cat, Other World and Final
    ///   Demons. The two cannot be split inside one particle: a `particleAction` that swaps the
    ///   texture partway through is not run by `advanceSimulationTime` under `SKRenderer` —
    ///   measured, 0 of 5,505 particles changed texture — so it would sit outside everything
    ///   `Tools/scenecheck` can see, the same reason live video is not done.
    /// - **A different fade** — 2894041887's `Shooting_Star` writes `alphafade: {}`, read by
    ///   `buildEmitter` as no fade, against its glow's fade-in over half its life.
    /// - **A trail, not a sprite** — `firefliestrail` emits 10 a second for as long as the
    ///   firefly lives, each drifting off at ±5 units/s, which is the shape a per-particle
    ///   emitter exists for. `star_shine` is scaled 2.5× off its parent and oscillates.
    private func mergeRider(_ child: WEParticleChild, into emitter: SKEmitterNode,
                            parent: WEParticleSystem, over: WEInstanceOverride?,
                            label: String, wallpaperDir: URL) -> Bool {
        func decline(_ why: String) -> Bool {
            Self.log("particle '\(label)': 'eventfollow' child '\(child.name ?? "?")' declined: \(why)")
            return false
        }
        func isZero(_ vector: String?) -> Bool {
            guard let vector else { return true }
            let (x, y, z) = vector.parseVector3()
            return x == 0 && y == 0 && z == 0
        }
        func isOne(_ vector: String?) -> Bool {
            guard let vector else { return true }
            let (x, y, z) = vector.parseVector3()
            return x == 1 && y == 1 && z == 1
        }
        func initializer(_ name: String, of ps: WEParticleSystem) -> WEParticleInitializer? {
            ps.initializer?.first { $0.name == name }
        }
        func op(_ name: String, of ps: WEParticleSystem) -> WEParticleOperator? {
            ps.operator?.first { $0.name == name }
        }
        func range(_ ini: WEParticleInitializer?, default value: Double) -> (Double, Double) {
            (ini?.min?.doubleValue ?? value, ini?.max?.doubleValue ?? value)
        }
        func blending(_ ps: WEParticleSystem) -> (String?, Bool) {
            guard let path = ps.material,
                  let pass = (loadJSON(path: path, wallpaperDir: wallpaperDir) as WEMaterial?)?
                    .passes?.first else { return (nil, false) }
            return (pass.blending, pass.combos?["REFRACT"] == 1)
        }

        guard let path = child.name,
              let rider: WEParticleSystem = loadJSON(path: path, wallpaperDir: wallpaperDir) else {
            return decline("does not load")
        }
        // Placed exactly on the parent particle, and nothing hanging off it in turn.
        guard isZero(child.origin), isOne(child.scale), isZero(child.angles),
              rider.children?.entries.isEmpty ?? true else {
            return decline("placed off the parent, or carries children")
        }
        // One particle per parent particle, born on it, at the moment it is born.
        guard let em = rider.emitter?.first, rider.emitter?.count == 1,
              (em.rate ?? 0) == 0, em.instantaneous?.doubleValue == 1,
              (em.distancemax?.doubleValue ?? 0) == 0, isZero(em.origin),
              (em.speedmax ?? 0) == 0 else {
            return decline("emits more than one particle per parent, or away from it")
        }
        // No motion of its own, so it stays where the parent particle carries it.
        let allowedInitializers: Set<String> = ["lifetimerandom", "sizerandom", "colorrandom",
                                                "alpharandom"]
        let allowedOperators: Set<String> = ["movement", "alphafade"]
        guard (rider.initializer ?? []).allSatisfy({ allowedInitializers.contains($0.name ?? "") }),
              (rider.operator ?? []).allSatisfy({ allowedOperators.contains($0.name ?? "") }),
              isZero(op("movement", of: rider)?.gravity) else {
            return decline("moves, turns or changes on its own")
        }
        guard rider.renderer?.first?.name ?? "sprite" == "sprite",
              parent.renderer?.first?.name != "spritetrail",
              op("sizechange", of: parent) == nil else {
            return decline("drawn as a trail, or its parent changes size")
        }
        // The same life, to the second, with no spread: one texture lives and dies as one.
        let riderLife = range(initializer("lifetimerandom", of: rider), default: 1)
        let parentLife = range(initializer("lifetimerandom", of: parent), default: 1)
        guard riderLife.0 == riderLife.1, parentLife.0 == parentLife.1,
              riderLife.0 == parentLife.0 else {
            return decline("lifetime \(riderLife) against the parent's \(parentLife)")
        }
        // The same fade, read the way `buildEmitter` reads it.
        let riderFade = op("alphafade", of: rider)
        let parentFade = op("alphafade", of: parent)
        guard (riderFade?.fadeintime ?? 0) == (parentFade?.fadeintime ?? 0),
              (riderFade?.fadeouttime ?? 1) == (parentFade?.fadeouttime ?? 1) else {
            return decline("fades on a different curve from its parent")
        }
        // The same colour, since the merged sprite is tinted as one. Both ends of the range are
        // compared even though `buildEmitter` tints by `max` alone today: the merge is only
        // exact if the two sprites would have been tinted alike under *any* reading of the
        // range, and a parent and glow with different `min`s would otherwise merge silently and
        // stay merged the day the emitter starts honouring the spread. No initializer at all is
        // an untinted white sprite; an initializer without a `min` randomises up from black.
        func colourRange(_ ini: WEParticleInitializer?) -> [Double] {
            let white = (255.0, 255.0, 255.0)
            guard let ini else { return [255, 255, 255, 255, 255, 255] }
            let lo = ini.min?.vectorValue ?? (0, 0, 0), hi = ini.max?.vectorValue ?? white
            return [lo.0, lo.1, lo.2, hi.0, hi.1, hi.2]
        }
        guard colourRange(initializer("colorrandom", of: rider))
                == colourRange(initializer("colorrandom", of: parent)) else {
            return decline("coloured differently from its parent")
        }
        // Both additive, so the merged texture is the plain sum of the two sprites — the order
        // they were drawn in no longer matters, and the sum is what the frame would have held.
        let (riderBlend, riderRefracts) = blending(rider)
        let (parentBlend, _) = blending(parent)
        guard riderBlend == "additive", parentBlend == "additive", !riderRefracts else {
            return decline("not additive over an additive parent")
        }
        // Enough budget for every parent particle alive at once to carry one.
        let budget = Double(child.maxcount ?? rider.maxcount ?? 0) * (over?.count ?? 1)
        let alive = Double(emitter.particleBirthRate * emitter.particleLifetime)
        guard budget >= alive.rounded(.up) else {
            return decline("budget \(budget) for \(alive) parent particles")
        }
        // Opacity relative to the parent's, which the merged sprite as a whole carries.
        let riderAlpha = range(initializer("alpharandom", of: rider), default: 1)
        let parentAlpha = range(initializer("alpharandom", of: parent), default: 1)
        let relativeAlpha = ((riderAlpha.0 + riderAlpha.1) / 2) / ((parentAlpha.0 + parentAlpha.1) / 2)
        guard relativeAlpha > 0, relativeAlpha <= 1 else {
            return decline("more opaque than its parent")
        }

        let riderSize = range(initializer("sizerandom", of: rider), default: 1)
        let parentSize = range(initializer("sizerandom", of: parent), default: 1)
        let riderAverage = (riderSize.0 + riderSize.1) / 2
        let parentAverage = (parentSize.0 + parentSize.1) / 2
        guard riderAverage > 0, parentAverage > 0,
              let parentImage = emitter.particleTexture?.cgImage(),
              let materialPath = rider.material,
              let texName = ((loadJSON(path: materialPath, wallpaperDir: wallpaperDir) as WEMaterial?)?
                .passes?.first?.textures?.first ?? nil),
              let riderImage = (loadTexture(named: texName, materialDir: materialPath,
                                            wallpaperDir: wallpaperDir)
                                ?? generateProceduralTexture(named: texName))?
                .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return decline("a texture does not load")
        }

        // One canvas spanning the larger of the two, the smaller centred in it at its true
        // proportion. Sized by the larger sprite's own texture, within 128–512 pixels.
        let outer = max(riderAverage, parentAverage)
        let outerImage = riderAverage >= parentAverage ? riderImage : parentImage
        let side = min(max(CGFloat(max(outerImage.width, outerImage.height)), 128), 512)
        let canvas = CGRect(x: 0, y: 0, width: side, height: side)
        func rect(for size: Double) -> CGRect {
            let edge = side * CGFloat(size / outer)
            return CGRect(x: (side - edge) / 2, y: (side - edge) / 2, width: edge, height: edge)
        }
        guard let ctx = CGContext(data: nil, width: Int(side), height: Int(side),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return decline("no drawing context")
        }
        ctx.clear(canvas)
        ctx.interpolationQuality = .high
        ctx.setBlendMode(.plusLighter)
        ctx.setAlpha(CGFloat(relativeAlpha))
        ctx.draw(riderImage, in: rect(for: riderAverage))
        ctx.setAlpha(1)
        ctx.draw(parentImage, in: rect(for: parentAverage))
        guard let merged = ctx.makeImage() else { return decline("no merged image") }

        // The particle grows to the larger sprite; its spread follows that sprite's own, in the
        // form `buildEmitter` writes it.
        let sizeMultiplier = over?.size ?? 1
        emitter.particleTexture = SKTexture(cgImage: merged)
        emitter.particleSize = CGSize(width: outer * sizeMultiplier, height: outer * sizeMultiplier)
        let outerSize = riderAverage >= parentAverage ? riderSize : parentSize
        // A ratio around `particleScale` 1, so the override does not apply to it again; see the
        // same line in `buildEmitter`.
        emitter.particleScaleRange = CGFloat(abs(outerSize.1 - outerSize.0) / outer)
        Self.log("particle '\(label)': 'eventfollow' child '\(path)' merged into its parent's sprite")
        return true
    }

    /// One `SKEmitterNode` from one particle system file, scaled by the object's
    /// `instanceoverride`. `maxcount`, when given, replaces the system's own — a child entry may
    /// write one.
    ///
    /// `beforeWarmup` runs on the finished emitter just ahead of the `starttime` pre-simulation,
    /// for a caller that still has something to change about every particle it will spawn.
    private func buildEmitter(_ ps: WEParticleSystem, over: WEInstanceOverride?, maxcount: Int?,
                              label: String, wallpaperDir: URL,
                              beforeWarmup: (SKEmitterNode) -> Void = { _ in }) -> SKEmitterNode? {
        let emitter = SKEmitterNode()

        // Particle texture from material
        if let materialPath = ps.material {
            let material: WEMaterial? = loadJSON(path: materialPath, wallpaperDir: wallpaperDir)
            // A refracting particle does not draw its colour texture: `genericparticle` with
            // `REFRACT` samples the frame *behind* the particle, displaced through the normal map
            // in slot 1 — drops on glass, splashes, heat haze. Slot 0 is a placeholder (Final
            // Demons' is literally named `particles 256x1280 blank`). SpriteKit cannot read the
            // frame beneath a node, so drawn as a sprite the placeholder came out as hundreds of
            // flat grey squares over the whole wallpaper. Declined, as multi-pass effects are:
            // an invisible distortion missing is a far smaller error than an opaque one added.
            // 23 materials across 9 scenes in the installed library carry the combo.
            if material?.passes?.first?.combos?["REFRACT"] == 1 {
                Self.log("particle '\(label)': refracting material, declined")
                return nil
            }
            if let texName = material?.passes?.first?.textures?.first ?? nil {
                let texImage = loadTexture(named: texName, materialDir: materialPath, wallpaperDir: wallpaperDir)
                    ?? generateProceduralTexture(named: texName)
                if let img = texImage {
                    emitter.particleTexture = SKTexture(image: img)
                }
            }

            // Blend mode
            if let blending = material?.passes?.first?.blending {
                emitter.particleBlendMode = blending == "additive" ? .add : .alpha
            }
        }

        // How this copy of the preset differs from the preset. Every number in it multiplies
        // what the preset declares; see `WEInstanceOverride` for why, and for what it cost to
        // read only two of its fields.

        // Emitter properties
        if let em = ps.emitter?.first {
            emitter.particleBirthRate = CGFloat(em.rate ?? 100) * CGFloat(over?.rate ?? 1)

            // Emission area. `sphererandom` scatters within a radius, `boxrandom` within a
            // rectangle whose half-extents differ per axis — a rain emitter spanning the frame
            // writes "1920 1080 0". Reading only the first component would make every box
            // emitter square and, for a wide frame, would stop the rain short of the sides.
            if let extent = em.distancemax {
                let (x, y, _) = extent.vectorValue
                let width = CGFloat(x) * 2
                let height = em.name == "boxrandom" ? CGFloat(y) * 2 : width
                emitter.particlePositionRange = CGVector(dx: width, dy: height)
            }

            // Where the particles are born, relative to the object. Rain presets are authored as
            // an emitter at the object's centre pushed up by `origin` — `rainperspective` sits at
            // "0 768 0", `rainrefractive` at "0 1024 0" — with a thin `boxrandom` strip
            // ("1024 0 0") so the drops start in a line *above* the frame and fall into it.
            // Decoded and never applied, every one of those strips sat at its layer's centre, and
            // together with the flipped velocity below the rain rose out of mid-frame: rendered
            // with every other layer hidden, Toyota Supra's rain streaks filled only the upper
            // half of the frame before this and the whole height after. 148 of the library's 493
            // systems, across 51 scenes, carry a non-zero origin.
            //
            // No scaling here on purpose: the emitter is a child of the layer's holder, which
            // already carries the object's scale, so the offset is scaled exactly as the object's
            // own placement is — the same as WE, where `origin` lives in the system's local space.
            if let origin = em.origin {
                let (ox, oy, _) = origin.parseVector3()
                emitter.position = CGPoint(x: ox, y: oy)
            }
        }
        var hasVelocity = false

        // Initializers
        for ini in ps.initializer ?? [] {
            switch ini.name {
            case "lifetimerandom":
                let minLife = ini.min?.doubleValue ?? 1
                let maxLife = ini.max?.doubleValue ?? 1
                emitter.particleLifetime = CGFloat((minLife + maxLife) / 2)
                emitter.particleLifetimeRange = CGFloat(maxLife - minLife)

            case "sizerandom":
                let minSize = ini.min?.doubleValue ?? 1
                let maxSize = ini.max?.doubleValue ?? 1
                let avgSize = (minSize + maxSize) / 2
                let sizeMultiplier = over?.size ?? 1.0
                emitter.particleSize = CGSize(width: avgSize * sizeMultiplier, height: avgSize * sizeMultiplier)
                // `particleScaleRange` is a spread around `particleScale` 1, a ratio of the size
                // set just above, so the override is already in it through `particleSize`.
                // Multiplying it in a second time made a `size: 3` override triple the spread as
                // well as the size — a preset authored 10–20 (±1/3 of its mean) drew particles
                // anywhere from nothing to twice their mean — and a `size: 0.3` one flatten a
                // hand-picked size variance to under a third of what the author set.
                emitter.particleScaleRange = CGFloat((maxSize - minSize) / avgSize)

            case "velocityrandom":
                hasVelocity = true
                let minV = ini.min?.vectorValue ?? (0, 0, 0)
                let maxV = ini.max?.vectorValue ?? (0, 0, 0)
                let avgSpeedX = (minV.0 + maxV.0) / 2
                let avgSpeedY = (minV.1 + maxV.1) / 2
                let avgSpeedZ = (minV.2 + maxV.2) / 2
                // Particle space is Y-up, the same as the scene's own object placement (see
                // `apply(_:to:)`), so the velocity goes straight into SpriteKit's angle with no
                // flip. This used to negate Y on the belief that WE's velocity is Y-down, and the
                // presets themselves say otherwise: `rainperspective` is born at origin "0 768 0"
                // — above the layer — with velocity "0 -3000 0", and `snowperspective` is born at
                // "150 550 0" with "-10 -50 0" to "-37 -90 0". An emitter pushed up and aimed down
                // is a sky to fall from; pushed up and aimed up it would be a sky that empties
                // itself off the top of the frame. Read Y-down, every rain and snow
                // system rose out of the middle of its layer instead of falling into the frame
                // from the top; 93 of the library's 493 systems carry a downward Y velocity.
                if avgSpeedX != 0 || avgSpeedY != 0 {
                    let speed = sqrt(avgSpeedX * avgSpeedX + avgSpeedY * avgSpeedY)
                    emitter.particleSpeed = CGFloat(speed)
                    emitter.particleSpeedRange = CGFloat(abs(maxV.1 - minV.1) / 2)
                    emitter.emissionAngle = CGFloat(atan2(avgSpeedY, avgSpeedX))
                    emitter.emissionAngleRange = 0.1
                } else if avgSpeedZ != 0 {
                    // Depth only: `starfield` flies its stars straight at the camera, "0 0 150"
                    // to "0 0 2000" — six systems in two scenes move along Z alone. Seen down the
                    // Z axis that is motion outward in every direction at once, so fold Z into
                    // the speed and spread the angle over the full circle. Only when X and Y are
                    // both zero — where they are not, Z is a depth wobble on a motion the frame
                    // can already show, and adding it would only make that motion faster.
                    //
                    // This is a stand-in, not a reading, and it was left as one on purpose after
                    // looking for a faithful one. Purple Space's preview shows what the author
                    // saw: long streaks radiating from the middle of the *frame* across the whole
                    // of it, not a puff around each emitter. `starfield` sets `flags: 4`, as do
                    // the presets whose names promise depth (`rainperspective`, one of the two
                    // `snowperspective` copies, every `leaves` preset), while `snowflat` writes 0.
                    // Read as Wallpaper Engine's "perspective" switch — an inference from those
                    // names, not a documented bit — the system is drawn through a perspective
                    // camera, and a star's screen position is the frame centre plus its offset
                    // scaled by D/(D − z), which runs away as z nears the camera. Two things stop
                    // that being drawn here. D comes from a field of view Wallpaper Engine does
                    // not write into the scene (the scene's own projection is orthographic,
                    // 3840×1080), so any value would be fitted to a preview rather than read from
                    // the file. And a streak has to point along its own path, which differs per
                    // particle when the paths fan out — an `SKEmitterNode` gives every particle
                    // one rotation plus a random range, so the `spritetrail` branch below can
                    // only orient them all the same way.
                    emitter.particleSpeed = CGFloat(abs(avgSpeedZ))
                    emitter.particleSpeedRange = CGFloat(abs(maxV.2 - minV.2) / 2)
                    emitter.emissionAngleRange = 2 * .pi
                }

            case "turbulentvelocityrandom":
                // Handled after the loop, and only for a system with no `velocityrandom`; see
                // there.
                break

            case "alpharandom":
                let minA = ini.min?.doubleValue ?? 1
                let maxA = ini.max?.doubleValue ?? 1
                emitter.particleAlpha = CGFloat((minA + maxA) / 2)
                emitter.particleAlphaRange = CGFloat(maxA - minA)

            case "colorrandom":
                if let maxColor = ini.max?.vectorValue {
                    // Colors in WE particles are 0-255
                    emitter.particleColor = NSColor(
                        red: maxColor.0 / 255.0,
                        green: maxColor.1 / 255.0,
                        blue: maxColor.2 / 255.0,
                        alpha: 1.0)
                    emitter.particleColorBlendFactor = 1
                }

            default:
                break
            }
        }

        // A system with no `velocityrandom` but a `turbulentvelocityrandom` — embers, bubbles,
        // torch and wildfire flames — was left at SKEmitterNode's default speed of zero, so every
        // particle sat on the spot it was born. 71 of the 493 systems, across 17 scenes, move by
        // turbulence alone.
        // Turbulence is a noise field with no preferred direction, so the nearest thing SpriteKit
        // has is the authored speed in every direction: `speedmin`/`speedmax` as speed and range,
        // and the full circle as the emission angle. Not applied where `velocityrandom` exists:
        // there the turbulence is a wander on top of an authored heading (smoke1 carries both),
        // and replacing the heading with a random one would throw that direction away.
        //
        // Where the speed is written varies. 42 of those 71 put `speedmin`/`speedmax` on the
        // initializer itself (bubbles, torch, wildfire, smoke2, vapor0); the 27 `ember` and
        // `ember_small` copies write none there and carry their speed band on a `turbulence`
        // operator instead ("100"–"150", once "250"–"1000"), so that is the fallback. The two
        // left over are audio-driven stars with no speed anywhere, and stay still.
        //
        // Placed here, before the instance overrides, so `instanceoverride.speed` scales this
        // speed the same way it scales one read from `velocityrandom`.
        if !hasVelocity,
           let turbulence = ps.initializer?.first(where: { $0.name == "turbulentvelocityrandom" }) {
            let field = ps.operator?.first(where: { $0.name == "turbulence" })
            let low = turbulence.speedmin ?? field?.speedmin
            let high = turbulence.speedmax ?? field?.speedmax
            if low != nil || high != nil {
                let lo = low?.doubleValue ?? 0
                let hi = high?.doubleValue ?? lo
                emitter.particleSpeed = CGFloat((lo + hi) / 2)
                emitter.particleSpeedRange = CGFloat(abs(hi - lo))
                emitter.emissionAngleRange = 2 * .pi
            }
        }

        // The instance's own scaling, applied after the initializers rather than inside them.
        //
        // The order is load-bearing in both directions. It has to come after, because a preset
        // that declares no `alpharandom` — smoke1 is one — leaves `particleAlpha` at
        // SKEmitterNode's default of 1, and an override folded into a case that never runs would
        // be dropped exactly where it matters most. And it has to come before the operators and
        // the particle budget below, because `alphafade` reads `particleAlpha` back as the peak
        // of its keyframe sequence, and the budget divides `maxcount` by the lifetime.
        if let alpha = over?.alpha {
            emitter.particleAlpha = min(emitter.particleAlpha * CGFloat(alpha), 1)
            emitter.particleAlphaRange *= CGFloat(alpha)
        }
        if let speed = over?.speed {
            emitter.particleSpeed *= CGFloat(speed)
            emitter.particleSpeedRange *= CGFloat(speed)
        }
        if let lifetime = over?.lifetime {
            emitter.particleLifetime *= CGFloat(lifetime)
            emitter.particleLifetimeRange *= CGFloat(lifetime)
        }
        // `colorn` is normalised, `color` is the same tint written 0–255. Both replace whatever
        // `colorrandom` initialised rather than scaling it: this is the author picking a colour
        // for this copy, which is how Batman's smoke is red and its rain comes in two colours
        // from one preset.
        if let tint = over?.colorn?.parseColor() {
            emitter.particleColor = NSColor(red: tint.r, green: tint.g, blue: tint.b, alpha: 1)
            emitter.particleColorBlendFactor = 1
        } else if let tint = over?.color?.parseColor() {
            emitter.particleColor = NSColor(red: tint.r / 255, green: tint.g / 255,
                                            blue: tint.b / 255, alpha: 1)
            emitter.particleColorBlendFactor = 1
        }
        // `brightness` scales that colour, and only that colour. Nine layers in the library use
        // it. Where no colour is in play the emitter is showing its texture untouched, and the
        // only way to brighten it here would be to switch colourisation on — which replaces the
        // sprite's own shading with a flat tone. Nine layers is not worth flattening a sprite for.
        if let brightness = over?.brightness, emitter.particleColorBlendFactor > 0,
           let lit = emitter.particleColor.usingColorSpace(.deviceRGB) {
            emitter.particleColor = NSColor(red: min(lit.redComponent * brightness, 1),
                                            green: min(lit.greenComponent * brightness, 1),
                                            blue: min(lit.blueComponent * brightness, 1),
                                            alpha: 1)
        }

        // Operators
        for op in ps.operator ?? [] {
            switch op.name {
            case "movement":
                if let gravityStr = op.gravity {
                    let (gx, gy, gz) = gravityStr.parseVector3()
                    // Y-up, like the velocity above and for the same reason — and no longer
                    // flipped. Read Y-down, the splash droplets Toyota Supra throws up at
                    // "±32 75 0" under a gravity of "0 -200 0" were launched downwards and pulled
                    // upwards — the arc of a splash turned upside down, with both flips agreeing
                    // with each other and neither with the file. 61 systems in the library pull
                    // down and 30 pull up.
                    emitter.xAcceleration = CGFloat(gx)
                    emitter.yAcceleration = CGFloat(gy)
                    // Depth-only gravity has no in-plane component to show. Five systems write
                    // one ("0 0 250", a perspective particle preset), and they used to read it as
                    // a downward pull; that reading is kept rather than changed blind, because
                    // none of them is a scene this change could be checked against. Only when X
                    // and Y are both zero, so a real in-plane pull is never overridden by Z.
                    if gx == 0 && gy == 0 && gz != 0 {
                        emitter.yAcceleration = CGFloat(-gz)
                    }
                }

            case "alphafade":
                // `fadeintime` and `fadeouttime` are fractions of the particle's life, not
                // seconds: 0.1 and 0.9 mean "up by a tenth in, down from nine tenths on".
                // SKKeyframeSequence maps normalised life to alpha directly, which is the same
                // shape — far closer than the constant fade rate this used to approximate it
                // with, and it matters because these systems are additive and their sprites are
                // enormous. Held at full opacity, a scene's fog, lightning and stars stack into
                // a white rectangle.
                let fadeIn = CGFloat(op.fadeintime ?? 0)
                let fadeOut = CGFloat(op.fadeouttime ?? 1)
                guard fadeIn > 0 || fadeOut < 1 else { break }
                let peak = emitter.particleAlpha
                let start = max(min(fadeIn, 0.98), 0.01)
                let end = max(min(fadeOut, 0.99), start + 0.01)
                emitter.particleAlphaSequence = SKKeyframeSequence(
                    keyframeValues: [0, peak, peak, 0] as [NSNumber],
                    times: [0, start, end, 1] as [NSNumber])

            case "sizechange":
                // Same shape as `alphafade`, one property over: a ramp between two scale factors
                // across a window of the particle's life. Smoke is the reason it matters — a puff
                // authored to swell from a tenth of its size to full otherwise pops into the
                // frame already enormous.
                //
                // Every field defaults to a no-op, and 4 of the library's 72 uses write nothing
                // but the name, so bail rather than install a sequence that ramps 1 to 1: a scale
                // sequence supersedes `particleScaleRange`, and installing one for nothing would
                // quietly flatten the size variance the preset asked for.
                let from = CGFloat(op.startvalue?.doubleValue ?? 1)
                let to = CGFloat(op.endvalue?.doubleValue ?? 1)
                guard from != to else { break }
                let begins = max(min(CGFloat(op.starttime?.doubleValue ?? 0), 0.98), 0)
                let ends = max(min(CGFloat(op.endtime?.doubleValue ?? 1), 1), begins + 0.01)
                emitter.particleScaleSequence = SKKeyframeSequence(
                    keyframeValues: [from, from, to, to] as [NSNumber],
                    times: [0, begins, ends, 1] as [NSNumber])

            default:
                break
            }
        }

        // Honour the system's particle budget.
        //
        // Wallpaper Engine caps how many particles may be alive at once; SpriteKit has no such
        // control, so the cap has to become a birth rate: at equilibrium a system emitting `r`
        // particles a second with lifetime `l` holds `r × l` of them. Ignoring this is not a
        // subtle error — one rain system asks for 700 a second against a ceiling of 10000, and
        // unbounded it buries the scene. Two wallpapers rendered as a flat white rectangle until
        // this went in, and only became visible at all once their particle JSON started
        // decoding, so the overshoot had been hiding behind a parser bug.
        //
        // `instanceoverride.count` scales that ceiling, and it is the field the budget is most
        // sensitive to: Batman asks for 0.04 of its lightning preset's allowance and 2× of one
        // rain preset's, from the same two lines of JSON. Because the ceiling is `maxcount`
        // divided by the lifetime, an overridden lifetime has to be in place before this runs —
        // it is, above.
        if let maxCount = maxcount ?? ps.maxcount, maxCount > 0, emitter.particleLifetime > 0 {
            let ceiling = CGFloat(maxCount) * CGFloat(over?.count ?? 1) / emitter.particleLifetime
            emitter.particleBirthRate = min(emitter.particleBirthRate, ceiling)
        }

        // Renderer: spritetrail gets elongated aspect ratio
        if let renderer = ps.renderer?.first, renderer.name == "spritetrail" {
            let trailLength = CGFloat(renderer.maxlength ?? 50)
            emitter.particleSize = CGSize(width: 2, height: trailLength)
            // Align particles to movement direction
            emitter.particleRotation = emitter.emissionAngle
        }

        // Placement beyond the emitter's own `origin` offset is deliberately left alone: the
        // emitter hangs off a holder that carries the object's transform, the same as every
        // image layer, so both go through one path and both parallax.

        // Max particles
        emitter.numParticlesToEmit = 0 // infinite

        // Pre-simulate `starttime` seconds, so the wallpaper opens on the system already running
        // rather than on an empty emitter filling up. It is what Wallpaper Engine does with the
        // field, and the systems that set it are exactly the ones that need it: light shafts at
        // 0.2–0.3 particles a second with 8–20 s lifetimes write 10–15, fog writes 2. Without
        // it a light-shaft system emits its first beam seconds after load and takes its whole
        // 8–20 s lifetime to build up to the density its author saw, on every launch and every
        // wallpaper change. Measured with every other layer hidden, the particle light on screen
        // the instant the scene is built went from 0.0% of the frame to 7.3% on The Ark and to
        // 68% on ARK: Survival Evolved, whose rays are scaled 4×2 across the whole picture.
        // 317 of the library's 493 systems, across 63 scenes, set a non-zero `starttime`.
        //
        // Last, after every property above, because the pre-simulation spawns particles with
        // whatever configuration is in place when it runs — called earlier, the first
        // `starttime` seconds of particles would carry the preset's defaults instead of the
        // instance's speed, colour, alpha and budget. Measured in a real `SKView`: an emitter
        // advanced before it joins the tree keeps its particles once presented (a 0.3/s,
        // 14 s system shows 3 after a 10 s pre-simulation and 1 without).
        beforeWarmup(emitter)
        if let warmup = ps.starttime, warmup > 0 {
            emitter.advanceSimulationTime(warmup)
        }

        return emitter
    }

    // MARK: - Asset Loading

    private func loadJSON<T: Decodable>(path: String, wallpaperDir: URL) -> T? {
        // Try PKG first
        if let parser = pkgParser, let data = parser.extractFile(named: path) {
            return try? JSONDecoder().decode(T.self, from: data)
        }
        // Fall back to loose file
        let url = wallpaperDir.appending(path: path)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(T.self, from: data) {
            return decoded
        }
        // Finally the shared WE asset library, which is where util/ and presets/ live
        for candidate in self.sharedAssetURLs(for: path) {
            if let data = try? Data(contentsOf: candidate),
               let decoded = try? JSONDecoder().decode(T.self, from: data) {
                return decoded
            }
        }
        return nil
    }

    /// - Parameter resolved: handed the `TEXParser` the image came from, when it came from a
    ///   `.tex` — how an image layer gets at a sprite sheet's frames without a second lookup.
    private func loadTexture(named name: String, materialDir: String, wallpaperDir: URL,
                             resolved: ((TEXParser) -> Void)? = nil) -> NSImage? {
        // Build candidate base paths (no extension): relative to material dir, then relative
        // to the materials/ root, then bare. Both the .tex and the plain-image lookups below
        // use these, so a name that already carries a subdirectory (e.g. "util/white")
        // resolves the same way in either case.
        let materialDirPath = (materialDir as NSString).deletingLastPathComponent
        var basePaths = [String]()
        if !materialDirPath.isEmpty {
            basePaths.append("\(materialDirPath)/\(name)")
        }
        let materialsRoot = materialDirPath.split(separator: "/").first.map(String.init) ?? "materials"
        let rootBase = "\(materialsRoot)/\(name)"
        if !basePaths.contains(rootBase) {
            basePaths.append(rootBase)
        }
        basePaths.append(name)

        for texPath in basePaths.map({ "\($0).tex" }) {
            // Try .tex from PKG
            if let parser = pkgParser, let texData = parser.extractFile(named: texPath) {
                Self.log("  TEX from PKG '\(texPath)' size=\(texData.count)")
                let texParser = TEXParser(data: Data(texData))  // Copy to reset indices
                if let image = texParser.extractImage() {
                    resolved?(texParser)
                    return image
                }
                Self.log("  TEXParser.extractImage() returned nil for '\(texPath)'")
            }

            // Try .tex from loose file
            let texURL = wallpaperDir.appending(path: texPath)
            if let texData = try? Data(contentsOf: texURL) {
                let texParser = TEXParser(data: texData)
                if let image = texParser.extractImage() {
                    resolved?(texParser)
                    return image
                }
            }

            // Try .tex from the shared WE asset library
            for candidate in self.sharedAssetURLs(for: texPath) {
                if let texData = try? Data(contentsOf: candidate) {
                    let texParser = TEXParser(data: texData)
                    if let image = texParser.extractImage() {
                        resolved?(texParser)
                        return image
                    }
                }
            }
        }

        // Try common image formats directly. WE ships plain .png next to the raw-RGBA .tex
        // for util textures like util/white, which TEXParser cannot decode.
        for base in basePaths {
            for ext in ["png", "jpg", "jpeg", "gif"] {
                let imgPath = "\(base).\(ext)"
                if let parser = pkgParser, let imgData = parser.extractFile(named: imgPath),
                   let image = NSImage(data: imgData) { return image }
                let imgURL = wallpaperDir.appending(path: imgPath)
                if let image = NSImage(contentsOf: imgURL) { return image }
                for candidate in self.sharedAssetURLs(for: imgPath) {
                    if let image = NSImage(contentsOf: candidate) { return image }
                }
            }
        }

        Self.log("  No texture found for '\(name)'")
        return nil
    }

    /// Generate simple procedural textures for built-in particle names
    private func generateProceduralTexture(named name: String) -> NSImage? {
        let size: CGFloat = 32

        switch name {
        case "particle/drop":
            // Elongated raindrop: bright center, soft edges
            return generateRadialGradient(size: CGSize(width: 4, height: 16), color: .white)

        case _ where name.contains("halo"):
            // Soft circular glow
            return generateRadialGradient(size: CGSize(width: size, height: size), color: .white)

        default:
            // Generic soft circle
            return generateRadialGradient(size: CGSize(width: size, height: size), color: .white)
        }
    }

    private func generateRadialGradient(size: CGSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()

        let ctx = NSGraphicsContext.current!.cgContext
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // Convert to RGB color space to guarantee 4 components (r, g, b, a)
        let rgbColor = color.usingColorSpace(.deviceRGB) ?? color
        let r = rgbColor.redComponent
        let g = rgbColor.greenComponent
        let b = rgbColor.blueComponent
        let a = rgbColor.alphaComponent
        let colors = [
            CGColor(colorSpace: colorSpace, components: [r, g, b, a])!,
            CGColor(colorSpace: colorSpace, components: [r, g, b, 0])!
        ] as CFArray
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])

        image.unlockFocus()
        return image
    }

}
