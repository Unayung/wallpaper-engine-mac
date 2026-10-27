//
//  SceneAnimation.swift
//  Open Wallpaper Engine
//
//  Keyframe tracks from scene.json, and their evaluation at a point in time.
//

import Foundation

/// A curve handle on one side of a keyframe.
///
/// Wallpaper Engine's editor emits one on each side of every keyframe with an `enabled` flag.
/// The overwhelmingly common pair is `front {x: 1, y: 0}` / `back {x: -1, y: 0}` — a flat
/// tangent, which turns the segment into a plain ease-in-out — but 99 of the enabled handles in
/// this library carry a real slope, so they cannot be assumed away.
///
/// `x` is a **fraction of the segment**, not a count of frames: every observed value falls in
/// [-1, 1] while segments run to thousands of frames, and `y` tracks the segment's own value
/// delta. Reading `x` as frames makes the tangent term scale with the segment length instead of
/// cancelling against it, which sent a 5634-frame sun track 150,000 units off screen.
struct WETangent: Decodable {
    var enabled: Bool?
    var x: Double?
    var y: Double?

    /// The Hermite tangent term for this handle — the slope already multiplied by the segment
    /// length, so it is in plain value units. `nil` when this side of the segment is linear.
    ///
    /// Slope is `y / (x · span)`, so `span · slope` collapses to `y / x` and the segment length
    /// drops out. The back handle points backwards in time, so both of its components are
    /// negated and the quotient still comes out with the right sign.
    var tangentTerm: Double? {
        guard enabled == true, let x, let y, abs(x) > 1e-9 else { return nil }
        return y / x
    }
}

struct WEKeyframe: Decodable {
    var frame: Double
    var value: Double
    var front: WETangent?
    var back: WETangent?

    private enum CodingKeys: String, CodingKey { case frame, value, front, back }

    init(frame: Double, value: Double, front: WETangent?, back: WETangent?) {
        self.frame = frame
        self.value = value
        self.front = front
        self.back = back
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = (try? c.decodeIfPresent(Double.self, forKey: .frame)) ?? 0
        value = (try? c.decodeIfPresent(Double.self, forKey: .value)) ?? 0
        front = (try? c.decodeIfPresent(WETangent.self, forKey: .front)) ?? nil
        back = (try? c.decodeIfPresent(WETangent.self, forKey: .back)) ?? nil
    }
}

enum WEAnimationMode: String {
    /// Play once and hold the last keyframe. Intro fades and one-shot reveals use this.
    case single
    /// Wrap back to the start of the timeline.
    case loop
    /// Ping-pong between the ends. Breathing scales and swaying layers use this.
    case mirror
}

/// One animated property: up to three channels of keyframes plus the timeline they run on.
///
/// The property itself keeps its authored value alongside the track — Wallpaper Engine writes
/// `{"value": .., "animation": {..}}` — and `relative` decides whether the track replaces that
/// value or is added to it. Both forms are in use, and reading one as the other either pins a
/// layer to the origin or launches it off the frame.
struct WEAnimationTrack {
    /// Keyframes per channel: 0 is x, 1 is y, 2 is z. A scalar property such as `alpha` only
    /// fills channel 0.
    let channels: [[WEKeyframe]]
    /// Timeline rate. Usually 30, but it is a genuine float — one wallpaper runs a hundred-second
    /// flight path at 0.6 fps.
    let fps: Double
    /// Timeline length in frames, which is not necessarily the last keyframe's frame.
    let length: Double
    let mode: WEAnimationMode
    /// Whether channel values are offsets from the property's authored value.
    let relative: Bool
    /// Wallpaper Engine parks a track here when the cursor, not the clock, is meant to drive it —
    /// hover and click reactions. This renderer has no such trigger, so a paused track stays on
    /// its first frame rather than playing itself unprompted.
    let startPaused: Bool
}

// MARK: - Decoding

extension WEAnimationTrack: Decodable {
    private enum CodingKeys: String, CodingKey {
        case c0, c1, c2, options, relative
    }

    private struct Options: Decodable {
        var fps: Double?
        var length: Double?
        var mode: String?
        var startpaused: Bool?
        var wraploop: Bool?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let options = (try? c.decodeIfPresent(Options.self, forKey: .options)) ?? nil

