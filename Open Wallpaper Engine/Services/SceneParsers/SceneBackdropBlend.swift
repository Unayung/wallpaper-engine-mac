//
//  SceneBackdropBlend.swift
//  Open Wallpaper Engine
//
//  Wallpaper Engine's framebuffer blend modes, for a layer whose backdrop never changes.
//

import Foundation
import SpriteKit
import Metal

/// The half of `colorBlendMode` that fixed-function blending cannot do — overlay, soft light,
/// lighten, colour dodge, tint and the rest of `shaders/common_blending.h` — done exactly, for
/// the layers where that is possible.
///
/// Wallpaper Engine runs these modes by sampling the frame drawn so far (`_rt_FullFrameBuffer`)
/// under the layer and writing `ApplyBlending(mode, frame, layer, layer.a)` — see the tail of
/// `genericimage2.frag`. A sprite in SpriteKit never sees the frame beneath it. But when
/// everything drawn beneath a layer is static, that frame is a constant: it can be rendered once,
/// at load, and handed to the layer's shader as a texture, and the shader then computes the very
/// formula Wallpaper Engine computes. That is all this does; where the backdrop moves, the layer
/// keeps normal alpha, as before.
///
/// The result is not written opaque. Wallpaper Engine's output is `mix(A, F(A, B), opacity)`;
/// this emits `F` premultiplied by the layer's opacity and lets SpriteKit's ordinary
/// source-over supply the `A * (1 - opacity)` term from the *real* framebuffer. Where the layer is
/// transparent nothing at all is written, so the snapshot only ever matters under the layer's
/// own pixels — and the snapshot's resolution (the scene's, not the display's) only softens the
/// blend inside the artwork, never the backdrop around it.
enum SceneBackdropBlend {
    /// Whether `mode` is one this path handles: a real mode that `blendMode(forColorBlendMode:)`
    /// has no `SKBlendMode` for. 0 and absent are normal alpha and need nothing.
    static func needsBackdrop(_ mode: Int?) -> Bool {
        guard let mode, mode != 0 else { return false }
        return formula(mode) != nil
            && SceneWallpaperViewModel.blendMode(forColorBlendMode: mode) == nil
    }

