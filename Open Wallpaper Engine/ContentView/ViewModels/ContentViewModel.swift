//
//  ContentViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

class ContentViewModel: ObservableObject, DropDelegate {
    // Every input to the library chain schedules a refresh of the `wallpapers` snapshot,
    // which is what the explorer renders. See `refresh()`.
    @AppStorage("SortingBy") var sortingBy: WEWallpaperSortingMethod = .name { didSet { scheduleRefresh() } }
    @AppStorage("SortingSequence") var sortingSequence: WEWallpaperSortingSequence = .increase { didSet { scheduleRefresh() } }

    // Show Only is a *restriction* set, so its default must be empty. It was `.all` here
    // while reset() used `.none`, so a fresh profile (no FRShowOnly key stored) listed only
    // the wallpapers carrying "approved": true — 29 of 155 in the measured library — with
    // the Approved box ticked and no hint why, and the bug vanished after a Reset Filters.
    // No stored-value migration: @AppStorage never writes its default, so a stored value
    // only exists because the user toggled a box, and then it is what they chose.
    @AppStorage("FRShowOnly")                   public var showOnly                     =                   FRShowOnly.none { didSet { scheduleRefresh() } }
    @AppStorage("FRType")                       public var type                         =                       FRType.all { didSet { scheduleRefresh() } }
    @AppStorage("FRAgeRating")                  public var ageRating                    =                  FRAgeRating.all { didSet { scheduleRefresh() } }
    // No Resolution filter: see the note above FRSource for why it was declined.
    @AppStorage("FRSource")                     public var source                       =                     FRSource.all { didSet { scheduleRefresh() } }
    @AppStorage("FRTag")                        public var tag                          =                        FRTag.all { didSet { scheduleRefresh() } }

    @AppStorage("FilterReveal") var isFilterReveal = false
    @AppStorage("SelectedIndex") var selectedIndex = 0
    
    @AppStorage("ExplorerIconSize") var explorerIconSize: Double = 200
    
    @Published var isDisplaySettingsReveal = false
    @Published var importAlertPresented = false
    /// True while the main window is on screen. Opening it re-reads the library, which
    /// catches anything that changed while it was hidden.
    @Published var isStaging = false {
        didSet { if isStaging && !oldValue { scheduleRefresh() } }
    }

    @Published var topTabBarSelection: Int = 0
    @Published var topTabBarHoverSelection: Int = -1
    
    @Published var imageScaleIndex: Int = -1
    
    @Published var wallpapers = [WEWallpaper]()
    
    @Published var isUnsafeWallpaperWarningPresented = false {
        // Proceed assigns before it dismisses, so the target is still there when it is needed.
        didSet { if !isUnsafeWallpaperWarningPresented { pendingUnsafeWallpaper = nil } }
    }

    /// The web/application wallpaper the unsafe-wallpaper sheet is asking about, and the screen
    /// it was chosen for. See `warningUnsafeWallpaperModal`.
    private(set) var pendingUnsafeWallpaper: (wallpaper: WEWallpaper, screenId: String)?

    @Published var hoveredWallpaper: WEWallpaper?
    
    @Published var isUnsubscribeConfirming = false

    @Published var selectedWallpapers = Set<URL>()
    @Published var isBatchUnsubscribeConfirming = false

    lazy var steamCmd: SteamCmdService = {
        let svc = SteamCmdService()
        steamCmdCancellable = svc.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return svc
    }()
    lazy var workshopVM: WorkshopViewModel = WorkshopViewModel(steamCmd: steamCmd)
    private var steamCmdCancellable: AnyCancellable?

    /// Debounced: each refresh re-reads and re-decodes the whole library.
    @Published var searchText = "" {
        didSet { if searchText != oldValue { scheduleRefresh(after: 0.15) } }
    }

    var importAlertError: WPImportError? = nil
    
    /// Built by `AppDelegate.init()`, so nothing here may reach for `AppDelegate.shared`.
    init() {
        watchLibraryDirectory()
        observeVolumes()
    }

