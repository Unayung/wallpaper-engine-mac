//
//  SceneModels.swift
//  Open Wallpaper Engine
//
//  Data models for Wallpaper Engine scene.json structure.
//  Decoded from scene.pkg → scene.json and referenced JSON files.
//

import Foundation

// MARK: - Top-level Scene

struct WEScene: Decodable {
    var camera: WECamera
    var general: WESceneGeneral
    var objects: [WESceneObject]
    var version: Int?
}

struct WECamera: Codable {
    var center: String?
    var eye: String?
    var up: String?
}

struct WESceneGeneral: Decodable {
    var clearcolor: String?
    var orthogonalprojection: WEOrthogonalProjection?
    var ambientcolor: String?
    var skylightcolor: String?

    /// Camera parallax, as the wallpaper's author left it.
    ///
    /// This flag is what decides whether a scene parallaxes at all, and it is off far more often
    /// than the layer data suggests: Wallpaper Engine writes a `parallaxDepth` of `1.0 1.0` onto
    /// image objects by default, so 63 of the 76 scenes in this library that carry depth values
    /// have the feature switched off. Honouring the flag is the difference between reproducing
    /// the wallpaper and inventing motion its author rejected.
    var cameraparallax: Bool?
    var cameraparallaxamount: Double?
    var cameraparallaxdelay: Double?
    var cameraparallaxmouseinfluence: Double?

    // These fields can be Bool, Int, or an object {"user":..,"value":..} in different wallpapers.

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Use try? because these fields can be plain strings OR {"user":..,"value":..} objects
        // `clearcolor` too: an author who exposes the background as a user property writes it
        // `{"user": "schemecolor", "value": "1 1 1"}`, and a plain String read of that came back
        // nil, leaving the scene on SKScene's default 0.15 grey instead of the colour authored.
        clearcolor = flexibleGeneral(String.self, container, .clearcolor)
        orthogonalprojection = try? container.decodeIfPresent(WEOrthogonalProjection.self, forKey: .orthogonalprojection)
        ambientcolor = try? container.decodeIfPresent(String.self, forKey: .ambientcolor)
        skylightcolor = try? container.decodeIfPresent(String.self, forKey: .skylightcolor)

        cameraparallax = flexibleGeneral(Bool.self, container, .cameraparallax)
        cameraparallaxamount = flexibleGeneral(Double.self, container, .cameraparallaxamount)
        cameraparallaxdelay = flexibleGeneral(Double.self, container, .cameraparallaxdelay)
        cameraparallaxmouseinfluence = flexibleGeneral(Double.self, container, .cameraparallaxmouseinfluence)
    }

    enum CodingKeys: String, CodingKey {
        case clearcolor, orthogonalprojection, ambientcolor, skylightcolor
        case cameraparallax, cameraparallaxamount, cameraparallaxdelay, cameraparallaxmouseinfluence
    }
}

struct WEOrthogonalProjection: Codable {
    var width: Int
    var height: Int
}

// MARK: - User properties

/// The values a wallpaper's user properties actually hold, as its `project.json` records them.
///
/// A scene binds a field to a user property by wrapping it, `{"user": "<key>", "value": ..}`,
/// or for a combo-driven toggle `{"user": {"name": "<key>", "condition": "2"}, "value": ..}`.
/// The `value` beside the binding is only what the property held when the author last saved the
/// *scene*; what Wallpaper Engine applies is `general.properties.<key>.value` in the project, and
/// the two drift apart whenever the author retunes a setting afterwards. Reading only `value`
/// rendered every wallpaper as its author had it mid-edit.
///
/// Measured over the installed library's scene files, counting only the outermost of a binding
/// nested inside another: 2306 bindings across 39 scenes — 1791 by key, 515 by condition. 1024
/// are `visible` (768 on objects, 256 on effects), 333 an object's `color`, 105 its `alpha`; 364
/// sit in script settings, 323 in effect uniforms, 33 in particle `instanceoverride`s and 31 in
/// `general`. No `combos` entry is bound anywhere. 39 name a property the project does not
/// declare and keep their authored value. **283 differ from the project, in 24 scenes** — 183
/// script settings (the clocks' 12/24-hour and date-format flags), 90 effect uniforms
/// (Samurai's moon tint authored red and set white; Hacker Apartment's grain and sharpen
/// authored on and set to 0), 5 particle overrides and 5 object fields. None of the 1024
/// visibility bindings differ: the visibility symptom this resolver was expected to fix does not
/// occur in this library, though the conditions are resolved all the same.
///
/// Read with `JSONSerialization`, never through `WEProject`, which models none of this — and
/// never written back. It reaches the decoders through `JSONDecoder.userInfo`, so every
/// wrapper resolves in the same place it already reads `value`, and a scene decoded without it
/// (a particle preset, a model file) keeps the authored values exactly as before.
struct SceneUserProperties {
    enum Value: Equatable {
        case bool(Bool)
        case number(Double)
        case string(String)
    }

    let values: [String: Value]

    static let userInfoKey = CodingUserInfoKey(rawValue: "SceneUserProperties")!

    init(values: [String: Value] = [:]) {
        self.values = values
    }

