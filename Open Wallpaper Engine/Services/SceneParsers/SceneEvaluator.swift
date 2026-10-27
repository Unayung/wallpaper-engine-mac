//
//  SceneEvaluator.swift
//  Open Wallpaper Engine
//
//  Turns a scene's layers plus an instant in time into flat placement data.
//

import Foundation
import CoreGraphics

/// Where a layer sits at one instant.
///
/// Deliberately carries no textures, no nodes and no scene semantics: the rasteriser consumes
/// this and nothing else, so replacing SpriteKit with a Metal compositor does not touch how any
/// of these numbers were arrived at.
struct ResolvedLayer {
    var position: CGPoint
    var scale: CGVector
    var rotation: CGFloat
    var alpha: CGFloat
}

/// The static half of a layer: its authored placement, its parallax depth, and the tracks that
/// animate any of it. Built once when the scene loads.
struct SceneLayerBinding {
    var position: CGPoint = .zero
    var scale: CGVector = CGVector(dx: 1, dy: 1)
    var rotation: CGFloat = 0
    var alpha: CGFloat = 1
    /// How far this layer travels against the camera, per axis. Wallpaper Engine writes
    /// `1.0 1.0` on most image objects by default, so a non-zero depth is not on its own a sign
    /// the author wanted parallax — the scene's `cameraparallax` flag is what decides that.
    var parallaxDepth: CGVector = .zero

    var originTrack: WEAnimationTrack?
    var scaleTrack: WEAnimationTrack?
    var anglesTrack: WEAnimationTrack?
    var alphaTrack: WEAnimationTrack?

    var isAnimated: Bool {
        originTrack != nil || scaleTrack != nil || anglesTrack != nil || alphaTrack != nil
    }

    var hasParallax: Bool {
        abs(parallaxDepth.dx) > 1e-4 || abs(parallaxDepth.dy) > 1e-4
    }

    /// Read a layer's placement out of its scene object.
    ///
    /// `angles` is (pitch, yaw, roll) in radians and only roll turns a flat layer. A zero scale
    /// component is treated as "not authored" rather than "collapse the layer", which is how the
    /// wallpapers that leave it at zero expect to be read.
    init(object obj: WESceneObject) {
        if let originStr = obj.origin {
            let (x, y, _) = originStr.parseVector3()
            position = CGPoint(x: x, y: y)
        }
        if let scaleStr = obj.scale {
            let (sx, sy, _) = scaleStr.parseVector3()
            if sx != 0 { scale.dx = CGFloat(sx) }
            if sy != 0 { scale.dy = CGFloat(sy) }
        }
        if let anglesStr = obj.angles {
            let (_, _, roll) = anglesStr.parseVector3()
            rotation = CGFloat(roll)
        }
        alpha = CGFloat(obj.alpha ?? 1.0)
        if let depthStr = obj.parallaxDepth {
            let (dx, dy) = depthStr.parseVector2()
            parallaxDepth = CGVector(dx: dx, dy: dy)
        }

        originTrack = obj.originTrack
        scaleTrack = obj.scaleTrack
        anglesTrack = obj.anglesTrack
        alphaTrack = obj.alphaTrack
    }
}

/// Evaluates a whole scene's layers at a point in time. Renderer-agnostic and self-contained
/// apart from the smoothed camera position, which is genuinely stateful across frames.
final class SceneEvaluator {
    struct ParallaxSettings {
        var enabled = false
        var amount = 0.0
        /// Seconds the camera takes to catch up with the cursor.
        var delay = 0.0
        var mouseInfluence = 0.0

        init() {}

        init(general: WESceneGeneral) {
            enabled = general.cameraparallax ?? false
            amount = general.cameraparallaxamount ?? 0
            delay = general.cameraparallaxdelay ?? 0
            mouseInfluence = general.cameraparallaxmouseinfluence ?? 0
        }
    }

    /// How far the camera travels, as a fraction of the projection, at full cursor deflection
    /// and `cameraparallaxamount` of 1.
    ///
    /// Nothing in the format states the camera's travel in scene units, and there is no
    /// reference renderer here to match against, so this constant was chosen by eye: with the
    /// library's typical `cameraparallaxamount` of 0.5 and the default depth of 1, a layer
    /// slides 2.5% of the frame from edge to edge. What carries the effect is the *ratio*
    /// between layer depths, which the scene data does state exactly.
    private static let cameraTravel = 0.05

