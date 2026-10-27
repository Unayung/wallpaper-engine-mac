//
//  WEProject.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/5.
//

import SwiftUI
import ImageIO

struct WEProjectPropertyOption: Codable, Equatable, Hashable {
    var label: String
    var value: String
}

struct WEProjectProperty: Codable, Equatable, Hashable {
    // optional
    var condition: String?
    var index: Int?
    var options: [WEProjectPropertyOption]?
    var order: Int?
    
    // must have
    var text: String
    var type: String
    var value: String
}

struct WEProjectProperties: Codable, Equatable, Hashable {
    var schemecolor: WEProjectProperty?
}

struct WEProjectGeneral: Codable, Equatable, Hashable {
    var properties: WEProjectProperties
}

enum WorkshopId: Codable, Equatable, Hashable, RawRepresentable {
    case int(Int)
    case string(String)
    
    var rawValue: String {
        switch self {
        case .int(let x):
            return String(x)
        case .string(let x):
            return x
        }
    }
    
    init?(rawValue: String) {
        guard rawValue.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        self = .string(rawValue)
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let x = try? container.decode(Int.self) {
            self = .int(x)
            return
        }
        if let x = try? container.decode(String.self) {
            self = .string(x)
            return
        }
        throw DecodingError.typeMismatch(Self.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Wrong type for Workshop ID"))
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let x):
            try container.encode(x)
        case .string(let x):
            try container.encode(x)
        }
    }
}

struct WEProject: Codable, Equatable, Hashable {
    var approved: Bool?
    var contentrating: String?
    var description: String?
    var file: String
    var general: WEProjectGeneral?
    var preview: String
    var tags: [String]?
    var title: String
    var visibility: String?
    var workshopid: WorkshopId?
    var workshopurl: String?
    var type: String
    var version: Int?
    
    static let invalid = Self(file: "",
                              preview: "",
                              title: "Error",
                              type: "video")

    /// Which of the app's renderers draws this wallpaper, or nil when none does.
    ///
    /// `type` is whatever the Workshop author's copy of Wallpaper Engine wrote, and it is not
    /// consistently cased: of the 61 video and web wallpapers in the library this was measured
    /// against, one says `"Video"` and three say `"Web"`. `WallpaperView` always lowercased it
    /// before dispatching, so those rendered — but the unsafe-wallpaper gate in
    /// `WallpaperViewModel.nextCurrentWallpaper` compared it verbatim, so the three `"Web"` pages
    /// were applied with no warning and never entered `TrustedWallpapers`, and the menu-bar
    /// placeholder in `AppDelegate.setPlacehoderWallpaper` skipped the `"Video"` one. Ask this
    /// instead of comparing `type` by hand, so every caller agrees on what a type is.
    var renderer: WERenderer? { WERenderer(rawValue: type.lowercased()) }

    /// Types that run author-supplied code, and so must be on the `TrustedWallpapers` allowlist
    /// before they are applied. `application` has no renderer but is still gated: being unable to
    /// draw it is no reason to skip the warning.
    var runsUntrustedCode: Bool { ["web", "application"].contains(type.lowercased()) }
}

enum WERenderer: String {
    case video, scene, web
}

/// Edits single values inside a wallpaper's `project.json` in place.
///
/// Encoding `WEProject` back to disk is lossy: the struct models only a handful of keys,
/// so a round-trip silently drops `ratingsex`, `ratingviolence`, every user property in
/// `general.properties` other than `schemecolor`, and anything else a Workshop author put
/// there. These helpers touch one field and leave the rest of the document untouched.
enum ProjectJSONPatch {
    /// Overwrite `general.properties.schemecolor.value`. Returns false when the wallpaper
    /// has no scheme colour to change, or the file could not be read or written.
    @discardableResult
    static func setSchemeColor(_ value: String, inWallpaperAt directory: URL) -> Bool {
        mutate(inWallpaperAt: directory) { root in
            guard var general = root["general"] as? [String: Any],
                  var properties = general["properties"] as? [String: Any],
                  var scheme = properties["schemecolor"] as? [String: Any]
            else { return false }

            scheme["value"] = value
            properties["schemecolor"] = scheme
            general["properties"] = properties
            root["general"] = general
            return true
        }
    }

