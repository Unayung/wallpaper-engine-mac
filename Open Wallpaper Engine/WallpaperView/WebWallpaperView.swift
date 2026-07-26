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

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        Self.enableFileAccess(on: configuration)
        Self.installWallpaperEngineCompatibility(on: configuration, handler: viewModel)
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let nsView = WKWebView(frame: .zero, configuration: configuration)
        nsView.navigationDelegate = viewModel
        Self.loadWallpaper(nsView, viewModel: viewModel)
        return nsView
    }

    /// Load wallpaper — uses loadHTMLString for URL-based wallpapers (YouTube/Vimeo)
    /// so the origin isn't file://, or loadFileURL for local wallpapers.
    private static func loadWallpaper(_ webView: WKWebView, viewModel: WebWallpaperViewModel) {
        guard let fileUrl = resolvedWallpaperURL(for: viewModel) else {
            let message = "The project file '\(viewModel.currentWallpaper.project.file)' was not found."
            webView.loadHTMLString(errorHTML(title: viewModel.currentWallpaper.project.title, message: message), baseURL: viewModel.readAccessURL)
            NSLog("[WebWallpaper] %@", message)
            return
        }

        NSLog("[WebWallpaper] Loading %@", fileUrl.absoluteString)
        if ["http", "https"].contains(fileUrl.scheme?.lowercased()) {
            webView.load(URLRequest(url: fileUrl))
            return
        }

        // Check if the HTML contains a redirect/embed to an external URL
        if let html = try? String(contentsOf: fileUrl, encoding: .utf8),
           html.contains("youtube.com") || html.contains("vimeo.com") {
            // Load as HTML string with https origin so YouTube/Vimeo embeds work
            webView.loadHTMLString(html, baseURL: URL(string: "https://localhost"))
        } else {
            webView.loadFileURL(fileUrl, allowingReadAccessTo: viewModel.readAccessURL)
        }
    }

    private static func resolvedWallpaperURL(for viewModel: WebWallpaperViewModel) -> URL? {
        let projectFile = viewModel.currentWallpaper.project.file
        if let remoteURL = URL(string: projectFile),
           ["http", "https"].contains(remoteURL.scheme?.lowercased()) {
            return remoteURL
        }

        let directURL = viewModel.fileUrl
        if FileManager.default.fileExists(atPath: directURL.path(percentEncoded: false)) {
            return directURL
        }

        let fallbackNames = ["index.html", "index.htm", "main.html", "main.htm"]
        for name in fallbackNames {
            let fallbackURL = viewModel.readAccessURL.appending(path: name)
            if FileManager.default.fileExists(atPath: fallbackURL.path(percentEncoded: false)) {
                NSLog("[WebWallpaper] Project file '%@' missing; falling back to %@", projectFile, name)
                return fallbackURL
            }
        }

        if let enumerator = FileManager.default.enumerator(
            at: viewModel.readAccessURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where ["html", "htm"].contains(url.pathExtension.lowercased()) {
                NSLog("[WebWallpaper] Project file '%@' missing; falling back to %@", projectFile, url.lastPathComponent)
                return url
            }
        }

        return nil
    }

    private static func errorHTML(title: String, message: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        html,body{margin:0;width:100%;height:100%;background:#111;color:#eee;font:14px -apple-system,BlinkMacSystemFont,sans-serif}
        body{display:flex;align-items:center;justify-content:center}
        main{max-width:720px;padding:28px}
        h1{font-size:22px;margin:0 0 12px}
        p{line-height:1.45;color:#bbb}
        </style>
        </head>
        <body><main><h1>\(title.htmlEscaped())</h1><p>\(message.htmlEscaped())</p></main></body>
        </html>
        """
    }

    private static func installWallpaperEngineCompatibility(on configuration: WKWebViewConfiguration, handler: WKScriptMessageHandler) {
        let controller = configuration.userContentController
        controller.add(handler, name: "wallpaperLog")
        controller.addUserScript(WKUserScript(
            source: wallpaperEngineCompatibilityScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
    }

    private static let wallpaperEngineCompatibilityScript = """
    (function() {
      if (window.__openWallpaperEngineCompatibilityInstalled) return;
      window.__openWallpaperEngineCompatibilityInstalled = true;

      function log(message) {
        try { window.webkit.messageHandlers.wallpaperLog.postMessage(String(message)); } catch (_) {}
      }

      var userProperties = {};

      window.wallpaperRegisterAudioListener = window.wallpaperRegisterAudioListener || function(callback) {
        window.__wallpaperAudioListener = callback;
      };

      window.wallpaperRegisterUserPropertiesListener = window.wallpaperRegisterUserPropertiesListener || function(callback) {
        window.__wallpaperUserPropertiesListener = callback;
        try { callback(userProperties); } catch (error) { log(error); }
      };

      window.wallpaperPropertyListener = window.wallpaperPropertyListener || {
        applyUserProperties: function(properties) {
          userProperties = properties || userProperties;
        },
        applyGeneralProperties: function() {},
        userDirectoryFilesAddedOrChanged: function() {},
        userDirectoryFilesRemoved: function() {}
      };

      window.wallpaperRequestRandomFileForProperty = window.wallpaperRequestRandomFileForProperty || function(propertyName, callback) {
        if (typeof callback === 'function') callback('');
      };

      window.wallpaperGetThumbnail = window.wallpaperGetThumbnail || function(file, callback) {
        if (typeof callback === 'function') callback(file);
      };

      window.wallpaperSetPaused = window.wallpaperSetPaused || function() {};

      window.addEventListener('error', function(event) {
        log((event.message || 'Script error') + ' at ' + (event.filename || 'unknown') + ':' + (event.lineno || 0));
      });
      window.addEventListener('unhandledrejection', function(event) {
        log('Unhandled promise rejection: ' + (event.reason && event.reason.message ? event.reason.message : event.reason));
      });
    })();
    """

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
        let selectedWallpaper = wallpaperViewModel.wallpaper(for: screenId)
        let currentWallpaper = viewModel.currentWallpaper

        if selectedWallpaper.wallpaperDirectory.appending(path: selectedWallpaper.project.file) != currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file) {
            viewModel.currentWallpaper = selectedWallpaper
            Self.loadWallpaper(nsView, viewModel: viewModel)
        }
        viewModel.applyWallpaperScaling(to: nsView)
    }
}

private extension String {
    func htmlEscaped() -> String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
