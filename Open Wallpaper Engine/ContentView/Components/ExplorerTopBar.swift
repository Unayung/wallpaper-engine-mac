//
//  ExplorerTopBar.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

struct ExplorerTopBar: SubviewOfContentView {
    @ObservedObject var viewModel: ContentViewModel
    
    @EnvironmentObject var globalSettingsViewModel: GlobalSettingsViewModel
    
    init(contentViewModel viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }
    
    var body: some View {
        HStack {
            TextField("Search", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            Button {
                viewModel.isFilterReveal.toggle()
            } label: {
                Label("Filter Results", systemImage: "checklist.checked")
            }
            .buttonStyle(.borderedProminent)
            if globalSettingsViewModel.settings.autoRefresh {
                Button {
                    viewModel.refresh()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
            Spacer()
            Button { 
                if viewModel.sortingSequence == .decrease {
                    viewModel.sortingSequence = .increase
                } else {
                    viewModel.sortingSequence = .decrease
                }
            } label: {
                Image(systemName: viewModel.sortingSequence == .increase ?
                      "arrowtriangle.down.fill" : "arrowtriangle.up.fill")
            }
            .buttonStyle(.plain)
            Picker("Sort By", selection: $viewModel.sortingBy) {
                // Tagged with the enum itself. SwiftUI matches a Picker's tags by exact type,
                // and `.tag(method.rawValue)` (a String) matched no WEWallpaperSortingMethod
                // selection, so the popup showed no value and choosing one wrote nothing.
                ForEach(WEWallpaperSortingMethod.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }
}