    /// Read the project file of the wallpaper in `directory`. A missing or unreadable file is no
    /// properties at all, which leaves every field at its authored value.
    init(wallpaperDirectory directory: URL) {
        var values: [String: Value] = [:]
        if var data = try? Data(contentsOf: directory.appending(path: "project.json")) {
            if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let general = root?["general"] as? [String: Any]
            let properties = general?["properties"] as? [String: Any] ?? [:]
            for (key, entry) in properties {
                guard let raw = (entry as? [String: Any])?["value"],
                      let value = Self.value(raw) else { continue }
                values[key] = value
            }
        }
        self.values = values
    }

    private static func value(_ raw: Any) -> Value? {
        if let n = raw as? NSNumber {
            // A JSON `true` arrives as an NSNumber too, and `as? Bool` would accept a 1 as well,
            // so only the CFBoolean type tells a checkbox from a slider.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        }
        if let s = raw as? String { return .string(s) }
        return nil
    }

    /// The object literal a script's `applyUserProperties` is handed. Colours stay the project's
    /// strings; nothing in this library reads one through that path.
    var jsLiteral: String {
        let object: [String: Any] = values.mapValues {
            switch $0 {
            case .bool(let b): return b
            case .number(let d): return d
            case .string(let s): return s
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let literal = String(data: data, encoding: .utf8) else { return "{}" }
        return literal
    }

    // MARK: Resolving a binding

    /// What a `user` key binds to.
    private enum Binding: Decodable {
        case key(String)
        /// True when the property's value equals `condition` — how a combo switches between
        /// variants of a layer.
        case condition(name: String, equals: String)

        private enum CodingKeys: String, CodingKey { case name, condition }

        init(from decoder: Decoder) throws {
            if let key = try? decoder.singleValueContainer().decode(String.self) {
                self = .key(key)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let name = try c.decode(String.self, forKey: .name)
            // Written as a string in all 515 occurrences, but a number would mean the same.
            if let s = try? c.decode(String.self, forKey: .condition) {
                self = .condition(name: name, equals: s)
            } else if let d = try? c.decode(Double.self, forKey: .condition) {
                self = .condition(name: name, equals: SceneUserProperties.text(d))
            } else {
                self = .key(name)
            }
        }
    }

    private func value(for binding: Binding) -> Value? {
        switch binding {
        case .key(let key):
            return values[key]
        case .condition(let name, let condition):
            guard let current = values[name] else { return nil }
            switch current {
            case .string(let s): return .bool(s == condition)
            case .number(let d): return .bool(Self.text(d) == condition)
            case .bool(let b): return .bool((b ? "true" : "false") == condition || (b ? "1" : "0") == condition)
            }
        }
    }

    /// The project's value for the binding under `key`, untyped. Nil when there is no binding,
    /// no properties were supplied, or the project does not declare the property.
    static func resolveRaw<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K,
                                         decoder: Decoder) -> Value? {
        guard let properties = decoder.userInfo[userInfoKey] as? SceneUserProperties,
              !properties.values.isEmpty,
              let binding = (try? container.decodeIfPresent(Binding.self, forKey: key)) ?? nil
        else { return nil }
        return properties.value(for: binding)
    }

    /// The project's value for the binding under `key`, as the type the field is read as — or
    /// `authored` when there is no binding, or the project's value cannot be that type.
    static func resolve<T, K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K,
                                         decoder: Decoder, authored: T?) -> T? {
        guard let raw = resolveRaw(container, key, decoder: decoder) else { return authored }
        return coerce(raw, like: authored) ?? authored
    }

    /// Convert a project value to the field's type. The one non-obvious case is a number for a
    /// vector field: a slider bound to `scale` is a single number in the project and `"x y z"` in
    /// the scene (Wallpaper Engine widens it), so it is repeated to the authored component count.
    /// A flag fed to a numeric field becomes 1/0, but a flag fed to text keeps the authored text:
    /// one `text` property in this library holds `false`, and painting the word would be wrong.
    private static func coerce<T>(_ raw: Value, like authored: T?) -> T? {
        if T.self == Bool.self {
            switch raw {
            case .bool(let b): return b as? T
            case .number(let d): return (d != 0) as? T
            case .string(let s):
                switch s.lowercased() {
                case "true", "1": return true as? T
                case "false", "0": return false as? T
                default: return nil
                }
            }
        }
        if T.self == Double.self {
            switch raw {
            case .bool(let b): return (b ? 1.0 : 0.0) as? T
            case .number(let d): return d as? T
            case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces)) as? T
            }
        }
        if T.self == Int.self {
            switch raw {
            case .bool(let b): return (b ? 1 : 0) as? T
            case .number(let d): return Int(d.rounded()) as? T
            case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces)) as? T
            }
        }
        if T.self == String.self {
            let authoredText = authored as? String
            let components = authoredText?.split(separator: " ").filter { Double($0) != nil }.count ?? 0
            let numeric = components > 0
                && components == authoredText?.split(separator: " ").count
            switch raw {
            case .string(let s):
                // A vector or colour field bound to a combo or text property must not take the
                // property's label verbatim: "origin" = "Left" would decode as no position at
                // all, which is worse than the authored one. Only a string that reads as the
                // same number of components replaces a numeric authored value.
                if numeric {
                    let parts = s.split(separator: " ")
                    guard parts.count == components, parts.allSatisfy({ Double($0) != nil })
                    else { return nil }
                }
                return s as? T
            case .number(let d):
                return Array(repeating: text(d), count: max(components, 1))
                    .joined(separator: " ") as? T
            case .bool(let b):
                guard numeric else { return nil }
                return Array(repeating: b ? "1" : "0", count: components)
                    .joined(separator: " ") as? T
            }
        }
        return nil
    }

    /// A number the way a scene writes it: integral values without a fraction, so a combo index
    /// `2` matches a condition `"2"`.
    private static func text(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
        return String(d)
    }
}

