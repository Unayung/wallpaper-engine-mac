//
//  ExplorerGlobalMenu.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

struct ExplorerGlobalMenu: SubviewOfContentView {
    
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    
    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel) {
        self.wallpaperViewModel = wallpaperViewModel
        self.viewModel = viewModel
    }
    
    var body: some View {
        Section {
            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: FileManager.default.wallpapersDirectory.path(percentEncoded: false))
            } label: {
                Label("Open All in Finder", systemImage: "folder.badge.gearshape")
            }
            Menu("View") {
                Section {
                    Picker("Icon Size", selection: $viewModel.explorerIconSize) {
                        Text("Small Icons").tag(Double(100))
                        Text("Medium Icons").tag(Double(125))
                        Text("Large Icons").tag(Double(150))
                    }
                    .pickerStyle(.inline)
                }
                // "Titles per page" lived here; it drove the paging that never paged.
                // See WallpaperExplorer.
            }
        }
        .labelStyle(.titleAndIcon)
    }
}
