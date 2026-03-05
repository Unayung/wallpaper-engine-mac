//
//  ContentViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import AVKit
import SwiftUI
import UniformTypeIdentifiers

class ContentViewModel: ObservableObject, DropDelegate {
    @AppStorage("SortingBy") var sortingBy: WEWallpaperSortingMethod = .name
    @AppStorage("SortingSequence") var sortingSequence: WEWallpaperSortingSequence = .increase
    
    @AppStorage("FRShowOnly")                   public var showOnly                     =                   FRShowOnly.all
    @AppStorage("FRType")                       public var type                         =                       FRType.all
    @AppStorage("FRAgeRating")                  public var ageRating                    =                  FRAgeRating.all
    @AppStorage("FRWidescreenResolution")       public var widescreenResolution         =       FRWidescreenResolution.all
    @AppStorage("FRUltraWidescreenResolution")  public var ultraWidescreenResolution    =  FRUltraWidescreenResolution.all
    @AppStorage("FRDualscreenResolution")       public var dualscreenResolution         =       FRDualscreenResolution.all
    @AppStorage("FRTriplescreenResolution")     public var triplescreenResolution       =     FRTriplescreenResolution.all
    @AppStorage("FRPortraitScreenResolution")   public var potraitscreenResolution      =   FRPortraitScreenResolution.all
    @AppStorage("FRMiscResolution")             public var miscResolution               =             FRMiscResolution.all
    @AppStorage("FRSource")                     public var source                       =                     FRSource.all
    @AppStorage("FRTag")                        public var tag                          =                        FRTag.all
    
    @AppStorage("FilterReveal") var isFilterReveal = false
    @AppStorage("WallpaperURLs") var wallpaperUrls = [URL]()
    @AppStorage("SelectedIndex") var selectedIndex = 0
    
    @AppStorage("ExplorerIconSize") var explorerIconSize: Double = 200
    
    @Published var isDisplaySettingsReveal = false
    @Published var importAlertPresented = false
    @Published var isStaging = false
    
    @Published var topTabBarSelection: Int = 0
    @Published var topTabBarHoverSelection: Int = -1
    
    @Published var imageScaleIndex: Int = -1
    
    @Published var wallpapers = [WEWallpaper]()
    
    @Published var isUnsafeWallpaperWarningPresented = false
    
    @Published var hoveredWallpaper: WEWallpaper?
    
    @Published var isUnsubscribeConfirming = false

    @Published var selectedWallpapers = Set<URL>()
    @Published var isBatchUnsubscribeConfirming = false

    @Published var searchText = ""
    
    @AppStorage("WallpapersPerPage") var wallpapersPerPage: Int = 50
    
    var importAlertError: WPImportError? = nil
    
    convenience init(isStaging: Bool, topTabBarSelection: Int = 0) {
        self.init()
        
        let wallpapers = autoRefreshWallpapers
        
        self.isStaging = isStaging
        self.topTabBarSelection = topTabBarSelection
        self.wallpapers = wallpapers
    }
    
    /// current page index number is starting from '1'
    @Published public var currentPage: Int = 1
//    {
//        willSet {
//            self.currentPage = newValue > self.maxPage ? self.maxPage : newValue
//        }
//    }
    
    private var urls: [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.wallpapersDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else {
            return []
        }
        return contents
    }
    
    /// Show all the wallpaper inside application wallpaper directory, without being filtered
    private var allWallpapers: [WEWallpaper] {
        self.urls.map({ url in
            if let data = try? Data(contentsOf: url.appending(path: "project.json")), let project = try? JSONDecoder().decode(WEProject.self, from: data) {
                return WEWallpaper(using: project, where: url)
            } else {
                return WEWallpaper(using: .invalid, where: url)
            }
        })
    }
    
    private var searchedWallpapers: [WEWallpaper] {
        allWallpapers.filter { wallpaper in
            let project = wallpaper.project
            let searchText = searchText.lowercased()
            
            guard !searchText.isEmpty else { return true }
            
            guard !project.title.lowercased().contains(searchText) else { return true }
            
            guard !project.type.lowercased().contains(searchText) else { return true }
            
            if let description = project.description?.lowercased() {
                guard !description.contains(searchText) else { return true }
            }
            
            if let tags = project.tags {
                guard !tags.allSatisfy({ $0.lowercased().contains(searchText) })
                else { return true }
            }
            
            if let workshopid = project.workshopid {
                guard !workshopid.rawValue.contains(searchText) else { return true }
            }
            
            guard !wallpaper.wallpaperDirectory.lastPathComponent
                .lowercased()
                .contains(searchText) else { return true }
            
            return false
        }
    }
    
