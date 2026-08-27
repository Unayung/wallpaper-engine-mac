//
//  SceneModels.swift
//  Open Wallpaper Engine
//
//  Data models for Wallpaper Engine scene.json structure.
//  Decoded from scene.pkg → scene.json and referenced JSON files.
//

import Foundation

// MARK: - Top-level Scene

struct WEScene: Codable {
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

struct WESceneGeneral: Codable {
    var clearcolor: String?
    var orthogonalprojection: WEOrthogonalProjection?
    var ambientcolor: String?
    var skylightcolor: String?

    // These fields can be Bool, Int, or an object {"user":..,"value":..} in different wallpapers.
    // We only need the String fields above for rendering, so skip strict decoding of the rest.

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Use try? because these fields can be plain strings OR {"user":..,"value":..} objects
        clearcolor = try? container.decodeIfPresent(String.self, forKey: .clearcolor)
        orthogonalprojection = try? container.decodeIfPresent(WEOrthogonalProjection.self, forKey: .orthogonalprojection)
        ambientcolor = try? container.decodeIfPresent(String.self, forKey: .ambientcolor)
        skylightcolor = try? container.decodeIfPresent(String.self, forKey: .skylightcolor)
    }

    enum CodingKeys: String, CodingKey {
        case clearcolor, orthogonalprojection, ambientcolor, skylightcolor
    }
}

struct WEOrthogonalProjection: Codable {
    var width: Int
    var height: Int
}

// MARK: - Scene Objects

/// Wallpaper Engine stores many scene values either directly or in a
/// {"script":"...","value":...} wrapper. Preserve both forms without executing
/// downloaded scripts.
struct WEScriptedValue<Value: Codable>: Codable {
    var value: Value?
    var script: String?