// MARK: - Scene Objects

/// A scene field that is not a plain value.
///
/// Wallpaper Engine writes the same field three ways: bare, wrapped as
/// `{"user": "<property>", "value": ..}` when the wallpaper exposes it as a user setting, and
/// `{"value": .., "animation": {..}}` when it is keyframed. Decoding only the bare form dropped
/// both — which left layers the author had switched off drawing at full opacity, and gave
/// animated layers no placement at all.
///
/// Note that an animated field keeps its authored `value` alongside the track, so this only ever
/// needs to read `value`. The keyframe fallback below is for envelopes that omit it, which
/// nothing in this library does but the format does not forbid.
private struct WEWrappedValue<T: Decodable>: Decodable {
    var value: T?

    private struct Keyframe: Decodable {
        var frame: Double?
        var value: T?
    }
    private struct Animation: Decodable {
        var c0: [Keyframe]?
    }
    private enum CodingKeys: String, CodingKey {
        case value, animation, user
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let direct = try? c.decodeIfPresent(T.self, forKey: .value) {
            value = direct
        } else {
            let animation = (try? c.decodeIfPresent(Animation.self, forKey: .animation)) ?? nil
            value = animation?.c0?
                .min(by: { ($0.frame ?? 0) < ($1.frame ?? 0) })?
                .value
        }
        // The authored `value` is only what the property was when the author saved the scene;
        // see `SceneUserProperties` for why the project's own value has to win.
        value = SceneUserProperties.resolve(c, .user, decoder: decoder, authored: value)
    }
}

/// Decode a scene field in whichever of the three shapes it happens to use.
///
/// Generic over the key type because the object's own fields are not the only place the shapes
/// turn up: a particle layer's `instanceoverride` wraps its numbers the same way.
private func flexible<T: Decodable, K: CodingKey>(
    _ type: T.Type,
    _ container: KeyedDecodingContainer<K>,
    _ key: K
) -> T? {
    if let plain = try? container.decodeIfPresent(T.self, forKey: key) {
        return plain
    }
    return ((try? container.decodeIfPresent(WEWrappedValue<T>.self, forKey: key)) ?? nil)?.value
}

/// The JavaScript behind a field, when the author bound a script to it. Sits in the same
/// `{"script": .., "value": ..}` wrapper the keyframe and user shapes use.
private func script(
    _ container: KeyedDecodingContainer<WESceneObject.CodingKeys>,
    _ key: WESceneObject.CodingKeys
) -> String? {
    ((try? container.decodeIfPresent(WEScriptWrapper.self, forKey: key)) ?? nil)?.script
}

/// The settings that script was left on, when the author exposed any.
private func scriptProperties(
    _ container: KeyedDecodingContainer<WESceneObject.CodingKeys>,
    _ key: WESceneObject.CodingKeys
) -> [String: WEScriptPropertyValue]? {
    ((try? container.decodeIfPresent(WEScriptWrapper.self, forKey: key)) ?? nil)?.scriptproperties
}

private struct WEScriptWrapper: Decodable {
    var script: String?
    var scriptproperties: [String: WEScriptPropertyValue]?
    private enum CodingKeys: String, CodingKey { case script, scriptproperties }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        script = (try? c.decodeIfPresent(String.self, forKey: .script)) ?? nil
        scriptproperties = (try? c.decodeIfPresent([String: WEScriptPropertyValue].self,
                                                   forKey: .scriptproperties)) ?? nil
    }
}

/// The keyframe track behind a field, when it has one. Returns nil for the plain and
/// user-wrapped shapes, which is most fields in most wallpapers.
private func track(
    _ container: KeyedDecodingContainer<WESceneObject.CodingKeys>,
    _ key: WESceneObject.CodingKeys
) -> WEAnimationTrack? {
    ((try? container.decodeIfPresent(WEAnimationEnvelope.self, forKey: key)) ?? nil)?.animation
}

/// Same lenient read for `general`, whose camera settings are bare in some wallpapers and
/// user-wrapped in others.
private func flexibleGeneral<T: Decodable>(
    _ type: T.Type,
    _ container: KeyedDecodingContainer<WESceneGeneral.CodingKeys>,
    _ key: WESceneGeneral.CodingKeys
) -> T? {
    if let plain = try? container.decodeIfPresent(T.self, forKey: key) {
        return plain
    }
    return ((try? container.decodeIfPresent(WEGeneralWrappedValue<T>.self, forKey: key)) ?? nil)?.value
}

