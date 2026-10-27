//
//  SceneEffectBuilder.swift
//  Open Wallpaper Engine
//
//  Turns a layer's `effects` array into a chain of SpriteKit shaders.
//
//  Wallpaper Engine's effects are local to their layer, not post-processing over the composed
//  frame: 1682 of the 1764 effect passes in this library bind no texture beyond the layer they
//  are applied to. That is what makes a SpriteKit chain viable at all — nesting one
//  `SKEffectNode` per pass reproduces the structure without a render graph, render targets or a
//  second rasteriser.
//
//  Every stage fails safe. A shader that will not resolve, preprocess, translate or bind is
//  dropped and the layer draws exactly as it did before effects existed, so a wallpaper can
//  never be made worse by a pass this renderer does not understand.
//

import Cocoa
import SpriteKit

struct SceneEffectBuilder {
    /// Reads an asset. `bundle` is the effect's own directory, tried first, because an effect
    /// bundle's `materials/` and `shaders/` are relative to itself rather than to the wallpaper.
    let read: (_ path: String, _ bundle: String?) -> Data?
    let readTexture: (_ path: String, _ bundle: String?) -> NSImage?
    /// Settings → Reflections. Off drops every effect that runs Wallpaper Engine's `reflection`
    /// shader as if its author had switched it off: it is not counted in the tally, so the
    /// verification report shows exactly those passes gone (3 in the installed library: 1990
    /// Miata, BMW, Lonely Cat) and nothing reported as untranslatable that was not. It is the one
    /// effect with its own control because Wallpaper Engine's own settings give it one, and
    /// because it is a whole extra offscreen pass over a usually full-width layer.
    var reflections = true

    /// What happened, for the log and for the verification harness.
    struct Tally {
        var effects = 0
        var passes = 0
        var built = 0
        var unresolved = 0
        var untranslatable = 0

        static func + (a: Tally, b: Tally) -> Tally {
            Tally(effects: a.effects + b.effects, passes: a.passes + b.passes,
                  built: a.built + b.built, unresolved: a.unresolved + b.unresolved,
                  untranslatable: a.untranslatable + b.untranslatable)
        }
    }

    /// One translated pass, with what the rasterizer needs to know about its cost.
    struct Pass {
        let shader: SKShader
        /// The pass does not read the clock, so its output only changes when its input does.
        let isTimeInvariant: Bool
        /// The `name` the scene gave the effect this pass belongs to, which is what a script
        /// switches it by: `getEffect(name).visible`.
        var effect: String? = nil
    }

    /// Passes for one layer, innermost first.
    func chain(for object: WESceneObject, tally: inout Tally) -> [Pass] {
        var shaders: [Pass] = []
        for effect in object.effects ?? [] {
            guard effect.visible != false, let file = effect.file else { continue }

            let bundle = (file as NSString).deletingLastPathComponent
            let manifest = read(file, nil).flatMap { try? JSONDecoder().decode(WEEffectFile.self, from: $0) }
            if !reflections, let manifest,
               (manifest.passes ?? []).contains(where: { isReflection($0, bundle: bundle) }) {
                continue
            }
            tally.effects += 1
            guard let manifest else {
                tally.unresolved += 1
                continue
            }

            // Nesting SKEffectNodes hands each pass exactly one input: the output of the pass
            // inside it. That reproduces an effect faithfully only when the effect is a straight
            // chain, and most of Wallpaper Engine's multi-pass effects are not.
            //
            // Measured over the nine multi-pass effects in the shared asset library, eight of
            // them — blur, blurprecise, godrays, shine, localcontrast, motionblur, cursorripple,
            // glitter — end in a pass that binds *two* targets: the result they cast into a
            // buffer, and the untouched layer to composite it back over. Handed only the cast
            // result, that pass composites the frame against itself and paints it one colour,
            // which is what it did to four wallpapers before this guard existed. They need real
            // render targets with multiple inputs, which is a renderer this one is not.
            //
            // `refraction` is the exception and the reason this is a shape test rather than a
            // count: two passes, neither writing to a target, neither binding one. That is a
            // chain, and nesting reproduces it exactly.
            let passes = manifest.passes ?? []
            tally.passes += passes.count
            guard !passes.isEmpty, passes.allSatisfy(isChainable) else {
                tally.untranslatable += passes.count
                continue
            }
            for (index, pass) in passes.enumerated() {
                let config = index < (effect.passes?.count ?? 0) ? effect.passes?[index] : nil
                if var shader = build(pass: pass, config: config, bundle: bundle) {
                    shader.effect = effect.name
                    shaders.append(shader)
                    tally.built += 1
                } else {
                    tally.untranslatable += 1
                }
            }
        }
        return shaders
    }

