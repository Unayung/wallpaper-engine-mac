//
//  WallpaperExplorer.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

struct WallpaperExplorer: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    
    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel) {
        self.viewModel = viewModel
        self.wallpaperViewModel = wallpaperViewModel
    }
    
    var body: some View {
        ScrollView {
            // MARK: Items
            if viewModel.wallpapers.isEmpty {
                HStack {
                    Spacer()
                    Text("""
                        No wallpapers found for your search.
                        Expand or reset the categories in the filter sidebar or try another search term.
                        """)
                    .font(.title)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .lineSpacing(10)
                    Spacer()
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 50)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: viewModel.explorerIconSize, 
                                                       maximum: viewModel.explorerIconSize * 2)
                )], alignment: .leading) {
                    // Rendered from the snapshot, never the computed chain: see refresh().
                    // Keyed by folder rather than position, so a search or re-sort moves
                    // tiles instead of handing each slot a different wallpaper to reload.
                    ForEach(Array(viewModel.wallpapers.enumerated()), id: \.1.wallpaperDirectory) { (index, wallpaper) in
                        ExplorerItem(viewModel: viewModel, wallpaperViewModel: wallpaperViewModel, wallpaper: wallpaper, index: index)
                            .contextMenu {
                                ExplorerItemMenu(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel, current: wallpaper)
                                ExplorerGlobalMenu(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel)
                            }
                            .animation(.spring(), value: viewModel.imageScaleIndex)
//                            .animation(.spring(), value: wallpaperViewModel.currentWallpaper.rawValue)
                    }
                }
                .padding(.trailing)
            }
        }
        // No pagination. There used to be page buttons over the bottom of the grid, but the
        // slicing behind them was commented out, so they changed nothing — and the grid is
        // a LazyVGrid, which already only builds the tiles on screen, so paging would buy
        // nothing back.
    }
}

// MARK: - View Modifiers Extension
struct SelectedItem: ViewModifier {
    var selected: Bool
    
    init(_ selected: Bool) {
        self.selected = selected
    }
    
    func body(content: Content) -> some View {
        return content
            .border(Color.accentColor, width: selected ? 3 : 0)
    }
}

extension View {
    func selected(_ selected: Bool = true) -> some View {
        return modifier(SelectedItem(selected))
    }
}