        fps = options?.fps ?? 30
        length = options?.length ?? 0
        mode = WEAnimationMode(rawValue: options?.mode ?? "") ?? .single
        relative = ((try? c.decodeIfPresent(Bool.self, forKey: .relative)) ?? nil) ?? false
        startPaused = options?.startpaused ?? false

        var decoded: [[WEKeyframe]] = []
        for key in [CodingKeys.c0, .c1, .c2] {
            var keys = ((try? c.decodeIfPresent([WEKeyframe].self, forKey: key)) ?? [])
                .sorted { $0.frame < $1.frame }
            // A wrapping loop closes the curve: repeating the opening keyframe at the end of the
            // timeline makes the last segment ease back to the start instead of cutting to it.
            if options?.wraploop == true, mode == .loop,
               let first = keys.first, let last = keys.last, last.frame < length {
                keys.append(WEKeyframe(frame: length, value: first.value,
                                       front: first.front, back: first.back))
            }
            decoded.append(keys)
        }
        channels = decoded

        guard decoded.contains(where: { !$0.isEmpty }) else {
            throw DecodingError.dataCorruptedError(forKey: .c0, in: c,
                                                   debugDescription: "animation has no keyframes")
        }
    }
}

/// The `{"value": .., "animation": {..}}` envelope Wallpaper Engine writes for an animated
/// property, decoded for the track alone — the authored value is read separately, by the same
/// lenient path that reads every non-animated property.
struct WEAnimationEnvelope: Decodable {
    var animation: WEAnimationTrack?

    private enum CodingKeys: String, CodingKey { case animation }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        animation = (try? c.decodeIfPresent(WEAnimationTrack.self, forKey: .animation)) ?? nil
    }
}

// MARK: - Evaluation

extension WEAnimationTrack {
    /// Where on the timeline, in frames, a wall-clock offset since the wallpaper loaded lands.
    func frame(atSeconds seconds: Double) -> Double {
        guard !startPaused, fps > 0, length > 0 else { return 0 }
        let f = seconds * fps
        switch mode {
        case .single:
            return min(f, length)
        case .loop:
            return f.truncatingRemainder(dividingBy: length)
        case .mirror:
            let p = f.truncatingRemainder(dividingBy: length * 2)
            return p <= length ? p : length * 2 - p
        }
    }

    /// Channel `index` at a timeline position, or `nil` when that channel carries no keyframes.
    ///
    /// Segments are cubic Hermite, which is what the editor's handles describe. A handle that is
    /// disabled or degenerate falls back to the segment's own linear slope, so a track authored
    /// without curves interpolates straight.
    func value(channel index: Int, atFrame f: Double) -> Double? {
        guard channels.indices.contains(index) else { return nil }
        let keys = channels[index]
        guard let first = keys.first, let last = keys.last else { return nil }
        if f <= first.frame { return first.value }
        if f >= last.frame { return last.value }

        var lower = 0
        while lower + 1 < keys.count - 1, keys[lower + 1].frame <= f { lower += 1 }
        let a = keys[lower], b = keys[lower + 1]

        let span = b.frame - a.frame
        guard span > 0 else { return b.value }
        let u = (f - a.frame) / span

        // Tangent terms are `span × slope`; a straight segment's is just its value delta.
        let linear = b.value - a.value
        let m0 = a.front?.tangentTerm ?? linear
        let m1 = b.back?.tangentTerm ?? linear

        let u2 = u * u, u3 = u2 * u
        return (2 * u3 - 3 * u2 + 1) * a.value
             + (u3 - 2 * u2 + u) * m0
             + (-2 * u3 + 3 * u2) * b.value
             + (u3 - u2) * m1
    }

    /// All three channels at once, falling back to `base` per component for channels the track
    /// does not drive.
    func vector(atSeconds seconds: Double, base: (Double, Double, Double)) -> (Double, Double, Double) {
        let f = frame(atSeconds: seconds)
        let offset = relative ? base : (0.0, 0.0, 0.0)
        return (
            value(channel: 0, atFrame: f).map { offset.0 + $0 } ?? base.0,
            value(channel: 1, atFrame: f).map { offset.1 + $0 } ?? base.1,
            value(channel: 2, atFrame: f).map { offset.2 + $0 } ?? base.2
        )
    }

    /// Channel 0 alone, for scalar properties such as `alpha`.
    func scalar(atSeconds seconds: Double, base: Double) -> Double {
        let f = frame(atSeconds: seconds)
        guard let v = value(channel: 0, atFrame: f) else { return base }
        return relative ? base + v : v
    }
}