    // MARK: - Audio visualiser canvases

    /// Whether a blank layer exists only as the canvas of an audio visualiser this renderer
    /// declines, so that drawing it would show the canvas instead of what is painted on it.
    ///
    /// An audio visualiser in Wallpaper Engine is a plain solid layer — almost always white, the
    /// editor's default — with a spectrum generator on it that throws the layer's pixels away
    /// and draws bars in their place. Those generators cannot run here (no audio capture, and
    /// SKUniform has no array form for the spectrum), so the pass is declined and the layer used
    /// to draw unprocessed: a bare white rectangle where the bars should be. Over the installed
    /// library that was 8 drawn solid layers in 7 scenes — Sunset on Station's white square in its
    /// music sign, Pixels' 500×100 slab, Lost Landscape's pair, Honkai's 600×600 square, Good
    /// rest, Apple Music's panel, and a dim one in Hacker Apartment — plus Apple Music's two
    /// flat-white textured squares. (Road Infinite, Other World and
    /// Final Demons carry the same canvas, but under a "musicplayers" group their author ships
    /// switched off, so it was never drawn.) In Wallpaper Engine itself, with nothing playing,
    /// these layers draw nothing at all, which is what not drawing them reproduces.
    ///
    /// The test is deliberately narrow, every condition measured against the library:
    /// - **A blank canvas only** — the caller asks only for solid layers and for textures that
    ///   are a single flat colour (`SceneWallpaperViewModel.isFlatColour`). The two textured
    ///   layers in the library that carry a generator are Apple Music's white rounded squares,
    ///   which pass that test; a textured layer that holds a picture keeps it, whatever is on
    ///   it. Over-drawing a blank canvas is a fidelity bug, losing a picture would be a worse one.
    /// - **A generator, not a modulator** — see `WEShaderTranslator.audioSpectrumGenerator`.
    ///   `pulse` and friends are declined too, but they act on artwork that is right to show.
    /// - **It replaces the layer's alpha.** Every generator here is a fork of `Simple_Audio_Bars`
    ///   and shares its `TRANSPARENCY` combo: `1` (replace, the default) sets alpha to the bar
    ///   coverage and `4` (intersect) multiplies by it, so at silence the plain bars draw
    ///   nothing. The `enhanced_simple_audio_bars` fork (Honkai, both Lost Landscape layers)
    ///   defaults `BAR_STYLE` to rounded bars, whose caps still show at silence as a row of
    ///   small dots — dropping the canvas loses those dots, which is far closer to the
    ///   wallpaper than the full white slab it replaces.
    ///   Preserve, add, subtract and opaque keep the canvas visible in Wallpaper Engine too, and
    ///   a generator without that combo is not understood well enough to hide anything for. Of
    ///   the 10 drawn canvases, 9 are on `1` and Hacker Apartment's is on `4`; none on others.
    /// - **It is actually declined.** If a generator ever builds — audio capture, array
    ///   uniforms — the canvas comes back with it.
    func isDeclinedAudioCanvas(_ object: WESceneObject) -> Bool {
        for effect in object.effects ?? [] {
            guard effect.visible != false, let file = effect.file,
                  let data = read(file, nil),
                  let manifest = try? JSONDecoder().decode(WEEffectFile.self, from: data) else {
                continue
            }
            let bundle = (file as NSString).deletingLastPathComponent
            for (index, pass) in (manifest.passes ?? []).enumerated() {
                let config = index < (effect.passes?.count ?? 0) ? effect.passes?[index] : nil
                // The substring test is only a cheap filter in front of the preprocessor: this
                // is asked of every textured layer with an effect, and nearly none qualify.
                guard let prepared = prepare(pass: pass, config: config, bundle: bundle),
                      prepared.fragment.contains("g_AudioSpectrum"),
                      let combos = WEShaderTranslator.audioSpectrumGenerator(
                        fragment: prepared.fragment,
                        overrides: prepared.combos,
                        include: { name in
                            source(named: "shaders/\(name)", bundle: bundle)
                                ?? source(named: name, bundle: bundle)
                        }),
                      let transparency = combos["TRANSPARENCY"],
                      transparency == 1 || transparency == 4 else { continue }
                let declined = !isChainable(pass)
                    || build(pass: pass, config: config, bundle: bundle) == nil
                if declined { return true }
            }
        }
        return false
    }