    deinit {
        libraryWatcher?.cancel()
        volumeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    convenience init(isStaging: Bool, topTabBarSelection: Int = 0) {
        self.init()
        
        let wallpapers = autoRefreshWallpapers
        
        self.isStaging = isStaging
        self.topTabBarSelection = topTabBarSelection
        self.wallpapers = wallpapers
    }
    
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
    ///
    /// A directory with no `project.json` is not a wallpaper at all — an empty folder left by a
    /// failed or delisted Workshop download, a stray file, a dead symlink. Those used to surface
    /// as `.invalid` tiles titled "Error" that `WallpaperPreview` then refused to apply, which
    /// reads as the app being broken rather than the entry being junk, so they are dropped.
    /// A folder that *has* a manifest which fails to decode is kept as `.invalid`: that is a real
    /// wallpaper the app could not parse, and hiding it would hide the bug.
    ///
    /// This filter was lost once already, in merge 5ca0d6a, which brought back a plain `map`
    /// and with it 9 "Error" tiles over the measured library (2 empty folders, 7 presets).
    /// `Tools/appcheck` reports those entries as SKIP precisely because this hides them.
    private var allWallpapers: [WEWallpaper] {
        self.urls.compactMap({ url in
            let projectURL = url.appending(path: "project.json")
            guard FileManager.default.fileExists(atPath: projectURL.path(percentEncoded: false))
            else { return nil }

            guard let data = try? Data(contentsOf: projectURL) else { return nil }

            if let project = try? JSONDecoder().decode(WEProject.self, from: data) {
                return WEWallpaper(using: project, where: url)
            }

            // Workshop "preset" items are a settings override for some other wallpaper: they
            // carry `preset` and `dependency` but no `type`, and often no `file`. `WallpaperView`
            // dispatches purely on `type`, so there is nothing they could ever render — drop them
            // instead of listing an unappliable "Error" tile. Anything that does declare a type
            // and still fails to decode is kept as `.invalid`, because that is a parsing bug.
            let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard raw?["type"] != nil else { return nil }

            return WEWallpaper(using: .invalid, where: url)
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
                // Any tag, not every tag: `allSatisfy` hid a ["Nature", "Landscape"]
                // wallpaper from "nature" (3 hits in the library instead of 11).
                guard !tags.contains(where: { $0.lowercased().contains(searchText) })
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

            // Show Only — a restriction, so an empty selection must mean "no restriction".
            // The previous form asked `self.showOnly.contains(<wallpaper's flags>)`, which with
            // the default empty selection hid every wallpaper carrying "approved": true — i.e.
            // most of the Steam Workshop. Only `.approved` is derivable from project.json
            // today; the other flags are never set, so they cannot be required here.
            if self.showOnly.contains(.approved) && wallpaper.project.approved != true {
                return false
            }
            
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

            // Tags. A wallpaper passes when any of its genres is selected. An empty
            // selection is treated as no restriction: the half-written block this replaces
            // ended in `guard self.tag != .none else { return false }`, so a stored FRTag of
            // 0 would have hidden the entire library.
            let tags = self.tag.intersection(.all)
            if !tags.isEmpty && tags != .all {
                guard !Self.genres(of: wallpaper).isDisjoint(with: tags) else { return false }
            }

            // Source. Same convention as Tags: empty means no restriction, and only known bits
            // count, so a stored "Official" (an option that no longer exists) shows everything.
            let sources = self.source.intersection(.all)
            if !sources.isEmpty && sources != .all {
                guard sources.contains(FRSource.of(wallpaper)) else { return false }
            }

            // Finish Filtering
            return true
        }
    }

    /// FRTag option names, normalised for matching: Workshop writes "Pixel art" and "Sci-Fi"
    /// where the options say "PixelArt" and "Sci-Fi".
    private static let genreByName: [String: FRTag] = Dictionary(
        uniqueKeysWithValues: FRTag.allOptions.enumerated().map { (normalisedGenre($1), FRTag(rawValue: 1 << $0)) }
    )

    private static func normalisedGenre(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The genres a wallpaper's tags name; none recognised (or no tags) is "Unspecified".
    private static func genres(of wallpaper: WEWallpaper) -> FRTag {
        let found = (wallpaper.project.tags ?? []).reduce(into: FRTag.none) { set, tag in
            if let genre = genreByName[normalisedGenre(tag)] { set.insert(genre) }
        }
        return found.isEmpty ? .unspecifiedGenre : found
    }

    /// Wallpaper Engine's three content ratings in increasing order of restriction. Raw
    /// string order put "Questionable" above "Mature" and "Everyone". Unrated sorts first.
    private static func ratingOrdinal(_ wallpaper: WEWallpaper) -> Int {
        switch wallpaper.project.contentrating?.lowercased() {
        case "everyone":        return 0
        case "questionable":    return 1
        case "mature":          return 2
        default:                return -1
        }
    }

    /// `.increase` is ascending: A to Z, Everyone to Mature, smallest to largest.
    ///
    /// The previous comparator returned true only when `$0 > $1` under `.increase`, so the
    /// list ran Z to A (CJK titles first, "2000s…" last); it compared titles with `<=`,
    /// i.e. by code point, which put every lowercase title after every capitalised one; and
    /// its `.fileSize`/`.decrease` branch compared titles, not sizes. It also walked each
    /// wallpaper's directory inside the comparator — O(n log n) walks per sort — where the
    /// sizes are now taken once up front.
    private var sortedWallpapers: [WEWallpaper] {
        let wallpapers = filteredWallpapers
        let ascending = sortingSequence == .increase

        let primary: (Int, Int) -> ComparisonResult
        switch sortingBy {
        case .name:
            primary = { _, _ in .orderedSame } // the title tie-break below *is* the key
        case .rating:
            let ratings = wallpapers.map(Self.ratingOrdinal)
            primary = { Self.compare(ratings[$0], ratings[$1]) }
        case .fileSize:
            let sizes = wallpapers.map(\.wallpaperSize)
            primary = { Self.compare(sizes[$0], sizes[$1]) }
        }

        let order = wallpapers.indices.sorted { a, b in
            var result = primary(a, b)
            if result == .orderedSame {
                // Finder's ordering: case-insensitive, locale-aware, digits by value.
                result = wallpapers[a].project.title.localizedStandardCompare(wallpapers[b].project.title)
            }
            if result == .orderedSame {
                // Deterministic for equal titles, so the grid does not reshuffle per render.
                result = wallpapers[a].wallpaperDirectory.lastPathComponent
                    .compare(wallpapers[b].wallpaperDirectory.lastPathComponent)
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        return order.map { wallpapers[$0] }
    }

    private static func compare(_ a: Int, _ b: Int) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    /// The library, filtered, searched and sorted. Read it through the `wallpapers` snapshot.
    public var autoRefreshWallpapers: [WEWallpaper] {
        sortedWallpapers
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

    /// Every selected wallpaper, whether or not the current search and filters show it.
    ///
    /// Resolved against the unfiltered library on purpose. The selection survives a search,
    /// and the batch-unsubscribe buttons act on all of it, so a message built from the
    /// filtered list named one wallpaper while "Move All 3 to Trash" deleted three.
    func selectedWallpaperItems() -> [WEWallpaper] {
        allWallpapers
            .filter { selectedWallpapers.contains($0.wallpaperDirectory) }
            .sorted { $0.project.title.localizedStandardCompare($1.project.title) == .orderedAscending }
    }

    func toggleFilter() {
        isFilterReveal.toggle()
    }
    
    func alertImportModal(which error: WPImportError) {
        self.importAlertError = error
        self.importAlertPresented = true
    }
    
    /// Ask before loading a web or application wallpaper that is not on the trusted list.
    ///
    /// The sheet hangs off the main window, so with that window closed — the usual state when
    /// picking from the status bar's Recent menu — setting the flag presented nothing and the
    /// choice silently did nothing. The window is brought up first.
    ///
    /// The screen is recorded with the wallpaper because Proceed applies it later, through
    /// `currentWallpaper`, i.e. to whatever screen is selected *then*; the Display Settings
    /// picker may have moved in between, or the screen may have been unplugged and the
    /// selection reset. `WallpaperViewModel.currentWallpaper` asks `unsafeTargetScreen(for:)`.
    func warningUnsafeWallpaperModal(which wallpaper: WEWallpaper, for screenId: String) {
        pendingUnsafeWallpaper = (wallpaper, screenId)
        AppDelegate.shared.openMainWindow()
        self.isUnsafeWallpaperWarningPresented = true
    }

    /// The screen `wallpaper` was chosen for, if it is the one the unsafe-wallpaper sheet is
    /// currently asking about.
    func unsafeTargetScreen(for wallpaper: WEWallpaper) -> String? {
        guard isUnsafeWallpaperWarningPresented, let pending = pendingUnsafeWallpaper,
              pending.wallpaper.wallpaperDirectory == wallpaper.wallpaperDirectory else { return nil }
        return pending.screenId
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let proposal = DropProposal(operation: .copy)
        return proposal
    }

    func performDrop(info: DropInfo) -> Bool {
        // Every dropped item, not just `.first`: dropping several folders used to import one.
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else {
            alertImportModal(which: .unkown)
            return false
        }

        // Providers answer on their own background queues; collect the URLs in drop order
        // under a lock, then import once they are all in.
        final class Collected: @unchecked Sendable {
            let lock = NSLock()
            var urls: [URL?]
            init(count: Int) { urls = Array(repeating: nil, count: count) }
        }
        let collected = Collected(count: providers.count)
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                collected.lock.lock()
                collected.urls[index] = url
                collected.lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            let resolved = collected.urls.compactMap { $0 }
            var report = WallpaperImporter.importItems(at: resolved)
            if resolved.count < providers.count {
                report.skipped.append("\(providers.count - resolved.count) dropped item(s): not a readable file")
            }
            DispatchQueue.main.async { self?.finishImport(report) }
        }
        return true
    }

    /// Show the result of an import. Must run on the main queue: it mutates @Published
    /// state, which the old drop handler did from NSItemProvider's completion queue.
    ///
    /// The refresh matters as much as the alert. Imports land in the library on a later
    /// queue hop and change no @Published value, so WallpaperExplorer was never invalidated
    /// and a successful import stayed invisible until something unrelated redrew the grid —
    /// which is exactly when users drop the same file a second time.
    func finishImport(_ report: WallpaperImportReport) {
        dispatchPrecondition(condition: .onQueue(.main))
        refresh()
        if report.isEmpty {
            alertImportModal(which: .doesNotContainWallpaper)
        } else if !report.isClean {
            alertImportModal(which: .report(report))
        }
    }

    /// Re-read the library into the `wallpapers` snapshot the explorer renders.
    ///
    /// The explorer used to read the computed chain directly — three times per body
    /// (`isEmpty`, the `ForEach`, and `maxPage`), each a directory listing plus a decode of
    /// every project.json — and it observes the wallpaper view model as well, so that cost
    /// (20–40 ms measured, over a 16 ms frame) was paid per search keystroke, per tick of
    /// the Volume and Playback Rate sliders, and on every auto-mute. The snapshot is now
    /// recomputed only when an input changes: filters, sort, search (debounced), the main
    /// window opening, imports, edits in the preview pane, and the library directory itself
    /// (see `watchLibraryDirectory`).
    public func refresh() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        rewatchIfLibraryMoved()
        self.wallpapers = autoRefreshWallpapers
    }

    private var pendingRefresh: DispatchWorkItem?

    /// Coalesce bursts (reset() writes a dozen filters; a copy writes many entries) into
    /// one refresh on the main queue.
    func scheduleRefresh(after delay: TimeInterval = 0) {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private var libraryWatcher: DispatchSourceFileSystemObject?
    /// The folder `libraryWatcher` holds a descriptor on, to tell when `wallpapersDirectory` has
    /// started resolving somewhere else.
    private var watchedLibraryDirectory: URL?
    private var volumeObservers: [NSObjectProtocol] = []

    /// Settings moved the library to another folder (or back). The watcher holds a descriptor on
    /// the *old* folder, so it would go on refreshing for changes nobody is looking at and miss
    /// every one in the new folder; it is re-opened on the new one before the grid is refreshed.
    func libraryDirectoryDidChange() {
        libraryWatcher?.cancel()
        libraryWatcher = nil
        watchedLibraryDirectory = nil
        refresh()
    }

    /// `wallpapersDirectory` is not a fixed folder: a chosen folder counts only while it exists,
    /// so the library moves between it and the default whenever its drive is mounted or ejected
    /// (or the folder is created, renamed or deleted) — without anything in Settings changing.
    /// The watcher opened on the old folder would then go on watching it, and Finder edits in the
    /// folder the grid actually lists would never appear. Re-resolving costs one `stat`, so it is
    /// done on every refresh, and on every mount and unmount below.
    private func rewatchIfLibraryMoved() {
        let current = FileManager.default.wallpapersDirectory.standardizedFileURL
        guard libraryWatcher == nil || current != watchedLibraryDirectory else { return }
        libraryWatcher?.cancel()
        libraryWatcher = nil
        watchedLibraryDirectory = nil
        watchLibraryDirectory()
    }

    /// A mount or unmount is what makes a chosen folder on an external or network drive appear or
    /// vanish. The watcher sees an ejection as `.revoke`, but nothing it holds can see a mount, so
    /// a library set to an external folder and launched with the drive unplugged would list the
    /// default folder until something else happened to refresh.
    private func observeVolumes() {
        let center = NSWorkspace.shared.notificationCenter
        volumeObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                self?.libraryLocationMayHaveChanged()
            }
        }
    }

    /// The watcher is kept right even while the main window is closed, since nothing else would
    /// re-open it; the grid itself is only re-read when someone is looking at it, as for any
    /// other change to the folder.
    private func libraryLocationMayHaveChanged() {
        rewatchIfLibraryMoved()
        if isStaging { scheduleRefresh(after: 0.3) }
    }

    /// Refresh when entries appear in or vanish from the library folder: steamcmd
    /// downloads, deletions from the context menu, or the user editing it in Finder. Only
    /// the folder's own listing is watched; edits inside a wallpaper (a rename in the
    /// preview pane) call `refresh()` themselves.
    ///
    /// `.write` is the listing changing. `.delete`, `.rename` and `.revoke` are the folder itself
    /// going away — deleted or renamed in Finder, or its volume unmounted (an `O_EVTONLY`
    /// descriptor gets only `.revoke` then, so without it an ejected drive left the grid listing
    /// tiles whose files were gone). The descriptor is useless after any of them, so it is
    /// dropped and the library re-resolved, which falls back to the default folder.
    private func watchLibraryDirectory() {
        let directory = FileManager.default.wallpapersDirectory.standardizedFileURL
        let fd = open(directory.path(percentEncoded: false), O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .revoke], queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.rename, .delete, .revoke]) {
                // Only this source: by now the watcher may already be a newer one.
                source.cancel()
                if self.libraryWatcher === source {
                    self.libraryWatcher = nil
                    self.watchedLibraryDirectory = nil
                }
                // Not at once: on an ejection the mount point can outlive the revoke briefly, and
                // re-resolving then would re-open on the dying volume. The unmount notification
                // re-resolves too, so whichever comes later settles it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.libraryLocationMayHaveChanged()
                }
                return
            }
            guard self.isStaging else { return }
            self.scheduleRefresh(after: 0.3)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        libraryWatcher = source
        watchedLibraryDirectory = directory
    }
    
    /// Provide a filter reset to default function, usually being used to show all wallpapers without filtered
    public func reset() {
        self.showOnly                   = .none // notice it's show ONLY, it acts oppositely to the others
        self.type                       = .all
        self.ageRating                  = .all
        self.source                     = .all
        self.tag                        = .all
    }
}
