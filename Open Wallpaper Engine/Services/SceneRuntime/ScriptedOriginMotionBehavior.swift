//
//  ScriptedOriginMotionBehavior.swift
//  Open Wallpaper Engine
//
//  Safely recognizes common origin-property motion without executing
//  downloaded Wallpaper Engine JavaScript.
//

import Foundation

enum ScriptedOriginWrapBoundary: Equatable {
    case lessThan(Double)
    case lessThanOrEqual(Double)
    case greaterThan(Double)
    case greaterThanOrEqual(Double)
}

struct ScriptedOriginVerticalOscillation: Equatable {
    let step: Double
    let amplitude: Double
}

struct ScriptedOriginMotionConfiguration: Equatable {
    let horizontalStep: Double
    let alternateHorizontalStep: Double?
    let alternateWhenXGreaterThan: Double?
    let wrapBoundary: ScriptedOriginWrapBoundary?
    let restartX: Double?
    let verticalOscillation: ScriptedOriginVerticalOscillation?
    let randomYRange: ClosedRange<Double>?
}

enum SceneScriptConstantsParser {
    static func parse(_ scripts: [String]) -> [String: Double] {
        let number = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
        let pattern =
            #"\bshared\.([A-Za-z_]\w*)\s*=\s*("# + number + #")\s*(?:;|$)"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines]
        ) else {
            return [:]
        }

        var constants: [String: Double] = [:]
        for script in scripts {
            let range = NSRange(script.startIndex..<script.endIndex, in: script)
            for match in expression.matches(in: script, range: range) {
                guard
                    let nameRange = Range(match.range(at: 1), in: script),
                    let value = captureDouble(match, group: 2, in: script),
                    value.isFinite
                else {
                    continue
                }
                constants[String(script[nameRange])] = value
            }
        }
        return constants
    }
}

enum ScriptedOriginMotionParser {
    static func parse(
        _ script: String,
        constants: [String: Double]
    ) -> ScriptedOriginMotionConfiguration? {
        let horizontalSteps = parseHorizontalSteps(script, constants: constants)
        guard !horizontalSteps.isEmpty else { return nil }

        let alternateBoundary = captureDouble(
            #"if\s*\(\s*value\.x\s*>\s*("# + number + #")\s*\)"#,
            in: script,
            group: 1
        )
        let horizontalStep: Double
        let alternateStep: Double?
        if horizontalSteps.count >= 2, alternateBoundary != nil {
            alternateStep = horizontalSteps[0]
            horizontalStep = horizontalSteps[1]
        } else {
            alternateStep = nil
            horizontalStep = horizontalSteps[0]
        }

        let wrap = parseWrap(in: script)
        let vertical = parseVerticalOscillation(in: script)
        let randomRange = parseRandomYRange(in: script)

        guard
            horizontalStep.isFinite,
            alternateStep?.isFinite != false,
            alternateBoundary?.isFinite != false,
            wrap.restartX?.isFinite != false
        else {
            return nil
        }

        return ScriptedOriginMotionConfiguration(
            horizontalStep: horizontalStep,
            alternateHorizontalStep: alternateStep,
            alternateWhenXGreaterThan: alternateStep == nil ? nil : alternateBoundary,
            wrapBoundary: wrap.boundary,
            restartX: wrap.restartX,
            verticalOscillation: vertical,
            randomYRange: randomRange
        )
    }

    private static let number = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#

    private static func parseHorizontalSteps(
        _ script: String,
        constants: [String: Double]
    ) -> [Double] {
        let pattern =
            #"value\.x\s*(?:=\s*value\.x\s*([+-])|([+-])=)\s*(?:shared\.([A-Za-z_]\w*)(?:\s*\*\s*("#
            + number + #"))?|("# + number + #"))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(script.startIndex..<script.endIndex, in: script)
        return expression.matches(in: script, range: range).compactMap { match in
            let operatorText = captureString(match, group: 1, in: script)
                ?? captureString(match, group: 2, in: script)
            guard let operatorText else {
                return nil
            }

            let magnitude: Double
            if let constantName = captureString(match, group: 3, in: script) {
                guard let constant = constants[constantName] else { return nil }
                let factor = captureDouble(match, group: 4, in: script) ?? 1
                magnitude = constant * factor
            } else if let literal = captureDouble(match, group: 5, in: script) {
                magnitude = literal
            } else {
                return nil
            }
            let sign = operatorText == "-" ? -1.0 : 1.0
            let result = sign * magnitude
            return result.isFinite ? result : nil
        }
    }

    private static func parseWrap(
        in script: String
    ) -> (boundary: ScriptedOriginWrapBoundary?, restartX: Double?) {
        let pattern =
            #"if\s*\(\s*value\.x\s*([<>]=?)\s*("# + number
            + #")\s*\)\s*\{\s*value\.x\s*=\s*("# + number + #")"#
        guard
            let match = firstMatch(pattern, in: script),
            let comparison = captureString(match, group: 1, in: script),
            let threshold = captureDouble(match, group: 2, in: script),
            let restartX = captureDouble(match, group: 3, in: script)
        else {
            return (nil, nil)
        }

        let boundary: ScriptedOriginWrapBoundary
        switch comparison {
        case "<":
            boundary = .lessThan(threshold)
        case "<=":
            boundary = .lessThanOrEqual(threshold)
        case ">":
            boundary = .greaterThan(threshold)
        case ">=":
            boundary = .greaterThanOrEqual(threshold)
        default:
            return (nil, nil)
        }
        return (boundary, restartX)
    }

