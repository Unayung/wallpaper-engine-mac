//
//  WallpaperSKScene.swift
//  Open Wallpaper Engine
//
//  The SpriteKit half of the scene pipeline: drives the evaluator and writes what it returns
//  onto the node tree. Everything it knows about a layer arrives as a `ResolvedLayer`.
//

import Cocoa
import SpriteKit

final class WallpaperSKScene: SKScene {
    /// Node carrying a layer's transform. See the holder/artwork split in
    /// `SceneWallpaperViewModel.buildSKScene` for why alpha does not live here.
    private var holders: [SKNode] = []
    /// The drawable hanging off each holder, if the layer has one. Alpha goes here.
    private var artwork: [SKNode?] = []
    private var evaluator: SceneEvaluator?

    /// Playback time, accumulated rather than read off the clock so that pausing the wallpaper —
    /// which stops `update` being called at all — resumes where it left off instead of jumping
    /// forward by however long the display was asleep.
    private var elapsed: TimeInterval = 0
    private var lastUpdate: TimeInterval?

    /// Cursor position for parallax, normalised to [-1, 1] about the wallpaper's centre.
    /// The offline render harness sets this because it has no window and therefore no cursor.
    var pointerOverride: CGPoint?

    /// A text layer a script can redraw — by returning a string from its own text script, or by
    /// writing `text` on the layer's handle from any script at all.
    struct TextLayer {
        let node: SKSpriteNode
        let style: SceneTextLayer.Style
        /// What the layer is currently showing, so an unchanged string costs no raster.
        var shown: String
        /// Called after a new string has resized the sprite. Set on a layer blended against a
        /// static backdrop, whose shader maps the sprite's corners onto that backdrop and has to
        /// follow them — see `SceneWallpaperViewModel.blendAgainstStaticBackdrops`.
        var resized: ((SKSpriteNode) -> Void)? = nil
    }

    /// A text layer whose string comes from its own script.
    struct ScriptedText {
        let handle: Int
        /// Index into the `texts` handed to `bind(scripts:…)`.
        let text: Int
    }

    private var scripts: SceneScriptRuntime?
    private var texts: [TextLayer] = []
    private var textById: [Int: Int] = [:]
    private var scriptedText: [ScriptedText] = []
    private var lastScriptTick: TimeInterval?
    /// Layer index by scene object id, for writes made through a layer handle.
    private var indexById: [Int: Int] = [:]
    /// Each layer's built effect passes by effect name, for `getEffect(name).visible`.
    private var effectNodes: [Int: [String: [SKEffectNode]]] = [:]

    /// Scripts are polled rather than run per frame. The overwhelming majority are clocks, whose
    /// output changes at most once a second; the raster behind a changed string costs far more
    /// than the call that produced it, and a wallpaper runs all day.
    private static let scriptInterval: TimeInterval = 0.1

    /// An image layer playing a sprite sheet: its frames in order, and how long each shows.
    struct SpriteAnimation {
        let node: SKSpriteNode
        let textures: [SKTexture]
        let durations: [TimeInterval]
    }
    private var spriteAnimations: [SpriteAnimation] = []
    /// Where each animation is: the frame showing, and how long it has shown.
    private var spriteCursors: [(frame: Int, shown: TimeInterval)] = []
    private var lastSpriteUpdate: TimeInterval?

    /// A layer moved by one of the script shapes upstream's 0.9.0 recognises and reproduces
    /// natively — see `MobBehavior.swift`, `MotionItemBehavior.swift` and
    /// `ScriptedOriginMotionBehavior.swift`. These are the moving scripts the sandboxed runtime
    /// here does not run live (it evaluates an origin script only when the result is a constant;
    /// see `SceneScriptRuntime.staticOrigin`), so the two do not overlap.
    ///
    /// They write the layer's holder, in its parent's space. Wallpaper Engine's scene space is
    /// already SpriteKit's — y up, the authored `origin` is the holder's position as it stands —
    /// so the controllers' numbers go straight onto the node, as they did in upstream's scene.
    struct ScriptedMotion {
        enum Driver {
            /// A MapleStory mob: walks between bounds, faces its direction, and picks its own
            /// sprite-sheet frame, so the layer's sheet does not also play on the clock.
            case mob(MobController, artwork: SKSpriteNode, textures: [SKTexture], baseXScale: CGFloat)
            case item(MotionItemController)
            case origin(ScriptedOriginMotionController)
        }
        let holder: SKNode
        let driver: Driver
    }
    private var scriptedMotions: [ScriptedMotion] = []
    private var lastMotionUpdate: TimeInterval?

    func bind(scriptedMotions: [ScriptedMotion]) {
        self.scriptedMotions = scriptedMotions
        for motion in scriptedMotions { apply(motion, dt: 0) }
    }

    func bind(spriteAnimations: [SpriteAnimation]) {
        self.spriteAnimations = spriteAnimations.filter {
            $0.textures.count > 1 && $0.textures.count == $0.durations.count
        }
        spriteCursors = Array(repeating: (0, 0), count: self.spriteAnimations.count)
    }

