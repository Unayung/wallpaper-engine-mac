Open Wallpaper Engine (Patched)
=========

**English** | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md)

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

A patched fork of [Open Wallpaper Engine](https://github.com/MrWindDog/wallpaper-engine-mac) for macOS, adding scene wallpaper rendering and web wallpaper fixes.

> **Note:** This is NOT affiliated with the commercial Wallpaper Engine on Steam. This is an open-source macOS app that can display wallpaper assets from Wallpaper Engine's Steam Workshop.

## Related Projects

- **[Open Wallpaper Engine for Linux](https://github.com/Unayung/simple-linux-wallpaperengine-gui)** — A PyQt6 GUI for [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine), with Steam Workshop integration and UI design ported from this macOS version.

## Credits

This project is built on top of the work of:

- **[MrWindDog](https://github.com/MrWindDog)** — Maintainer of the upstream [wallpaper-engine-mac](https://github.com/MrWindDog/wallpaper-engine-mac) fork, added new features and UI refinements
- **[Haren Chen](https://github.com/haren724)** — Original creator of [open-wallpaper-engine-mac](https://github.com/haren724/open-wallpaper-engine-mac), built the core app architecture (SwiftUI, video wallpaper playback, import system, playlist UI)
- **[1ris_W](https://github.com/Erica-Iris)** — Chinese i18n translation
- **[Klaus Zhu](https://github.com/klauszhu1105)** — App logo icons
- **[Chen Chia Yang](https://github.com/Unayung)** — Scene wallpaper rendering, web wallpaper fixes, Steam Workshop integration, multi-display support, zip import

Licensed under [GPL-3.0](LICENSE), same as the original project.

## What's New in 0.8.0

### Multi-Display Support
Assign different wallpapers to each connected monitor with per-screen enable/disable control.
- **Display Settings panel** — Visual monitor layout showing all connected screens, click to select
- **Per-screen wallpaper** — Each display can show a different wallpaper independently
- **Enable/disable toggle** — Turn wallpaper on or off per monitor
- **Auto-detect** — New monitors are automatically detected and enabled when connected

### Multi-Desktop Support
Wallpapers now display across all macOS desktops (Spaces) with continuous playback — no interruption when switching desktops.

### Recent Wallpapers Menu
Quickly switch wallpapers from the status bar menu. The last 10 wallpapers you've used are listed for one-click access.

### Playback Settings — Fixed
Performance playback settings (pause/mute/stop when other apps are focused) now work correctly for all wallpaper types.

### Settings apply instantly
Every control in Settings takes effect the moment it changes, as in macOS's own settings windows;
there is no OK or Cancel. The quality presets (Low / Medium / High / Ultra) show which one the
current settings amount to, or "Custom". "Start with macOS" shows what macOS itself reports,
including a pending approval in System Settings → Login Items, and "Reset" asks before resetting.
Settings shows only controls that do something: the disabled placeholders (language, audio output,
video framework, anti-aliasing, process priority, log level, the Plugins page) are gone. The app
follows the system language, and General links to Language & Region for a per-app choice; the
GIF-animation toggle that sat alone on Plugins is now "Animate GIF previews in library" in General.
General → Library can point the library at another folder (Choose…, Reset to Default, Show in
Finder); nothing is moved or deleted, a screen showing a wallpaper from the previous folder keeps
it, and while a chosen folder is unavailable (an unplugged drive) the default one is used, switching back by itself when
the drive returns. General →
Developer shows where Wallpaper Engine's shared assets were found — scenes need them for shared
models, materials and particle presets — lets you pick that folder, and can disable scene scripts
to tell a scripted layer from a mis-rendered one. Scene wallpapers reload when either changes.

### Steam Workshop Browser
Browse, search, and download wallpapers directly from the Steam Workshop without leaving the app.
- **Search & filter** — Search by name, filter by content rating (Everyone/Questionable/Mature), type (Scene/Video/Web), and genre tags
- **Sort options** — Trending, Most Recent, Most Popular, Most Subscribed
- **steamcmd integration** — Auto-detects steamcmd (Homebrew or custom path), with install instructions if not found
- **Steam login** — Supports password, Steam Guard, and cached session authentication
- **Download with progress** — Real-time status updates during download (authenticating, downloading %, validating, copying)
- **Safe defaults** — Content rating defaults to "Everyone" to filter out mature content

### Library Filters
The library's filter sidebar narrows your installed wallpapers by Type, Age Rating, Source (Workshop or My Wallpapers) and genre Tags, read from each wallpaper's `project.json`. In Source and Tags, unticking every box shows everything. There is no Resolution filter: Wallpaper Engine's resolution boxes match Workshop tags that installed packages do not carry.

### Zip Import
Import wallpaper packages directly from `.zip` files — no need to manually extract first. Works via File > Import and drag-and-drop.

### Multi-Select & Batch Unsubscribe
Cmd+click to select multiple wallpapers, then right-click to batch unsubscribe.

### Wallpaper Storage Isolation
Wallpapers are now stored in `~/Documents/Open Wallpaper Engine/` instead of the raw Documents directory, preventing "error" wallpapers when cloning the repo on a fresh machine. The folder can be changed in Settings → General → Library.

## What's Patched

### Web Wallpapers — Fixed gray/blank rendering
WebGL-based wallpapers rendered as gray rectangles because `WKWebView` blocked local file access for textures and assets.

**Fix:** Enabled `allowFileAccessFromFileURLs` and `allowUniversalAccessFromFileURLs` on the WKWebView configuration, allowing WebGL shaders to load local texture files.

### Scene Wallpapers — Implemented from scratch
Scene wallpapers (the most common type on Steam Workshop) were completely unimplemented — just showed "Hello, World!".

**New implementation includes:**
- **PKG parser** — Reads Wallpaper Engine's PKGV archive format to extract scene.json, models, materials, and textures
- **TEX parser** — Reads TEXV0005 texture containers: embedded JPEG/PNG payloads, raw pixels (usually LZ4-block compressed) in RGBA8888 or 1–2 bytes per pixel, and DXT1/DXT3/DXT5 block compression, across every TEXB revision 0001–0004. A `.tex` that holds an MP4 is detected by its payload and drawn as its first frame
- **Scene JSON decoder** — Parses scene.json with flexible decoding that handles Wallpaper Engine's polymorphic fields (values can be plain types or `{"script":..,"value":..}` objects)
- **SpriteKit renderer** — Renders scene image layers as SKSpriteNodes with correct positioning, sizing, alpha, color tinting, and blend modes
- **Preview fallback** — Falls back to preview.jpg/png/gif when textures can't be extracted
- **Text layers** — Clocks, labels and readouts are rasterised at Wallpaper Engine's own scale (`pointsize × 4`) inside the box the author baked, and the JavaScript behind them runs in a sandboxed `JSContext` (see Scene Motion)
- **Scene sound** — A scene's sound objects play through `AVAudioPlayer`, following the app's volume, pause and audio-screen rules like every other wallpaper type

### Import — Fixed folder import
The import panel now correctly handles both individual wallpaper folders and parent directories containing multiple wallpapers.

## Scene Effects

Each layer's `effects` array becomes a chain of nested `SKEffectNode`s, one per pass. This works
because Wallpaper Engine's effects are local to their layer rather than post-processing over the
composed frame — 1682 of the 1764 effect passes in a typical library bind no texture beyond the
layer they are applied to, so no render graph is needed.

`WEShaderTranslator` rewrites each pass's GLSL ES 1.0 into something SpriteKit will compile:
resolving `#include`, evaluating the `[COMBO]` conditionals (`ApplyBlending` selects its blend mode
with `#if BLENDMODE == n` *inside a function body*, so this cannot be deferred), folding the vertex
shader's varying computations into the fragment shader, and mapping WE's HLSL-flavoured helpers.
Uniform values come from the effect instance's `constantshadervalues`.

Every stage fails safe: an effect that will not resolve, translate or bind is dropped and the layer
draws exactly as it did before.

**Cost.** Each pass is an offscreen render, so effects are not free, and a pass costs in
proportion to the area of the layer it wraps. A pass is cached when everything beneath it is still
(SpriteKit caches a pass's *input*, not its output), and a layer drawn much smaller than its
artwork has its passes rendered at the drawn size. The heaviest scenes in a typical library still
cost around 39 ms (Angel) and 29 ms (dragon-flames) a frame at their authored 4K, past the budget
for 60 fps; a 1440p display pays roughly half of that for the composite. Lower the frame rate in
Settings for those, or turn effects off.

Settings → Quality → Reflections switches off just Wallpaper Engine's "Reflection" effect (used by
three scenes in a typical library) while leaving the other effects on.

**Blend modes.** Multiply, screen, add and subtract map onto SpriteKit's own. Modes that read the
frame beneath the layer (overlay, soft light, colour dodge, …) are computed against a snapshot of
that frame, which is only possible where nothing beneath can change — 4 of the 18 layers in a
typical library that ask for one. The rest draw as normal alpha.

**Audio visualisers.** A visualiser is a white canvas under an audio-reactive shader that, at
silence, makes it transparent. The shader is declined (no system-audio capture), so its blank
canvas is dropped with it rather than left as a white rectangle.

## Scene Motion

Scenes are evaluated per frame rather than composited once. A renderer-agnostic `SceneEvaluator`
turns `(scene, time, cursor)` into placement data, and the SpriteKit rasterizer only draws what it
returns.

- **Camera parallax** — Layers slide against the cursor in proportion to their `parallaxDepth`,
  smoothed by the scene's own `cameraparallaxdelay`. The scene's `cameraparallax` flag decides
  whether this happens at all: Wallpaper Engine writes a default depth of `1.0 1.0` onto most image
  objects, so depth data alone is not a sign the author wanted the effect. Wallpaper windows ignore
  mouse events, so the cursor is sampled by polling rather than through an event monitor.
- **Keyframe animation** — Keyframed `origin`, `scale`, `angles` and `alpha` are interpolated as
  cubic Hermite segments on the track's own timeline, honouring `single` / `loop` / `mirror` modes,
  `relative` offsets and `wraploop`. Tracks Wallpaper Engine parks for a cursor trigger
  (`startpaused`, typically hover reactions) stay on their first frame.
- **Scripts** — The scene's JavaScript runs in a bare `JSContext` (no DOM, network or file system):
  119 of the 120 scripts in a typical library run. Scripts that read the calendar — clocks,
  calendars, the layout scripts that move layers to match — run live; scripts driven by audio,
  media players or the cursor keep the value Wallpaper Engine baked into the scene.

## Current Limitations

- **Video textures** — A handful of `.tex` files carry an embedded MP4 rather than a still image. These layers are drawn as the video's first frame, so a scene whose motion *is* that video (a city skyline, drifting fog) is still.
- **Particle fidelity** — emitters approximate Wallpaper Engine's systems: `alphafade`, `sizechange`, the particle budget and the layer's `instanceoverride` are honoured, `turbulence` only for its speed band (not as a wandering field), and `oscillatealpha` not at all. Child systems that follow each particle are dropped, except the glow riding a shooting star.
- **Audio, media and cursor scripts** — Scripts driven by the audio spectrum, a music player or the cursor have no data here and keep the value Wallpaper Engine baked into the scene.
- **Multi-pass effects** — `godrays`, `shine` and `blur` render a "cast" pass into a target and then combine it with the *untouched* layer. A nested chain only ever supplies one input, so these are skipped; doing them needs real render targets.
- **Audio-reactive effects** — Effects wired to the audio spectrum are skipped rather than run with the response pinned to zero, which collapses some of them entirely. macOS has no system-audio capture without a virtual device.
- **Frame cost on heavy scenes** — the heaviest scenes cost around 39 ms (Angel) and 29 ms (dragon-flames) a frame at their authored 4K, which will not hold 60 fps. Reduce the frame rate in Settings, or turn effects off.
- **Blend modes over moving layers** — Overlay, soft light and the other modes that read the frame beneath draw as normal alpha when anything beneath them animates.
- **Escape hatch** — the translation reconstructs another engine's shader pipeline, so `defaults write com.winddog.wallpaper-engine SceneEffectsDisabled -bool YES` turns the whole chain off and restores the plain composite.
- **Hover and click reactions** — Animations the author triggers from the cursor are held at their opening frame; there is no hover notion in a desktop wallpaper.
- **Emitter rotation** — Particle emitters take their object's position and scale but not its roll, because the mapping from Wallpaper Engine's velocity initializers to SpriteKit's emission angle is already approximate.
- **3D scenes** — Scenes without an orthographic projection fall back to their preview image.
- **Live-data wallpapers** — Wallpapers that display Spotify or Apple Music state have nothing to show without that data and render as their empty chrome.

## Supported Wallpaper Types

| Type | Status |
|------|--------|
| Video (.mp4, .mov, .m4v; H.264, HEVC, VP9 where the Mac has the decoder) | Working (original) |
| Web (HTML/WebGL) | Working (patched) |
| Scene (static images) | Working (new) |
| Scene (particles) | Working |
| Scene (DXT / LZ4 textures) | Working |
| Scene (camera parallax) | Working |
| Scene (keyframe animation) | Working |
| Scene (single-pass effects) | Working |
| Scene (multi-pass / audio effects) | Not supported |
| Scene (video textures) | First frame only |
| Scene (text layers and clock/calendar scripts) | Working |
| Scene (sound) | Working |
| Application | Not supported |

## Build from Source

### Prerequisites
- macOS >= 13.0
- Xcode >= 14.4
- Xcode Command Line Tools

### Steps
```sh
git clone https://github.com/unayung/wallpaper-engine-mac
cd wallpaper-engine-mac
open "Open Wallpaper Engine.xcodeproj"
```

In Xcode, change the signing certificate to your own or select "Sign to Run Locally", then press `Cmd + R` to build and run.

## Usage

### Browse & Download from Steam Workshop

1. Install steamcmd (`brew install steamcmd`) or point the app to an existing binary
2. Switch to the **Workshop** tab and log in with your Steam account (must own Wallpaper Engine)
3. Enter a [Steam Web API key](https://steamcommunity.com/dev/apikey) when prompted
4. Search, filter, and click **Download** on any wallpaper

### Import from Local Files

- **Folder:** File > Import from Folder — select wallpaper folders containing `project.json`
- **Zip:** File > Import or drag-and-drop a `.zip` file containing wallpaper packages
- **Manual:** Copy wallpaper folders directly into `~/Documents/Open Wallpaper Engine/`

## Files Changed (vs upstream)

**Modified:**
- `WebWallpaperView.swift` — WKWebView file access configuration
- `WallpaperView.swift` — Scene wallpaper dispatch
- `SceneWallpaperView.swift` — Rewritten as SpriteKit NSViewRepresentable
- `ImportPanels.swift` — Folder import logic fix

**Added:**
- `Services/SceneParsers/PKGParser.swift` — PKGV archive parser
- `Services/SceneParsers/TEXParser.swift` — TEXV texture parser
- `Services/SceneParsers/SceneModels.swift` — Scene JSON data models
- `Services/SceneWallpaperViewModel.swift` — Scene loading and SpriteKit rendering
- `Services/SteamCmdService.swift` — steamcmd detection, login, and workshop download
- `Services/WorkshopAPIService.swift` — Steam Web API client for workshop browsing
- `Services/WorkshopViewModel.swift` — Workshop browser state management
- `Services/WallpaperDirectory.swift` — Centralized wallpaper storage path
- `Services/ZipImporter.swift` — Zip file extraction and import
- `ContentView/Components/WorkshopView.swift` — Workshop browser UI