    /// `F(A, B)` for one mode, as GLSL over `vec3 A` (backdrop) and `vec3 B` (layer), transcribed
    /// from `common_blending.h`. Per-channel modes go through a helper taking floats, so the
    /// ternaries stay scalar as they are there. Nil for a number the header does not define.
    ///
    /// Modes 5 and 10 (`min`, `max`) and 31 are the three the header does *not* mix by opacity;
    /// 31 has a native mapping and never gets here, and 5 and 10 are mixed here like the rest,
    /// which is what the header's output would look like at full opacity and the only reading
    /// under which a half-transparent pixel does not paint its rectangle. No layer in this
    /// library uses either.
    private static func formula(_ mode: Int) -> (helpers: String, expr: String)? {
        func perChannel(_ name: String, _ body: String) -> (String, String) {
            ("float \(name)(float base, float blend) { return \(body); }\n",
             "vec3(\(name)(A.r, B.r), \(name)(A.g, B.g), \(name)(A.b, B.b))")
        }
        let dodge = "((blend == 1.0) ? blend : min(base / (1.0 - blend), 1.0))"
        let burn = "((blend == 0.0) ? blend : max((1.0 - ((1.0 - base) / blend)), 0.0))"
        switch mode {
        case 1: return ("", "min(B, A)")
        case 2: return ("", "A * B")
        case 3: return perChannel("we_burn", burn)
        case 4, 20: return ("", "max(A + B - vec3(1.0), vec3(0.0))")
        case 5: return ("", "min(A, B)")
        case 6: return ("", "max(B, A)")
        case 7: return ("", "vec3(1.0) - (vec3(1.0) - A) * (vec3(1.0) - B)")
        case 8: return perChannel("we_dodge", dodge)
        case 9: return ("", "min(A + B, vec3(1.0))")
        case 10: return ("", "max(A, B)")
        case 11:
            return perChannel("we_overlay",
                              "(base < 0.5 ? (2.0 * base * blend) : (1.0 - 2.0 * (1.0 - base) * (1.0 - blend)))")
        case 12:
            return perChannel("we_softlight",
                              "((blend < 0.5) ? (2.0 * base * blend + base * base * (1.0 - 2.0 * blend))"
                              + " : (sqrt(base) * (2.0 * blend - 1.0) + 2.0 * base * (1.0 - blend)))")
        case 13:
            // BlendHardLight(base, blend) is BlendOverlay(blend, base).
            return perChannel("we_hardlight",
                              "(blend < 0.5 ? (2.0 * blend * base) : (1.0 - 2.0 * (1.0 - blend) * (1.0 - base)))")
        case 14:
            return ("float we_burn(float base, float blend) { return \(burn); }\n"
                    + "float we_dodge(float base, float blend) { return \(dodge); }\n"
                    + "float we_vivid(float base, float blend) { return (blend < 0.5) ? "
                    + "we_burn(base, 2.0 * blend) : we_dodge(base, 2.0 * (blend - 0.5)); }\n",
                    "vec3(we_vivid(A.r, B.r), we_vivid(A.g, B.g), we_vivid(A.b, B.b))")
        case 15:
            return perChannel("we_linearlight",
                              "(blend < 0.5 ? max(base + 2.0 * blend - 1.0, 0.0) : (base + 2.0 * (blend - 0.5)))")
        case 16:
            return perChannel("we_pinlight",
                              "((blend < 0.5) ? min(2.0 * blend, base) : max(2.0 * (blend - 0.5), base))")
        case 17:
            return ("float we_burn(float base, float blend) { return \(burn); }\n"
                    + "float we_dodge(float base, float blend) { return \(dodge); }\n"
                    + "float we_hardmix(float base, float blend) { float v = (blend < 0.5) ? "
                    + "we_burn(base, 2.0 * blend) : we_dodge(base, 2.0 * (blend - 0.5)); "
                    + "return v < 0.5 ? 0.0 : 1.0; }\n",
                    "vec3(we_hardmix(A.r, B.r), we_hardmix(A.g, B.g), we_hardmix(A.b, B.b))")
        case 18: return ("", "abs(A - B)")
        case 19: return ("", "A + B - 2.0 * A * B")
        case 21:
            return perChannel("we_reflect", "((blend == 1.0) ? blend : min(base * base / (1.0 - blend), 1.0))")
        case 22:
            // BlendGlow(base, blend) is BlendReflect(blend, base).
            return perChannel("we_glow", "((base == 1.0) ? base : min(blend * blend / (1.0 - base), 1.0))")
        case 23: return ("", "min(A, B) - max(A, B) + vec3(1.0)")
        case 24: return ("", "(A + B) / 2.0")
        case 25: return ("", "vec3(1.0) - abs(vec3(1.0) - A - B)")
        case 30: return ("", "vec3(max(A.x, max(A.y, A.z))) * B")
        case 32: return ("", "A + A * B")
        // 26–29 (hue, saturation, colour, luminosity) go through the header's HSL conversion.
        // Not transcribed: no layer in this library uses them, and an untested 60-line port is
        // the kind of approximation this path exists not to ship.
        default: return nil
        }
    }

    /// The fragment shader for one mode.
    ///
    /// `u_map` carries the affine map from the sprite's own texture space to the backdrop's: the
    /// backdrop UV at `v_tex_coord` (0, 0), and the steps along its two axes. It is an affine map
    /// rather than a rectangle so a rotated or mirrored layer samples the right texel too.
    ///
    /// `SKDefaultShading()` is the texel as SpriteKit would draw it: premultiplied, and carrying
    /// the node's `alpha` — see `tintShaderSource` for why sampling `u_texture` by hand drops
    /// that. Wallpaper Engine's layer colour is straight (`texel * g_Color4`), so it is
    /// un-premultiplied before the tint multiplies it, which is the order `genericimage2.frag`
    /// applies them in. No `uniform` declarations: `SKShader` emits them from `uniforms`.
    static func shaderSource(mode: Int) -> String? {
        guard let (helpers, expr) = formula(mode) else { return nil }
        return helpers + """
        void main() {
            vec4 texel = SKDefaultShading();
            float opacity = texel.a;
            vec3 B = (opacity > 0.0 ? texel.rgb / opacity : vec3(0.0)) * u_tint;
            vec2 uv = u_map0 + v_tex_coord.x * u_mapU + v_tex_coord.y * u_mapV;
            vec3 A = texture2D(u_backdrop, uv).rgb;
            vec3 F = clamp(\(expr), 0.0, 1.0);
            gl_FragColor = vec4(F * opacity, opacity);
        }
        """
    }

