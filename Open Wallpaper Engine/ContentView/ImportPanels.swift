//
//  ImportPanels.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/4.
//

import Cocoa
import UniformTypeIdentifiers

struct WPImportError: LocalizedError {
    var errorDescription: String?
    var failureReason: String?
    var helpAnchor: String?
    var recoverySuggestion: String?
    
    static let permissionDenied         = WPImportError(errorDescription: "Permission Denied",
                                                failureReason: "This app doesn't have the permission to access to the folder(s) you selected",
                                                helpAnchor: "File Permission",
                                                recoverySuggestion: "Try enable it in 'System Settings' - 'Privacy & Security'")
    
    static let doesNotContainWallpaper  = WPImportError(errorDescription: "No Wallpaper(s) Inside",
                                                       failureReason: "Maybe you selected the wrong folder which doesn't contain any wallpapers",
                                                       helpAnchor: "Contents in Folder(s)",
                                                       recoverySuggestion: "Check the folder(s) you selected and try again")
    
    static let unkown                   = WPImportError(errorDescription: "Unkown Error",
                                                        failureReason: "",
                                                        helpAnchor: "",
                                                        recoverySuggestion: "")

    /// An import that found things but did not import all of them cleanly: say what, item by
    /// item, instead of the print() each failure used to end in.
    static func report(_ report: WallpaperImportReport) -> WPImportError {
        let title = report.imported.isEmpty
            ? "Nothing Imported"
            : "Imported \(report.imported.count) Wallpaper(s), With Problems"
        let lines = (report.skipped.map { "Skipped \($0)" } + report.warnings.map { "Warning — \($0)" })
        let shown = lines.prefix(8).joined(separator: "\n")
        let more = lines.count > 8 ? "\n…and \(lines.count - 8) more" : ""
        return WPImportError(errorDescription: title,
                             failureReason: shown + more,
                             helpAnchor: "",
                             recoverySuggestion: "")
    }
}

extension AppDelegate {
    @objc func openImportFromFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        // Everything the importer accepts. A bare video could only be dragged in before.
        panel.allowedContentTypes = [.folder, .zip, .mpeg4Movie, .quickTimeMovie]
            + [UTType(filenameExtension: "m4v")].compactMap { $0 }
        panel.beginSheetModal(for: self.mainWindowController.window) { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let urls = panel.urls
            // Same importer as drag-and-drop, so both accept the same things by the same
            // rules. Off the main thread: it copies whole wallpaper folders.
            DispatchQueue.global(qos: .userInitiated).async {
                let report = WallpaperImporter.importItems(at: urls)
                DispatchQueue.main.async {
                    self?.contentViewModel.finishImport(report)
                }
            }
        }
    }
}