    /// Whether a pass runs Wallpaper Engine's `reflection` shader, by the shader its material
    /// names — the same name the effect bundle and its material are filed under in the shared
    /// asset library, and what a wallpaper bundling its own copy keeps.
    private func isReflection(_ pass: WEEffectFile.Pass, bundle: String) -> Bool {
        guard let materialPath = pass.material,
              let data = read(materialPath, bundle),
              let material = try? JSONDecoder().decode(WEMaterial.self, from: data),
              let shader = material.passes?.first?.shader else { return false }
        return (shader as NSString).lastPathComponent == "reflection"
    }

    /// Whether a pass can be reproduced by wrapping the layer in one more `SKEffectNode`: it
    /// draws where it stands rather than into a buffer, and reads nothing but what it is given.
    private func isChainable(_ pass: WEEffectFile.Pass) -> Bool {
        pass.target == nil && (pass.bind?.isEmpty ?? true)
    }

    // MARK: - One pass

    /// A pass's shader source and the combos it would be compiled with, before translation.
    private struct Prepared {
        let fragment: String
        let vertex: String?
        let textures: [String?]
        let combos: [String: Int]
    }

    private func prepare(pass: WEEffectFile.Pass,
                         config: WESceneEffectPass?,
                         bundle: String) -> Prepared? {
        guard let materialPath = pass.material,
              let materialData = read(materialPath, bundle),
              let material = try? JSONDecoder().decode(WEMaterial.self, from: materialData),
              let shaderName = material.passes?.first?.shader else { return nil }

        guard let fragment = source(of: shaderName, extension: "frag", bundle: bundle) else {
            return nil
        }
        let vertex = source(of: shaderName, extension: "vert", bundle: bundle)

        // Combos come from three places, in increasing priority: the shader's own `[COMBO]`
        // defaults (resolved inside the translator), the material, and the scene's instance.
        // A fourth is implicit: a sampler annotated with a `combo` switches it on merely by
        // having a texture assigned, which is how a mask enables `#if MASK` without any
        // wallpaper ever writing that key.
        let textures = slotTextures(scene: config?.textures,
                                    material: material.passes?.first?.textures)
        var combos = material.passes?.first?.combos ?? [:]
        for (key, value) in samplerCombos(in: fragment, textures: textures) {
            combos[key] = value
        }
        for (key, value) in config?.combos ?? [:] { combos[key] = value }
        return Prepared(fragment: fragment, vertex: vertex, textures: textures, combos: combos)
    }

