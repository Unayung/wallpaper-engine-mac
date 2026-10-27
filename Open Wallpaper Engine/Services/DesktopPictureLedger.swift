//
//  DesktopPictureLedger.swift
//  Open Wallpaper Engine
//
//  Remembers the user's own desktop picture per screen while the app has replaced it
//  with a still of the playing wallpaper (`staticWP_*.tiff`, which tints the menu bar).
//

import Foundation

/// The bookkeeping half of the desktop-picture swap, free of `NSWorkspace` so the rules
/// can be exercised on their own. `AppDelegate` reads the current pictures, asks this what
/// to remember and what to put back, and does the writing.
///
/// Two rules keep the swap from losing the user's choice, and the single saved URL this
/// replaces broke both. A screen's current picture is only ever treated as ours — kept
/// out of the ledger, and overwritten on restore — when it is a placeholder; any other
/// picture is the user's latest choice, even one made while the app was closed or while
/// it ran, and is never reverted. And everything is per screen, so a second display's
/// own picture is not replaced by the main display's on quit.
enum DesktopPictureLedger {
    static let key = "OSWallpapers"
    /// The single URL written by earlier versions; used once as a fallback, then dropped.
    static let legacyKey = "OSWallpaper"

    static func isPlaceholder(_ url: URL?) -> Bool {
        url?.lastPathComponent.hasPrefix("staticWP_") == true
    }

    static func load(from defaults: UserDefaults = .standard) -> [String: URL] {
        let raw = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return raw.compactMapValues(URL.init(string:))
    }

    static func store(_ ledger: [String: URL], to defaults: UserDefaults = .standard) {
        defaults.set(ledger.mapValues(\.absoluteString), forKey: key)
    }

    /// The ledger after looking at what each screen shows now. Entries for screens not
    /// currently connected are kept, so a display unplugged mid-session still gets its
    /// picture back next time.
    static func capture(current: [String: URL?], into ledger: [String: URL], legacy: URL?) -> [String: URL] {
        var ledger = ledger
        for (screenId, url) in current {
            if let url = url, !isPlaceholder(url) {
                ledger[screenId] = url
            } else if ledger[screenId] == nil, let legacy = legacy, !isPlaceholder(legacy) {
                // A placeholder left on screen by a version that only knew one URL.
                ledger[screenId] = legacy
            }
        }
        return ledger
    }

    /// The picture to put back on each screen: only where ours is showing.
    static func restorations(current: [String: URL?], ledger: [String: URL]) -> [String: URL] {
        var plan: [String: URL] = [:]
        for (screenId, url) in current where isPlaceholder(url) {
            if let original = ledger[screenId] { plan[screenId] = original }
        }
        return plan
    }
}
