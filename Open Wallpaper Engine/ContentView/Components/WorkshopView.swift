import SwiftUI

struct WorkshopView: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    /// Observed rather than read once, so saving a key on the login screen opens the browser.
    @AppStorage("SteamWebAPIKey") private var apiKey = ""
    @State private var showLogin = false

    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    /// Browsing needs only the Web API key — QueryFiles never touches steamcmd — so the browser
    /// opens as soon as there is one. Only downloading needs a steamcmd login, and the cards
    /// already say "Login to download" without one. It used to be the other way round: no
    /// browsing at all until steamcmd was installed and logged in.
    var body: some View {
        VStack(spacing: 0) {
            if !apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                if !viewModel.steamCmd.isLoggedIn {
                    downloadsUnavailableBar
                }
                WorkshopBrowserView(viewModel: viewModel.workshopVM)
            } else if !viewModel.steamCmd.isInstalled {
                SteamCmdNotInstalledView(steamCmd: viewModel.steamCmd)
            } else if !viewModel.steamCmd.isLoggedIn {
                SteamLoginView(steamCmd: viewModel.steamCmd)
            } else {
                WorkshopBrowserView(viewModel: viewModel.workshopVM)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showLogin) {
            VStack(spacing: 0) {
                if viewModel.steamCmd.isInstalled {
                    SteamLoginView(steamCmd: viewModel.steamCmd)
                } else {
                    SteamCmdNotInstalledView(steamCmd: viewModel.steamCmd)
                }
                Button("Close") { showLogin = false }
                    .keyboardShortcut(.cancelAction)
                    .padding(.bottom)
            }
            .onChange(of: viewModel.steamCmd.isLoggedIn) { loggedIn in
                if loggedIn { showLogin = false }
            }
        }
    }

    private var downloadsUnavailableBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
            Text(viewModel.steamCmd.isInstalled
                 ? "Log in to Steam to download wallpapers."
                 : "Install steamcmd to download wallpapers.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button(viewModel.steamCmd.isInstalled ? "Log In..." : "Set Up...") { showLogin = true }
                .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
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

            if let error = steamCmd.pathError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

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
    @State private var showGenres = false

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

            // Filters. Rating and Type are single-choice because Steam ANDs every tag it
            // is given; genres are a collapsible grid so the bar stays one row tall.
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Picker("Rating", selection: ratingSelection) {
                        Text("Any rating").tag(String?.none)
                        ForEach(WorkshopViewModel.contentRatingTags, id: \.self) { tag in
                            Text(tag).tag(String?.some(tag))
                        }
                    }
                    .frame(width: 150)

                    Picker("Type", selection: typeSelection) {
                        Text("Any type").tag(String?.none)
                        ForEach(WorkshopViewModel.typeTags, id: \.self) { tag in
                            Text(tag).tag(String?.some(tag))
                        }
                    }
                    .frame(width: 140)

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showGenres.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showGenres ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Text(genreButtonLabel)
                        }
                    }
                    .buttonStyle(.bordered)

                    if viewModel.activeGenreCount > 0 {
                        Button("Clear") {
                            viewModel.clearGenres()
                            Task { await viewModel.search() }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if showGenres {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Click once to require a genre, twice to hide it everywhere.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                            ForEach(WorkshopViewModel.genreTags, id: \.self) { tag in
                                genreChip(tag)
                            }
                        }
                    }
                }

                if viewModel.hiddenByExclusion > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "eye.slash")
                        Text("\(viewModel.hiddenByExclusion) hidden by your excluded genres")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal)

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
                        if let error = viewModel.loadMoreError {
                            Label("Couldn't load more: \(error)", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button(viewModel.loadMoreError == nil ? "Load More" : "Try Again") {
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

    private var ratingSelection: Binding<String?> {
        Binding(
            get: { viewModel.selectedRating },
            set: { viewModel.selectRating($0); Task { await viewModel.search() } }
        )
    }

    private var typeSelection: Binding<String?> {
        Binding(
            get: { viewModel.selectedType },
            set: { viewModel.selectType($0); Task { await viewModel.search() } }
        )
    }

    private var genreButtonLabel: String {
        let n = viewModel.activeGenreCount
        return n == 0 ? "Genres" : "Genres (\(n))"
    }

    private func genreChip(_ tag: String) -> some View {
        let state = viewModel.state(of: tag)
        return Button {
            viewModel.cycleGenre(tag)
            Task { await viewModel.search() }
        } label: {
            HStack(spacing: 3) {
                switch state {
                case .included:
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                case .excluded:
                    Image(systemName: "eye.slash.fill").font(.system(size: 8))
                case .neutral:
                    EmptyView()
                }
                Text(tag)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(chipBackground(state))
            .foregroundStyle(chipForeground(state))
            .cornerRadius(11)
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(state == .excluded ? Color.red.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(chipHelp(tag, state))
    }

    private func chipBackground(_ state: WorkshopViewModel.TagState) -> Color {
        switch state {
        case .included: return .accentColor
        case .excluded: return Color.red.opacity(0.12)
        case .neutral: return Color(nsColor: .controlBackgroundColor)
        }
    }

    private func chipForeground(_ state: WorkshopViewModel.TagState) -> Color {
        switch state {
        case .included: return .white
        case .excluded: return .secondary
        case .neutral: return .primary
        }
    }

    private func chipHelp(_ tag: String, _ state: WorkshopViewModel.TagState) -> String {
        switch state {
        case .neutral: return "Show only \(tag)"
        case .included: return "Hide \(tag) from results"
        case .excluded: return "Stop hiding \(tag)"
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
                Spacer(minLength: 2)
                Button {
                    viewModel.steamCmd.cancelDownload(workshopId: item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Cancel download")
            }
        case .completed:
            HStack(spacing: 4) {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Spacer(minLength: 2)
                // Downloading again is how an item the author updated gets updated: the import
                // replaces the library copy.
                if viewModel.steamCmd.isLoggedIn {
                    Button {
                        viewModel.download(item: item)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Download again to get the latest version")
                }
            }
        case .failed(let msg):
            // A failure is not final. The state used to stick until the app restarted, and the
            // Download button only exists for `.none`, so a network blip or an expired session
            // cost the item for the rest of the session.
            VStack(alignment: .leading, spacing: 4) {
                Label("Failed", systemImage: "xmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.red)
                Text(msg).font(.caption2).foregroundStyle(.secondary)
                if viewModel.steamCmd.isLoggedIn {
                    Button {
                        viewModel.download(item: item)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
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