    func bind(evaluator: SceneEvaluator, holders: [SKNode], artwork: [SKNode?], ids: [Int?] = []) {
        self.evaluator = evaluator
        self.holders = holders
        self.artwork = artwork
        indexById = [:]
        for (index, id) in ids.enumerated() {
            if let id, indexById[id] == nil { indexById[id] = index }
        }
    }

    /// - Parameters:
    ///   - texts: every text layer built, by object id where it has one.
    ///   - effects: each layer's effect passes by effect name.
    func bind(scripts: SceneScriptRuntime?, texts: [(id: Int?, layer: TextLayer)],
              scripted: [ScriptedText], effects: [Int: [String: [SKEffectNode]]] = [:]) {
        self.scripts = scripts
        self.texts = texts.map(\.layer)
        textById = [:]
        for (index, entry) in texts.enumerated() {
            if let id = entry.id, textById[id] == nil { textById[id] = index }
        }
        self.scriptedText = scripted
        self.effectNodes = effects
        // `init` runs once, before the first `update`, and what it returns is what the layer
        // starts from — the value `update` is then handed.
        guard let scripts else { return }
        for layer in scriptedText {
            if let initial = scripts.initialText(layer.handle, value: self.texts[layer.text].shown) {
                show(initial, at: layer.text)
            }
        }
        // What the live property scripts settled on before the build, and whatever the text
        // inits wrote through a handle — all of it before the first frame is drawn.
        apply(scripts.drainWrites())
    }

    override func update(_ currentTime: TimeInterval) {
        // Ahead of the static short-circuit below: a scene can be motionless in every way the
        // evaluator understands and still carry a clock, which is most of the wallpapers that
        // have one.
        tickScripts(currentTime)
        // Also ahead of it, for the same reason: a sheet plays on a layer that does not move.
        tickSprites(currentTime)

        // After the evaluator, so a scripted mover's position wins over the authored one the
        // evaluator writes, and outside its static short-circuit, because the layers these move
        // are otherwise still.
        defer { tickMotion(currentTime) }

        guard let evaluator, !evaluator.isStatic else { return }

        // A large step means the wallpaper was paused, the display slept, or the machine was
        // busy; clamping it keeps a loop from jumping a whole cycle on the frame after.
        let dt = min(max(currentTime - (lastUpdate ?? currentTime), 0), 1.0 / 15.0)
        lastUpdate = currentTime
        elapsed += dt

        let resolved = evaluator.evaluate(elapsed: elapsed, pointer: pointer(), dt: dt)
        for (index, layer) in resolved.enumerated() where index < holders.count {
            let holder = holders[index]
            holder.position = layer.position
            holder.xScale = layer.scale.dx
            holder.yScale = layer.scale.dy
            holder.zRotation = layer.rotation
            // Only written when it actually moves. An assignment marks the node dirty, and a
            // dirty node inside a rasterized SKEffectNode throws away the cached pass that
            // `effectChain` set up precisely because nothing about the layer changes.
            if let art = artwork[index], art.alpha != layer.alpha { art.alpha = layer.alpha }
        }
    }

    private func tickMotion(_ currentTime: TimeInterval) {
        guard !scriptedMotions.isEmpty else { return }
        let dt = min(max(currentTime - (lastMotionUpdate ?? currentTime), 0), 1.0 / 15.0)
        lastMotionUpdate = currentTime
        guard dt > 0 else { return }
        for motion in scriptedMotions { apply(motion, dt: dt) }
    }

    /// Advance one mover by `dt` (0 only places it) and write the result onto its nodes.
    private func apply(_ motion: ScriptedMotion, dt: TimeInterval) {
        switch motion.driver {
        case let .mob(controller, artwork, textures, baseXScale):
            let state = dt > 0 ? controller.update(deltaTime: dt) : controller.state
            motion.holder.position.x = state.x
            // Facing is a mirror of the artwork, not of the holder, so children keep their side.
            artwork.xScale = abs(baseXScale) * (state.direction < 0 ? -1 : 1)
            if !textures.isEmpty {
                let frame = textures[min(max(state.frame, 0), textures.count - 1)]
                if artwork.texture !== frame { artwork.texture = frame }
            }
        case let .item(controller):
            let p = dt > 0 ? controller.update(deltaTime: dt) : controller.position
            motion.holder.position = CGPoint(x: p.x, y: p.y)
        case let .origin(controller):
            let p = dt > 0 ? controller.update(deltaTime: dt) : controller.position
            motion.holder.position = CGPoint(x: p.x, y: p.y)
        }
    }

