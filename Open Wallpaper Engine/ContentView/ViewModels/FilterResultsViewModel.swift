//
//  FilterResultsViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

typealias FilterResultsViewModel = ContentViewModel

protocol FilterResultsModel: OptionSet where Element == Self, RawValue == Int {
    static var allOptions: [String] { get }
}

struct FRShowOnly: OptionSet {
    let rawValue: Int
    
    static let allOptions = [
        ("Approved", "trophy.fill"),
        ("My Favourites", "heart.fill"),
        ("Mobile Compatible", "iphone.gen3"),
        ("Audio Responsive", ""),
        ("Customizable", "")
    ]
    
    static let approved             = FRShowOnly(rawValue: 1 << 0)
    static let myFavourites         = FRShowOnly(rawValue: 1 << 1)
    static let mobileCompatible     = FRShowOnly(rawValue: 1 << 2)
    static let audioResponsive      = FRShowOnly(rawValue: 1 << 3)
    static let customizable         = FRShowOnly(rawValue: 1 << 4)
    
    static let all: FRShowOnly = [.approved, myFavourites, mobileCompatible, .audioResponsive, .customizable]
    static let none: FRShowOnly = []
}

struct FRType: FilterResultsModel {
    let rawValue: Int
    
    static let allOptions = [
        "Scene",
        "Video",
        "Web",
        "Application"
//        "Wallpaper",
//        "Preset"
    ]
    static let scene            = FRType(rawValue: 1 << 0)
    static let video            = FRType(rawValue: 1 << 1)
    static let web              = FRType(rawValue: 1 << 2)
    static let application      = FRType(rawValue: 1 << 3)
//    static let wallpaper        = FRType(rawValue: 1 << 4)
//    static let preset           = FRType(rawValue: 1 << 5)
    
    static let all: FRType      = [.scene, .video, .web, .application/*, .wallpaper, .preset*/]
    static let none: FRType     = []
}

struct FRAgeRating: FilterResultsModel {
    let rawValue: Int
    
    static let allOptions = [
        "Everyone",
        "Partial Nudity",
        "Mature"
    ]
    
    static let everyone             = FRAgeRating(rawValue: 1 << 0)
    static let partialNudity        = FRAgeRating(rawValue: 1 << 1)
    static let mature               = FRAgeRating(rawValue: 1 << 2)
    
    static let all: FRAgeRating     = [.everyone, .partialNudity, .mature]
    static let none: FRAgeRating    = []
}

// There is no Resolution filter, deliberately. The sidebar used to offer Wallpaper Engine's 21
// resolution boxes (Widescreen 1280x720 … Triple 11520x2160, Standard, Other, Dynamic), greyed
// out and read by nothing. The data does exist — every scene declares
// `general.orthogonalprojection` in its scene.json and every video track has a size, and all 148
// wallpapers in the measured library resolve — but it was declined, for two reasons measured on
// 2026-10-27:
// - Cost. Read uncached, it takes 25–36 ms for the 93 scenes (scene.json out of scene.pkg) and
//   57–61 ms for the 52 videos (AVFoundation track size), against 4.5 ms for the whole library
//   chain, which re-runs on the main thread on every refresh. It would need an index built off
//   the main thread, keyed by path + mtime, and a window in which that index is incomplete.
// - Meaning. Those boxes are Workshop tags an author picks, and Wallpaper Engine's own filter
//   matches the tag, which project.json does not carry. Only 97 of the 148 measured sizes fall on
//   a listed resolution; the other 45 (2499x1406, 3840x6000, 1082x1072, …) would have to land in
//   "Standard" or "Other" by thresholds this app would invent.
// The old FR*Resolution UserDefaults keys are simply no longer read.

/// Where a wallpaper came from. Like Tags (and unlike Type), an empty selection means no
/// restriction, and so does one holding only bits no option uses any more: Wallpaper Engine's
/// third source, "Official", was dropped because nothing in a package says it shipped with
/// Wallpaper Engine (none of the measured library did), and a stored value of just that bit — or
/// the 0 left by unticking both boxes — must not empty the grid. The remaining bits keep their
/// old positions so a stored selection still means what it meant.
struct FRSource: OptionSet {
    let rawValue: Int

    static let workshop        = Self.init(rawValue: 1 << 1)
    static let myWallpapers    = Self.init(rawValue: 1 << 2)

    static let all: Self       = [.workshop, .myWallpapers]
    static let none: Self      = []

    static let options: [(title: LocalizedStringKey, flag: FRSource)] = [
        ("Workshop", .workshop),
        ("My Wallpapers", .myWallpapers)
    ]