    private func build(pass: WEEffectFile.Pass,
                       config: WESceneEffectPass?,
                       bundle: String) -> Pass? {
        guard let prepared = prepare(pass: pass, config: config, bundle: bundle) else { return nil }
        let (fragment, vertex, textures, combos) =
            (prepared.fragment, prepared.vertex, prepared.textures, prepared.combos)

        // An effect the author wired to the audio spectrum cannot be rendered without audio, and
        // compiling the audio variant out is not a neutral fallback — it pins the response to
        // zero, which for `pulse` means scaling the layer to nothing. A BMW wallpaper built
        // around audio-responsive lights lost its car that way and rendered as bare smoke. Until
        // there is system-audio capture, these are declined and the layer draws unprocessed.
        guard (combos["AUDIOPROCESSING"] ?? 0) == 0 else { return nil }

        guard let translated = WEShaderTranslator.translate(
            fragment: fragment,
            vertex: vertex,
            overrides: combos,
            include: { name in
                source(named: "shaders/\(name)", bundle: bundle)
                    ?? source(named: name, bundle: bundle)
            }
        ) else { return nil }

        guard let uniforms = bind(translated, config: config, textures: textures,
                                  bundle: bundle) else { return nil }

        let shader = SKShader(source: translated.source)
        shader.uniforms = uniforms
        return Pass(shader: shader, isTimeInvariant: !translated.usesTime)
    }

    // MARK: - Shader source

    private func source(of shader: String, extension ext: String, bundle: String) -> String? {
        source(named: "shaders/\(shader).\(ext)", bundle: bundle)
    }

    /// Shader source, with line endings normalised at the point of reading.
    ///
    /// Wallpaper Engine ships these files CRLF, and `"\r\n"` is a single `Character` in Swift, so
    /// `split(separator: "\n")` returns the whole file as one line. Every line-based reader here
    /// silently sees nothing. `samplerCombos` below was the second place this bit: it never found
    /// the mask declaration, so `MASK` stayed off, and a painted tint that should have been
    /// confined to the mask flooded its entire layer with flat colour.
    private func source(named path: String, bundle: String) -> String? {
        guard let data = read(path, bundle),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Texture slots

    /// The texture assigned to each sampler slot: the scene's own choice where it made one, the
    /// material's where it did not, `nil` where neither did.
    ///
    /// The material is a real source and was never consulted. `waterripple` and `waterflow` name
    /// their normal or phase map in slot 2 *only* in the material — the shader's annotation for
    /// that slot carries a label and no default — so a scene that did not repeat the path had
    /// nothing to bind and the pass was declined. A `null` in the material is not an
    /// assignment; it is the material leaving that slot open, and both write one into slot 1:
    /// `waterripple`'s mask, whose `MASK` combo would switch on with no mask to read and confine
    /// the ripple to nothing, and `waterflow`'s flow map, whose annotation supplies
    /// `util/noflow`. So a null falls through to the annotated default exactly as an absent slot
    /// does. (`refraction` does the same, but is a multi-pass effect and declined before this.)
    private func slotTextures(scene: [String?]?, material: [String?]?) -> [String?] {
        let count = max(scene?.count ?? 0, material?.count ?? 0)
        return (0..<count).map { slot in
            let fromScene = scene.flatMap { $0.indices.contains(slot) ? $0[slot] : nil }
            let fromMaterial = material.flatMap { $0.indices.contains(slot) ? $0[slot] : nil }
            return fromScene ?? fromMaterial
        }
    }

    // MARK: - Combos implied by texture slots

    /// `uniform sampler2D g_Texture1; // {"combo":"MASK", ...}` — the combo is on when the scene
    /// assigned a texture to that slot. Read from the raw source, because this has to be settled
    /// before the conditionals are evaluated.
    private func samplerCombos(in fragment: String, textures: [String?]) -> [String: Int] {
        var out: [String: Int] = [:]
        for raw in fragment.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("uniform sampler2D g_Texture"),
                  let commentRange = line.range(of: "//") else { continue }
            let name = line.dropFirst("uniform sampler2D ".count)
                .prefix { $0 != ";" && !$0.isWhitespace }
            guard let slot = Int(name.dropFirst("g_Texture".count)) else { continue }
            guard let annotation = (try? JSONSerialization.jsonObject(
                with: Data(line[commentRange.upperBound...].trimmingCharacters(in: .whitespaces).utf8)))
                    as? [String: Any],
                  let combo = annotation["combo"] as? String else { continue }
            let assigned = textures.indices.contains(slot) && textures[slot] != nil
            out[combo] = assigned ? 1 : 0
        }
        return out
    }