    /// Step every playing sprite sheet by the time since the last frame.
    ///
    /// Clamped like the evaluator's step, so a wallpaper resumed after an hour carries on from
    /// where it stopped rather than racing through the backlog. A frame time can be shorter than
    /// a display frame (a 60 fps sheet on a 30 fps setting), so more than one frame may pass per
    /// tick. The texture is only assigned when the frame actually changes: like an alpha write,
    /// it throws away the cached pass of any effect chain wrapping the layer.
    private func tickSprites(_ currentTime: TimeInterval) {
        guard !spriteAnimations.isEmpty else { return }
        let dt = min(max(currentTime - (lastSpriteUpdate ?? currentTime), 0), 1.0 / 15.0)
        lastSpriteUpdate = currentTime
        for index in spriteAnimations.indices {
            let animation = spriteAnimations[index]
            var cursor = spriteCursors[index]
            cursor.shown += dt
            let before = cursor.frame
            while cursor.shown >= animation.durations[cursor.frame] {
                cursor.shown -= animation.durations[cursor.frame]
                cursor.frame = (cursor.frame + 1) % animation.textures.count
            }
            spriteCursors[index] = cursor
            if cursor.frame != before { animation.node.texture = animation.textures[cursor.frame] }
        }
    }

    /// Re-run the scripted strings, and redraw only the layers whose text actually changed.
    private func tickScripts(_ currentTime: TimeInterval) {
        guard let scripts, !scriptedText.isEmpty || scripts.hasLiveProperties else { return }
        let elapsed = lastScriptTick.map { currentTime - $0 } ?? Self.scriptInterval
        if lastScriptTick != nil, elapsed < Self.scriptInterval { return }
        lastScriptTick = currentTime

        // One budget across both, because this is the main thread: see `SceneScriptRuntime.tick`.
        // Only the script calls themselves are charged, not the rasters `show` pays for.
        scripts.tick {
            scripts.tickProperties(elapsed: elapsed)
            for layer in scriptedText {
                guard let produced = scripts.update(layer.handle, value: texts[layer.text].shown) else {
                    continue
                }
                show(produced, at: layer.text)
            }
        }
        apply(scripts.drainWrites())
    }

    /// Honour what scripts wrote onto layers through their handles, as far as the built scene
    /// can: a layer that was never built — hidden at load, or nothing to draw — has no node to
    /// show, and an effect the build declined has no pass to switch.
    private func apply(_ writes: [(layer: Int, write: SceneScriptRuntime.Write)]) {
        for (id, write) in writes {
            let index = indexById[id]
            switch write {
            case .text(let string):
                if let text = textById[id] { show(string, at: text) }
            case .visible(let visible):
                if let index { holders[index].isHidden = !visible }
            case .alpha(let value):
                guard let index, let art = artwork[index] else { continue }
                let alpha = CGFloat(min(max(value, 0), 1))
                evaluator?.rebase(index, alpha: alpha)
                if art.alpha != alpha { art.alpha = alpha }
            case .origin(let point):
                guard let index else { continue }
                evaluator?.rebase(index, position: point)
                holders[index].position = point
            case .scale(let scale):
                guard let index else { continue }
                evaluator?.rebase(index, scale: scale)
                holders[index].xScale = scale.dx
                holders[index].yScale = scale.dy
            case .effect(let name, let visible):
                for pass in effectNodes[id]?[name] ?? [] { pass.shouldEnableEffects = visible }
            }
        }
    }

    /// Put a script's string on its layer. An empty string hides the layer rather than being
    /// ignored: it used to be dropped as "nothing to draw", which left every "now playing"
    /// readout showing the placeholder its author typed in the editor — "Song Title",
    /// "Artist Name", Pixels' "audio" / "artist" — where Wallpaper Engine, with nothing playing,
    /// shows nothing.
    private func show(_ produced: String, at index: Int) {
        let layer = texts[index]
        guard produced != layer.shown else { return }
        if produced.isEmpty {
            layer.node.isHidden = true
            texts[index].shown = produced
            return
        }
        guard let (image, size) = SceneTextLayer.image(produced, style: layer.style) else { return }
        layer.node.texture = SKTexture(image: image)
        layer.node.size = size
        layer.resized?(layer.node)
        layer.node.isHidden = false
        texts[index].shown = produced
    }

    /// Where the cursor is, relative to the centre of the display this wallpaper is on.
    ///
    /// Read by polling rather than through an event monitor on purpose: wallpaper windows set
    /// `ignoresMouseEvents`, and the global monitor `AppDelegate` already runs for web wallpapers
    /// is deliberately kept to a narrow event mask. `NSEvent.mouseLocation` is a plain read of
    /// the current position, so sampling it once per frame costs nothing and adds no events.
    private func pointer() -> CGPoint {
        if let pointerOverride { return pointerOverride }
        guard let frame = view?.window?.screen?.frame ?? NSScreen.main?.frame,
              frame.width > 0, frame.height > 0 else { return .zero }
        let location = NSEvent.mouseLocation
        return CGPoint(
            x: min(max((location.x - frame.midX) / (frame.width / 2), -1), 1),
            y: min(max((location.y - frame.midY) / (frame.height / 2), -1), 1)
        )
    }
}
