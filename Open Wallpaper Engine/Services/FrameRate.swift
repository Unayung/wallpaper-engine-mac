//
//  FrameRate.swift
//  Open Wallpaper Engine
//
//  The frame rates a display can actually deliver, so the FPS setting can only name one.
//

import AppKit

enum FrameRate {
    static let minimum = 10

    /// Rates the display paces evenly: its refresh rate divided by a whole number.
    ///
    /// SKView does not run at an arbitrary `preferredFramesPerSecond`; it rounds the request up
    /// to the next such divisor. Measured on a 60 Hz display, 16 fps ran at 20.9 updates a
    /// second and 25 at 31.0, so a slider offering every integer was showing numbers that were
    /// never the rate delivered.
    static func options(refresh: Int, upTo ceiling: Int = 120) -> [Int] {
        let refresh = max(refresh, minimum)
        return (1...refresh)
            .filter { refresh % $0 == 0 }
            .map { refresh / $0 }
            .filter { $0 >= minimum && $0 <= ceiling }
            .sorted()
    }

    /// The deliverable rate nearest to `requested`. A tie goes to the higher one, because that is
    /// what SKView itself delivers for it (it rounds a request up to the next divisor; see
    /// `options`) — so a saved rate halfway between two, such as 25 on a 60 Hz display, keeps
    /// running at the 30 it always did rather than dropping to 20.
    static func deliverable(_ requested: Double, refresh: Int) -> Int {
        let choices = options(refresh: refresh)
        guard !choices.isEmpty else { return max(Int(requested.rounded()), minimum) }
        return choices.min { a, b in
            let da = abs(Double(a) - requested), db = abs(Double(b) - requested)
            return da == db ? a > b : da < db
        } ?? choices[0]
    }

    /// For the display a view is on, or the main one.
    static func deliverable(_ requested: Double, on screen: NSScreen?) -> Int {
        deliverable(requested, refresh: (screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60)
    }
}