    /// Workshop when the manifest names a Workshop id, or the folder is named by one: steamcmd
    /// downloads are imported as `<library>/<workshopid>` and their project.json usually carries
    /// no `workshopid` (76 of the 136 in the measured library), and dragging in steamcmd's own
    /// `workshop/content/431960` folder keeps the same names. Everything else — a bare video, a
    /// zip, a folder of one's own — is the user's.
    static func of(_ wallpaper: WEWallpaper) -> FRSource {
        if wallpaper.project.workshopid != nil { return .workshop }
        return isWorkshopFolderName(wallpaper.wallpaperDirectory.lastPathComponent) ? .workshop : .myWallpapers
    }

    /// Whether a library folder name reads as a Workshop id. "All digits" alone was not enough:
    /// the bare-video import names its folder after the clip and writes a project.json with no
    /// `workshopid`, so `1.mp4` or `20231015.mp4` landed in a numeric folder and was filed under
    /// Workshop — unticking Workshop hid the video just imported. Steam's published-file ids had
    /// passed nine digits years before Wallpaper Engine's Workshop opened (the smallest in the
    /// measured library is 860914166), so anything shorter is the user's. A longer all-digit
    /// clip name (a Unix timestamp) would still pass, which is why `WallpaperImporter` also
    /// refuses to create a folder this test accepts.
    static func isWorkshopFolderName(_ name: String) -> Bool {
        name.count >= 9 && name.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// Workshop genres, matched against project.json's `tags` by `ContentViewModel.genres(of:)`.
/// An empty selection means no restriction (see `filteredWallpapers`). The labels are shown as
/// written and follow the Workshop's spelling: "Pixel Art" normalises to the same key as its
/// "Pixel art" tag, and "Unspecified" is the Workshop's own tag (1 item in the measured
/// library), which the old "UnspecifiedGenre" label never matched by name.
struct FRTag: FilterResultsModel {
    let rawValue: Int

    static let allOptions = [
        "Abstract",
        "Animal",
        "Anime",
        "Cartoon",
        "CGI",
        "Cyberpunk",
        "Fantasy",
        "Game",
        "Girls",
        "Guys",
        "Landscape",
        "Medieval",
        "Memes",
        "MMD",
        "Music",
        "Nature",
        "Pixel Art",
        "Relaxing",
        "Retro",
        "Sci-Fi",
        "Sports",
        "Technology",
        "Television",
        "Vehicle",
        "Unspecified"
    ]
    
    static let abstract             = FRTag(rawValue: 1 << 0)
    static let animal               = FRTag(rawValue: 1 << 1)
    static let anime                = FRTag(rawValue: 1 << 2)
    static let cartoon              = FRTag(rawValue: 1 << 3)
    static let cgi                  = FRTag(rawValue: 1 << 4)
    static let cyberpunk            = FRTag(rawValue: 1 << 5)
    static let fantasy              = FRTag(rawValue: 1 << 6)
    static let game                 = FRTag(rawValue: 1 << 7)
    static let girls                = FRTag(rawValue: 1 << 8)
    static let guys                 = FRTag(rawValue: 1 << 9)
    static let landscape            = FRTag(rawValue: 1 << 10)
    static let medieval             = FRTag(rawValue: 1 << 11)
    static let memes                = FRTag(rawValue: 1 << 12)
    static let mmd                  = FRTag(rawValue: 1 << 13)
    static let music                = FRTag(rawValue: 1 << 14)
    static let nature               = FRTag(rawValue: 1 << 15)
    static let pixelArt             = FRTag(rawValue: 1 << 16)
    static let relaxing             = FRTag(rawValue: 1 << 17)
    static let retro                = FRTag(rawValue: 1 << 18)
    static let sciFi                = FRTag(rawValue: 1 << 19)
    static let sports               = FRTag(rawValue: 1 << 20)
    static let technology           = FRTag(rawValue: 1 << 21)
    static let television           = FRTag(rawValue: 1 << 22)
    static let vehicle              = FRTag(rawValue: 1 << 23)
    static let unspecifiedGenre     = FRTag(rawValue: 1 << 24)
    
    static let all: FRTag = [
        .abstract, .animal, .anime, .cartoon, .cgi, .cyberpunk, .fantasy, .game, .girls,
        .guys, .landscape, .medieval, .memes, .mmd, .music, .nature, .pixelArt, .relaxing,
        .retro, .sciFi, .sports, .technology, .television, .vehicle, .unspecifiedGenre
    ]
    static let none: FRTag = []
}