    private var layers: [SceneLayerBinding]
    private let parallax: ParallaxSettings
    private let projection: CGSize

    /// Smoothed cursor displacement in normalised [-1, 1] units. `cameraparallaxdelay` is a time
    /// constant, so the camera lags the cursor rather than snapping to it.
    private var displacement = CGPoint.zero

    /// True when no layer moves, ever. The rasteriser skips its per-frame work entirely for
    /// these, which is most of the library.
    let isStatic: Bool

    init(layers: [SceneLayerBinding], general: WESceneGeneral, projection: CGSize) {
        self.layers = layers
        self.projection = projection

        let settings = ParallaxSettings(general: general)
        let parallaxApplies = settings.enabled
            && abs(settings.amount) > 1e-6
            && abs(settings.mouseInfluence) > 1e-6
            && layers.contains(where: \.hasParallax)
        self.parallax = parallaxApplies ? settings : ParallaxSettings()

        self.isStatic = !parallaxApplies && !layers.contains(where: \.isAnimated)
    }

    /// Move a layer's authored placement, for a script that drives it. What a keyframe track or
    /// parallax does to the layer is still applied on top, as it is to the authored value.
    func rebase(_ index: Int, position: CGPoint? = nil, scale: CGVector? = nil, alpha: CGFloat? = nil) {
        guard layers.indices.contains(index) else { return }
        if let position { layers[index].position = position }
        if let scale { layers[index].scale = scale }
        if let alpha { layers[index].alpha = alpha }
    }

    /// Placements for every layer, in the order they were handed to `init`.
    ///
    /// - Parameters:
    ///   - elapsed: seconds of playback since the wallpaper loaded, excluding paused time.
    ///   - pointer: cursor position relative to the wallpaper's centre, normalised to [-1, 1].
    ///   - dt: seconds since the previous call, for the camera's smoothing.
    func evaluate(elapsed: TimeInterval, pointer: CGPoint, dt: TimeInterval) -> [ResolvedLayer] {
        advanceCamera(towards: pointer, dt: dt)
        let travelX = displacement.x * parallax.amount * Self.cameraTravel * projection.width
        let travelY = displacement.y * parallax.amount * Self.cameraTravel * projection.height

        return layers.map { layer in
            var out = ResolvedLayer(position: layer.position, scale: layer.scale,
                                    rotation: layer.rotation, alpha: layer.alpha)

            if let track = layer.originTrack {
                let (x, y, _) = track.vector(atSeconds: elapsed,
                                             base: (layer.position.x, layer.position.y, 0))
                out.position = CGPoint(x: x, y: y)
            }
            if let track = layer.scaleTrack {
                let (sx, sy, _) = track.vector(atSeconds: elapsed,
                                               base: (layer.scale.dx, layer.scale.dy, 0))
                out.scale = CGVector(dx: sx, dy: sy)
            }
            if let track = layer.anglesTrack {
                let (_, _, roll) = track.vector(atSeconds: elapsed,
                                                base: (0, 0, layer.rotation))
                out.rotation = CGFloat(roll)
            }
            if let track = layer.alphaTrack {
                // Clamped because a Hermite segment overshoots its endpoints whenever the
                // authored handles are steep, and a fade to full opacity routinely lands a few
                // percent above 1. Opacity has no meaning outside [0, 1]; position and scale do,
                // so only this one is bounded.
                let a = track.scalar(atSeconds: elapsed, base: layer.alpha)
                out.alpha = CGFloat(min(max(a, 0), 1))
            }

            // Parallax displaces the layer wherever its animation left it, so it is applied last.
            // The sign is negative because moving the cursor right pans the camera right, which
            // slides the content left.
            out.position.x -= travelX * layer.parallaxDepth.dx
            out.position.y -= travelY * layer.parallaxDepth.dy
            return out
        }
    }

    private func advanceCamera(towards pointer: CGPoint, dt: TimeInterval) {
        guard parallax.enabled else { return }
        let target = CGPoint(x: pointer.x * parallax.mouseInfluence,
                             y: pointer.y * parallax.mouseInfluence)
        // An exponential approach reaches ~63% of the remaining distance in one `delay`, which is
        // the lag Wallpaper Engine's own delay setting describes. A delay at or below the frame
        // interval just snaps.
        let k = parallax.delay > 1e-4 ? 1 - exp(-dt / parallax.delay) : 1
        displacement.x += (target.x - displacement.x) * k
        displacement.y += (target.y - displacement.y) * k
    }
}