private struct WEGeneralWrappedValue<T: Decodable>: Decodable {
    var value: T?
    private enum CodingKeys: String, CodingKey { case value, user }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = (try? c.decodeIfPresent(T.self, forKey: .value)) ?? nil
        value = SceneUserProperties.resolve(c, .user, decoder: decoder, authored: value)
    }
}

struct WESceneObject: Decodable {
    // Common
    var id: Int?
    var name: String?
    var origin: String?
    var scale: String?
    var angles: String?
    var visible: Bool?
    /// Id of the object this one is positioned relative to, if any.
    var parent: Int?

    // Keyframe tracks, kept alongside the authored values they animate. See `SceneAnimation`.
    var originTrack: WEAnimationTrack?
    var scaleTrack: WEAnimationTrack?
    var anglesTrack: WEAnimationTrack?
    var alphaTrack: WEAnimationTrack?

    // Image objects
    var image: String?       // path to model JSON
    /// First entry of `instance.textures`: the texture an instanced model draws for this object.
    var instanceTexture: String?
    var alpha: Double?
    var brightness: Double?
    var color: String?
    var colorBlendMode: Int?
    var size: String?
    var alignment: String?
    var solid: Bool?
    var copybackground: Bool?
    var parallaxDepth: String?
    var perspective: Bool?

    // Particle objects
    var particle: String?    // path to particle JSON
    var instanceoverride: WEInstanceOverride?

    // Text objects. See `SceneTextLayer` for how these are laid out and rasterised.
    var text: String?
    /// The JavaScript behind an animated string, when the author bound one. Kept beside `text`
    /// rather than replacing it: Wallpaper Engine bakes the last value the script produced into
    /// `value`, and that baked string is what the layer shows until the script is evaluated.
    var textScript: String?
    /// The slider positions and toggles the user left that script on.
    var textScriptProperties: [String: WEScriptPropertyValue]?
    /// Scripts bound to the layer's visibility and opacity. Only read for what they decide with
    /// no media playing — see `SceneScriptRuntime.hiddenWithNoMedia`.
    var visibleScript: String?
    var visibleScriptProperties: [String: WEScriptPropertyValue]?
    var alphaScript: String?
    var alphaScriptProperties: [String: WEScriptPropertyValue]?
    /// Script bound to the layer's position, and its settings. Only evaluated when it is a pure
    /// function of those settings — see `SceneScriptRuntime.staticOrigin`.
    var originScript: String?
    var originScriptProperties: [String: WEScriptPropertyValue]?
    /// Script bound to the layer's scale. Only ever run live, and only when it is clock-driven —
    /// see `SceneScriptRuntime.liveProperties`.
    var scaleScript: String?
    var scaleScriptProperties: [String: WEScriptPropertyValue]?
    /// Every script bound to any of the object's fields, the five above included. Only read to
    /// find layers whose sprite-sheet frame a script chooses (see
    /// `SceneWallpaperViewModel.scriptedTextureAnimations`): a switch's script sits wherever its
    /// author put it — Lost Landscape's day/night switch drives its frame from `angles` — and a
    /// list of known fields would miss the next one.
    var allScripts: [String] = []
    var font: String?
    var pointsize: Double?
    var horizontalalign: String?
    var verticalalign: String?
    var backgroundcolor: String?
    var opaquebackground: Bool?
    /// Whether the text wraps at `maxwidth`. Off — or absent — on 348 of the library's 386 text
    /// objects, and there `size` is only the extent of the baked string, not a wrapping bound.
    var limitwidth: Bool?
    var maxwidth: Double?
    /// Whether the text is cut to `maxrows` lines; `limituseellipsis` ends the cut with "…".
    var limitrows: Bool?
    var maxrows: Double?
    var limituseellipsis: Bool?

    /// Post-processing chain applied to this layer. See `SceneEffectBuilder`.
    var effects: [WESceneEffect]?

    enum CodingKeys: String, CodingKey {
        case id, name, origin, scale, angles, visible, parent
        case image, instance, alpha, brightness, color, colorBlendMode, size, alignment
        case solid, copybackground, parallaxDepth, perspective
        case particle, instanceoverride, effects
        case text, font, pointsize, horizontalalign, verticalalign
        case backgroundcolor, opaquebackground
        case limitwidth, maxwidth, limitrows, maxrows, limituseellipsis
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Fields that are always simple types
        id = try? c.decodeIfPresent(Int.self, forKey: .id)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        parent = try? c.decodeIfPresent(Int.self, forKey: .parent)
        image = try? c.decodeIfPresent(String.self, forKey: .image)
        instanceTexture = ((try? c.decodeIfPresent(WEInstanceTextures.self, forKey: .instance)) ?? nil)?
            .textures?.first ?? nil
        particle = try? c.decodeIfPresent(String.self, forKey: .particle)
        instanceoverride = try? c.decodeIfPresent(WEInstanceOverride.self, forKey: .instanceoverride)

