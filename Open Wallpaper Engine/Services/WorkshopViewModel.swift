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
        // Forward steamCmd changes (e.g. downloadProgress) to trigger view updates
        self.cancellable = steamCmd.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    @MainActor
    func search() async {
        isLoading = true
        errorMessage = nil

        do {
            let results = try await api.searchItems(
                query: searchText,
                tags: selectedTags,
                sortOrder: sortOrder,
                page: currentPage
            )
            items = results
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    @MainActor
    func loadMore() async {
        currentPage += 1
        isLoading = true

        do {
            let results = try await api.searchItems(
                query: searchText,
                tags: selectedTags,
                sortOrder: sortOrder,
                page: currentPage
            )
            items.append(contentsOf: results)
        } catch {
            errorMessage = error.localizedDescription
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
}
