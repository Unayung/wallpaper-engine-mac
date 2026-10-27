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
    let screenId: String

    init(wallpaperViewModel: WallpaperViewModel, screenId: String) {
        self.wallpaperViewModel = wallpaperViewModel
        self.screenId = screenId
        self._viewModel = StateObject(wrappedValue: WebWallpaperViewModel(wallpaper: wallpaperViewModel.wallpaper(for: screenId)))
    }

    func makeNSView(context: Context) -> WebWallpaperContainerView {
        let configuration = WKWebViewConfiguration()
        Self.enableFileAccess(on: configuration)
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // At document start, so the globals exist before the page's first script probes them.
        configuration.userContentController.addUserScript(WKUserScript(
            source: WebWallpaperViewModel.hostAPIScript,
            injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let nsView = WKWebView(frame: .zero, configuration: configuration)
        // No white page while the wallpaper loads: WebKit paints its own white background
        // until the page's first frame, which on a heavy WebGL or video page is seconds of a
        // white desktop. Transparent shows the window's black instead.
        // A private KVC key, so guarded like the file-access keys below: a WebKit without it
        // throws, and the page then just keeps its white background.
        _ = ObjCExceptionCatcher.performSafe({ nsView.setValue(false, forKey: "drawsBackground") })
        nsView.underPageBackgroundColor = .black
        nsView.navigationDelegate = viewModel
        viewModel.webView = nsView

        // The cover is attached before anything loads or binds: every load resets it, and the
        // view model reloads by itself after a web-content crash, so loading lives there.
        let container = WebWallpaperContainerView(webView: nsView)
        viewModel.freezeCover = container.freezeCover
        viewModel.bind(to: wallpaperViewModel, screenId: screenId)
        viewModel.load()
        return container
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

        // Universal access is a property of the configuration, not of WKPreferences: on
        // WKPreferences both key variants throw (and the catcher swallowed it, so this used to
        // end with universal access silently off). The configuration is tried first; the
        // preferences variants stay as a fallback for WebKit versions that kept it there.
        if !ObjCExceptionCatcher.performSafe({
            configuration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        }) {
            for key in universalAccessKeys {
                if ObjCExceptionCatcher.performSafe({ prefs.setValue(true, forKey: key) }) { break }
            }
        }
    }

    func updateNSView(_ container: WebWallpaperContainerView, context: Context) {
        let selectedWallpaper = wallpaperViewModel.wallpaper(for: screenId)
        let currentWallpaper = viewModel.currentWallpaper

        if selectedWallpaper.wallpaperDirectory.appending(path: selectedWallpaper.project.file) != currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file) {
            viewModel.currentWallpaper = selectedWallpaper
            viewModel.load()
        }
    }
}

/// The web view plus the still that stands in for it while playback is paused.
///
/// The still has to be a sibling rather than a subview of the web view, because the web view
/// itself is hidden while paused — that is what makes WebKit throttle the page.
final class WebWallpaperContainerView: NSView {
    let webView: WKWebView
    let freezeCover = NSImageView()

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        for view in [webView, freezeCover] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        freezeCover.imageScaling = .scaleAxesIndependently
        freezeCover.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