        // Fields that may be bare, user-wrapped, or keyframed — see `flexible`.
        origin = flexible(String.self, c, .origin)
        scale = flexible(String.self, c, .scale)
        angles = flexible(String.self, c, .angles)
        visible = flexible(Bool.self, c, .visible)
        alpha = flexible(Double.self, c, .alpha)
        brightness = flexible(Double.self, c, .brightness)
        color = flexible(String.self, c, .color)
        colorBlendMode = flexible(Int.self, c, .colorBlendMode)
        size = flexible(String.self, c, .size)
        alignment = flexible(String.self, c, .alignment)
        solid = try? c.decodeIfPresent(Bool.self, forKey: .solid)
        copybackground = try? c.decodeIfPresent(Bool.self, forKey: .copybackground)
        // Flexible since the user-property resolver: one object in this library binds its depth
        // to a slider, and the bare String read dropped that field, authored value and all.
        parallaxDepth = flexible(String.self, c, .parallaxDepth)
        perspective = try? c.decodeIfPresent(Bool.self, forKey: .perspective)

        text = flexible(String.self, c, .text)
        textScript = script(c, .text)
        textScriptProperties = scriptProperties(c, .text)
        visibleScript = script(c, .visible)
        visibleScriptProperties = scriptProperties(c, .visible)
        alphaScript = script(c, .alpha)
        alphaScriptProperties = scriptProperties(c, .alpha)
        originScript = script(c, .origin)
        originScriptProperties = scriptProperties(c, .origin)
        scaleScript = script(c, .scale)
        scaleScriptProperties = scriptProperties(c, .scale)
        if let any = try? decoder.container(keyedBy: AnyFieldKey.self) {
            allScripts = any.allKeys.compactMap {
                ((try? any.decodeIfPresent(WEScriptWrapper.self, forKey: $0)) ?? nil)?.script
            }
        }
        font = try? c.decodeIfPresent(String.self, forKey: .font)
        pointsize = flexible(Double.self, c, .pointsize)
        horizontalalign = flexible(String.self, c, .horizontalalign)
        verticalalign = flexible(String.self, c, .verticalalign)
        backgroundcolor = flexible(String.self, c, .backgroundcolor)
        opaquebackground = flexible(Bool.self, c, .opaquebackground)
        // User-wrappable like everything else here: Honkai binds `maxwidth` to a property.
        limitwidth = flexible(Bool.self, c, .limitwidth)
        maxwidth = flexible(Double.self, c, .maxwidth)
        limitrows = flexible(Bool.self, c, .limitrows)
        maxrows = flexible(Double.self, c, .maxrows)
        limituseellipsis = flexible(Bool.self, c, .limituseellipsis)

        originTrack = track(c, .origin)
        scaleTrack = track(c, .scale)
        anglesTrack = track(c, .angles)
        alphaTrack = track(c, .alpha)

        effects = try? c.decodeIfPresent([WESceneEffect].self, forKey: .effects)
    }
}

/// An object's `instance` block, read for its textures only. Entries are null where the material's
/// own texture stands, so they decode as optionals.
private struct WEInstanceTextures: Decodable {
    var textures: [String?]?
    private enum CodingKeys: String, CodingKey { case textures }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        textures = (try? c.decodeIfPresent([String?].self, forKey: .textures)) ?? nil
    }
}

// MARK: - Effects

/// One entry of an object's `effects` array: which effect, and how this instance is configured.
struct WESceneEffect: Decodable {
    /// Path to the effect's own `effect.json`, e.g. `effects/tint/effect.json`.
    var file: String?
    var name: String?
    var visible: Bool?
    /// Per-pass configuration, positionally matched to the effect file's own passes.
    var passes: [WESceneEffectPass]?

    private enum CodingKeys: String, CodingKey { case file, name, visible, passes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try? c.decodeIfPresent(String.self, forKey: .file)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        // `visible` is user-wrappable here exactly as it is on an object.
        if let plain = try? c.decodeIfPresent(Bool.self, forKey: .visible) {
            visible = plain
        } else {
            visible = ((try? c.decodeIfPresent(WEVisibilityWrapper.self, forKey: .visible)) ?? nil)?.value
        }
        passes = try? c.decodeIfPresent([WESceneEffectPass].self, forKey: .passes)
    }
}

private struct WEVisibilityWrapper: Decodable {
    var value: Bool?
    private enum CodingKeys: String, CodingKey { case value, user }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = (try? c.decodeIfPresent(Bool.self, forKey: .value)) ?? nil
        value = SceneUserProperties.resolve(c, .user, decoder: decoder, authored: value)
    }
}

struct WESceneEffectPass: Decodable {
    /// Compile-time variant selectors, beating the shader's own `[COMBO]` defaults.
    var combos: [String: Int]?
    /// Uniform overrides, keyed by the uniform annotation's `material` name — or occasionally by
    /// its localisation label, which is why binding tries both.
    var constantshadervalues: [String: WEShaderValue]?
    /// Texture per sampler slot. Slot 0 is null: that is the layer being processed.
    var textures: [String?]?

    private enum CodingKeys: String, CodingKey { case combos, constantshadervalues, textures }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        combos = try? c.decodeIfPresent([String: Int].self, forKey: .combos)
        constantshadervalues = try? c.decodeIfPresent([String: WEShaderValue].self,
                                                      forKey: .constantshadervalues)
        textures = try? c.decodeIfPresent([String?].self, forKey: .textures)
    }
}

