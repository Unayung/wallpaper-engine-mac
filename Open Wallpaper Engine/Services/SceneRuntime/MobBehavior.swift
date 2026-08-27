//
//  MobBehavior.swift
//  Open Wallpaper Engine
//
//  Recognizes the declarative Mob configuration used by MapleStory scene
//  wallpapers and reproduces it natively without executing Workshop scripts.
//

import Foundation

struct MobBehaviorConfiguration: Equatable {
    let lowerBound: Double
    let upperBound: Double
    let moveFrames: [Int]
    let standFrames: [Int]
    let speed: Double
    let jumpFrame: Int?
}

enum MobScriptParser {
    static func parse(_ script: String) -> MobBehaviorConfiguration? {
        guard script.contains("new shared.Mob") else { return nil }

        guard
            let rangeText = capture(
                #"range\s*:\s*\[\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+))\s*,\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+))\s*\]"#,
                in: script,
                group: 0
            ),
            let rangeMatch = firstMatch(
                #"range\s*:\s*\[\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+))\s*,\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+))\s*\]"#,
                in: rangeText
            ),
            let lower = doubleCapture(rangeMatch, group: 1, in: rangeText),
            let upper = doubleCapture(rangeMatch, group: 2, in: rangeText),
            lower <= upper,
            let moveFrames = parseFrameList(named: "moveList", in: script),
            let standFrames = parseFrameList(named: "standList", in: script),
            !moveFrames.isEmpty,
            !standFrames.isEmpty
        else {
            return nil
        }

        let speed = parseNumber(named: "speed", in: script) ?? 1
        let jumpFrame = parseNumber(named: "jumpFrame", in: script).map { Int($0) }

        return MobBehaviorConfiguration(
            lowerBound: lower,
            upperBound: upper,
            moveFrames: moveFrames,
            standFrames: standFrames,
            speed: speed,
            jumpFrame: jumpFrame
        )
    }

    private static func parseFrameList(named name: String, in script: String) -> [Int]? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"\#(escapedName)\s*:\s*\[([^\]]*)\]"#
        guard
            let match = firstMatch(pattern, in: script),
            let range = Range(match.range(at: 1), in: script)
        else {
            return nil
        }

        return script[range]
            .split(separator: ",")
            .compactMap { token in
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let value = Double(trimmed) else { return nil }
                return Int(value)
            }
    }

    private static func parseNumber(named name: String, in script: String) -> Double? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"\#(escapedName)\s*:\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+))"#
        guard let match = firstMatch(pattern, in: script) else { return nil }
        return doubleCapture(match, group: 1, in: script)
    }

    private static func capture(
        _ pattern: String,
        in source: String,
        group: Int
    ) -> String? {
        guard
            let match = firstMatch(pattern, in: source),
            let range = Range(match.range(at: group), in: source)
        else {
            return nil
        }
        return String(source[range])
    }

    private static func firstMatch(_ pattern: String, in source: String) -> NSTextCheckingResult? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.firstMatch(in: source, range: range)
    }

    private static func doubleCapture(
        _ match: NSTextCheckingResult,
        group: Int,
        in source: String
    ) -> Double? {
        guard let range = Range(match.range(at: group), in: source) else {
            return nil
        }
        return Double(source[range])
    }
}

protocol MobRandomSource: AnyObject {
    func nextUnit() -> Double
}

final class SystemMobRandomSource: MobRandomSource {
    func nextUnit() -> Double {
        Double.random(in: 0..<1)
    }
}

enum MobActivity: Equatable {
    case moving
    case standing
}

struct MobControllerState: Equatable {
    var x: Double
    var direction: Int
    var activity: MobActivity
    var frame: Int
    var remainingStateTime: Double
}

final class MobController {
    private static let updateInterval = 1.0 / 30.0

    let configuration: MobBehaviorConfiguration
    private(set) var state: MobControllerState

    private let randomSource: MobRandomSource
    private var accumulatedTime = 0.0
    private var moveFrameIndex = 0
    private var standFrameIndex = 0

    init(
        configuration: MobBehaviorConfiguration,
        randomSource: MobRandomSource = SystemMobRandomSource(),
        initialX: Double? = nil,
        initialDirection: Int? = nil,
        initiallyMoving: Bool? = nil
    ) {
        self.configuration = configuration
        self.randomSource = randomSource

        let moving = initiallyMoving ?? (randomSource.nextUnit() > 0.5)
        let direction = initialDirection ?? (randomSource.nextUnit() > 0.5 ? 1 : -1)
        let requestedX: Double
        if let initialX {
            requestedX = initialX
        } else {
            requestedX = configuration.lowerBound
                + (configuration.upperBound - configuration.lowerBound)
                * clampedUnit(randomSource.nextUnit())
        }
        let x = min(
            max(requestedX, configuration.lowerBound),
            configuration.upperBound
        )
        let initialFrame = moving
            ? configuration.moveFrames[0]
            : configuration.standFrames[0]

        state = MobControllerState(
            x: x,
            direction: direction >= 0 ? 1 : -1,
            activity: moving ? .moving : .standing,
            frame: initialFrame,
            remainingStateTime: Self.randomDuration(using: randomSource)
        )
    }

    @discardableResult
    func update(deltaTime: Double) -> MobControllerState {
        guard deltaTime > 0 else { return state }

        accumulatedTime += min(deltaTime, 1)
        while accumulatedTime + 0.000_000_1 >= Self.updateInterval {
            step()
            accumulatedTime -= Self.updateInterval
        }
        return state
    }

    private func step() {
        switch state.activity {
        case .moving:
            if state.x <= configuration.lowerBound {
                state.x = configuration.lowerBound
                state.direction = -1
            } else if state.x >= configuration.upperBound {
                state.x = configuration.upperBound
                state.direction = 1
            } else if randomSource.nextUnit() < 0.008 {
                state.direction *= -1
            }

            state.x -= Double(state.direction) * configuration.speed
            state.x = min(max(state.x, configuration.lowerBound), configuration.upperBound)
            state.frame = configuration.moveFrames[moveFrameIndex]
            moveFrameIndex = (moveFrameIndex + 1) % configuration.moveFrames.count

        case .standing:
            state.frame = configuration.standFrames[standFrameIndex]
            standFrameIndex = (standFrameIndex + 1) % configuration.standFrames.count
        }

        state.remainingStateTime -= Self.updateInterval
        if state.remainingStateTime <= 0.000_000_1 {
            state.activity = state.activity == .moving ? .standing : .moving
            state.remainingStateTime = Self.randomDuration(using: randomSource)
        }
    }

    private static func randomDuration(using randomSource: MobRandomSource) -> Double {
        let value = clampedUnit(randomSource.nextUnit())
        return Double(min(4, 1 + Int(floor(value * 4))))
    }
}

private func clampedUnit(_ value: Double) -> Double {
    min(max(value, 0), 0.999_999_999)
}