    /// The shader for one layer. Each blended layer gets its own: the backdrop and the map are
    /// the layer's alone, and an `SKShader`'s uniforms are shared by every node that uses it.
    static func shader(mode: Int, tint: SIMD3<Float>, backdrop: SKTexture,
                       map0: SIMD2<Float>, mapU: SIMD2<Float>, mapV: SIMD2<Float>) -> SKShader? {
        guard let source = shaderSource(mode: mode) else { return nil }
        let shader = SKShader(source: source)
        shader.uniforms = [
            SKUniform(name: "u_backdrop", texture: backdrop),
            SKUniform(name: "u_tint", vectorFloat3: tint),
            SKUniform(name: "u_map0", vectorFloat2: map0),
            SKUniform(name: "u_mapU", vectorFloat2: mapU),
            SKUniform(name: "u_mapV", vectorFloat2: mapV),
        ]
        return shader
    }

    // MARK: - Offline snapshot

    private static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()

    /// Render `scene` as it stands — whatever is hidden stays hidden — and return the pixels inside
    /// `crop`, a rectangle in scene coordinates, as a texture — with the rectangle it actually
    /// covers, which is `crop` rounded out to whole pixels and clipped to the scene.
    ///
    /// `SKRenderer` rather than `SKView.texture(from:)`: the build runs on a background queue and
    /// an `SKView` is an `NSView`. The render pass is cleared to the scene's background colour,
    /// because `SKRenderer` does not paint it and `SKView` does (see `Tools/README.md`), and
    /// `update(atTime:)` is never called: that would run the scene's scripts and start its
    /// evaluator's clock from a load-time instant, and a static backdrop needs neither.
    ///
    /// The pixels are handed to `SKTexture(data:size:)` as raw bytes, not through a `CGImage`, so
    /// nothing colour-manages them on the way back in: the shader must read exactly the numbers
    /// SpriteKit wrote, or the blend is computed against a backdrop that is not the frame.
    static func snapshot(_ scene: SKScene, crop: CGRect) -> (SKTexture, CGRect)? {
        guard let device, let queue else { return nil }
        let width = Int(scene.size.width.rounded()), height = Int(scene.size.height.rounded())
        let x0 = max(0, Int(crop.minX.rounded(.down))), x1 = min(width, Int(crop.maxX.rounded(.up)))
        let y0 = max(0, Int(crop.minY.rounded(.down))), y1 = min(height, Int(crop.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }

        // Rendered into a private texture and copied out through a shared buffer: a shared
        // *texture* is Apple-silicon-only, and managed storage is deprecated there.
        let w = x1 - x0, h = y1 - y0
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let target = device.makeTexture(descriptor: desc),
              let readback = device.makeBuffer(length: w * h * 4, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer() else { return nil }

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (scene.backgroundColor.usingColorSpace(.deviceRGB) ?? scene.backgroundColor)
            .getRed(&r, green: &g, blue: &b, alpha: &a)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(Double(r), Double(g), Double(b), 1)
        pass.colorAttachments[0].storeAction = .store

        let renderer = SKRenderer(device: device)
        renderer.scene = scene
        // As `SceneWallpaperView` sets it on the `SKView`: painter's order is zPosition alone.
        renderer.ignoresSiblingOrder = true
        renderer.render(withViewport: CGRect(x: 0, y: 0, width: width, height: height),
                        commandBuffer: cmd, renderPassDescriptor: pass)
        // Metal's rows run top-down and the scene's y runs up, so the crop's top edge in the
        // texture is `height - y1`.
        guard let blit = cmd.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: x0, y: height - y1, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: readback, destinationOffset: 0,
                  destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        renderer.scene = nil

        let bytes = readback.contents().bindMemory(to: UInt8.self, capacity: w * h * 4)
        // BGRA → RGBA, and bottom row first: `SKTexture(data:size:)` reads its first row as the
        // texture's bottom edge (v = 0).
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            let src = (h - 1 - row) * w * 4, dst = row * w * 4
            for i in stride(from: 0, to: w * 4, by: 4) {
                rgba[dst + i] = bytes[src + i + 2]
                rgba[dst + i + 1] = bytes[src + i + 1]
                rgba[dst + i + 2] = bytes[src + i]
                rgba[dst + i + 3] = 255
            }
        }
        let texture = SKTexture(data: Data(rgba), size: CGSize(width: w, height: h))
        texture.filteringMode = .linear
        return (texture, CGRect(x: x0, y: y0, width: w, height: h))
    }
}
