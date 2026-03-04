Open Wallpaper Engine (Patched)
=========

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

A patched fork of [Open Wallpaper Engine](https://github.com/MrWindDog/wallpaper-engine-mac) for macOS, adding scene wallpaper rendering and web wallpaper fixes.

> **Note:** This is NOT affiliated with the commercial Wallpaper Engine on Steam. This is an open-source macOS app that can display wallpaper assets from Wallpaper Engine's Steam Workshop.

## Credits

This project is built on top of the work of:

- **[MrWindDog](https://github.com/MrWindDog)** — Maintainer of the upstream [wallpaper-engine-mac](https://github.com/MrWindDog/wallpaper-engine-mac) fork, added new features and UI refinements
- **[Haren Chen](https://github.com/haren724)** — Original creator of [open-wallpaper-engine-mac](https://github.com/haren724/open-wallpaper-engine-mac), built the core app architecture (SwiftUI, video wallpaper playback, import system, playlist UI)
- **[1ris_W](https://github.com/Erica-Iris)** — Chinese i18n translation
- **[Klaus Zhu](https://github.com/klauszhu1105)** — App logo icons

Licensed under [GPL-3.0](LICENSE), same as the original project.

## What's Patched

### Web Wallpapers — Fixed gray/blank rendering
WebGL-based wallpapers rendered as gray rectangles because `WKWebView` blocked local file access for textures and assets.

**Fix:** Enabled `allowFileAccessFromFileURLs` and `allowUniversalAccessFromFileURLs` on the WKWebView configuration, allowing WebGL shaders to load local texture files.

### Scene Wallpapers — Implemented from scratch
Scene wallpapers (the most common type on Steam Workshop) were completely unimplemented — just showed "Hello, World!".

**New implementation includes:**
- **PKG parser** — Reads Wallpaper Engine's PKGV archive format to extract scene.json, models, materials, and textures
- **TEX parser** — Reads TEXV0005 texture containers, extracts embedded JPEG/PNG image data from TEXI/TEXB sections
- **Scene JSON decoder** — Parses scene.json with flexible decoding that handles Wallpaper Engine's polymorphic fields (values can be plain types or `{"script":..,"value":..}` objects)
- **SpriteKit renderer** — Renders scene image layers as SKSpriteNodes with correct positioning, sizing, alpha, color tinting, and blend modes
- **Preview fallback** — Falls back to preview.jpg/png/gif when textures can't be extracted
- **TEXI format detection** — Quickly identifies and skips DXT-compressed textures that can't be decoded

### Import — Fixed folder import
The import panel now correctly handles both individual wallpaper folders and parent directories containing multiple wallpapers.

## Current Limitations

- **DXT textures** — Wallpapers using DXT1/DXT5 compressed textures (TEXI format 4/7/8) cannot be rendered. These are GPU-native compressed formats that require either a software decompressor or Metal-based rendering. The app falls back to the preview image for these wallpapers.
- **Particle effects** — Scene particle systems (rain, snow, sparkles) are parsed but disabled in rendering to avoid visual artifacts. The particle mapping code exists but needs refinement.
- **Audio-reactive scripts** — Wallpaper Engine's JavaScript-based audio visualization scripts are not executed. Properties with scripts fall back to their static `value`.
- **Shader effects** — Custom GLSL shaders (bloom, blur, color correction) are not applied.
- **Camera parallax** — Mouse-tracking camera movement is not implemented.
- **Animated scenes** — Sprite animations and timeline-based object animations are not supported.
- **Some JPEG thumbnails** — A small number of TEXB format 1 files contain non-standard JPEG data that macOS cannot decode. These are typically DXT-compressed textures misidentified as format 1.

## Supported Wallpaper Types

| Type | Status |
|------|--------|
| Video (.mp4, .webm) | Working (original) |
| Web (HTML/WebGL) | Working (patched) |
| Scene (static images) | Working (new) |
| Scene (particles) | Partial (disabled) |
| Scene (DXT textures) | Preview fallback |
| Application | Not supported |

## Installation

Download the `.dmg` from Releases, or build from source (see below).

## Build

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

### Import from Wallpaper Engine (Steam)

1. Open the app's File menu
2. Select "Import from Folder"
3. Choose your Wallpaper Engine workshop folder (typically `~/.steam/steam/steamapps/workshop/content/431960/`) or select individual wallpaper folders
4. Each wallpaper folder should contain a `project.json` file

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