    init(value: Value?, script: String? = nil) {
        self.value = value
        self.script = script
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let plainValue = try? single.decode(Value.self) {
            value = plainValue
            script = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decodeIfPresent(Value.self, forKey: .value)
        script = try container.decodeIfPresent(String.self, forKey: .script)
    }

    func encode(to encoder: Encoder) throws {
        if script == nil, let value {
            var single = encoder.singleValueContainer()
            try single.encode(value)
            return
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(script, forKey: .script)
    }

    private enum CodingKeys: String, CodingKey {
        case value, script
    }
}

struct WESceneObject: Codable {
    // Common
    var id: Int?
    var parent: Int?
    var name: String?
    private var originValue: WEScriptedValue<String>?
    private var scaleValue: WEScriptedValue<String>?
    var angles: String?
    private var visibleValue: WEScriptedValue<Bool>?

    // Image objects
    var image: String?       // path to model JSON
    private var alphaValue: WEScriptedValue<Double>?
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

    // Sound / effects
    var sound: [String]?
    var effects: [WEEffect]?

    var origin: String? { originValue?.value }
    var originScript: String? { originValue?.script }
    var scale: String? { scaleValue?.value }
    var scaleScript: String? { scaleValue?.script }
    var visible: Bool? { visibleValue?.value }
    var visibleScript: String? { visibleValue?.script }
    var alpha: Double? { alphaValue?.value }
    var alphaScript: String? { alphaValue?.script }

    enum CodingKeys: String, CodingKey {
        case id, parent, name, origin, scale, angles, visible
        case image, alpha, brightness, color, colorBlendMode, size, alignment
        case solid, copybackground, parallaxDepth, perspective
        case particle, instanceoverride
        case sound, effects
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Fields that are always simple types
        id = try? c.decodeIfPresent(Int.self, forKey: .id)
        parent = try? c.decodeIfPresent(Int.self, forKey: .parent)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        image = try? c.decodeIfPresent(String.self, forKey: .image)
        particle = try? c.decodeIfPresent(String.self, forKey: .particle)
        instanceoverride = try? c.decodeIfPresent(WEInstanceOverride.self, forKey: .instanceoverride)
        sound = try? c.decodeIfPresent([String].self, forKey: .sound)
        effects = try? c.decodeIfPresent([WEEffect].self, forKey: .effects)

        // Fields that may be simple values or {"script":..,"value":..} objects
        originValue = try? c.decodeIfPresent(WEScriptedValue<String>.self, forKey: .origin)
        scaleValue = try? c.decodeIfPresent(WEScriptedValue<String>.self, forKey: .scale)
        angles = try? c.decodeIfPresent(String.self, forKey: .angles)
        visibleValue = try? c.decodeIfPresent(WEScriptedValue<Bool>.self, forKey: .visible)
        alphaValue = try? c.decodeIfPresent(WEScriptedValue<Double>.self, forKey: .alpha)
        brightness = try? c.decodeIfPresent(Double.self, forKey: .brightness)
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        colorBlendMode = try? c.decodeIfPresent(Int.self, forKey: .colorBlendMode)
        size = try? c.decodeIfPresent(String.self, forKey: .size)
        alignment = try? c.decodeIfPresent(String.self, forKey: .alignment)
        solid = try? c.decodeIfPresent(Bool.self, forKey: .solid)
        copybackground = try? c.decodeIfPresent(Bool.self, forKey: .copybackground)
        parallaxDepth = try? c.decodeIfPresent(String.self, forKey: .parallaxDepth)
        perspective = try? c.decodeIfPresent(Bool.self, forKey: .perspective)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(parent, forKey: .parent)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(originValue, forKey: .origin)
        try c.encodeIfPresent(scaleValue, forKey: .scale)
        try c.encodeIfPresent(angles, forKey: .angles)
        try c.encodeIfPresent(visibleValue, forKey: .visible)
        try c.encodeIfPresent(image, forKey: .image)
        try c.encodeIfPresent(alphaValue, forKey: .alpha)
        try c.encodeIfPresent(brightness, forKey: .brightness)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(colorBlendMode, forKey: .colorBlendMode)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(alignment, forKey: .alignment)
        try c.encodeIfPresent(solid, forKey: .solid)
        try c.encodeIfPresent(copybackground, forKey: .copybackground)
        try c.encodeIfPresent(parallaxDepth, forKey: .parallaxDepth)
        try c.encodeIfPresent(perspective, forKey: .perspective)
        try c.encodeIfPresent(particle, forKey: .particle)
        try c.encodeIfPresent(instanceoverride, forKey: .instanceoverride)
        try c.encodeIfPresent(sound, forKey: .sound)
        try c.encodeIfPresent(effects, forKey: .effects)
    }
}

struct WEEffect: Codable {
    var file: String?
    var id: Int?
    var name: String?
    var passes: [WEEffectPass]?
    private var visibleValue: WEScriptedValue<Bool>?

    var visible: Bool? { visibleValue?.value }
    var visibleScript: String? { visibleValue?.script }

    private enum CodingKeys: String, CodingKey {
        case file, id, name, passes, visible
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try? c.decodeIfPresent(String.self, forKey: .file)
        id = try? c.decodeIfPresent(Int.self, forKey: .id)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        passes = try? c.decodeIfPresent([WEEffectPass].self, forKey: .passes)
        visibleValue = try? c.decodeIfPresent(WEScriptedValue<Bool>.self, forKey: .visible)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(file, forKey: .file)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(passes, forKey: .passes)
        try c.encodeIfPresent(visibleValue, forKey: .visible)
    }
}

struct WEEffectPass: Codable {
    var id: Int?
    var constantShaderValues: WEEffectShaderValues?
    var textures: [String?]?

    private enum CodingKeys: String, CodingKey {
        case id
        case constantShaderValues = "constantshadervalues"
        case textures
    }
}

struct WEEffectShaderValues: Codable {
    var repeatValue: String?
    var speedX: Double?
    var speedY: Double?
    var alpha: Double?

    private enum CodingKeys: String, CodingKey {
        case repeatValue = "repeat"
        case speedX = "speedx"
        case speedY = "speedy"
        case alpha
    }
}

struct WEInstanceOverride: Codable {
    var id: Int?
    var colorn: String?
    var rate: WEScriptValue?
    var size: Double?
}

struct WEScriptValue: Codable {
    var script: String?
    var value: Double?

    init(from decoder: Decoder) throws {
        // Can be just a number or an object with script+value
        if let container = try? decoder.singleValueContainer(),
           let num = try? container.decode(Double.self) {
            self.value = num
            self.script = nil
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.script = try container.decodeIfPresent(String.self, forKey: .script)
            self.value = try container.decodeIfPresent(Double.self, forKey: .value)
        }
    }

    enum CodingKeys: String, CodingKey {
        case script, value
    }
}

// MARK: - Model / Material

struct WEModel: Codable {
    var autosize: Bool?
    var material: String?    // path to material JSON
}

struct WEMaterial: Codable {
    var passes: [WEMaterialPass]?
}

struct WEMaterialPass: Codable {
    var blending: String?    // "translucent", "additive"
    var shader: String?
    var textures: [String]?
    var combos: [String: Int]?
    var cullmode: String?
    var depthtest: String?
    var depthwrite: String?
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
}

struct WEParticleEmitter: Codable {
    var id: Int?
    var name: String?
    var rate: Double?
    var origin: String?
    var directions: String?
    var distancemax: Double?
    var distancemin: Double?
    var speedmax: Double?
    var speedmin: Double?
}

struct WEParticleInitializer: Codable {
    var id: Int?
    var name: String?
    var min: WEFlexValue?
    var max: WEFlexValue?
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
