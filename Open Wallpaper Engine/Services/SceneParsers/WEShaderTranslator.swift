//
//  WEShaderTranslator.swift
//  Open Wallpaper Engine
//
//  Rewrites a Wallpaper Engine effect shader into something SpriteKit will compile.
//
//  Wallpaper Engine writes GLSL ES 1.0 through its own preprocessor: `#include` against a shared
//  header set, `[COMBO]` directives that select compile-time variants, HLSL-flavoured helpers
//  (`texSample2D`, `frac`, `saturate`, `CAST3`, `mul`) and `g_*` uniforms annotated with JSON in
//  trailing comments. SpriteKit accepts a bare GLSL ES fragment function and nothing else: no
//  includes, no vertex stage, no `precision` qualifier, and a fixed set of built-in names.
//
//  Everything here exists to close that gap. The conditionals in particular cannot be left for
//  the downstream compiler: `ApplyBlending` selects its blend mode with `#if BLENDMODE == n`
//  inside a function body, so the combo values have to be resolved here or the function returns
//  nothing at all.
//

import Foundation

/// A `g_*` uniform, as declared and annotated in the shader source.
struct WEShaderUniform {
    enum Kind: String {
        case float, vec2, vec3, vec4, sampler2D, mat4, int
        var componentCount: Int {
            switch self {
            case .float, .int: return 1
            case .vec2: return 2
            case .vec3: return 3
            case .vec4: return 4
            case .mat4: return 16
            case .sampler2D: return 0
            }
        }
    }

    let name: String
    let kind: Kind
    /// The key `constantshadervalues` uses to override this uniform, from the annotation's
    /// `"material"` field. Wallpaper Engine also writes the localisation label as a key in some
    /// wallpapers, so both are accepted when binding.
    let materialKey: String?
    let label: String?
    var defaultValue: [Float]
    /// For samplers: the `g_TextureN` slot number.
    let textureSlot: Int?
    /// For samplers: the texture the annotation names when the scene assigns none — `util/noflow`
    /// for a displacement map, `util/black` for a time offset. These are not decoration: a flow
    /// map that reads as zero instead of neutral pushes the layer's coordinates off the edge of
    /// its own texture, and the layer comes out a single flat colour.
    let defaultTexture: String?
}

enum WEShaderTranslator {
    struct Result {
        let source: String
        /// Non-sampler uniforms the caller has to bind, already carrying their defaults.
        let uniforms: [WEShaderUniform]
        /// Sampler slots the shader actually reads. Slot 0 is the layer itself and is bound to
        /// SpriteKit's `u_texture`; the rest need real textures.
        let samplers: [WEShaderUniform]
        let combos: [String: Int]
        /// Whether the shader reads the clock. A pass that does not is a pure function of its
        /// input, so its result can be cached instead of recomputed every frame.
        let usesTime: Bool
    }

    /// The names SpriteKit supplies to a shader on an effect node. Deliberately shorter than the
    /// documented SKShader list: `u_alpha` and `u_path_length` exist for sprite and shape shaders
    /// but are not in scope here, and treating them as available produced shaders that compiled
    /// to undeclared identifiers. Anything not on this list has to be bound or declined.
    private static let builtins: Set<String> = [
        "u_texture", "v_tex_coord", "u_time", "u_sprite_size",
    ]

    // MARK: - Entry point

    /// - Parameters:
    ///   - fragment: the effect pass's `.frag` source.
    ///   - vertex: its `.vert` source, if any. Not compiled — its `main` is folded into the
    ///     fragment shader to supply the varyings it would have interpolated.
    ///   - overrides: combo values from the scene's effect instance, beating the `[COMBO]` defaults.
    ///   - include: resolves `#include "name.h"` to source.
    static func translate(fragment: String,
                          vertex: String?,
                          overrides: [String: Int],
                          include: (String) -> String?) -> Result? {
        // Wallpaper Engine ships its shaders with CRLF endings, and in Swift "\r\n" is a single
        // Character — so `split(separator: "\n")` finds nothing to split and hands every
        // line-based step below the entire file as one line. Nothing then matches `#include` or
        // `#if`, and the untouched source reaches the compiler complete with its include
        // directives. Normalising first is what makes any of this work.
        let fragment = normalized(fragment)
        let vertex = vertex.map(normalized)
        func resolveInclude(_ name: String) -> String? { include(name).map(normalized) }

        var defines = combos(in: fragment)
        if let vertex { defines.merge(combos(in: vertex)) { a, _ in a } }
        defines.merge(overrides) { _, new in new }

        // No audio capture, so every audio-reactive variant is compiled out rather than left to
        // reference `g_AudioSpectrum16Left[16]` — SKUniform has no array form, and a declaration
        // it cannot bind fails the whole shader. The effect still runs, just without the pulse.
        defines["AUDIOPROCESSING"] = 0

        guard let fragBody = preprocess(fragment, defines: &defines, include: resolveInclude) else { return nil }
        let vertBody = vertex.flatMap { source -> String? in
            var d = defines
            return preprocess(source, defines: &d, include: resolveInclude)
        }

        let fragUniforms = uniforms(in: fragBody)
        let vertUniforms = vertBody.map { uniforms(in: $0) } ?? []
        var merged: [String: WEShaderUniform] = [:]
        for u in fragUniforms + vertUniforms where merged[u.name] == nil { merged[u.name] = u }

        // Comments go once the annotations have been read, because everything downstream scans
        // the code for identifiers and none of those scans can tell a comment from code. The
        // undeclared-identifier check below declined any shader with a `g_` name left in a
        // commented-out line: `reflection.frag` keeps its old body as
        // `//gl_FragColor = mix(..., g_Additive);`, `g_Additive` is declared nowhere, and so the
        // reflection on BMW, 1990 Miata and Lonely Cat was declined for a word in a comment.
        // Stripping comments brought five passes back in five scenes, all of which compile —
        // and exposed that `reflection` itself is wrong here for another reason, which is why
        // `SceneEffectBuilder` now declines it by name. The `return` test would have mistaken
        // prose for a statement the same way.
        guard let built = assemble(fragment: strippingComments(fragBody),
                                   vertex: vertBody.map(strippingComments),
                                   uniforms: merged, defines: defines) else {
            return nil
        }

        let used = built.used.compactMap { merged[$0] }
        return Result(source: built.source,
                      uniforms: used.filter { $0.kind != .sampler2D }.sorted { $0.name < $1.name },
                      samplers: used.filter { $0.kind == .sampler2D }.sorted { $0.name < $1.name },
                      combos: defines,
                      usesTime: containsIdentifier("u_time", in: built.source))
    }

