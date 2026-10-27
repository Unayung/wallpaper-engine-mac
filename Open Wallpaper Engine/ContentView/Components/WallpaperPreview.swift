//
//  WallpaperPreview.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

struct WallpaperPreview: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    
    @Environment(\.undoManager) var undoManager
    
    @State var isEditingId = ""
    @State var title = ""
    @State var newTag = ""
    
    @State var hoveredTag: String?
    @State var isTagsHovered = false
    
    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel) {
        self.viewModel = viewModel
        self.wallpaperViewModel = wallpaperViewModel
    }
    
    /// The selected wallpaper's size on disk, measured once per directory by `.task(id:)`.
    ///
    /// It used to be a computed property read in `body`: a recursive walk of the whole folder
    /// on every render, and this pane re-renders on every tick of its own Volume and Playback
    /// Rate sliders. It also walked the library entry as given, and most entries are symlinks
    /// into Steam's workshop folder, which `directoryTotalAllocatedSize` does not follow — 122
    /// of the 154 listed wallpapers read "??? MB". `WEWallpaper.wallpaperSize` resolves the
    /// link first.
    @State private var wallpaperSize = "…"

    private static func measuredSize(of wallpaper: WEWallpaper) async -> String {
        let bytes = await Task.detached(priority: .utility) { wallpaper.wallpaperSize }.value
        // 0 is what `wallpaperSize` reports when the folder cannot be read.
        guard bytes > 0 else { return "??? MB" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: Scheme colour

    /// Only wallpapers that declare `general.properties.schemecolor` have one to change.
    var hasSchemeColor: Bool {
        wallpaperViewModel.currentWallpaper.project.general?.properties.schemecolor != nil
    }

    /// Reads and writes the wallpaper's own scheme colour. Wallpaper Engine stores it as
    /// three space-separated floats in 0...1.
    var schemeColor: Binding<Color> {
        Binding(
            get: {
                guard let raw = wallpaperViewModel.currentWallpaper
                    .project.general?.properties.schemecolor?.value else { return .gray }
                let c = raw.parseColor()
                return Color(red: c.r, green: c.g, blue: c.b)
            },
            set: { newValue in
                guard let srgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                let encoded = String(format: "%.5f %.5f %.5f",
                                     srgb.redComponent, srgb.greenComponent, srgb.blueComponent)

                var wallpaper = wallpaperViewModel.currentWallpaper
                // Patch the file surgically — encoding WEProject would drop ratingsex,
                // ratingviolence and every other property it does not model.
                guard ProjectJSONPatch.setSchemeColor(
                    encoded, inWallpaperAt: wallpaper.wallpaperDirectory
                ) else { return }

                wallpaper.project.general?.properties.schemecolor?.value = encoded
                wallpaperViewModel.currentWallpaper = wallpaper
            }
        )
    }

    var body: some View {
        VStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 10) {
                        // This pane re-renders on every tick of its own Volume and Playback
                        // Rate sliders, so it must not read project.json from disk here.
                        GifImage(contentsOf: wallpaperViewModel.currentWallpaper.previewURL)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .background(Color(nsColor: NSColor.controlBackgroundColor))
                            .frame(width: 280, height: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 16.0))
                            .border(Color.white, width: 4)
                        HStack {
                            if isEditingId == "title" {
                                TextField("Wallpaper Title", text: $title)
                                    .onSubmit {
                                        var wallpaper = wallpaperViewModel.currentWallpaper
                                        isEditingId = ""

                                        // Patch the one key. Re-encoding WEProject here used to
                                        // rewrite project.json from the handful of keys the struct
                                        // models, and 64 of 155 library projects lost data that way
                                        // (14,634 leaf values, 10,526 of them user properties).
                                        guard ProjectJSONPatch.setTitle(
                                            title, inWallpaperAt: wallpaper.wallpaperDirectory
                                        ) else { return }

                                        wallpaper.project.title = title
                                        wallpaperViewModel.currentWallpaper = wallpaper
                                        viewModel.refresh() // the grid renders a snapshot
                                    }
                            } else {
                                Text(wallpaperViewModel.currentWallpaper.project.title.isEmpty ? "Untitled" : wallpaperViewModel.currentWallpaper.project.title)
                                    .frame(minWidth: 50)
                                    .id("title")
                                    .lineLimit(1)
                                    .onTapGesture(count: 2) {
                                        title = wallpaperViewModel.currentWallpaper.project.title
                                        isEditingId = "title"
                                    }
                                Image(systemName: "square.and.pencil")
                            }
                            
                        }
                    }
                    HStack {
                        Image("we.placeholder")
                            .resizable()
                            .frame(width: 32, height: 32)
                        Text("Unkown Author")
                    }
                    HStack {
                        HStack(spacing: 5) {
                            Image(systemName: "star")
                            Image(systemName: "star")
                            Image(systemName: "star")
                            Image(systemName: "star")
                            Image(systemName: "star")
                        }
                        .font(.caption)
                        Button { } label: {
                            Image(systemName: "heart")
                        }
                        .disabled(true)
                    }
                    HStack {
                        Text(wallpaperViewModel.currentWallpaper.project.type)
                        Text(wallpaperSize)
                            .task(id: wallpaperViewModel.currentWallpaper.wallpaperDirectory) {
                                let wallpaper = wallpaperViewModel.currentWallpaper
                                wallpaperSize = "…"
                                let measured = await Self.measuredSize(of: wallpaper)
                                // Superseded by another selection while measuring.
                                guard !Task.isCancelled else { return }
                                wallpaperSize = measured
                            }
                    }
                    .font(.footnote)
                    
                    ViewThatFits(in: .horizontal) {
                        tags.animation(.spring(), value: isTagsHovered)
                        ScrollView(.horizontal, showsIndicators: false) {
                            tags.animation(.spring(), value: isTagsHovered)
                        }
                    }
                    
                    .onHover { isTagsHovered = $0 }
                    
                    if isEditingId == "tags" {
                        HStack {
                            Button {
                                newTag = ""
                                isEditingId = ""
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            TextField("New Tag", text: $newTag)
                                .onSubmit {
                                    defer {
                                        newTag = ""
                                        isEditingId = ""
                                    }
                                    
                                    guard !newTag.isEmpty else { return }
                                    
                                    var wallpaper = wallpaperViewModel.currentWallpaper
                                    
                                    var tags = wallpaper.project.tags ?? []
                                    
                                    tags = Array(Set(tags)) // remove duplicate items
                                    
                                    tags.append(newTag)
                                    
                                    tags = Array(Set(tags)) // remove duplicate items
                                    
                                    wallpaper.project.tags = tags.sorted()

                                    // Patch just the tags array. Encoding WEProject here used
                                    // to rewrite the whole file through a model that knows one
                                    // of the 200+ keys a Workshop project.json can carry, so
                                    // adding a tag silently deleted the rest.
                                    guard ProjectJSONPatch.setTags(
                                        wallpaper.project.tags ?? [],
                                        inWallpaperAt: wallpaper.wallpaperDirectory
                                    ) else { return }

                                    wallpaperViewModel.currentWallpaper = wallpaper
                                    viewModel.refresh() // tags are searchable; the grid renders a snapshot
                                }
                        }
                    }
                    VStack(spacing: 3) {
                        Button { } label: {
                            Label("Unsubscribe", systemImage: "xmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        HStack(spacing: 3) {
                            Button { } label: {
                                Label("Comment", systemImage: "text.badge.star")
                                    .frame(maxWidth: .infinity)
                            }
                            Button { } label: {
                                Image(systemName: "doc.on.doc.fill")
                            }
                            Button { } label: {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                        }
                    }
                    .disabled(true)
                    // MARK: Properties
                    HStack(spacing: 3) {
                        Text("Properties")
                        VStack {
                            Divider()
                                .frame(height: 1)
                                .overlay(Color.accentColor)
                        }
                    }
                    VStack(spacing: 16) {
                        ColorPicker(selection: schemeColor, supportsOpacity: false) {
                            HStack {
                                Label("Scheme Color", systemImage: "paintpalette.fill")
                                Spacer()
                            }
                        }
                        .opacity(hasSchemeColor ? 1 : 0.5)
                        .disabled(!hasSchemeColor)
                        .help(hasSchemeColor
                              ? "Saved into this wallpaper's project.json"
                              : "This wallpaper does not define a scheme colour")
                        switch wallpaperViewModel.currentWallpaper.project.type.lowercased() {
                        case "video":
                            HStack {
                                Label("Volume", systemImage: "speaker.wave.3.fill")
                                Spacer()
                                Slider(value: $wallpaperViewModel.playVolume, in: 0...1).frame(width: 100)
                                Text(String(format: "%.0f", wallpaperViewModel.playVolume * 100) + "%")
                                    .frame(width: 35)
                            }
                            HStack {
                                Label("Playback Rate", systemImage: "play.fill")
                                Spacer()
                                Slider(value: $wallpaperViewModel.playRate, in: 0...2, step: 0.1).frame(width: 100)
                                Text(String(format: "%.01fx", wallpaperViewModel.playRate))
                                    .frame(width: 35)
                            }
                        case "web":
                            EmptyView()
                        default:
                            EmptyView()
                        }
                    }
                    VStack(spacing: 3) {
                        HStack(spacing: 3) {
                            Text("Your Presets")
                            VStack {
                                Divider()
                                    .frame(height: 1)
                                    .overlay(Color.accentColor)
                            }
                        }
                        Group {
                            HStack(spacing: 3) {
                                Button { } label: {
                                    Label("Load", systemImage: "folder.fill")
                                        .frame(maxWidth: .infinity)
                                    
                                }
                                Button { } label: {
                                    Label("Save", systemImage: "square.and.arrow.down.fill")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            Button { } label: {
                                Label("Apply to all Wallpapers", systemImage: "list.bullet.rectangle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            Button { } label: {
                                Label("Share JSON", systemImage: "arrow.2.squarepath")
                                    .frame(maxWidth: .infinity)
                            }
                            Button { } label: {
                                Label("Reset", systemImage: "arrow.triangle.2.circlepath")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                        .disabled(true)
                    }
                }
                .blur(radius: wallpaperViewModel.currentWallpaper.project == .invalid ? 16.0 : 0)
                .overlay {
                    if wallpaperViewModel.currentWallpaper.project == .invalid {
                        Text("Please select a valid wallpaper")
                    }
                }
                .disabled(wallpaperViewModel.currentWallpaper.project == .invalid ? true : false)
                .animation(.default, value: wallpaperViewModel.currentWallpaper.project)
                .padding([.horizontal, .top])
            }

            HStack {
                Spacer()
                Button {
                    AppDelegate.shared.mainWindowController.close()
                } label: {
                    Text("OK").frame(width: 50)
                }
                .buttonStyle(.borderedProminent)
                Button { 
                    AppDelegate.shared.mainWindowController.close()
                } label: {
                    Text("Cancel").frame(width: 50)
                }
            }
            .padding()
        }
    }
    
    /// Shows all tags about current wallpaper in horizontal
    var tags: some View {
        HStack {
            if let tags = wallpaperViewModel.currentWallpaper.project.tags {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .padding(5)
                        .background {
                            RoundedRectangle(cornerRadius: 25.0)
                                .colorInvert()
                                .foregroundStyle(Color.primary)
                            RoundedRectangle(cornerRadius: 25.0)
                                .stroke(Color.secondary, lineWidth: 1.6)
                        }
                        .overlay(alignment: .topTrailing) {
                            if hoveredTag == tag {
                                Button {
                                    var wallpaper = wallpaperViewModel.currentWallpaper

                                    guard let tags = wallpaper.project.tags else { return } // else case seems impossible, however much safer

                                    // Keep the authored order. Deduplicating through a Set used to
                                    // shuffle the remaining tags on every removal.
                                    let remaining = tags.filter { $0 != tag }
                                    guard remaining.count != tags.count else { return }

                                    // Same lossy-encoding trap as the title: patch, don't re-encode.
                                    guard ProjectJSONPatch.setTags(
                                        remaining, inWallpaperAt: wallpaper.wallpaperDirectory
                                    ) else { return }

                                    wallpaper.project.tags = remaining
                                    wallpaperViewModel.currentWallpaper = wallpaper
                                    viewModel.refresh() // tags are searchable; the grid renders a snapshot
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.white, .red)
                                .symbolRenderingMode(.palette)
                                .offset(x: 5, y: -2.5)
                            }
                        }
                        .onHover { hovered in
                            if hovered {
                                hoveredTag = tag
                            } else {
                                hoveredTag = nil
                            }
                        }
                }
            } else {
                Text("No Tags")
                    .foregroundStyle(Color.secondary)
            }
            
            if isTagsHovered {
                Button {
                    isEditingId = "tags"
                } label: {
                    Image(systemName: "plus")
                        .font(.body)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.footnote)
        .lineLimit(1)
    }
}

extension URL {
    /// check if the URL is a directory and if it is reachable
    func isDirectoryAndReachable() throws -> Bool {
        guard try resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            return false
        }
        return try checkResourceIsReachable()
    }

    /// returns total allocated size of a the directory including its subFolders or not
    func directoryTotalAllocatedSize(includingSubfolders: Bool = false) throws -> Int? {
        guard try isDirectoryAndReachable() else { return nil }
        if includingSubfolders {
            guard
                let urls = FileManager.default.enumerator(at: self, includingPropertiesForKeys: nil)?.allObjects as? [URL] else { return nil }
            return try urls.lazy.reduce(0) {
                    (try $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0) + $0
            }
        }
        return try FileManager.default.contentsOfDirectory(at: self, includingPropertiesForKeys: nil).lazy.reduce(0) {
                 (try $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                    .totalFileAllocatedSize ?? 0) + $0
        }
    }
}