/// A uniform override, written bare or wrapped in `{"value": ..}`, as a number, a string of
/// space-separated numbers, or a bool.
struct WEShaderValue: Decodable {
    var components: [Float]

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer() {
            if let d = try? single.decode(Double.self) { components = [Float(d)]; return }
            if let b = try? single.decode(Bool.self) { components = [b ? 1 : 0]; return }
            if let s = try? single.decode(String.self) {
                components = s.split(separator: " ").compactMap { Float($0) }
                return
            }
        }
        let keyed = try decoder.container(keyedBy: AnyKey.self)
        guard let key = AnyKey(stringValue: "value") else { components = []; return }
        if let d = try? keyed.decode(Double.self, forKey: key) { components = [Float(d)] }
        else if let b = try? keyed.decode(Bool.self, forKey: key) { components = [b ? 1 : 0] }
        else if let s = try? keyed.decode(String.self, forKey: key) {
            components = s.split(separator: " ").compactMap { Float($0) }
        } else { components = [] }
        // 323 of the library's user bindings sit here, and 90 of them differ from the project:
        // Samurai's moon tint is authored red and set white, Hacker Apartment's grain and sharpen
        // are authored on and set to 0. Routed through a string so a slider bound to a vector
        // uniform widens to the authored component count the same way an object field does.
        if let user = AnyKey(stringValue: "user"),
           let resolved: String = SceneUserProperties.resolve(
               keyed, user, decoder: decoder,
               authored: components.map { "\($0)" }.joined(separator: " ")) {
            components = resolved.split(separator: " ").compactMap { Float($0) }
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// An effect bundle's own manifest: the ordered passes it applies.
struct WEEffectFile: Decodable {
    var passes: [Pass]?
    struct Pass: Decodable {
        var material: String?
        /// The render target this pass writes to, named `_rt_…`. Absent means it draws in place,
        /// which for the last pass of every effect is the layer itself.
        var target: String?
        /// Targets this pass reads. A pass binding two of them is a combine — it wants both the
        /// result of an earlier pass and something else, usually the untouched layer.
        var bind: [Bind]?
        struct Bind: Decodable {
            var name: String?
            var index: Int?
        }
    }
}

/// How this object's copy of a shared particle preset differs from the preset.
///
/// Wallpaper Engine ships a handful of particle systems — `particles/presets/smoke1.json`,
/// `raindownpour.json`, `fog2.json` — and a scene places the same preset a dozen times over,
/// each copy tuned by one of these blocks. 418 of this library's 493 particle objects carry one,
/// across 58 scenes, so the block is the normal case and not a rarity.
///
/// Every numeric field is a *multiplier* on what the preset declares, not a replacement. The
/// library's values run from 0.03 to 20 and `alpha` reaches 5, which only makes sense as a scale
/// factor.
///
/// Reading only `rate` and `size` from it is what buried The Batman's frame under white smoke:
/// its three `Smoke cloud` layers are authored at `alpha: 0.06` and tinted red, and without those
/// two fields they emitted at full opacity in the preset's own white, at 600 px a puff scaled 3×
/// by the object — half the frame, in artwork the author had made all but invisible.
///
/// Every field can arrive bare or wrapped as `{"user": .., "value": ..}` — Batman counts its
/// lightning bolts through a user slider. That matters more than it looks: the struct decodes as
/// a whole, so one wrapped field on a `Double?` used to throw and take the *entire* override with
/// it, silently, including the `rate` that was decoding fine. 23 objects across 8 scenes were
/// losing every field that way.
struct WEInstanceOverride: Decodable {
    var id: Int?
    /// Particle tint, normalised 0–1. `color` is the same thing written 0–255; both spellings
    /// occur, 171 of the first and 11 of the second.
    var colorn: String?
    var color: String?
    var rate: Double?
    var size: Double?
    var alpha: Double?
    /// Scales `maxcount`, the preset's ceiling on how many particles may be alive at once.
    var count: Double?
    var speed: Double?
    var lifetime: Double?
    var brightness: Double?

    enum CodingKeys: String, CodingKey {
        case id, colorn, color, rate, size, alpha, count, speed, lifetime, brightness
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decodeIfPresent(Int.self, forKey: .id)
        colorn = flexible(String.self, c, .colorn)
        color = flexible(String.self, c, .color)
        rate = flexible(Double.self, c, .rate)
        size = flexible(Double.self, c, .size)
        alpha = flexible(Double.self, c, .alpha)
        count = flexible(Double.self, c, .count)
        speed = flexible(Double.self, c, .speed)
        lifetime = flexible(Double.self, c, .lifetime)
        brightness = flexible(Double.self, c, .brightness)
    }
}

// MARK: - Model / Material

struct WEModel: Codable {
    var autosize: Bool?
    var material: String?    // path to material JSON
}

/// A material file, decoded one field at a time.
///
/// This used to be a synthesised `Codable`, which made the whole material a single point of
/// failure: one field in an unexpected shape threw past the struct and the material came back
/// nil. Every caller treats a nil material as "this layer has nothing to draw", so the failure
/// never surfaced as an error — an image layer logged `No texture in material`, a particle
/// system lost its sprite, and an effect pass was counted as untranslatable. The field that did
/// it was `textures`, declared `[String]` while Wallpaper Engine writes `null` into every slot
/// the material leaves to the scene: `waterripple` ships `[null, null,
/// "effects/waterripplenormal"]`, `waterflow` `[null, null, "effects/waterflowphase"]`,
/// `refraction` `[null, "effects/refractnormal"]`. Those three effects alone are placed in 36
/// scenes of this library, and 39 carry some material with a null slot — Road Infinite lost an
/// image layer to one. It is the same trap the particle structs keep falling into — a
/// field that is usually one shape and sometimes another — so every field is read with `try?`
/// and a bad one costs only itself.
struct WEMaterial: Decodable {
    var passes: [WEMaterialPass]?

    private enum CodingKeys: String, CodingKey { case passes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        passes = (try? c.decodeIfPresent([WEMaterialPass].self, forKey: .passes)) ?? nil
    }
}

struct WEMaterialPass: Decodable {
    var blending: String?    // "translucent", "additive"
    var shader: String?
    /// One entry per sampler slot, `nil` where the material leaves the slot to the scene or to
    /// the shader's own annotation. Slot 0 is the layer's own texture.
    var textures: [String?]?
    var cullmode: String?
    var depthtest: String?
    var depthwrite: String?
    /// Compile-time variant selectors baked into the material.
    var combos: [String: Int]?

    private enum CodingKeys: String, CodingKey {
        case blending, shader, textures, cullmode, depthtest, depthwrite, combos
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blending = (try? c.decodeIfPresent(String.self, forKey: .blending)) ?? nil
        shader = (try? c.decodeIfPresent(String.self, forKey: .shader)) ?? nil
        textures = (try? c.decodeIfPresent([String?].self, forKey: .textures)) ?? nil
        cullmode = (try? c.decodeIfPresent(String.self, forKey: .cullmode)) ?? nil
        depthtest = (try? c.decodeIfPresent(String.self, forKey: .depthtest)) ?? nil
        depthwrite = (try? c.decodeIfPresent(String.self, forKey: .depthwrite)) ?? nil
        combos = (try? c.decodeIfPresent([String: Int].self, forKey: .combos)) ?? nil
    }
}

// MARK: - Particle System

struct WEParticleSystem: Codable {
    var emitter: [WEParticleEmitter]?
    var initializer: [WEParticleInitializer]?
    var `operator`: [WEParticleOperator]?
    var renderer: [WEParticleRenderer]?
    var material: String?
    var maxcount: Int?
    var flags: Int?
    var starttime: Double?
    var animationmode: String?
    var sequencemultiplier: Double?
    /// Further systems this one carries along — `ember` brings `emberglow`, `torch` brings
    /// `torchembers`. Wrapped rather than declared `[WEParticleChild]?` because a synthesised
    /// array fails as a unit, and a failure here would not cost the children, it would cost the
    /// whole `WEParticleSystem` and the parent layer with it — the trap `distancemax` documents.
    var children: WEParticleChildren?
}

/// A particle system's `children`, decoded so that nothing about them can fail the parent.
/// Presets with none write `"children": null`, which is an absent value, not an error; an entry
/// that is not an object at all is dropped on its own.
struct WEParticleChildren: Codable {
    var entries: [WEParticleChild]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode([WELenient<WEParticleChild>].self)) ?? []
        entries = raw.compactMap(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }
}

/// One element of an array that may be malformed without taking its siblings down with it.
struct WELenient<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// One entry of `children`: another particle system file, and how it hangs off its parent.
///
/// `type` is what decides whether SpriteKit can draw it at all. `static` (also what an entry
/// with no `type` means) is a second system placed with the parent and sharing its transform;
/// `eventfollow`, `eventspawn` and `eventdeath` attach a system to every *particle* of the parent
/// — a trail that follows each spark, a splash where each drop lands. See `childSystems`.
///
/// The placement fields are relative to the parent system and default to identity. None of the
/// library's 50 static children writes any of them — only `id` — but the event kinds do, and
/// nothing stops an author editing a static one.
struct WEParticleChild: Codable {
    var name: String?
    var type: String?
    var origin: String?
    var scale: String?
    var angles: String?
    /// Replaces the child preset's own `maxcount`. Written by 62 of the 87 event children and
    /// none of the static ones.
    var maxcount: Int?

