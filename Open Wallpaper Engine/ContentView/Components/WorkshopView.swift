import SwiftUI

struct WorkshopView: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel

    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.steamCmd.isInstalled {
                SteamCmdNotInstalledView(steamCmd: viewModel.steamCmd)
            } else if !viewModel.steamCmd.isLoggedIn {
                SteamLoginView(steamCmd: viewModel.steamCmd)
            } else {
                WorkshopBrowserView(viewModel: viewModel.workshopVM)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - steamcmd Not Installed

private struct SteamCmdNotInstalledView: View {
    @ObservedObject var steamCmd: SteamCmdService
    @State private var isCopied = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("steamcmd Not Found")
                .font(.title2)
                .bold()

            Text("Steam Workshop requires steamcmd to download wallpapers.\nInstall it with Homebrew:")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack {
                Text("brew install steamcmd")
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install steamcmd", forType: .string)
                    isCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isCopied = false }
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }

            Divider().frame(width: 200)

            Text("Or locate an existing steamcmd binary:")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Browse...") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.message = "Select the steamcmd executable"
                if panel.runModal() == .OK, let url = panel.url {
                    steamCmd.setCustomPath(url.path)
                }
            }
            .buttonStyle(.bordered)

            Button("Re-detect") {
                steamCmd.detectSteamCmd()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(40)
    }
}

// MARK: - Steam Login

private struct SteamLoginView: View {
    @ObservedObject var steamCmd: SteamCmdService
    @State private var username = ""
    @State private var password = ""
    @State private var guardCode = ""
    @State private var showGuardCode = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Steam Login")
                .font(.title2)
                .bold()

            Text("Log in with your Steam account to browse and download wallpapers.\nYou must own Wallpaper Engine on Steam.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)

            VStack(spacing: 10) {
                TextField("Steam Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)

                if showGuardCode {
                    TextField("Steam Guard Code", text: $guardCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }

                if let error = steamCmd.loginError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)

                    if error.contains("Steam Guard") && !showGuardCode {
                        Button("Enter Steam Guard Code") {
                            showGuardCode = true
                        }
                        .buttonStyle(.link)
                    }
                }

                HStack(spacing: 12) {
                    Button("Log In") {
                        steamCmd.login(
                            username: username,
                            password: password,
                            guardCode: showGuardCode ? guardCode : nil
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(username.isEmpty || password.isEmpty || steamCmd.isLoggingIn)

                    if !username.isEmpty {
                        Button("Use Cached Session") {
                            steamCmd.loginWithCachedSession(username: username)
                        }
                        .buttonStyle(.bordered)
                        .disabled(steamCmd.isLoggingIn)
                    }
                }

                if steamCmd.isLoggingIn {
                    ProgressView()
                        .controlSize(.small)
                    Text("Authenticating with Steam...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // API Key section
            VStack(spacing: 6) {
                Divider().padding(.vertical, 8)
                Text("You'll also need a Steam Web API key to browse the Workshop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                APIKeyInputView {}
            }
        }
        .padding(40)
    }
}

// MARK: - Workshop Browser

private struct WorkshopBrowserView: View {
    @ObservedObject var viewModel: WorkshopViewModel

    var body: some View {
        VStack(spacing: 8) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search wallpapers...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        viewModel.currentPage = 1
                        Task { await viewModel.search() }
                    }
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                        viewModel.currentPage = 1
                        Task { await viewModel.search() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Picker("Sort", selection: $viewModel.sortOrder) {
                    ForEach(WorkshopSortOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }
                .frame(width: 160)
                .onChange(of: viewModel.sortOrder) { _ in
                    viewModel.currentPage = 1
                    Task { await viewModel.search() }
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)

            // Tag filters
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    tagGroup("Rating:", WorkshopViewModel.contentRatingTags)
                    Divider().frame(height: 20)
                    tagGroup("Type:", WorkshopViewModel.typeTags)
                    Divider().frame(height: 20)
                    tagGroup("", WorkshopViewModel.genreTags)
                }
                .padding(.horizontal)
            }

            // Results
            if viewModel.isLoading && viewModel.items.isEmpty {
                Spacer()
                ProgressView("Searching Workshop...")
                Spacer()
            } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    APIKeyInputView {
                        Task { await viewModel.search() }
                    }
                }
                Spacer()
            } else if viewModel.items.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Search the Steam Workshop")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Find wallpapers by name, tag, or browse trending content.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)

                    if WorkshopAPIService.loadAPIKey().isEmpty {
                        Divider().frame(width: 300).padding(.vertical, 4)
                        Text("A Steam Web API key is required to browse.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        APIKeyInputView {
                            Task { await viewModel.search() }
                        }
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 300))], spacing: 12) {
                        ForEach(viewModel.items) { item in
                            WorkshopItemCard(item: item, viewModel: viewModel)
                        }
                    }
                    .padding()

                    if !viewModel.items.isEmpty {
                        Button("Load More") {
                            Task { await viewModel.loadMore() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isLoading)
                        .padding(.bottom)
                    }
                }
            }
        }
        .task {
            if viewModel.items.isEmpty {
                await viewModel.search()
            }
        }
    }

    private func tagGroup(_ label: String, _ tags: [String]) -> some View {
        HStack(spacing: 4) {
            if !label.isEmpty {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(tags, id: \.self) { tag in
                Button {
                    viewModel.toggleTag(tag)
                    viewModel.currentPage = 1
                    Task { await viewModel.search() }
                } label: {
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(viewModel.selectedTags.contains(tag) ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                        .foregroundStyle(viewModel.selectedTags.contains(tag) ? .white : .primary)
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Workshop Item Card

private struct WorkshopItemCard: View {
    let item: WorkshopItem
    @ObservedObject var viewModel: WorkshopViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Preview image
            AsyncImage(url: item.previewImageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                        .clipped()
                case .failure:
                    placeholder
                default:
                    placeholder
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(height: 120)
            .clipped()

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)

                HStack {
                    if !item.tags.isEmpty {
                        Text(item.tags.prefix(2).joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if item.subscriptions > 0 {
                        Label("\(formatCount(item.subscriptions))", systemImage: "heart")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Download button
                downloadButton
            }
            .padding(8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
    }

    @ViewBuilder
    private var downloadButton: some View {
        let state = viewModel.downloadState(for: item)
        switch state {
        case .downloading(let status):
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .completed:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failed(let msg):
            VStack(alignment: .leading) {
                Label("Failed", systemImage: "xmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.red)
                Text(msg).font(.caption2).foregroundStyle(.secondary)
            }
        case .none:
            if viewModel.steamCmd.isLoggedIn {
                Button {
                    viewModel.download(item: item)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Text("Login to download")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .aspectRatio(16/9, contentMode: .fill)
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// MARK: - API Key Input

private struct APIKeyInputView: View {
    @State private var apiKey = WorkshopAPIService.loadAPIKey()
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Steam Web API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
                    .onSubmit { save() }

                Button("Save & Search") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 4) {
                Text("Get a free key at")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Link("steamcommunity.com/dev/apikey", destination: URL(string: "https://steamcommunity.com/dev/apikey")!)
                    .font(.caption)
            }
        }
    }

    private func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        WorkshopAPIService.saveAPIKey(trimmed)
        onSave()
    }
}
