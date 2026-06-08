//
//  WallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/5.
//

import Cocoa
import SwiftUI

struct WallpaperView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    let screenId: String

    var body: some View {
        let wallpaper = viewModel.wallpaper(for: screenId)
        switch wallpaper.project.type.lowercased() {
        case "video":
            VideoWallpaperView(wallpaperViewModel: viewModel, screenId: screenId)
        case "scene":
            SceneWallpaperView(wallpaperViewModel: viewModel, screenId: screenId)
        case "web":
            WebWallpaperView(wallpaperViewModel: viewModel, screenId: screenId)
        default:
            EmptyView()
        }
    }
}