    private enum CodingKeys: String, CodingKey {
        case name, type, origin, scale, angles, maxcount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil
        origin = (try? c.decodeIfPresent(String.self, forKey: .origin)) ?? nil
        scale = (try? c.decodeIfPresent(String.self, forKey: .scale)) ?? nil
        angles = (try? c.decodeIfPresent(String.self, forKey: .angles)) ?? nil
        // `Int(_:)` traps on a non-finite or out-of-range Double, and `WEFlexValue` reads its
        // strings through `Double(_:)`, which accepts "inf" and "nan" — one malformed Workshop
        // preset would take down the whole app at scene load. `Int(exactly:)` of the rounded
        // value cannot trap.
        maxcount = ((try? c.decodeIfPresent(WEFlexValue.self, forKey: .maxcount)) ?? nil)
            .flatMap { Int(exactly: $0.doubleValue.rounded()) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeIfPresent(scale, forKey: .scale)
        try c.encodeIfPresent(angles, forKey: .angles)
        try c.encodeIfPresent(maxcount, forKey: .maxcount)
    }
}

struct WEParticleEmitter: Codable {
    var id: Int?
    var name: String?
    var rate: Double?
    var origin: String?
    var directions: String?
    /// Emission extent. A `sphererandom` emitter writes a plain radius; a `boxrandom` one writes
    /// per-axis half-extents as `"1920 1080 0"`.
    ///
    /// Declaring these `Double?` made every box emitter's file fail to decode — and because the
    /// failure is at the level of the whole `WEParticleSystem`, the layer vanished rather than
    /// degrading. 25 of the 94 particle systems in this library, across 26 scenes, lost their
    /// snow, rain and embers to this one field.
    var distancemax: WEFlexValue?
    var distancemin: WEFlexValue?
    var speedmax: Double?
    var speedmin: Double?
    /// How many particles the emitter releases at once when it starts, as opposed to `rate`'s
    /// steady stream. Only an event child's emitter uses it — `shootingstarglow` writes
    /// `"instantaneous": 1, "rate": 0`, one particle per parent particle and no more — and it is
    /// read only to recognise that shape; see `SceneWallpaperViewModel.mergeRider`. Flexible for
    /// the reason `distancemax` documents.
    var instantaneous: WEFlexValue?
}

struct WEParticleInitializer: Codable {
    var id: Int?
    var name: String?
    var min: WEFlexValue?
    var max: WEFlexValue?
    /// `turbulentvelocityrandom` writes its speed as a pair of scalars instead of a min/max
    /// vector. `WEFlexValue` rather than `Double?` for the reason `distancemax` documents: a
    /// throwing field here deletes the whole particle system, not just the field.
    var speedmin: WEFlexValue?
    var speedmax: WEFlexValue?
}

/// A value that can be either a number or a string (e.g. "0 -3000 0")
enum WEFlexValue: Codable {
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let num = try? container.decode(Double.self) {
            self = .number(num)
        } else if let str = try? container.decode(String.self) {
            self = .string(str)
        } else {
            self = .number(0)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        }
    }