    private var filteredWallpapers: [WEWallpaper] {
        searchedWallpapers.filter { wallpaper in

            // Show Only
            var showOnly = FRShowOnly.none
            if let approved = wallpaper.project.approved, approved { showOnly.insert(.approved) }
            guard self.showOnly.contains(showOnly) else { return false }
            
            // Type
            var type = FRType.none
            switch wallpaper.project.type.lowercased() {
            case "video":
                type = .video
            case "scene":
                type = .scene
            case "web":
                type = .web
            case "application":
                type = .application
            default:
                break
            }
            guard self.type.contains(type) else { return false }
            
            // 
            
            // Age Rating
            var ageRating: FRAgeRating
            switch wallpaper.project.contentrating {
            case "Everyone":
                ageRating = .everyone
            case "Questionable":
                ageRating = .partialNudity
            case "Mature":
                ageRating = .mature
            default:
                ageRating = .none
            }
            guard self.ageRating.contains(ageRating) else { return false }
            
            // Tags
            var tags = FRTag.none
            var transformedTags: [FRTag] = []
            if let someTags = wallpaper.project.tags {
//                tags = someTags.map { tag in
//                    switch tag.lowercased() {
//                    case "abstract":
//                        return FRTag.abstract
//                    case "animal":
//                        return FRTag.animal
//                    case "anime":
//                        return FRTag.anime
//                    case "cartoon":
//                        return FRTag.cartoon
//                    case "cgi":
//                        return FRTag.cgi
//                    case "cyberpunk":
//                        return FRTag.cyberpunk
//                    case "fantasy":
//                        return FRTag.fantasy
//                    case "game":
//                        return FRTag.game
//                    case "girls":
//                        return FRTag.girls
//                    case "guys":
//                        return FRTag.guys
//                    case "landscape":
//                        return FRTag.landscape
//                    case "medieval":
//                        return FRTag.medieval
//                    case "memes":
//                        return FRTag.memes
//                    case "mmd":
//                        return FRTag.mmd
//                    case "music":
//                        return FRTag.music
//                    case "nature":
//                        return FRTag.nature
//                    case "pixelart":
//                        return FRTag.pixelArt
//                    case "relaxing":
//                        return FRTag.relaxing
//                    case "retro":
//                        return FRTag.retro
//                    case "sci-fi":
//                        return FRTag.sciFi
//                    case "sports":
//                        return FRTag.sports
//                    case "technology":
//                        return FRTag.technology
//                    case "television":
//                        return FRTag.television
//                    case "vehicle":
//                        return FRTag.vehicle
//                    default:
//                        return FRTag.unspecifiedGenre
//                    }
//                }
            } else {
                tags = .none
            }
            guard self.tag != .none else { return false }
            
            // Finish Filtering
            return true
        }
    }
    
    private var sortedWallpapers: [WEWallpaper] {
        filteredWallpapers.sorted {
            switch sortingBy {
            case .name:
                if $0.project.title <= $1.project.title,
                      sortingSequence == .increase
                 { return false }
                
                if $0.project.title >= $1.project.title,
                      sortingSequence == .decrease
                 { return false }
                
                return true
            case .rating:
                if $0.project.contentrating ?? "0" <= $1.project.contentrating ?? "0",
                      sortingSequence == .increase
                 { return false }
                
                if $0.project.contentrating ?? "0" >= $1.project.contentrating ?? "0",
                      sortingSequence == .decrease
                 { return false }
                
                return true
//            case .favorite:
//                return false
            case .fileSize:
                if $0.wallpaperSize <= $1.wallpaperSize,
                      sortingSequence == .increase
                 { return false }
                
                if $0.project.title >= $1.project.title,
                      sortingSequence == .decrease
                 { return false }
                
                return true
//            case .subDate:
//                return false
//            case .lastUpdated:
//                return false
            }
        }
    }
    
    /// Provide wallpapers information for UI, being filtered by FilterResults and divided in pages
    public var autoRefreshWallpapers: [WEWallpaper] {
        sortedWallpapers
//        let startIndex = (self.currentPage - 1) * self.wallpapersPerPage
//        let filteredWallpapers = self.filteredWallpapers
//        let clip = filteredWallpapers[startIndex..<filteredWallpapers.endIndex]
//        return Array(clip.prefix(self.wallpapersPerPage))
    }
    
    /// Caculates the maximium possible page index for all wallpapers in your application wallpaper directory
    var maxPage: Int {
        Int(self.filteredWallpapers.count / self.wallpapersPerPage)
    }
    
    func toggleSelection(for wallpaper: WEWallpaper) {
        let url = wallpaper.wallpaperDirectory
        if selectedWallpapers.contains(url) {
            selectedWallpapers.remove(url)
        } else {
            selectedWallpapers.insert(url)
        }
    }