    /// Overwrite the `tags` array.
    @discardableResult
    static func setTags(_ tags: [String], inWallpaperAt directory: URL) -> Bool {
        mutate(inWallpaperAt: directory) { root in
            root["tags"] = tags
            return true
        }
    }

    /// Overwrite `title`.
    @discardableResult
    static func setTitle(_ title: String, inWallpaperAt directory: URL) -> Bool {
        mutate(inWallpaperAt: directory) { root in
            root["title"] = title
            return true
        }
    }

    /// Read project.json as a plain dictionary, hand it to `change`, write it back if that
    /// returned true. Untouched keys survive verbatim.
    private static func mutate(
        inWallpaperAt directory: URL,
        _ change: (inout [String: Any]) -> Bool
    ) -> Bool {
        let url = directory.appending(path: "project.json")
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }

        guard change(&root) else { return false }

        guard let out = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        ) else { return false }

        do {
            try out.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

struct WEWallpaper: Codable, RawRepresentable, Identifiable {
    
    var id: Int { self.project.hashValue }
    var rawValue: String {
        do {
            let rawValueData = try JSONEncoder().encode(self)
            return String(data: rawValueData, encoding: .utf8)!
        } catch {
            print(error)
            return ""
        }
    }
    
    var wallpaperDirectory: URL
    var project: WEProject
    
    var wallpaperSize: Int {
        // Resolved first: library entries are often symlinks into Steam's workshop folder
        // (130 of 162 in the measured library), and a symlink is not a directory to
        // `directoryTotalAllocatedSize`, so every one of them reported 0 bytes.
        guard let sizeBytes = try? self.wallpaperDirectory.resolvingSymlinksInPath()
            .directoryTotalAllocatedSize(includingSubfolders: true)
        else { return 0 }
        return sizeBytes
    }
    
    /// The preview image named by the project, or the bundled not-found placeholder for a
    /// folder whose project.json did not decode.
    var previewURL: URL {
        guard project != .invalid, !project.preview.isEmpty else {
            return Bundle.main.url(forResource: "WallpaperNotFound", withExtension: "mp4")!
        }
        return wallpaperDirectory.appending(path: project.preview)
    }

    init(using project: WEProject, where url: URL) {
        self.wallpaperDirectory = url
        self.project = project
    }
    
    enum CodingKeys: CodingKey {
        case wallpaperDirectory
        case project
        // <all the other elements too>
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.wallpaperDirectory = try container.decode(URL.self, forKey: .wallpaperDirectory)
        self.project = try container.decode(WEProject.self, forKey: .project)
        // <and so on>
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wallpaperDirectory, forKey: .wallpaperDirectory)
        try container.encode(project, forKey: .project)
        // <and so on>
    }
    
    init?(rawValue: String) {
        if let rawValueData = rawValue.data(using: .utf8),
           let wallpaper = try? JSONDecoder().decode(WEWallpaper.self, from: rawValueData) {
            self = wallpaper
        } else {
            return nil
        }
    }
}

enum WEWallpaperSortingMethod: String, CaseIterable, Identifiable {
    
    var id: Self { self }
    
    case name = "Name"
    case rating = "Rating"
//    case favorite = "Favorite"
    case fileSize = "File Size"
//    case subDate = "Subscription Date"
//    case lastUpdated = "Last Updated"
}

enum WEWallpaperSortingSequence: Int {
    case decrease = 0, increase = 1
}

enum WEInitError: Error {
    enum WEJSONProjectInitError: Error {
        case notFound, corrupted, mismatched, unkownError
    }
    
    enum WEResourcesInitError: Error {
        case notFound, mismatchedFormat, corrupted, unkownError
    }
    
    enum WEPreviewInitError: Error {
        case notFound, notImage, unkownError
    }
    
    case badDirectoryPath
    case JSONProject(was: WEJSONProjectInitError)
    case resources(was: WEResourcesInitError)
    case preview(was: WEPreviewInitError)
}