    var doubleValue: Double {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s) ?? 0
        }
    }

    var vectorValue: (Double, Double, Double) {
        switch self {
        case .number(let n): return (n, n, n)
        case .string(let s): return s.parseVector3()
        }
    }
}

struct WEParticleOperator: Codable {
    var id: Int?
    var name: String?
    var gravity: String?
    var drag: Double?
    var fadeintime: Double?
    var fadeouttime: Double?
    /// `sizechange` ramps a particle's scale across a window of its life. All four fields are
    /// optional and every one of them defaults to a no-op — a bare `{"name": "sizechange"}`
    /// changes nothing, and 4 of the library's 72 uses are exactly that.
    ///
    /// `WEFlexValue` and not `Double?`, because these four names are shared with `colorchange`,
    /// which writes colours into them: `"startvalue": "1 0.749 0"`. Typed as a number that
    /// throws, and the throw is not local — it fails `WEParticleOperator`, which fails the
    /// operator array, which fails the whole `WEParticleSystem`, and the layer disappears
    /// instead of degrading. Declaring them `Double?` cost 30 emitters across 7 scenes in the
    /// run that caught it: dragon - flames dropped from 33 nodes to 21. Same trap `distancemax`
    /// above already carries a warning about.
    var starttime: WEFlexValue?
    var endtime: WEFlexValue?
    var startvalue: WEFlexValue?
    var endvalue: WEFlexValue?
    /// The `turbulence` operator's speed band — the only place the `ember` presets write a speed
    /// at all; see `buildParticleNode`. Flexible for the same reason as the four above.
    var speedmin: WEFlexValue?
    var speedmax: WEFlexValue?
}

struct WEParticleRenderer: Codable {
    var id: Int?
    var name: String?       // "sprite", "spritetrail"
    var length: Double?
    var maxlength: Double?
}

// MARK: - String Parsing Helpers

extension String {
    /// Parse "x y z" space-separated vector string
    func parseVector3() -> (Double, Double, Double) {
        let parts = self.split(separator: " ").compactMap { Double($0) }
        return (
            parts.count > 0 ? parts[0] : 0,
            parts.count > 1 ? parts[1] : 0,
            parts.count > 2 ? parts[2] : 0
        )
    }

    /// Parse "x y" space-separated 2D vector
    func parseVector2() -> (Double, Double) {
        let parts = self.split(separator: " ").compactMap { Double($0) }
        return (
            parts.count > 0 ? parts[0] : 0,
            parts.count > 1 ? parts[1] : 0
        )
    }

    /// Parse "r g b" color string (0-1 range) to NSColor
    func parseColor() -> (r: Double, g: Double, b: Double) {
        let v = self.parseVector3()
        return (r: v.0, g: v.1, b: v.2)
    }
}

/// Any field name, for walking an object's keys without listing them.
struct AnyFieldKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
