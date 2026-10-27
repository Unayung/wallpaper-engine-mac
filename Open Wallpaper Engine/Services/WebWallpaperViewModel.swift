//
//  WebWallpaperViewModel.swift
//  Open Wallpaper Engine
//
//  Created by Toby on 2023/8/28.
//

import WebKit
import SwiftUI
import Combine

class WebWallpaperViewModel: NSObject, ObservableObject, WKNavigationDelegate {
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
        // Display sleep is a policy decision, not a playback one: AppDelegate observes the
        // sleep/wake notifications and applies the `Display asleep` setting.
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Wallpaper Engine host API

    /// The globals a Wallpaper Engine page expects its host to provide, installed before any of
    /// the page's own scripts run.
    ///
    /// Pages probe for these and branch on the answer, so leaving them undefined is not neutral.
    /// 2AM Cyberpunk City prints "can't register audio listener" into an on-screen log box; the
    /// Customizable Module Visualizer silently switches to a random-number generator and
    /// animates bars to no sound at all. Wallpaper Engine itself, with nothing playing, keeps
    /// calling the audio listener with 128 zeros about 30 times a second — 2AM Cyberpunk
    /// resets a ten-second "Not receiving audio from Wallpaper Engine" timer on every call — so
    /// that is what is fed here: the faithful reading of a silent room, not a no-op.
    ///
    /// The media registrars (now-playing title, thumbnail, timeline) are accepted and never
    /// called, which is what Wallpaper Engine does when no media session is active.
    static let hostAPIScript = """
    (function () {
        if (window.__oweHost) { return; }
        var host = window.__oweHost = { paused: false, audio: [], audioTimer: null };
        var silence = new Array(128).fill(0);
        function tickAudio() {
            if (host.paused) { return; }
            for (var i = 0; i < host.audio.length; i++) {
                try { host.audio[i](silence.slice()); } catch (e) { console.error(e); }
            }
        }
        window.wallpaperRegisterAudioListener = function (callback) {
            if (typeof callback !== 'function') { return; }
            host.audio.push(callback);
            if (!host.audioTimer) { host.audioTimer = setInterval(tickAudio, 33); }
        };
        ['wallpaperRegisterMediaStatusListener', 'wallpaperRegisterMediaPropertiesListener',
         'wallpaperRegisterMediaThumbnailListener', 'wallpaperRegisterMediaPlaybackListener',
         'wallpaperRegisterMediaTimelineListener'].forEach(function (name) {
            if (!window[name]) { window[name] = function () {}; }
        });

        // Pause gate. Only pages written for Wallpaper Engine implement setPaused, and plenty
        // of the rest drive a canvas or WebGL loop from requestAnimationFrame, which WebKit keeps
        // firing for an on-screen view. While paused, frame callbacks are held rather than run,
        // and released together on resume, so the loop stops without the page having to know.
        var raf = window.requestAnimationFrame.bind(window);
        var caf = window.cancelAnimationFrame.bind(window);
        var held = new Map(), nextHeld = -1;
        window.requestAnimationFrame = function (callback) {
            if (!host.paused) { return raf(callback); }
            var id = nextHeld--;
            held.set(id, callback);
            return id;
        };
        window.cancelAnimationFrame = function (id) {
            if (id < 0) { held.delete(id); } else { caf(id); }
        };
        host.setPaused = function (paused) {
            if (host.paused === paused) { return; }
            host.paused = paused;
            var l = window.wallpaperPropertyListener;
            try { if (l && l.setPaused) { l.setPaused(paused); } } catch (e) { console.error(e); }
            if (!paused) {
                var callbacks = Array.from(held.values());
                held.clear();
                callbacks.forEach(function (callback) { raf(callback); });
            }
        };

        // Volume for media elements, including ones created after this call: WebKit has no
        // public per-view volume, so each element is set as it starts playing. The host volume
        // *scales* the level the page chose, remembered the first time an element is seen, and
        // `muted` is never touched: forcing `muted = (volume === 0)` unmuted media an author
        // had muted on purpose and replaced their mix with a flat level. Volume 0 is silence
        // without it.
        host.volume = 1;
        function applyVolume(element) {
            if (!element || typeof element.volume !== 'number') { return; }
            if (typeof element.__oweAuthorVolume !== 'number') {
                element.__oweAuthorVolume = element.volume;
            }
            element.volume = element.__oweAuthorVolume * host.volume;
        }
        host.setVolume = function (volume) {
            host.volume = Math.max(0, Math.min(1, volume));
            document.querySelectorAll('audio, video').forEach(applyVolume);
        };
        document.addEventListener('play', function (event) { applyVolume(event.target); }, true);
        document.addEventListener('loadedmetadata', function (event) { applyVolume(event.target); }, true);
    })();
    """

