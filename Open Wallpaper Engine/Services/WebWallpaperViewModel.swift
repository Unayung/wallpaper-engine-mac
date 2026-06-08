import WebKit
import SwiftUI

class WebWallpaperViewModel: NSObject, ObservableObject, WKNavigationDelegate {
    var currentWallpaper: WEWallpaper
    
    var fileUrl: URL {
        currentWallpaper.wallpaperDirectory.appending(path: currentWallpaper.project.file)
    }
    
    var readAccessURL: URL {
        currentWallpaper.wallpaperDirectory
    }
    
    weak var webView: WKWebView?

    init(wallpaper: WEWallpaper) {
        self.currentWallpaper = wallpaper
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceDidChange(_:)), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceDidChange(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Allow navigation to external URLs (e.g. YouTube embeds from URL-based web wallpapers)
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let javascriptStyle = "var css = '*{-webkit-touch-callout:none;-webkit-user-select:none}'; var head = document.head || document.getElementsByTagName('head')[0]; var style = document.createElement('style'); style.type = 'text/css'; style.appendChild(document.createTextNode(css)); head.appendChild(style);"
        webView.evaluateJavaScript(javascriptStyle, completionHandler: nil)
        
    }
    
    @objc func systemWillSleep(_ notification: Notification) {}

    @objc func systemDidWake(_ notification: Notification) {
        webView?.reload()
    }

    @objc func spaceDidChange(_ notification: Notification) {
        // Resume any paused HTML5 video/audio after Mission Control transition
        webView?.evaluateJavaScript(
            "document.querySelectorAll('video,audio').forEach(m => { if(m.paused) m.play(); })",
            completionHandler: nil
        )
    }
}
