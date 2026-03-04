//
//  WebWallpaperView.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/13.
//

import Cocoa
import SwiftUI
import WebKit

struct WebWallpaperView: NSViewRepresentable {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @StateObject var viewModel: WebWallpaperViewModel
    
    init(wallpaperViewModel: WallpaperViewModel) {
        self.wallpaperViewModel = wallpaperViewModel
        self._viewModel = StateObject(wrappedValue: WebWallpaperViewModel(wallpaper: wallpaperViewModel.currentWallpaper))
    }
    
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        Self.enableFileAccess(on: configuration)

        let nsView = WKWebView(frame: .zero, configuration: configuration)
        nsView.navigationDelegate = viewModel
        nsView.loadFileURL(viewModel.fileUrl, allowingReadAccessTo: viewModel.readAccessURL)
        return nsView
    }

    /// Enable file:// cross-origin access for WebGL wallpapers.
    /// Tries multiple private WebKit key variants, catching ObjC exceptions for each.
    private static func enableFileAccess(on configuration: WKWebViewConfiguration) {
        let prefs = configuration.preferences

        // Key variants across macOS versions
        let fileAccessKeys = ["allowFileAccessFromFileURLs", "_allowFileAccessFromFileURLs"]
        let universalAccessKeys = ["allowUniversalAccessFromFileURLs", "_allowUniversalAccessFromFileURLs"]

        for key in fileAccessKeys {
            if ObjCExceptionCatcher.performSafe({ prefs.setValue(true, forKey: key) }) { break }
        }

        for key in universalAccessKeys {
            if ObjCExceptionCatcher.performSafe({ prefs.setValue(true, forKey: key) }) { break }
        }
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        let selectedWallpaper = wallpaperViewModel.currentWallpaper
        let currentWallpaper = viewModel.currentWallpaper
        
        if selectedWallpaper.wallpaperDirectory.appending(path: selectedWallpaper.project.file) != currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file) {
            viewModel.currentWallpaper = selectedWallpaper
            nsView.loadFileURL(viewModel.fileUrl, allowingReadAccessTo: viewModel.readAccessURL)
        }
    }
}
