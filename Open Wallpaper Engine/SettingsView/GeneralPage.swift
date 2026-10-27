//
//  GeneralPage.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/12.
//

import ServiceManagement
import SwiftUI

struct GeneralPage: SettingsPage {
    @ObservedObject var viewModel: GlobalSettingsViewModel

    @State private var isConfirmingReset = false

    @AppStorage("TestAnimates") private var animatesGIFPreviews = false

    init(globalSettings viewModel: GlobalSettingsViewModel) {
        self.viewModel = viewModel
    }
    
    var body: some View {
        Form {
            // MARK: Automatic Startup
            Section {
                // Bound to what macOS reports, not to the stored bool, and switched through
                // SMAppService directly; see `GlobalSettingsViewModel.loginItemStatus`.
                Toggle("Start with macOS", isOn: Binding(
                    get: { viewModel.launchesAtLogin },
                    set: { viewModel.setLaunchAtLogin($0) }))
                switch viewModel.loginItemStatus {
                case .requiresApproval:
                    // Registered, but macOS will not launch it until the user allows it in Login
                    // Items — which a toggle that simply read "on" never told them.
                    HStack {
                        Text("Waiting for your approval in System Settings → Login Items.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                case .notFound:
                    Text("macOS cannot find this copy of the app to launch at login. Moving it to the Applications folder usually fixes this.")
                        .foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
                if let error = viewModel.loginItemError {
                    Text(error)
                        .foregroundStyle(.red)
                }
//                Toggle("Safe start after hibernation", isOn: $viewModel.settings.safeMode)
            } header: {
                Label("Automatic Startup", systemImage: "star.fill")
            }
            // MARK: Library
            // `autoRefresh` has only ever decided whether the library's toolbar shows its refresh
            // button (`ExplorerTopBar`) — the library is not refreshed on a timer either way — so
            // the toggle is named for what it does rather than for the field.
            Section {
                Toggle("Show refresh button in library", isOn: $viewModel.settings.autoRefresh)
                // Read by `ExplorerItem` to play GIF previews in the grid. It used to sit alone on
                // a placeholder "Plugins" page labelled "Animates"; the storage key is kept so a
                // choice made there survives the move. Off by default because every visible tile
                // then decodes and redraws its GIF continuously.
                Toggle("Animate GIF previews in library", isOn: $animatesGIFPreviews)
                libraryFolderRow
            } header: {
                Label("Library", systemImage: "square.grid.2x2.fill")
            } footer: {
                // What `GlobalSettingsViewModel.setWallpapersDirectory` does about the old folder,
                // said where the user makes the choice.
                Text("Changing the folder does not move or delete any files. A screen showing a wallpaper from the previous folder keeps it until you choose another, and new Workshop downloads go to the current folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // MARK: Language
            // The app follows the system language. The old picker here was disabled and its
            // `GlobalSettings.language` never applied; what macOS does offer is a per-app language
            // (System Settings → Language & Region → Applications), so the row points there.
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Language")
                        Text("Follows the system language. To use a different language for this app, add it under Applications in Language & Region.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Language & Region") {
                        // The Language & Region pane's identifier from macOS 13 on, read from
                        // /System/Library/ExtensionKit/Extensions/Localization.appex, whose
                        // Info.plist sets `allowsXAppleSystemPreferencesURLScheme`. It has no
                        // anchor for the Applications list, so this opens the pane itself.
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } header: {
                Label("Language", systemImage: "globe")
            }
            // MARK: macOS
            Section {
                Toggle("Adjust Menu Bar Color", isOn: $viewModel.settings.adjustMenuBarTint)
            } header: {
                Label("macOS", systemImage: "apple.logo")
            }
            // MARK: Appearance
            Section {
                Picker("Theme", selection: $viewModel.settings.appearance) {
                    Text("Light").tag(GSAppearance.light)
                    Text("Dark").tag(GSAppearance.dark)
                    Text("Auto").tag(GSAppearance.followSystem)
                }
            } header: {
                Label("Appearance", systemImage: "paintpalette.fill")
            }
            // MARK: Developer
            // Switches that used to exist only as `defaults write` keys. They are stored under the
            // same keys, so a value set from Terminal shows here and the other way round.
            Section {
                Toggle("Disable scene scripts", isOn: Binding(
                    get: { viewModel.sceneScriptsDisabled },
                    set: { viewModel.setSceneScriptsDisabled($0) }))
                assetsFolderRow
            } header: {
                Label("Developer", systemImage: "hammer.fill")
            } footer: {
                Text("With scripts disabled, every clock, calendar and other scripted layer shows the value saved in the scene instead of running its script. Use it to tell a layer a script changes from one that is drawn wrong. Scene wallpapers reload when either setting changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // MARK: Reset
            Section {
                HStack {
                    Text("Reset Config")
                    Spacer()
                    // Confirmed first: it applies at once like every other control here, and
                    // with no Cancel any more there is nothing to take it back.
                    Button {
                        isConfirmingReset = true
                    } label: {
                        Text("Reset").frame(width: 100)
                    }
                    .tint(Color.red)
                    .buttonStyle(.borderedProminent)
                    .confirmationDialog("Reset all settings to their defaults?",
                                        isPresented: $isConfirmingReset) {
                        Button("Reset All Settings", role: .destructive) {
                            viewModel.resetToDefaults()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This resets the playback rules, quality, frame rate, appearance and menu bar settings. Your wallpapers, library and Start with macOS are not affected. This cannot be undone.")
                    }
                }
            } header: {
                Label("Reset", systemImage: "exclamationmark.triangle.fill")
            }
        }.formStyle(.grouped)
    }

    // MARK: Folder rows

    /// The library folder. Everything about which folder that is lives in
    /// `FileManager.wallpapersDirectory`; this only reads it and sets the override.
    private var libraryFolderRow: some View {
        let fm = FileManager.default
        let chosen = fm.wallpapersDirectoryOverride
        let current = fm.wallpapersDirectory
        var note: LocalizedStringKey?
        if let chosen, !fm.isDirectory(chosen) {
            note = "The chosen folder \(chosen.path(percentEncoded: false)) is not available, so the default folder is used until it is."
        }
        return FolderRow(title: "Library folder",
                         path: current.path(percentEncoded: false),
                         note: note,
                         isCustom: chosen != nil,
                         show: current,
                         choose: {
                             if let url = chooseFolder(message: String(localized: "Choose the folder that holds your wallpapers."),
                                                       startingAt: current) {
                                 viewModel.setWallpapersDirectory(url)
                             }
                         },
                         reset: { viewModel.setWallpapersDirectory(nil) })
    }

    /// The shared Wallpaper Engine asset library, as scenes will resolve it on their next build.
    private var assetsFolderRow: some View {
        let custom = WEAssetLibrary.customPath
        let resolved = WEAssetLibrary.resolvedRoot()
        let note: LocalizedStringKey?
        if let custom, !FileManager.default.fileExists(atPath: custom) {
            note = "The chosen folder \(custom) does not exist, so the default location is used."
        } else if resolved == nil {
            // Why it matters, in the user's terms: scenes reference models/util, materials/util and
            // particles/presets from this library without bundling them (CLAUDE.md, Scene
            // wallpapers), so those layers are missing rather than wrong.
            note = "Not found. Scene layers that use Wallpaper Engine's shared models, materials and particle presets will be missing. Install Wallpaper Engine with Steam, or choose its assets folder."
        } else {
            note = nil
        }
        return FolderRow(title: "Wallpaper Engine assets",
                         path: (resolved ?? WEAssetLibrary.defaultCandidates[0]).path(percentEncoded: false),
                         note: note,
                         isCustom: custom != nil,
                         show: resolved,
                         choose: {
                             if let url = chooseFolder(message: String(localized: "Choose Wallpaper Engine's assets folder (wallpaper_engine/assets)."),
                                                       startingAt: resolved) {
                                 viewModel.setWallpaperEngineAssetsPath(url)
                             }
                         },
                         reset: { viewModel.setWallpaperEngineAssetsPath(nil) })
    }

    /// A directories-only open panel, run modally: Settings is its own window, and the panel
    /// returns before the row needs the answer.
    private func chooseFolder(message: String, startingAt directory: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = String(localized: "Choose")
        panel.directoryURL = directory
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// One folder setting: its path, a note when it is not what the user asked for, and the three
/// actions. Shared by the library and asset-library rows so they read and behave alike.
private struct FolderRow: View {
    let title: LocalizedStringKey
    let path: String
    let note: LocalizedStringKey?
    let isCustom: Bool
    /// What Show in Finder opens; nil (a folder that does not exist) disables it.
    let show: URL?
    let choose: () -> Void
    let reset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                if !isCustom {
                    Text("Default")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Show in Finder") {
                    if let show {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: show.path(percentEncoded: false))
                    }
                }
                .disabled(show == nil)
                Button("Choose…", action: choose)
                Button("Reset to Default", action: reset)
                    .disabled(!isCustom)
            }
        }
    }
}