    // MARK: - Playback control surface

    /// The web view this model drives. Weak: the representable owns the view.
    weak var webView: WKWebView?

    private var cancellables = Set<AnyCancellable>()
    private var playRate: Float = 1
    private var playVolume: Float = 1

    /// Mirror the shared `playRate` / `playVolume` onto the page, as `VideoWallpaperViewModel`
    /// mirrors them onto its `AVPlayer`. Without this a web wallpaper ignored Pause, Mute and
    /// every auto-pause / auto-mute policy: it kept rendering at full rate and kept its sound
    /// with the displays asleep.
    ///
    /// The `WallpaperViewModel` is passed in rather than reached through `AppDelegate.shared`, so
    /// nothing here depends on when this model is constructed.
    func bind(to wallpaperViewModel: WallpaperViewModel, screenId: String) {
        cancellables.removeAll()
        wallpaperViewModel.$playRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                guard let self else { return }
                self.playRate = rate
                self.applyPlayback()
            }
            .store(in: &cancellables)
        // Muted unless this is the screen that is heard; see WallpaperViewModel.audioScreenId.
        wallpaperViewModel.$playVolume.combineLatest(wallpaperViewModel.$audioScreenId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volume, audioScreenId in
                guard let self else { return }
                self.playVolume = audioScreenId == screenId ? volume : 0
                self.applyPlayback()
            }
            .store(in: &cancellables)
    }

    /// Push the current rate and volume into the page. Also re-run after every navigation,
    /// because a reload starts the page's script state from scratch.
    func applyPlayback() {
        guard let webView else { return }
        let paused = playRate == 0
        // While the first still of a freshly loaded page is pending, the page must keep
        // running: its own frame loop is what paints the frame the still is made of, and the
        // pause gate would hold it. `captureFreshCover` pauses the page once it has the still.
        let holdPage = paused && !needsFreshCover
        webView.evaluateJavaScript("""
            if (window.__oweHost) {
                window.__oweHost.setPaused(\(holdPage));
                window.__oweHost.setVolume(\(playVolume));
            }
            """, completionHandler: nil)
        // Media elements and Web Audio are stopped at the WebKit level too: the JS above only
        // reaches what the page exposes, and an AudioContext has no volume to set.
        webView.setAllMediaPlaybackSuspended(paused, completionHandler: nil)
        Self.setPageMuted(webView, playVolume == 0)
        setFrozen(paused)
    }

    /// Still image of the page shown in its place while paused. Weak: the container view owns it.
    weak var freezeCover: NSImageView?

    /// True from the start of a navigation until a still of *that* page has been taken.
    ///
    /// The cover used to be tied to nothing but the web view's visibility: `setFrozen(true)`
    /// returned early whenever the page was already hidden, so choosing another web wallpaper
    /// while paused loaded it underneath and went on showing the previous wallpaper's still;
    /// and a view built while paused took its still at once, of a page that had not loaded,
    /// which is an empty frame. Every load now resets the cover and marks it stale.
    private var needsFreshCover = true
    /// Set by `didFinish`, cleared by the next navigation or crash: a still before is of nothing.
    private var isPageLoaded = false
    private var isCapturingCover = false
    /// Bumped by every load, resume and give-up, so a capture that outlives one is dropped.
    private var coverGeneration = 0

    /// Swap the live page for a still of itself, and hide the page.
    ///
    /// The pause gate above only reaches `requestAnimationFrame` and pages that implement
    /// `setPaused`, and some do neither usefully: 2AM Cyberpunk City drives itself from
    /// `setTimeout` and its own `setPaused` has the stop commented out, so it kept running 16
    /// timer callbacks a second while "paused". A hidden `WKWebView` is throttled by WebKit
    /// itself — measured on the same page, 15 callbacks a second down to 1 — but hiding it
    /// alone would show whatever sits behind the window, so the last frame is put up first.
    private func setFrozen(_ frozen: Bool) {
        // Given up after repeated crashes: the preview is the cover, whatever the rate.
        guard let webView, let cover = freezeCover, !hasGivenUp else { return }
        if !frozen {
            // Only a real resume cancels: this runs on every volume change while playing.
            if isCapturingCover || webView.isHidden || !cover.isHidden {
                coverGeneration += 1
                isCapturingCover = false
            }
            webView.isHidden = false
            cover.isHidden = true
            cover.image = nil
            return
        }
        if needsFreshCover {
            captureFreshCover()
            return
        }
        guard !webView.isHidden else { return }
        let generation = coverGeneration
        webView.takeSnapshot(with: nil) { [weak self, weak webView, weak cover] image, _ in
            // Resumed (or navigated) while the snapshot was being taken: leave the page live.
            guard let self, self.coverGeneration == generation, self.playRate == 0,
                  let webView, let cover else { return }
            cover.image = image
            cover.isHidden = image == nil
            webView.isHidden = image != nil
        }
    }

    /// How long a page loaded while paused runs before its still is taken. `didFinish` is the
    /// document having loaded, not having drawn: a WebGL page still has to compile its shaders
    /// and decode its textures, so a still taken there is of a black frame.
    private static let freshCoverDelay: TimeInterval = 1.0

    /// Take the first still of a page loaded while paused, then hold the page.
    ///
    /// Waits for `didFinish` (which re-runs `applyPlayback`, so nothing is lost by returning
    /// early) and then a moment more; see `freshCoverDelay`. Media is already suspended by
    /// `applyPlayback`, so the page is silent while it paints.
    private func captureFreshCover() {
        guard isPageLoaded, !isCapturingCover else { return }
        isCapturingCover = true
        let generation = coverGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.freshCoverDelay) { [weak self] in
            guard let self, self.coverGeneration == generation, let webView = self.webView else { return }
            webView.takeSnapshot(with: nil) { [weak self, weak webView] image, _ in
                guard let self, self.coverGeneration == generation else { return }
                self.isCapturingCover = false
                self.needsFreshCover = false
                guard self.playRate == 0, let webView, let cover = self.freezeCover else { return }
                cover.image = image
                cover.isHidden = image == nil
                webView.isHidden = image != nil
                // Now the page may be held: `needsFreshCover` is clear, so this pauses it.
                self.applyPlayback()
            }
        }
    }

    // MARK: - Loading and crash recovery

    /// Load the current wallpaper into the web view, starting the cover over.
    ///
    /// A crash reload keeps the crash history; any other load is a different wallpaper (or
    /// the same one chosen again) and starts with a clean slate.
    func load(isCrashRecovery: Bool = false) {
        guard let webView else { return }
        if !isCrashRecovery {
            crashTimes.removeAll()
            hasGivenUp = false
        }
        pendingCrashReload?.cancel()
        pendingCrashReload = nil

        coverGeneration += 1
        isCapturingCover = false
        needsFreshCover = true
        isPageLoaded = false
        webView.isHidden = false
        freezeCover?.isHidden = true
        freezeCover?.image = nil
        freezeCover?.imageScaling = .scaleAxesIndependently

        // Load as an HTML string with an https origin when the page embeds YouTube/Vimeo,
        // which refuse a file:// origin; anything else as a file URL with access to its folder.
        let fileUrl = self.fileUrl
        if let html = try? String(contentsOf: fileUrl, encoding: .utf8),
           html.contains("youtube.com") || html.contains("vimeo.com") {
            webView.loadHTMLString(html, baseURL: URL(string: "https://localhost"))
        } else {
            webView.loadFileURL(fileUrl, allowingReadAccessTo: readAccessURL)
        }
    }

    /// When each recent web-content crash happened, oldest first.
    private var crashTimes: [Date] = []
    private var pendingCrashReload: DispatchWorkItem?
    /// Set once the page has crashed too often; the preview stands in for it until the next
    /// wallpaper is loaded here.
    private(set) var hasGivenUp = false

    /// The wait before the first, second and third reload after a crash.
    private static let crashReloadDelays: [TimeInterval] = [1, 5, 30]
    /// Crashes further apart than this are unrelated, and do not count towards giving up.
    private static let crashWindow: TimeInterval = 10 * 60

    /// The page's web-content process died: a WebGL page exhausting GPU memory, a WebKit
    /// bug, or the system reclaiming memory under pressure.
    ///
    /// Implementing this turns WebKit's own recovery off, which is the point. WebKit reloads
    /// a crashed page by itself only once in a short window — measured: killing the page's
    /// `com.apple.WebKit.WebContent` process a second time a few seconds after the first left
    /// it dead — and a wallpaper window has nobody to click "reload", so the desktop stayed
    /// black until the app was restarted. Here every crash is reloaded after a backoff, so a
    /// page that dies on load cannot spin the GPU in a loop, and past the last delay inside
    /// the window the wallpaper's preview is put up instead and the reason logged.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        crashTimes = crashTimes.filter { now.timeIntervalSince($0) < Self.crashWindow } + [now]
        let attempt = crashTimes.count
        isPageLoaded = false

        guard attempt <= Self.crashReloadDelays.count else {
            NSLog("[WebVM] %@: web content process terminated %d times within %d s; showing its preview instead",
                  fileUrl.path(percentEncoded: false), attempt, Int(Self.crashWindow))
            showPreviewInsteadOfPage()
            return
        }
        let delay = Self.crashReloadDelays[attempt - 1]
        NSLog("[WebVM] %@: web content process terminated (%d of %d); reloading in %.0f s",
              fileUrl.path(percentEncoded: false), attempt, Self.crashReloadDelays.count, delay)
        let work = DispatchWorkItem { [weak self] in self?.load(isCrashRecovery: true) }
        pendingCrashReload?.cancel()
        pendingCrashReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The wallpaper's own preview image, found as `VideoWallpaperViewModel` finds the one it
    /// falls back to for a video it cannot decode.
    private var previewImageURL: URL? {
        let dir = currentWallpaper.wallpaperDirectory
        let declared = currentWallpaper.project.preview
        let names = (declared.isEmpty ? [] : [declared]) + ["preview.gif", "preview.jpg", "preview.png"]
        return names.map { dir.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    private func showPreviewInsteadOfPage() {
        hasGivenUp = true
        coverGeneration += 1
        isCapturingCover = false
        guard let webView, let cover = freezeCover else { return }
        let image = previewImageURL.flatMap(NSImage.init(contentsOf:))
        // Proportional, not stretched like the snapshots: a preview is usually square and the
        // screen is not. Without any preview the window's black shows, as before, but no
        // longer a dead page.
        cover.imageScaling = .scaleProportionallyUpOrDown
        cover.image = image
        cover.isHidden = image == nil
        webView.isHidden = true
    }

    /// `-[WKWebView _setPageMuted:]`, the private call Safari's tab mute uses. It silences Web
    /// Audio as well as media elements, which nothing public does. Looked up at run time and
    /// skipped if a future WebKit drops it.
    private static func setPageMuted(_ webView: WKWebView, _ muted: Bool) {
        let selector = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: selector) else { return }
        typealias SetPageMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
        let call = unsafeBitCast(webView.method(for: selector), to: SetPageMuted.self)
        // _WKMediaAudioMuted = 1 << 0; 0 clears every muted state.
        call(webView, selector, muted ? 1 : 0)
    }

    /// The page's `project.json` `general.properties`, exactly as written.
    ///
    /// Read as a plain dictionary on purpose: `WEProject` models only `schemecolor` and would
    /// hand the page an almost empty object. The shape is already the one Wallpaper Engine
    /// passes to `applyUserProperties` — `{key: {type, value, …}}` — so it goes through untouched.
    private func userPropertiesJSON() -> String? {
        let url = currentWallpaper.wallpaperDirectory.appending(path: "project.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let general = root["general"] as? [String: Any],
              let properties = general["properties"] as? [String: Any],
              JSONSerialization.isValidJSONObject(properties),
              let json = try? JSONSerialization.data(withJSONObject: properties) else { return nil }
        return String(data: json, encoding: .utf8)
    }

    /// Hand the page the settings Wallpaper Engine would give it once it has loaded.
    ///
    /// Without this a page never learns its authored defaults, and some never start at all:
    /// 2AM Cyberpunk City gates its whole animation loop on a flag only `applyUserProperties`
    /// sets, so it spun on `setTimeout` forever over a black frame — 0.8% of pixels lit. With
    /// the properties delivered the same page draws its city, clock and visualizer (63%).
    private func deliverProperties(to webView: WKWebView) {
        let fps = Int(AppDelegate.shared.globalSettingsViewModel.settings.fps)
        var script = """
        (function () {
            var l = window.wallpaperPropertyListener;
            if (!l) { return; }
            try { if (l.applyGeneralProperties) { l.applyGeneralProperties({ fps: \(fps) }); } }
            catch (e) { console.error(e); }
        """
        if let properties = userPropertiesJSON() {
            script += """

            try { if (l.applyUserProperties) { l.applyUserProperties(\(properties)); } }
            catch (e) { console.error(e); }
            """
        }
        script += "\n})();"
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Allow navigation to external URLs (e.g. YouTube embeds from URL-based web wallpapers)
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPageLoaded = true
        // A page that is playing has painted by the time `freshCoverDelay` is up, so a later
        // pause can take its still at once, as it always did, instead of letting it run on.
        let generation = coverGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.freshCoverDelay) { [weak self] in
            guard let self, self.coverGeneration == generation, !self.isCapturingCover else { return }
            if self.playRate != 0 { self.needsFreshCover = false }
        }
        let javascriptStyle = "var css = '*{-webkit-touch-callout:none;-webkit-user-select:none}'; var head = document.head || document.getElementsByTagName('head')[0]; var style = document.createElement('style'); style.type = 'text/css'; style.appendChild(document.createTextNode(css)); head.appendChild(style);"
        webView.evaluateJavaScript(javascriptStyle, completionHandler: nil)

        deliverProperties(to: webView)
        applyPlayback()

        // The menu-bar placeholder used to be a snapshot taken here and set on the main
        // screen whichever screen this page was on; AppDelegate.refreshPlaceholders now
        // gives each screen the preview of its own wallpaper.
    }
}