    /// The resolved combos of a shader that reads the audio spectrum in the variant this renderer
    /// would compile, or `nil` for any other shader.
    ///
    /// This separates two kinds of audio-reactive effect that look alike from the outside. A
    /// *modulator* — `pulse` and `shake` in the shared library — reads the spectrum in its
    /// *vertex* stage, behind `#if AUDIOPROCESSING`, to move or scale a layer whose pixels it
    /// leaves alone. A *generator* — every audio visualiser in this library is a fork of the
    /// Workshop's `Simple_Audio_Bars` — reads it in the fragment stage with no such switch: the
    /// spectrum is what it draws, so its `g_AudioSpectrum…` arrays survive preprocessing in every
    /// variant. Only the fragment source is examined, for that reason.
    static func audioSpectrumGenerator(fragment: String,
                                       overrides: [String: Int],
                                       include: (String) -> String?) -> [String: Int]? {
        let fragment = normalized(fragment)
        var defines = combos(in: fragment)
        defines.merge(overrides) { _, new in new }
        defines["AUDIOPROCESSING"] = 0
        guard let body = preprocess(fragment, defines: &defines,
                                    include: { include($0).map(normalized) }),
              !identifiers(matchingPrefix: "g_AudioSpectrum", in: body).isEmpty else { return nil }
        return defines
    }

    private static func normalized(_ source: String) -> String {
        source.replacingOccurrences(of: "\r\n", with: "\n")
              .replacingOccurrences(of: "\r", with: "\n")
    }

    /// The source with `//` and `/* */` comments removed. A block comment keeps its newlines so
    /// the line structure every reader here depends on is unchanged. GLSL has no string
    /// literals, so there is nothing a comment marker could be quoted inside.
    static func strippingComments(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "/", next == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", next == "*" {
                i += 2
                while i < chars.count, !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") {
                    if chars[i] == "\n" { out.append("\n") }
                    i += 1
                }
                i += 2
                out.append(" ")
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    // MARK: - Combos

