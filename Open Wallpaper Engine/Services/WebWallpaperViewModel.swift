//
//  WebWallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Toby on 2023/8/28.
//

import WebKit
import SwiftUI

class WebWallpaperViewModel: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    var currentWallpaper: WEWallpaper
    
    var fileUrl: URL {
        currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file)
    }
    
    var readAccessURL: URL {
        currentWallpaper.wallpaperDirectory
    }
    
    init(wallpaper: WEWallpaper) {
        self.currentWallpaper = wallpaper
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Allow navigation to external URLs (e.g. YouTube embeds from URL-based web wallpapers)
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let javascriptStyle = "var css = '*{-webkit-touch-callout:none;-webkit-user-select:none}'; var head = document.head || document.getElementsByTagName('head')[0]; var style = document.createElement('style'); style.type = 'text/css'; style.appendChild(document.createTextNode(css)); head.appendChild(style);"
        webView.evaluateJavaScript(javascriptStyle, completionHandler: nil)
        applyWallpaperScaling(to: webView)
        
        if AppDelegate.shared.globalSettingsViewModel.settings.adjustMenuBarTint {
            webView.takeSnapshot(with: nil) { [weak self] nsImage, error in
                guard let self = self else { return }
                if let data = nsImage?.tiffRepresentation {
                    do {
                        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "staticWP_\(self.currentWallpaper.wallpaperDirectory.hashValue).tiff")
                        try data.write(to: url, options: .atomic)
                        try NSWorkspace.shared.setDesktopImageURL(url, for: .main!)
                    } catch {
                        print(error)
                    }
                }
            }
        }
    }

    func applyWallpaperScaling(to webView: WKWebView) {
        let fitMode = AppDelegate.shared.globalSettingsViewModel.settings.wallpaperScaling.webObjectFit
        let script = """
        (function() {
          var fit = '\(fitMode)';
          var css = [
            'html, body { width: 100% !important; height: 100% !important; margin: 0 !important; overflow: hidden !important; background: #000 !important; }',
            '#root, #app, .app, main { width: 100vw !important; height: 100vh !important; max-width: none !important; max-height: none !important; margin: 0 !important; }',
            'canvas, video, img, svg { max-width: none !important; max-height: none !important; }',
            'canvas, video, img { width: 100vw !important; height: 100vh !important; object-fit: ' + fit + ' !important; }'
          ].join('\\n');
          var style = document.getElementById('open-wallpaper-engine-scaling');
          if (!style) {
            style = document.createElement('style');
            style.id = 'open-wallpaper-engine-scaling';
            document.head.appendChild(style);
          }
          style.textContent = css;
          window.dispatchEvent(new Event('resize'));
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadError(error, in: webView)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        NSLog("[WebWallpaper] %@", String(describing: message.body))
    }

    private func showLoadError(_ error: Error, in webView: WKWebView) {
        NSLog("[WebWallpaper] Failed to load '%@': %@", fileUrl.path(percentEncoded: false), error.localizedDescription)
        let escapedTitle = currentWallpaper.project.title.htmlEscaped()
        let escapedError = error.localizedDescription.htmlEscaped()
        let escapedFile = fileUrl.path(percentEncoded: false).htmlEscaped()
        let html = """
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
        code{display:block;white-space:pre-wrap;background:#222;padding:12px;border-radius:6px;color:#ddd}
        </style>
        </head>
        <body><main>
        <h1>Could not load \(escapedTitle)</h1>
        <p>\(escapedError)</p>
        <code>\(escapedFile)</code>
        </main></body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: currentWallpaper.wallpaperDirectory)
    }
    
    @objc func systemWillSleep(_ notification: Notification) {
        // Handle going to sleep
        print("System is going to sleep")
        // Update your SwiftUI state here if needed
    }
        
    @objc func systemDidWake(_ notification: Notification) {
        // Handle waking up
        print("System woke up from sleep")
        // Update your SwiftUI state here if needed
    }
}

private extension GSWallpaperScaling {
    var webObjectFit: String {
        switch self {
        case .fill:
            return "cover"
        case .fit:
            return "contain"
        case .stretch:
            return "fill"
        }
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
