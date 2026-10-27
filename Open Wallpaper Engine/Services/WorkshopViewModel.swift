import Foundation
import SwiftUI
import Combine

class WorkshopViewModel: ObservableObject {
    @Published var items: [WorkshopItem] = []
    @Published var searchText = ""
    @Published var sortOrder: WorkshopSortOrder = .trending
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentPage = 1
    @Published var selectedTags: [String] = ["Everyone"]

    /// Genres the user never wants to see. Steam's QueryFiles has no "exclude" parameter —
    /// every tag it takes is a *required* tag — so exclusion is applied to the results
    /// after they come back. Persisted, because a dislike is not a per-session thing.
    @Published var excludedTags: Set<String> = [] {
        didSet {
            guard oldValue != excludedTags else { return }
            UserDefaults.standard.set(Array(excludedTags), forKey: Self.excludedKey)
        }
    }

    private static let excludedKey = "WorkshopExcludedTags"

    /// A tag's place in the filter: not mentioned, must be present, or must be absent.
    enum TagState { case neutral, included, excluded }

    func state(of tag: String) -> TagState {
        if excludedTags.contains(tag) { return .excluded }
        if selectedTags.contains(tag) { return .included }
        return .neutral
    }

    /// Drop anything carrying an excluded tag. Steam cannot do this for us.
    private func applyExclusions(_ items: [WorkshopItem]) -> [WorkshopItem] {
        guard !excludedTags.isEmpty else { return items }
        return items.filter { $0.tags.allSatisfy { !excludedTags.contains($0) } }
    }

    /// How many results the current page dropped, so the UI can say so instead of
    /// silently showing a short page.
    @Published var hiddenByExclusion = 0

    let steamCmd: SteamCmdService
    private let api = WorkshopAPIService()
    private var cancellable: AnyCancellable?

    static let contentRatingTags = ["Everyone", "Questionable", "Mature"]

    static let typeTags = ["Scene", "Video", "Web", "Application"]

    static let genreTags = [
        "Abstract", "Animal", "Anime", "Cartoon", "CGI",
        "Cyberpunk", "Fantasy", "Game", "Girls", "Guys",
        "Landscape", "Medieval", "Memes", "MMD", "Music",
        "Nature", "Pixel Art", "Relaxing", "Retro", "Sci-Fi",
        "Sports", "Technology", "Television", "Vehicle",
    ]

    static let resolutionTags = [
        "1920 x 1080", "2560 x 1440", "3840 x 2160",
        "3440 x 1440", "1440 x 2560",
    ]

    init(steamCmd: SteamCmdService) {
        self.steamCmd = steamCmd
        if let saved = UserDefaults.standard.array(forKey: Self.excludedKey) as? [String] {
            self.excludedTags = Set(saved)
        }
        // Forward steamCmd changes (e.g. downloadProgress) to trigger view updates
        self.cancellable = steamCmd.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Identifies the latest search. Filter changes fire searches back to back — flip Type, then
    /// Sort — and each used to run to completion independently, so whichever response arrived
    /// *last* filled the grid, possibly for a filter no longer selected. A response is applied
    /// only if no newer search has started since; the superseded request is cancelled outright.
    private var searchGeneration = 0
    private var inFlight: Task<[WorkshopItem], Error>?

    /// Set when Load More fails. Shown as a banner over the results that are still valid,
    /// unlike `errorMessage`, which replaces the grid.
    @Published var loadMoreError: String?

    private func request(page: Int) -> Task<[WorkshopItem], Error> {
        let (query, tags, sort) = (searchText, selectedTags, sortOrder)
        let api = self.api
        return Task { try await api.searchItems(query: query, tags: tags, sortOrder: sort, page: page) }
    }

    @MainActor
    func search() async {
        searchGeneration += 1
        let generation = searchGeneration
        inFlight?.cancel()
        let task = request(page: currentPage)
        inFlight = task

        isLoading = true
        errorMessage = nil
        loadMoreError = nil

        do {
            let results = try await task.value
            guard generation == searchGeneration else { return }
            let kept = applyExclusions(results)
            hiddenByExclusion = results.count - kept.count
            items = kept
        } catch {
            guard generation == searchGeneration else { return }
            // The old results belong to the old filter. Leaving them up under the new one, with
            // the error recorded where the view only shows it for an empty grid, presented them
            // as matching a rating or type they were never fetched for.
            items = []
            hiddenByExclusion = 0
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    @MainActor
    func loadMore() async {
        let generation = searchGeneration
        // The page is committed only once it has arrived: incrementing up front meant a failed
        // Load More silently skipped that page on the next attempt.
        let page = currentPage + 1
        let task = request(page: page)
        inFlight = task
        isLoading = true
        loadMoreError = nil

        do {
            let results = try await task.value
            guard generation == searchGeneration else { return }
            currentPage = page
            let kept = applyExclusions(results)
            hiddenByExclusion += results.count - kept.count
            // Steam can repeat an id across pages, and a duplicate id collides in the grid's ForEach.
            let known = Set(items.map(\.id))
            items.append(contentsOf: kept.filter { !known.contains($0.id) })
        } catch {
            guard generation == searchGeneration else { return }
            loadMoreError = error.localizedDescription
        }

        isLoading = false
    }

    func download(item: WorkshopItem) {
        steamCmd.downloadWorkshopItem(workshopId: item.id)
    }

    func downloadState(for item: WorkshopItem) -> SteamCmdService.DownloadState? {
        steamCmd.downloadProgress[item.id]
    }

    func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.removeAll { $0 == tag }
        } else {
            selectedTags.append(tag)
        }
        currentPage = 1
    }

    // MARK: - Filter actions
    //
    // Everything in selectedTags goes to Steam as a *required* tag, so they AND together.
    // Two ratings or two types at once therefore match nothing, which is why those two
    // groups are single-choice rather than free toggles.

    var selectedRating: String? {
        selectedTags.first { Self.contentRatingTags.contains($0) }
    }

    var selectedType: String? {
        selectedTags.first { Self.typeTags.contains($0) }
    }

    func selectRating(_ tag: String?) {
        selectedTags.removeAll { Self.contentRatingTags.contains($0) }
        if let tag { selectedTags.append(tag) }
        currentPage = 1
    }

    func selectType(_ tag: String?) {
        selectedTags.removeAll { Self.typeTags.contains($0) }
        if let tag { selectedTags.append(tag) }
        currentPage = 1
    }

    /// Genres cycle neutral → required → excluded → neutral.
    func cycleGenre(_ tag: String) {
        switch state(of: tag) {
        case .neutral:
            selectedTags.append(tag)
        case .included:
            selectedTags.removeAll { $0 == tag }
            excludedTags.insert(tag)
        case .excluded:
            excludedTags.remove(tag)
        }
        currentPage = 1
    }

    /// Genres only — rating and type are shown as their own controls.
    var activeGenreCount: Int {
        selectedTags.filter { Self.genreTags.contains($0) }.count + excludedTags.count
    }

    func clearGenres() {
        selectedTags.removeAll { Self.genreTags.contains($0) }
        excludedTags = []
        currentPage = 1
    }
}
