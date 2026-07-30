//
//  MotionItemBehavior.swift
//  Open Wallpaper Engine
//
//  Recognizes the declarative MotionItem helper used by scene wallpapers and
//  reproduces its constant-speed wrapping motion without executing JavaScript.
//

import Foundation

enum MotionItemAxis: Equatable {
    case x
    case y
}

struct MotionItemBehaviorConfiguration: Equatable {
    let axis: MotionItemAxis
    let direction: Int
    let speed: Double
    let randomRange: ClosedRange<Double>?
}

enum MotionItemScriptParser {
    static func parse(_ script: String) -> MotionItemBehaviorConfiguration? {
        guard script.contains("new shared.MotionItem") else { return nil }

        let number = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
        let pattern =
            #"new\s+shared\.MotionItem\s*\(\s*thisLayer\s*,\s*(\#(number))\s*,\s*['"](x-|x\+|y-|y\+)['"]\s*(?:,\s*\[\s*(\#(number))\s*,\s*(\#(number))\s*\])?\s*\)"#
        guard
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(
                in: script,
                range: NSRange(script.startIndex..<script.endIndex, in: script)
            ),
            let speed = doubleCapture(match, group: 1, in: script),
            let directionRange = Range(match.range(at: 2), in: script)
        else {
            return nil
        }

        let directionText = String(script[directionRange])
        let axis: MotionItemAxis = directionText.hasPrefix("x") ? .x : .y
        let direction = directionText.hasSuffix("-") ? -1 : 1

        var randomRange: ClosedRange<Double>?
        if
            match.range(at: 3).location != NSNotFound,
            match.range(at: 4).location != NSNotFound,
            let lower = doubleCapture(match, group: 3, in: script),
            let upper = doubleCapture(match, group: 4, in: script)
        {
            guard lower <= upper else { return nil }
            randomRange = lower...upper
        }

        return MotionItemBehaviorConfiguration(
            axis: axis,
            direction: direction,
            speed: speed,
            randomRange: randomRange
        )
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

struct MotionItemSize: Equatable {
    let width: Double
    let height: Double
}

struct MotionItemPosition: Equatable {
    var x: Double
    var y: Double
}

protocol MotionItemRandomSource: AnyObject {
    func nextUnit() -> Double
}

final class SystemMotionItemRandomSource: MotionItemRandomSource {
    func nextUnit() -> Double {
        Double.random(in: 0..<1)
    }
}

final class MotionItemController {
    private static let sourceFrameRate = 30.0

    let configuration: MotionItemBehaviorConfiguration
    private(set) var position: MotionItemPosition

    private let canvasSize: MotionItemSize
    private let itemSize: MotionItemSize
    private let randomSource: MotionItemRandomSource

    init(
        configuration: MotionItemBehaviorConfiguration,
        canvasSize: MotionItemSize,
        itemSize: MotionItemSize,
        initialPosition: MotionItemPosition,
        randomSource: MotionItemRandomSource = SystemMotionItemRandomSource()
    ) {
        self.configuration = configuration
        self.canvasSize = canvasSize
        self.itemSize = itemSize
        self.position = initialPosition
        self.randomSource = randomSource
    }

    @discardableResult
    func update(deltaTime: Double) -> MotionItemPosition {
        guard deltaTime > 0 else { return position }

        let distance = Double(configuration.direction)
            * configuration.speed
            * Self.sourceFrameRate
            * min(deltaTime, 1)

        switch configuration.axis {
        case .x:
            position.x += distance
            if hasPassedEnd(position.x, itemLength: itemSize.width) {
                position.x = restartPosition(
                    canvasLength: canvasSize.width,
                    itemLength: itemSize.width
                )
                randomizePerpendicularPosition(\.y)
            }
        case .y:
            position.y += distance
            if hasPassedEnd(position.y, itemLength: itemSize.height) {
                position.y = restartPosition(
                    canvasLength: canvasSize.height,
                    itemLength: itemSize.height
                )
                randomizePerpendicularPosition(\.x)
            }
        }

        return position
    }

    private func hasPassedEnd(_ value: Double, itemLength: Double) -> Bool {
        let halfLength = itemLength / 2
        if configuration.direction > 0 {
            return value > canvasLengthForAxis + halfLength
        }
        return value < -halfLength
    }

    private var canvasLengthForAxis: Double {
        configuration.axis == .x ? canvasSize.width : canvasSize.height
    }

    private func restartPosition(canvasLength: Double, itemLength: Double) -> Double {
        configuration.direction > 0
            ? -(itemLength / 2)
            : canvasLength + (itemLength / 2)
    }

    private func randomizePerpendicularPosition(
        _ keyPath: WritableKeyPath<MotionItemPosition, Double>
    ) {
        guard let range = configuration.randomRange else { return }
        let unit = min(max(randomSource.nextUnit(), 0), 1)
        position[keyPath: keyPath] = range.lowerBound
            + (range.upperBound - range.lowerBound) * unit
    }
}