    /// `// [COMBO] {"combo":"BLENDMODE","default":30}` — the variant switches, with their defaults.
    private static func combos(in source: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let range = line.range(of: "[COMBO]") else { continue }
            let json = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = obj["combo"] as? String else { continue }
            out[name] = intValue(obj["default"]) ?? 0
        }
        return out
    }

    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let n as Int: return n
        case let d as Double: return Int(d)
        case let b as Bool: return b ? 1 : 0
        case let s as String: return Int(s) ?? Double(s).map(Int.init)
        default: return nil
        }
    }

    // MARK: - Preprocessor

    /// Resolve includes, evaluate conditionals, and collect simple object-like defines.
    ///
    /// Function-like macros are left in place: they are the bulk of `common_blending.h` and the
    /// downstream compiler expands them perfectly well. Only the conditionals have to be settled
    /// here, because their conditions are combo values this renderer chooses.
    private static func preprocess(_ source: String,
                                   defines: inout [String: Int],
                                   include: (String) -> String?,
                                   depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }

        var lines: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#include") {
                guard let start = trimmed.firstIndex(of: "\""),
                      let end = trimmed.lastIndex(of: "\""), start < end else { continue }
                let name = String(trimmed[trimmed.index(after: start)..<end])
                guard let included = include(name),
                      let expanded = preprocess(included, defines: &defines,
                                                include: include, depth: depth + 1) else {
                    return nil
                }
                lines.append(contentsOf: expanded.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            } else {
                lines.append(String(line))
            }
        }

        // Now walk the conditionals. `active` is the emit state; `taken` records whether any
        // branch of the current #if chain already matched, so #elif and #else behave.
        var out: [String] = []
        var stack: [(active: Bool, taken: Bool, parent: Bool)] = []
        var emitting: Bool { stack.allSatisfy(\.active) }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#ifdef") || trimmed.hasPrefix("#ifndef") || trimmed.hasPrefix("#if") {
                let parent = emitting
                var value: Bool
                if trimmed.hasPrefix("#ifdef") {
                    value = defines[token(after: "#ifdef", in: trimmed)] != nil
                } else if trimmed.hasPrefix("#ifndef") {
                    value = defines[token(after: "#ifndef", in: trimmed)] == nil
                } else {
                    value = evaluate(String(trimmed.dropFirst(3)), defines: defines)
                }
                stack.append((active: parent && value, taken: value, parent: parent))
                continue
            }
            if trimmed.hasPrefix("#elif") {
                guard var top = stack.popLast() else { return nil }
                let value = !top.taken && evaluate(String(trimmed.dropFirst(5)), defines: defines)
                top.active = top.parent && value
                top.taken = top.taken || value
                stack.append(top)
                continue
            }
            if trimmed.hasPrefix("#else") {
                guard var top = stack.popLast() else { return nil }
                top.active = top.parent && !top.taken
                top.taken = true
                stack.append(top)
                continue
            }
            if trimmed.hasPrefix("#endif") {
                guard stack.popLast() != nil else { return nil }
                continue
            }

            guard emitting else { continue }

            // Record object-like integer defines so later conditionals can use them, and keep the
            // line so the downstream compiler still sees the macro.
            if trimmed.hasPrefix("#define") {
                let parts = trimmed.dropFirst(7).split(separator: " ", maxSplits: 1,
                                                       omittingEmptySubsequences: true)
                if parts.count == 2, !parts[0].contains("("),
                   let v = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                    defines[String(parts[0])] = v
                }
            }
            out.append(line)
        }

        return stack.isEmpty ? out.joined(separator: "\n") : nil
    }

    private static func token(after keyword: String, in line: String) -> String {
        line.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init) ?? ""
    }

    // MARK: - #if expression evaluation

    /// Evaluates a preprocessor condition. Undefined identifiers are 0, as in C.
    private static func evaluate(_ expression: String, defines: [String: Int]) -> Bool {
        var tokens = tokenize(expression)
        var index = 0
        let value = parseOr(&tokens, &index, defines)
        return value != 0
    }

    private static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        let operators: Set<Character> = ["(", ")", "!", "=", "<", ">", "&", "|", "+", "-", "*", "/"]
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                if !current.isEmpty { out.append(current); current = "" }
            } else if operators.contains(c) {
                if !current.isEmpty { out.append(current); current = "" }
                // Two-character operators
                if i + 1 < chars.count {
                    let pair = String([c, chars[i + 1]])
                    if ["==", "!=", "<=", ">=", "&&", "||"].contains(pair) {
                        out.append(pair); i += 2; continue
                    }
                }
                out.append(String(c))
            } else {
                current.append(c)
            }
            i += 1
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func parseOr(_ t: inout [String], _ i: inout Int, _ d: [String: Int]) -> Int {
        var left = parseAnd(&t, &i, d)
        while i < t.count, t[i] == "||" { i += 1; let r = parseAnd(&t, &i, d); left = (left != 0 || r != 0) ? 1 : 0 }
        return left
    }

    private static func parseAnd(_ t: inout [String], _ i: inout Int, _ d: [String: Int]) -> Int {
        var left = parseComparison(&t, &i, d)
        while i < t.count, t[i] == "&&" { i += 1; let r = parseComparison(&t, &i, d); left = (left != 0 && r != 0) ? 1 : 0 }
        return left
    }

    private static func parseComparison(_ t: inout [String], _ i: inout Int, _ d: [String: Int]) -> Int {
        var left = parseUnary(&t, &i, d)
        while i < t.count, ["==", "!=", "<", ">", "<=", ">="].contains(t[i]) {
            let op = t[i]; i += 1
            let right = parseUnary(&t, &i, d)
            switch op {
            case "==": left = left == right ? 1 : 0
            case "!=": left = left != right ? 1 : 0
            case "<":  left = left < right ? 1 : 0
            case ">":  left = left > right ? 1 : 0
            case "<=": left = left <= right ? 1 : 0
            default:   left = left >= right ? 1 : 0
            }
        }
        return left
    }

    private static func parseUnary(_ t: inout [String], _ i: inout Int, _ d: [String: Int]) -> Int {
        guard i < t.count else { return 0 }
        if t[i] == "!" { i += 1; return parseUnary(&t, &i, d) == 0 ? 1 : 0 }
        if t[i] == "-" { i += 1; return -parseUnary(&t, &i, d) }
        if t[i] == "(" {
            i += 1
            let v = parseOr(&t, &i, d)
            if i < t.count, t[i] == ")" { i += 1 }
            return v
        }
        if t[i] == "defined" {
            i += 1
            var paren = false
            if i < t.count, t[i] == "(" { paren = true; i += 1 }
            let name = i < t.count ? t[i] : ""
            i += 1
            if paren, i < t.count, t[i] == ")" { i += 1 }
            return d[name] != nil ? 1 : 0
        }
        let tok = t[i]; i += 1
        if let n = Int(tok) { return n }
        return d[tok] ?? 0
    }

    // MARK: - Uniform declarations

    /// `uniform vec3 g_TintColor; // {"material":"color","default":"1 0 0"}`
    private static func uniforms(in source: String) -> [WEShaderUniform] {
        var out: [WEShaderUniform] = []
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("uniform ") else { continue }

            let code = line.components(separatedBy: "//")[0]
            let comment = line.range(of: "//").map { String(line[$0.upperBound...]) } ?? ""
            let parts = code.dropFirst(8)
                .replacingOccurrences(of: ";", with: " ")
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            guard parts.count >= 2 else { continue }

            // Arrays (`float g_AudioSpectrum16Left[16]`) have no SKUniform form; skip them and
            // let the caller reject the shader if the body still refers to one.
            var name = parts[1]
            if name.contains("[") { continue }
            let typeName = parts[0]
            guard let kind = WEShaderUniform.Kind(rawValue: typeName) else { continue }
            if builtins.contains(name) { continue }
            if name.hasSuffix(";") { name = String(name.dropLast()) }

            let annotation = (try? JSONSerialization.jsonObject(
                with: Data(comment.trimmingCharacters(in: .whitespaces).utf8))) as? [String: Any]

            var slot: Int?
            if kind == .sampler2D, name.hasPrefix("g_Texture") {
                slot = Int(name.dropFirst("g_Texture".count))
            }

            out.append(WEShaderUniform(
                name: name,
                kind: kind,
                materialKey: annotation?["material"] as? String,
                label: annotation?["label"] as? String,
                defaultValue: floats(annotation?["default"], count: kind.componentCount),
                textureSlot: slot,
                defaultTexture: kind == .sampler2D ? annotation?["default"] as? String : nil))
        }
        return out
    }

    static func floats(_ any: Any?, count: Int) -> [Float] {
        var values: [Float] = []
        switch any {
        case let s as String:
            values = s.split(separator: " ").compactMap { Float($0) }
        case let d as Double: values = [Float(d)]
        case let i as Int: values = [Float(i)]
        case let b as Bool: values = [b ? 1 : 0]
        case let a as [Any]: values = a.compactMap { $0 as? Double }.map(Float.init)
        default: values = []
        }
        guard count > 0 else { return [] }
        if values.isEmpty { return Array(repeating: 0, count: count) }
        // A scalar written for a vector uniform fills every component, which is how the
        // annotations abbreviate greyscale colours.
        if values.count == 1 && count > 1 { return Array(repeating: values[0], count: count) }
        if values.count < count { return values + Array(repeating: 0, count: count - values.count) }
        return Array(values.prefix(count))
    }

    // MARK: - Assembly

    /// Build the fragment function SpriteKit will compile, plus the uniforms its code actually
    /// reads. The two have to be worked out together: a uniform is only declared if the body
    /// references it, and the caller must bind exactly the declared set.
    private static func assemble(fragment: String,
                                 vertex: String?,
                                 uniforms: [String: WEShaderUniform],
                                 defines: [String: Int]) -> (source: String, used: [String])? {
        guard let authoredFragMain = mainBody(of: fragment) else { return nil }

        // Varyings become locals. The vertex shader's own main computes them, and every varying
        // in this shader set is a linear function of `a_TexCoord` and uniforms — interpolating
        // such a function and evaluating it at the interpolated coordinate give the same answer,
        // so folding the vertex body into the fragment shader is exact rather than an
        // approximation. A varying the vertex shader never assigns stays zero.
        var preamble: [String] = []
        // Both stages are scanned for varying declarations, not just the fragment: a shader pair
        // will declare one on the vertex side and use it on the fragment side without repeating
        // it, and a varying with no local is an undeclared identifier the moment the vertex
        // body assigns to it.
        //
        // When both stages declare one, the wider type wins. HLSL, which Wallpaper Engine
        // compiles to, lets the stages disagree; GLSL and Metal do not. Sunset on Station's
        // `water_caustics` declares `varying vec2 v_TexCoord` in the fragment and reads
        // `v_TexCoord.zw` (its mask coordinates) from it, because the vertex side declares
        // `vec4` and fills `zw` — the fragment's narrower declaration failed the compile.
        // HLSL then truncates every bare use back to the fragment's own width (the same shader
        // samples the layer at plain `v_TexCoord`), so those uses get that swizzle spelled out.
        var varyings = declarations(prefix: "varying", in: fragment)
        var fragMain = authoredFragMain
        if let vertex {
            for v in declarations(prefix: "varying", in: vertex) {
                if let i = varyings.firstIndex(where: { $0.name == v.name }) {
                    let narrow = Self.vectorWidth(varyings[i].type)
                    if narrow > 0, Self.vectorWidth(v.type) > narrow {
                        varyings[i] = v
                        fragMain = Self.truncateBareUses(of: v.name, toWidth: narrow, in: fragMain)
                    }
                } else {
                    varyings.append(v)
                }
            }
        }
        fragMain = Self.truncateMixWeights(in: fragMain,
                                           declared: declarations(prefix: "uniform", in: fragment)
                                               + varyings)
        for v in varyings where !builtins.contains(v.name) {
            preamble.append("    \(v.type) \(v.name) = \(v.type)(0.0);")
        }
        if let vertex, let vertMain = mainBody(of: vertex) {
            for line in vertMain.split(separator: "\n", omittingEmptySubsequences: false) {
                let t = line.trimmingCharacters(in: .whitespaces)
                // gl_Position is the one thing a fragment shader cannot have.
                if t.hasPrefix("gl_Position") { continue }
                preamble.append("    " + t)
            }
        }

        // Everything above main that is not a uniform, varying, attribute or precision line:
        // the helper functions and macros the body calls.
        var blocks = topLevelBlocks(of: fragment)
        // The vertex stage's helpers come too, because its `main` body does: a perspective
        // transform calls `squareToQuad`, which the vertex shader defines, and folding the call
        // without its definition leaves an undeclared identifier. Only names the fragment stage
        // does not already define are taken — the two stages share headers, and defining a
        // function twice is a compile error rather than a harmless repeat.
        if let vertex {
            let already = Set(blocks.compactMap(\.name))
            for block in topLevelBlocks(of: vertex) {
                guard let name = block.name, !already.contains(name) else { continue }
                blocks.append(block)
            }
        }
        let helpers = blocks.map(\.text)

        let code = helpers.joined(separator: "\n") + "\n"
            + preamble.joined(separator: "\n") + "\n" + fragMain

        // Uniforms are deliberately *not* declared. SKShader generates a declaration for every
        // entry in its `uniforms` array and splices it into the source it hands to Metal;
        // declaring them here as well produces a second, malformed declaration
        // (`uniform float g_UserAlpha[0];`) that fails the whole compile. The caller binds
        // exactly the names returned here, and the shader body just refers to them.
        var used: [String] = []
        for u in uniforms.values.sorted(by: { $0.name < $1.name })
        where containsIdentifier(u.name, in: code) {
            used.append(u.name)
        }

        // Combos are emitted as macros, not just consumed by the conditionals above: WE's own
        // shaders pass them as values too — `ApplyBlending(BLENDMODE, ...)` — so a combo that
        // only ever existed inside this preprocessor is an undeclared identifier downstream.
        // Re-stating a `#define` the source already carries is legal because the value is
        // copied from that very line.
        let macros = defines.sorted { $0.key < $1.key }
            .map { "#define \($0.key) \($0.value)" }
            .joined(separator: "\n")

        // SpriteKit gives `gl_FragColor` no readable storage: assigning to it compiles, reading
        // it back is an undeclared identifier in the Metal it generates. Wallpaper Engine's
        // shaders do read it — `gl_FragColor = mix(texSample2D(g_Texture0, uv), gl_FragColor,
        // mask)` is its standard way of blending a pass against the layer it sits on — so 26
        // shaders in this library failed on a value they had written two lines earlier.
        //
        // Route the body through a local and write it out once at the end, which is what GLSL ES
        // says `gl_FragColor` means anyway. An early `return` would skip the final write and
        // leave the fragment undefined, so a body carrying one is declined instead — none of the
        // 460 translated passes in this library do.
        //
        // Every pass goes through the local now, not just the ones that read it back, because
        // the write-out is also where the alpha convention is converted (below).
        guard !containsReturnStatement(fragMain) else { return nil }
        var body = replaceIdentifier("gl_FragColor", with: "we_FragColor", in: fragMain)
        // The texture coordinate in Wallpaper Engine's space, top-down. Until this existed every
        // pass ran on SpriteKit's bottom-up `v_tex_coord`, which is invisible to a pass that
        // samples where it stands and wrong for every asymmetric `y` an author wrote: a scroll
        // direction, a gradient's top edge, a mirror offset. `reflection` was the visible case —
        // its `offset` of -0.3 on 1990 Miata moved the mirror off the top of the layer and
        // painted a white blob over the road. The prelude flips each sample back.
        let accumulator = """
            vec2 we_TexCoord = vec2(v_tex_coord.x, 1.0 - v_tex_coord.y);
            vec4 we_FragColor = vec4(0.0);
        """

        // SpriteKit works in premultiplied alpha at both ends of a shader and Wallpaper Engine
        // works in straight alpha, so the layer is un-premultiplied on the way in and the
        // result premultiplied on the way out. Measured with an 8×8 probe over black: a white
        // sprite at alpha 0.5 reaches an effect shader as (0.5, 0.5, 0.5, 0.5), not (1, 1, 1,
        // 0.5), and a shader writing (1, 1, 1, 0) paints *white*, because SpriteKit composites
        // the result with `one, one-minus-source-alpha`.
        //
        // That last fact is the bug this fixes. Most of Wallpaper Engine's colour passes —
        // tint, noise, clouds, the gradient generator — rewrite `rgb` and pass `a` through, so
        // over a transparent texel they produce (tint, 0): invisible in straight alpha,
        // *added* to the frame in premultiplied. A layer's transparent border came out as a
        // pale box (Sunset on Station's film-grain passes) or white squares (2847470774). A
        // pass that scales alpha (`albedo.a *= mask`) had the converse fault: premultiplied
        // colour left at full strength over a reduced alpha, so the faded part glowed.
        //
        // For passes that only move texels around — the waves, flows and shakes that are most
        // of the library — un-premultiplying and premultiplying again is the identity, so they
        // are unaffected. Values are clamped before premultiplying because Wallpaper Engine's
        // targets clamp a straight colour, and `rgb > 1` times a partial alpha would otherwise
        // survive into the blend.
        body = unpremultiplyingSamples(in: body)
        let writeOut = "    gl_FragColor = we_premultiply(we_FragColor);"

        let source = """
        \(prelude)
        \(constants(usedIn: [fragment, vertex ?? ""]))
        \(polyfills(usedIn: [fragment, vertex ?? ""]))
        \(alphaConversion)

        \(macros)

        \(helpers.joined(separator: "\n"))

        void main() {
        \(accumulator)
        \(preamble.joined(separator: "\n"))
        \(body)
        \(writeOut)
        }
        """

        guard let rewritten = rewrite(source) else { return nil }

        // SpriteKit hands textures and varyings to `main` alone, so a helper function that reads
        // one compiles to an undeclared identifier. Detect it here and decline the shader rather
        // than let it fail downstream: a rejected effect is skipped cleanly, a rejected compile
        // is the same picture plus several hundred lines of compiler output at launch.
        let helperText = helpers.joined(separator: "\n")
        for scoped in ["g_Texture0", "gl_FragColor"] + varyings.map(\.name)
        where containsIdentifier(scoped, in: helperText) {
            return nil
        }

        // A uniform is scoped to `main` for the same reason a texture is: SpriteKit gathers them
        // into a structure it passes to the fragment entry point, so a free function cannot see
        // one. A rounded-rectangle mask that reads its border width inside a distance helper
        // failed on exactly this. Only function bodies are searched — a macro that names a
        // uniform is expanded at its call site, which is usually main, and rejecting on the text
        // of the macro would throw away shaders that are fine.
        let helperBodies = helpers.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        for name in used where containsIdentifier(name, in: helperBodies) {
            return nil
        }

        // Anything left carrying a Wallpaper Engine prefix that nothing declares, binds, or
        // supplies: a uniform whose declaration sat inside a variant this build compiled out, a
        // varying the vertex pair never declared, a helper from a header that did not resolve.
        // Each of those compiles to an undeclared identifier, and a shader that fails to compile
        // still costs its layer a full offscreen pass every frame for no picture at all — so it
        // is cheaper to decline it here than to let SpriteKit discover it.
        let supplied = Set(used).union(builtins).union(varyings.map(\.name))
        for prefix in ["g_", "v_", "u_"] {
            for name in identifiers(matchingPrefix: prefix, in: rewritten) where !supplied.contains(name) {
                return nil
            }
        }

        return (rewritten, used)
    }

    /// Every `prefix…` identifier the source refers to.
    private static func identifiers(matchingPrefix prefix: String, in source: String) -> Set<String> {
        var out: Set<String> = []
        var current = ""
        for c in source {
            if isIdentifierChar(c) {
                current.append(c)
            } else {
                if current.hasPrefix(prefix) { out.insert(current) }
                current = ""
            }
        }
        if current.hasPrefix(prefix) { out.insert(current) }
        return out
    }

    /// Everything a stage declares above `main`, grouped so a multi-line definition stays whole.
    ///
    /// `name` is what the block defines when that can be read off its first line — the function
    /// before its parameter list, or the macro a `#define` introduces. Blocks without one are
    /// comments and blank lines, kept for the fragment stage's own layout and dropped when the
    /// vertex stage is merged in.
    private static func topLevelBlocks(of source: String) -> [(name: String?, text: String)] {
        var out: [(name: String?, text: String)] = []
        var pending: [String] = []
        var depth = 0
        var opened = false
        var inMain = false

        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let t = line.trimmingCharacters(in: .whitespaces)
            if !inMain, pending.isEmpty, isMainSignature(t) { inMain = true }
            let opens = line.filter { $0 == "{" }.count
            let closes = line.filter { $0 == "}" }.count

            if inMain {
                depth += opens - closes
                if depth == 0, closes > 0 { inMain = false }
                continue
            }
            if pending.isEmpty,
               t.hasPrefix("uniform") || t.hasPrefix("varying") || t.hasPrefix("attribute")
                || t.hasPrefix("precision") || t.hasPrefix("#version") || t.hasPrefix("layout") {
                continue
            }

            pending.append(line)
            depth += opens - closes
            if opens > 0 { opened = true }
            // A function may open its brace on the line after its signature, so a block only ends
            // once a brace has actually been opened and closed — or on a line that stands alone.
            if depth <= 0, opened || t.hasSuffix(";") || t.hasPrefix("#") || t.hasPrefix("//") || t.isEmpty {
                out.append((declaredName(in: pending[0]), pending.joined(separator: "\n")))
                pending = []
                depth = 0
                opened = false
            }
        }
        if !pending.isEmpty { out.append((declaredName(in: pending[0]), pending.joined(separator: "\n"))) }
        return out
    }

    private static func declaredName(in line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("//") else { return nil }
        if t.hasPrefix("#define ") {
            let name = t.dropFirst("#define ".count).prefix { isIdentifierChar($0) }
            return name.isEmpty ? nil : String(name)
        }
        guard let paren = t.firstIndex(of: "(") else { return nil }
        let name = String(t[t.startIndex..<paren]).reversed().prefix { isIdentifierChar($0) }
        return name.isEmpty ? nil : String(name.reversed())
    }

    /// Functions Wallpaper Engine's dialect has and SpriteKit's does not, emitted only when the
    /// shader calls one. `rewrite` renames the call, so these never collide with a builtin that
    /// SpriteKit may grow later.
    private static func polyfills(usedIn sources: [String]) -> String {
        let text = sources.joined(separator: "\n")
        guard containsIdentifier("inverse", in: text) else { return "" }
        // Matrix inverse by adjugate over determinant. Only the sizes a perspective transform
        // uses are provided; a call on any other type stays unresolved and declines the shader.
        return """
        mat2 we_inverse(mat2 m) {
            float d = m[0][0] * m[1][1] - m[0][1] * m[1][0];
            return mat2(m[1][1], -m[0][1], -m[1][0], m[0][0]) / d;
        }
        mat3 we_inverse(mat3 m) {
            float a = m[1][1] * m[2][2] - m[2][1] * m[1][2];
            float b = m[2][0] * m[1][2] - m[1][0] * m[2][2];
            float c = m[1][0] * m[2][1] - m[2][0] * m[1][1];
            float d = m[0][0] * a + m[0][1] * b + m[0][2] * c;
            return mat3(a, m[2][1] * m[0][2] - m[0][1] * m[2][2], m[0][1] * m[1][2] - m[1][1] * m[0][2],
                        b, m[0][0] * m[2][2] - m[2][0] * m[0][2], m[1][0] * m[0][2] - m[0][0] * m[1][2],
                        c, m[2][0] * m[0][1] - m[0][0] * m[2][1], m[0][0] * m[1][1] - m[1][0] * m[0][1]) / d;
        }
        """
    }

    /// The two ends of the straight/premultiplied conversion described in `assemble`. Free
    /// functions are fine here because they touch nothing SpriteKit scopes to `main`. A texel
    /// with no alpha has no recoverable colour, and zero is what it contributes either way.
    private static let alphaConversion = """
    vec4 we_unpremultiply(vec4 c) {
        return c.a > 0.0 ? vec4(c.rgb / c.a, c.a) : vec4(0.0);
    }
    vec4 we_premultiply(vec4 c) {
        float a = clamp(c.a, 0.0, 1.0);
        return vec4(clamp(c.rgb, 0.0, 1.0) * a, a);
    }
    """

    /// Wraps every sample of the layer, `g_Texture0`, in `we_unpremultiply(...)`.
    ///
    /// Only the layer. An auxiliary `SKTexture(image:)` also samples premultiplied — same probe
    /// — so converting those looked consistent, and it was tried: it put a striped block into
    /// the grass of 2607457838, whose foliage sway reads `util/noise`. Noise and flow maps keep
    /// independent data in their alpha channel, the premultiplied upload has already thrown
    /// away the colour under a low alpha, and dividing by that alpha amplifies what is left
    /// into large, wrong offsets. Masks are opaque, so leaving these slots alone costs nothing
    /// measurable. A call is recognised by its first argument, and the wrap closes at the
    /// call's own matching parenthesis so nested coordinates
    /// (`texSample2D(g_Texture0, uv + f(x))`) stay intact.
    private static func unpremultiplyingSamples(in body: String) -> String {
        let chars = Array(body)
        var out = ""
        out.reserveCapacity(chars.count + 64)
        var i = 0
        let calls = ["texSample2DLod", "texSample2D", "texture2D"]
        outer: while i < chars.count {
            let atBoundary = i == 0 || !isIdentifierChar(chars[i - 1])
            if atBoundary {
                for call in calls where matches(call, in: chars, at: i) {
                    var j = i + call.count
                    guard j >= chars.count || !isIdentifierChar(chars[j]) else { continue }
                    while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                    guard j < chars.count, chars[j] == "(" else { continue }
                    var k = j + 1
                    while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
                    let slot = "g_Texture0"
                    guard matches(slot, in: chars, at: k),
                          k + slot.count >= chars.count || !isIdentifierChar(chars[k + slot.count])
                    else { continue }
                    // Find the parenthesis that closes this call.
                    var depth = 0
                    var end = j
                    while end < chars.count {
                        if chars[end] == "(" { depth += 1 }
                        if chars[end] == ")" { depth -= 1; if depth == 0 { break } }
                        end += 1
                    }
                    guard end < chars.count else { continue }
                    // The coordinates may themselves sample the layer, so they are converted too.
                    let inner = unpremultiplyingSamples(in: String(chars[(j + 1)..<end]))
                    out += "we_unpremultiply(\(call)(\(inner)))"
                    i = end + 1
                    continue outer
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    private static func matches(_ word: String, in chars: [Character], at index: Int) -> Bool {
        let w = Array(word)
        guard index + w.count <= chars.count else { return false }
        return Array(chars[index..<(index + w.count)]) == w
    }

    /// Whether the body returns early. A `return` in a fragment `main` is legal GLSL and ends the
    /// shader on the spot, which is incompatible with writing an accumulated colour out at the end.
    private static func containsReturnStatement(_ body: String) -> Bool {
        containsIdentifier("return", in: body)
    }

    /// Constants Wallpaper Engine's own headers define, emitted only when this shader refers to
    /// one and no surviving header defined it.
    ///
    /// `common.h` carries these, but a shader that reaches for `M_PI` without including anything
    /// gets it from the compiler Wallpaper Engine ships. Defining them unconditionally would
    /// collide with the headers that *do* declare them, so each is checked both ways.
    /// Both stages are searched: the vertex body is folded into `main`, so a constant only the
    /// vertex shader used still has to be defined here.
    private static func constants(usedIn sources: [String]) -> String {
        let known = [("M_PI", "3.14159265359"), ("M_PI_HALF", "1.57079632679"),
                     ("M_PI_2", "6.28318530718"), ("M_E", "2.71828182846")]
        let text = sources.joined(separator: "\n")
        // The definition test is per identifier rather than by substring: `#define M_PI_HALF`
        // contains the text `#define M_PI`, and reading that as a definition of `M_PI` leaves the
        // shader without the constant it actually asked for.
        let defined = Set(text.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#define ") else { return nil }
            return String(t.dropFirst("#define ".count).prefix { isIdentifierChar($0) })
        })
        return known.filter { name, _ in
            containsIdentifier(name, in: text) && !defined.contains(name)
        }.map { "#define \($0.0) \($0.1)" }.joined(separator: "\n")
    }

    /// Wallpaper Engine's compiler injects these; SpriteKit does not.
    ///
    /// Every sample converts its coordinates back from Wallpaper Engine's texture space, where v
    /// runs top to bottom, to SpriteKit's, where it runs bottom to top. The shader body works in
    /// WE's space throughout — `a_TexCoord` arrives already flipped (see `assemble`) — so any
    /// constant an author wrote in that space means what it meant to them, and the two flips
    /// cancel for a pass that only samples where it stands. Auxiliary slots are flipped too:
    /// masks and noise maps are uploaded the same way up as the layer, and a mask sampled at
    /// `v_TexCoord.zw` has to land on the same texel as the layer sampled at `v_TexCoord.xy`.
    private static let prelude = """
    #define WE_SKSPACE(uv) vec2((uv).x, 1.0 - (uv).y)
    #define texSample2D(tex, uv) texture2D(tex, WE_SKSPACE(uv))
    #define texSample2DLod(tex, uv, lod) texture2D(tex, WE_SKSPACE(uv))
    #define frac(x) fract(x)
    #define saturate(x) clamp(x, 0.0, 1.0)
    #define lerp(a, b, t) mix(a, b, t)
    #define ddx(x) dFdx(x)
    #define ddy(x) dFdy(x)
    #define atan2(y, x) atan(y, x)
    #define mul(a, b) ((b) * (a))
    #define CAST2(x) vec2(x)
    #define CAST3(x) vec3(x)
    #define CAST4(x) vec4(x)
    #define CAST2X2(x) mat2(x)
    #define CAST3X3(x) mat3(x)
    #define CAST4X4(x) mat4(x)
    """

    /// Name substitutions that only make sense once the whole source is assembled.
    private static func rewrite(_ source: String) -> String? {
        var s = source
        // The layer's own texture and the clock are SpriteKit's, under its own names.
        s = replaceIdentifier("g_Texture0", with: "u_texture", in: s)
        s = replaceIdentifier("g_Time", with: "u_time", in: s)
        s = replaceIdentifier("a_TexCoord", with: "we_TexCoord", in: s)
        // Calls go to the polyfill above rather than to a builtin this dialect does not have.
        s = replaceIdentifier("inverse", with: "we_inverse", in: s)

        // GLSL marks a read-only parameter `in`, which is what it already is; SpriteKit's
        // translation passes the qualifier straight through to Metal, where it is not a type and
        // stops the compile. `out` and `inout` are a different matter — they need a reference
        // parameter Metal spells differently — so a shader using those is declined instead.
        for qualifier in ["(in ", ", in ", "( in ", ",in "] {
            s = s.replacingOccurrences(of: qualifier,
                                       with: qualifier.replacingOccurrences(of: "in ", with: ""))
        }
        for unsupported in ["(out ", ", out ", "(inout ", ", inout "] where s.contains(unsupported) {
            return nil
        }

        // Anything still referring to a vertex attribute, an array uniform or a resolution slot
        // this renderer does not supply would fail to compile; reject rather than ship a shader
        // that silently drops the layer.
        for unsupported in ["a_Position", "a_Normal", "a_Color", "gl_Position", "gl_FragData"] {
            if containsIdentifier(unsupported, in: s) { return nil }
        }
        return s
    }

    // MARK: - Source scanning helpers

    private static func isMainSignature(_ line: String) -> Bool {
        line.hasPrefix("void main") || line.hasPrefix("void  main")
    }

    /// The contents of `main`, without its braces.
    private static func mainBody(of source: String) -> String? {
        guard let range = source.range(of: "void main", options: [])
                ?? source.range(of: "void  main", options: []) else { return nil }
        guard let open = source[range.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[source.index(after: open)..<index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func declarations(prefix: String, in source: String) -> [(type: String, name: String)] {
        var out: [(String, String)] = []
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix + " ") else { continue }
            let parts = line.dropFirst(prefix.count + 1)
                .components(separatedBy: "//")[0]
                .replacingOccurrences(of: ";", with: " ")
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            guard parts.count >= 2, !parts[1].contains("[") else { continue }
            out.append((parts[0], parts[1]))
        }
        return out
    }

    /// `name` → `name.xy` (for width 2) wherever it is used without a swizzle or member access
    /// of its own, which is how HLSL reads a wider value where a narrower one was declared.
    private static func truncateBareUses(of name: String, toWidth width: Int, in source: String) -> String {
        let swizzle = "." + String("xyzw".prefix(width))
        var result = ""
        var search = source.startIndex
        while let r = source.range(of: name, range: search..<source.endIndex) {
            let beforeOK = r.lowerBound == source.startIndex
                || !isIdentifierChar(source[source.index(before: r.lowerBound)])
            let afterOK = r.upperBound == source.endIndex || !isIdentifierChar(source[r.upperBound])
            let rest = source[r.upperBound...].drop(while: { $0 == " " || $0 == "\t" })
            let accessed = rest.first == "."
            result += source[search..<r.lowerBound]
            result += (beforeOK && afterOK && !accessed) ? name + swizzle : name
            search = r.upperBound
        }
        result += source[search...]
        return result
    }

    /// `mix(a, b, t)` with `t` wider than `a` and `b` → `mix(a, b, t.xyz)`.
    ///
    /// HLSL's `lerp` truncates a wider weight to the operands' width; GLSL's `mix` has no such
    /// overload and Metal rejects the call. Retro Room's procedural noise is written
    /// `mix(u_colorLow, u_colorHigh, col)` with `vec3` colours and a `vec4` `col`, and lost its
    /// pass to it. Only calls whose three arguments are bare identifiers of known type are
    /// touched, so a call this rewrites is one that could not have compiled as written.
    private static func truncateMixWeights(in source: String,
                                           declared: [(type: String, name: String)]) -> String {
        var types: [String: Int] = [:]
        for d in declared { types[d.name] = vectorWidth(d.type) }
        // Locals: `vec4 col = ...;` / `float border;`.
        let local = try! NSRegularExpression(pattern: #"\b(float|vec[234])\s+([A-Za-z_]\w*)\s*[=;]"#)
        let ns = source as NSString
        for m in local.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 2))
            if types[name] == nil { types[name] = vectorWidth(ns.substring(with: m.range(at: 1))) }
        }
        let call = try! NSRegularExpression(
            pattern: #"\bmix\(\s*([A-Za-z_]\w*)\s*,\s*([A-Za-z_]\w*)\s*,\s*([A-Za-z_]\w*)\s*\)"#)
        var out = source
        for m in call.matches(in: source, range: NSRange(location: 0, length: ns.length)).reversed() {
            let (a, b, t) = (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)),
                             ns.substring(with: m.range(at: 3)))
            guard let wa = types[a], let wb = types[b], let wt = types[t],
                  wa == wb, wa > 1, wt > wa,
                  let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: "mix(\(a), \(b), \(t).\(String("xyzw".prefix(wa))))")
        }
        return out
    }

    /// Component count of a GLSL scalar or vector type (`float` 1, `vec3` 3); 0 for anything
    /// else, so a matrix or sampler is never "widened" into.
    private static func vectorWidth(_ type: String) -> Int {
        switch type {
        case "float", "int", "bool": return 1
        case "vec2", "ivec2", "bvec2": return 2
        case "vec3", "ivec3", "bvec3": return 3
        case "vec4", "ivec4", "bvec4": return 4
        default: return 0
        }
    }

    private static func isIdentifierChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    private static func containsIdentifier(_ name: String, in source: String) -> Bool {
        var search = source.startIndex
        while let r = source.range(of: name, range: search..<source.endIndex) {
            let beforeOK = r.lowerBound == source.startIndex
                || !isIdentifierChar(source[source.index(before: r.lowerBound)])
            let afterOK = r.upperBound == source.endIndex || !isIdentifierChar(source[r.upperBound])
            if beforeOK && afterOK { return true }
            search = r.upperBound
        }
        return false
    }

    private static func replaceIdentifier(_ name: String, with replacement: String, in source: String) -> String {
        var result = ""
        var search = source.startIndex
        while let r = source.range(of: name, range: search..<source.endIndex) {
            let beforeOK = r.lowerBound == source.startIndex
                || !isIdentifierChar(source[source.index(before: r.lowerBound)])
            let afterOK = r.upperBound == source.endIndex || !isIdentifierChar(source[r.upperBound])
            result += source[search..<r.lowerBound]
            result += (beforeOK && afterOK) ? replacement : name
            search = r.upperBound
        }
        result += source[search...]
        return result
    }
}