    func clearSelection() {
        selectedWallpapers.removeAll()
    }

    func isSelected(_ wallpaper: WEWallpaper) -> Bool {
        selectedWallpapers.contains(wallpaper.wallpaperDirectory)
    }

    func selectedWallpaperItems() -> [WEWallpaper] {
        autoRefreshWallpapers.filter { selectedWallpapers.contains($0.wallpaperDirectory) }
    }

    func toggleFilter() {
        isFilterReveal.toggle()
    }
    
    func alertImportModal(which error: WPImportError) {
        self.importAlertError = error
        self.importAlertPresented = true
    }
    
    func warningUnsafeWallpaperModal(which wallpaper: WEWallpaper) {
        self.isUnsafeWallpaperWarningPresented = true
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let proposal = DropProposal(operation: .copy)
        return proposal
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let itemProvider = info.itemProviders(for: [UTType.fileURL]).first
        else {
            alertImportModal(which: .unkown)
            return false
        }
        itemProvider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil)
            else {
                self?.alertImportModal(which: .unkown)
                return
            }
            // Do something with the file url
            // remember to dispatch on main in case of a @State change
            guard let wallpaper = try? FileWrapper(url: url)
            else{
                self?.alertImportModal(which: .unkown)
                return
            }
            
            if wallpaper.isDirectory {
                guard wallpaper.fileWrappers?["project.json"] != nil
                else{
                    self?.alertImportModal(which: .doesNotContainWallpaper)
                    return
                }
                DispatchQueue.main.async {
                    try? FileManager.default.copyItem(
                        at: url,
                        to: FileManager.default.wallpapersDirectory
                            .appending(path: url.lastPathComponent)
                    )
                }
            } else if wallpaper.isRegularFile, url.pathExtension.lowercased() == "zip" {
                DispatchQueue.main.async {
                    let count = ZipImporter.importZip(at: url)
                    if count == 0 {
                        self?.alertImportModal(which: .doesNotContainWallpaper)
                    }
                }
            } else if wallpaper.isRegularFile { // hello.mp4
                guard let filename = wallpaper.filename, [".mp4", ".mov"].contains(filename.suffix(4).lowercased()) else { return }
                
                let wallpaperDirectoryWrapper = FileWrapper(directoryWithFileWrappers: [filename: wallpaper])
                
                let projectData = WEProject(file: filename,
                                            preview: "preview.jpg",
                                            title: String(filename.prefix(filename.count - 4)),
                                            type: "video")
                
                // Generate a thumbnail (preview) image for importing video wallpaper
                let asset = AVAsset(url: url)
                let imageGenerator = AVAssetImageGenerator(asset: asset)
                imageGenerator.appliesPreferredTrackTransform = true
                let time = CMTimeMake(value: 1, timescale: 1) // 第一帧的时间
                imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { (_, cgImage, _, _, error) in
                    if let error = error {
                        print(error)
                    } else if let cgImage = cgImage {
                        if let data = NSBitmapImageRep(cgImage: cgImage).representation(using: NSBitmapImageRep.FileType.jpeg, properties: [:]) {
                            wallpaperDirectoryWrapper.addRegularFile(withContents: data, preferredFilename: "preview.jpg")
                            
                            wallpaperDirectoryWrapper.addRegularFile(withContents: try! JSONEncoder().encode(projectData), preferredFilename: "project.json")
                            
                            // Write to Work Directory
                            DispatchQueue.main.async {
                                do {
                                    try wallpaperDirectoryWrapper.write(
                                        to: FileManager.default.wallpapersDirectory.appending(path: String(filename.prefix(filename.count - 4))),
                                        originalContentsURL: nil)
                                } catch {
                                    print(error)
                                    return
                                }
                            }
                        }
                    }
                }
            }
        }
        return true
    }
    
    public func refresh() {
        self.wallpapers = autoRefreshWallpapers
    }
    
    /// Provide a filter reset to default function, usually being used to show all wallpapers without filtered
    public func reset() {
        self.showOnly                   = .none // notice it's show ONLY, it acts oppositely to the others
        self.type                       = .all
        self.ageRating                  = .all
        self.type                       = .all
        self.ageRating                  = .all
        self.widescreenResolution       = .all
        self.ultraWidescreenResolution  = .all
        self.dualscreenResolution       = .all
        self.triplescreenResolution     = .all
        self.potraitscreenResolution    = .all
        self.miscResolution             = .all
        self.source                     = .all
        self.tag                        = .all
    }
}

extension Array: RawRepresentable where Element: Codable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let result = try? JSONDecoder().decode([Element].self, from: data)
        else {
            return nil
        }
        self = result
    }
    
    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let result = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return result
    }
}