    // MARK: - Uniform binding

    private func bind(_ translated: WEShaderTranslator.Result,
                      config: WESceneEffectPass?,
                      textures: [String?],
                      bundle: String) -> [SKUniform]? {
        var out: [SKUniform] = []

        for uniform in translated.uniforms {
            // Resolution uniforms describe how much of a padded texture is real. Nothing here
            // pads, so every ratio the shaders compute from them has to come out as 1 — a zero
            // default would divide the layer's coordinates by zero and blank it.
            if uniform.name.hasPrefix("g_Texture"), uniform.name.hasSuffix("Resolution") {
                out.append(SKUniform(name: uniform.name,
                                     vectorFloat4: vector_float4(1, 1, 1, 1)))
                continue
            }

            var values = uniform.defaultValue
            if let override = value(for: uniform, in: config), !override.isEmpty {
                let padded = override.count >= values.count
                    ? Array(override.prefix(max(values.count, 1)))
                    : override + Array(repeating: 0, count: values.count - override.count)
                // A scalar written for a vector uniform fills it, as the annotations abbreviate.
                values = override.count == 1 && values.count > 1
                    ? Array(repeating: override[0], count: values.count)
                    : padded
            }

            switch uniform.kind {
            case .float, .int:
                out.append(SKUniform(name: uniform.name, float: values.first ?? 0))
            case .vec2:
                out.append(SKUniform(name: uniform.name,
                                     vectorFloat2: vector_float2(values[0], values[1])))
            case .vec3:
                out.append(SKUniform(name: uniform.name,
                                     vectorFloat3: vector_float3(values[0], values[1], values[2])))
            case .vec4:
                out.append(SKUniform(name: uniform.name,
                                     vectorFloat4: vector_float4(values[0], values[1],
                                                                 values[2], values[3])))
            case .mat4, .sampler2D:
                // A matrix uniform here can only be the model-view-projection the vertex stage
                // used, which this renderer does not reproduce; a shader that still reads one
                // after translation is not one we can honour.
                return nil
            }
        }

        for sampler in translated.samplers {
            guard let slot = sampler.textureSlot, slot != 0 else { continue }
            let path = textures.indices.contains(slot) ? textures[slot] : nil
            // No invented inputs. If a slot the shader actually reads has neither a texture the
            // scene assigned nor the neutral one its annotation names, there is nothing honest
            // to bind: a blend or overlay effect handed a blank second image paints the layer
            // flat, which is how an X-ray wallpaper went from a full picture to one colour.
            // Declining leaves the layer untouched, which is always a legitimate result.
            guard let image = path.flatMap({ readTexture($0, bundle) })
                    ?? sampler.defaultTexture.flatMap({ readTexture($0, bundle) }) else {
                return nil
            }
            out.append(SKUniform(name: sampler.name, texture: SKTexture(image: image)))
        }

        return out
    }

    private func value(for uniform: WEShaderUniform, in config: WESceneEffectPass?) -> [Float]? {
        guard let values = config?.constantshadervalues else { return nil }
        if let key = uniform.materialKey, let v = values[key] { return v.components }
        if let label = uniform.label, let v = values[label] { return v.components }
        return nil
    }

}