    private static func parseVerticalOscillation(
        in script: String
    ) -> ScriptedOriginVerticalOscillation? {
        guard
            let move = captureDouble(
                #"\bvar\s+move\s*=\s*("# + number + #")"#,
                in: script,
                group: 1
            ),
            let direction = captureString(
                #"value\.y\s*=\s*value\.y\s*([+-])\s*move"#,
                in: script,
                group: 1
            ),
            let amplitudeMultiplier = captureDouble(
                #"\bvar\s+r\s*=\s*("# + number + #")\s*\*\s*move"#,
                in: script,
                group: 1
            ),
            script.range(
                of: #"move\s*=\s*-move"#,
                options: .regularExpression
            ) != nil
        else {
            return nil
        }

        let step = (direction == "-" ? -1.0 : 1.0) * move
        let amplitude = abs(amplitudeMultiplier * move)
        guard step.isFinite, amplitude.isFinite, amplitude > 0 else { return nil }
        return ScriptedOriginVerticalOscillation(step: step, amplitude: amplitude)
    }

    private static func parseRandomYRange(
        in script: String
    ) -> ClosedRange<Double>? {
        let pattern =
            #"begin_y\s*=\s*\(\s*Math\.random\(\)\s*\*\s*\(\s*("#
            + number + #")\s*-\s*("# + number
            + #")\s*\+\s*1\s*\)\s*\)\s*\+\s*("# + number + #")"#
        guard
            let match = firstMatch(pattern, in: script),
            let upper = captureDouble(match, group: 1, in: script),
            let lower = captureDouble(match, group: 2, in: script),
            let offset = captureDouble(match, group: 3, in: script),
            lower == offset,
            lower <= upper
        else {
            return nil
        }
        return lower...upper
    }
}

protocol ScriptedOriginMotionRandomSource: AnyObject {
    func nextUnit() -> Double
}

final class SystemScriptedOriginMotionRandomSource:
    ScriptedOriginMotionRandomSource
{
    func nextUnit() -> Double {
        Double.random(in: 0..<1)
    }
}

final class ScriptedOriginMotionController {
    private static let sourceFrameDuration = 1.0 / 30.0

    private(set) var position: MotionItemPosition
    private let configuration: ScriptedOriginMotionConfiguration
    private let randomSource: ScriptedOriginMotionRandomSource
    private var accumulatedTime = 0.0
    private var verticalCenter: Double
    private var verticalStep: Double

    init(
        configuration: ScriptedOriginMotionConfiguration,
        initialPosition: MotionItemPosition,
        randomSource: ScriptedOriginMotionRandomSource =
            SystemScriptedOriginMotionRandomSource()
    ) {
        self.configuration = configuration
        self.position = initialPosition
        self.randomSource = randomSource
        self.verticalCenter = initialPosition.y
        self.verticalStep = configuration.verticalOscillation?.step ?? 0
    }

    @discardableResult
    func update(deltaTime: Double) -> MotionItemPosition {
        guard deltaTime > 0 else { return position }
        accumulatedTime += min(deltaTime, 0.25)

        while accumulatedTime + 0.000_000_001 >= Self.sourceFrameDuration {
            accumulatedTime -= Self.sourceFrameDuration
            advanceOneSourceFrame()
        }
        return position
    }

    private func advanceOneSourceFrame() {
        if
            let boundary = configuration.alternateWhenXGreaterThan,
            let alternateStep = configuration.alternateHorizontalStep,
            position.x > boundary
        {
            position.x += alternateStep
        } else {
            position.x += configuration.horizontalStep
        }

        if let vertical = configuration.verticalOscillation {
            position.y += verticalStep
            if abs(position.y - verticalCenter) > vertical.amplitude {
                verticalStep = -verticalStep
            }
        }

        guard
            hasCrossedWrapBoundary,
            let restartX = configuration.restartX
        else {
            return
        }
        position.x = restartX

        if let range = configuration.randomYRange {
            let unit = min(max(randomSource.nextUnit(), 0), 1)
            position.y = range.lowerBound
                + (range.upperBound - range.lowerBound) * unit
            verticalCenter = position.y
        }
    }

    private var hasCrossedWrapBoundary: Bool {
        switch configuration.wrapBoundary {
        case .lessThan(let boundary):
            return position.x < boundary
        case .lessThanOrEqual(let boundary):
            return position.x <= boundary
        case .greaterThan(let boundary):
            return position.x > boundary
        case .greaterThanOrEqual(let boundary):
            return position.x >= boundary
        case nil:
            return false
        }
    }
}

private func firstMatch(
    _ pattern: String,
    in source: String
) -> NSTextCheckingResult? {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
        return nil
    }
    return expression.firstMatch(
        in: source,
        range: NSRange(source.startIndex..<source.endIndex, in: source)
    )
}

private func captureString(
    _ match: NSTextCheckingResult,
    group: Int,
    in source: String
) -> String? {
    guard
        match.range(at: group).location != NSNotFound,
        let range = Range(match.range(at: group), in: source)
    else {
        return nil
    }
    return String(source[range])
}

private func captureString(
    _ pattern: String,
    in source: String,
    group: Int
) -> String? {
    guard let match = firstMatch(pattern, in: source) else { return nil }
    return captureString(match, group: group, in: source)
}

private func captureDouble(
    _ match: NSTextCheckingResult,
    group: Int,
    in source: String
) -> Double? {
    captureString(match, group: group, in: source).flatMap(Double.init)
}

private func captureDouble(
    _ pattern: String,
    in source: String,
    group: Int
) -> Double? {
    captureString(pattern, in: source, group: group).flatMap(Double.init)
}
