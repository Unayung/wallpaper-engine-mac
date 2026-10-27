import AppKit
import AVFoundation

/// What one import pass did, item by item, so the UI can say so instead of printing it.
struct WallpaperImportReport {
    /// Library folder names that were created.
    var imported: [String] = []
    /// "<item>: <reason>" for everything that was found but not imported.
    var skipped: [String] = []
    /// "<item>: <reason>" for things that were imported but may not work.
    var warnings: [String] = []

    var isClean: Bool { skipped.isEmpty && warnings.isEmpty }
    var isEmpty: Bool { imported.isEmpty && isClean }
}

/// The single import path behind drag-and-drop and File > Import.
///
/// Those two used to disagree: the drop handler wanted `project.json` at the top level of a
/// dropped folder, the panel scanned its children; the panel could not pick a video, the
/// drop handler could; and each had its own silent failure modes. The worst was the video
/// path, which wrote a `FileWrapper` straight onto `<library>/<name>` — when that folder
/// already existed, `write(to:originalContentsURL: nil)` failed with
/// NSFileWriteFileExistsError (516) *and* deleted the existing folder, so re-dropping a clip
/// destroyed the earlier import and imported nothing.
///
/// Everything here is staged in a scratch directory on the library's own volume and then
/// `moveItem`d into place. A move onto an existing name fails without touching either side,
/// so a collision can at worst skip an item, never destroy one.
///
/// Blocking: call it off the main thread.
enum WallpaperImporter {
    /// Bare videos accepted as video wallpapers. Anything else AVFoundation might open
    /// (.webm, .mkv) is not worth promising: the video wallpaper is an `AVPlayer`.
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static func importItems(
        at urls: [URL],
        into library: URL = FileManager.default.wallpapersDirectory
    ) -> WallpaperImportReport {
        var report = WallpaperImportReport()
        for url in urls {
            importItem(at: url, into: library, report: &report)
        }
        return report
    }

    private static func importItem(at url: URL, into library: URL, report: inout WallpaperImportReport) {
        let fm = FileManager.default
        let name = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
            report.skipped.append("\(name): not found")
            return
        }

        if isDirectory.boolValue {
            // A wallpaper folder, or a folder of them (steamcmd's workshop/content/431960).
            let folders = ZipImporter.findWallpaperFolders(in: url)
            guard !folders.isEmpty else {
                report.skipped.append("\(name): no project.json inside")
                return
            }
            for folder in folders {
                installFolder(folder, into: library, report: &report)
            }
            return
        }

        let ext = url.pathExtension.lowercased()
        if ext == "zip" {
            guard let extracted = ZipImporter.extract(zipAt: url) else {
                report.skipped.append("\(name): could not be extracted")
                return
            }
            defer { try? fm.removeItem(at: extracted) }
            let folders = ZipImporter.findWallpaperFolders(in: extracted)
            guard !folders.isEmpty else {
                report.skipped.append("\(name): no project.json inside")
                return
            }
            for folder in folders {
                installFolder(folder, into: library, report: &report)
            }
        } else if videoExtensions.contains(ext) {
            importVideo(at: url, into: library, report: &report)
        } else {
            report.skipped.append("\(name): not a wallpaper folder, .zip, .mp4, .mov or .m4v")
        }
    }

    // MARK: - Wallpaper folders

    /// Copy a wallpaper folder in under its own name. A folder of the same name is almost
    /// always the same Workshop item imported before, so it is reported and left alone
    /// rather than duplicated under a second name.
    private static func installFolder(_ source: URL, into library: URL, report: inout WallpaperImportReport) {
        let fm = FileManager.default
        let name = source.lastPathComponent
        let destination = library.appending(path: name)
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            report.skipped.append("\(name): already in your library")
            return
        }
        do {
            let staging = try stagingDirectory(for: library)
            defer { try? fm.removeItem(at: staging) }
            let staged = staging.appending(path: name)
            try fm.copyItem(at: source, to: staged)
            try fm.moveItem(at: staged, to: destination)
            report.imported.append(name)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            report.skipped.append("\(name): already in your library")
        } catch {
            report.skipped.append("\(name): \(error.localizedDescription)")
        }
    }

    // MARK: - Bare videos

    /// Wrap a bare video in a new wallpaper folder: the video, a preview frame, and a
    /// project.json written from scratch (the one case where encoding `WEProject` whole is
    /// right — there is no authored file to lose keys from).
    private static func importVideo(at url: URL, into library: URL, report: inout WallpaperImportReport) {
        let fm = FileManager.default
        let filename = url.lastPathComponent
        let title = url.deletingPathExtension().lastPathComponent
        do {
            let staging = try stagingDirectory(for: library)
            defer { try? fm.removeItem(at: staging) }
            let folder = staging.appending(path: title)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            try fm.copyItem(at: url, to: folder.appending(path: filename))

            // A video AVFoundation cannot decode (the library holds a VP9 .mp4 that reports
            // isPlayable = false) used to abort the import after only a print(). It is now
            // imported with a placeholder preview and a warning: the file is the user's to
            // keep or delete, and silence was the worst of the options.
            let preview: Data
            if let frame = firstFrameJPEG(of: url) {
                preview = frame
            } else {
                preview = placeholderJPEG()
                report.warnings.append("\(filename): macOS cannot decode this video (an unsupported codec such as VP9?), so it has no preview and may not play")
            }
            try preview.write(to: folder.appending(path: "preview.jpg"))

            let project = WEProject(file: filename, preview: "preview.jpg", title: title, type: "video")
            try JSONEncoder().encode(project).write(to: folder.appending(path: "project.json"))

            // A clip named like a Workshop id (`1698765432.mp4`, a timestamp) must not get a
            // folder named like one, or the Source filter files it under Workshop: this
            // project.json has no `workshopid` to say otherwise. Only the folder changes; the
            // title the grid shows is still the clip's name.
            let base = FRSource.isWorkshopFolderName(title) ? "Video \(title)" : title
            let name = try moveToUniqueName(folder, base: base, in: library)
            report.imported.append(name)
        } catch {
            report.skipped.append("\(filename): \(error.localizedDescription)")
        }
    }

    /// Move `item` to `<library>/<base>`, or "<base> 2", "<base> 3", … when taken. Two
    /// different clips can share a file name, so unlike a Workshop folder a collision here
    /// is not evidence of a duplicate.
    static func moveToUniqueName(_ item: URL, base: String, in library: URL) throws -> String {
        let fm = FileManager.default
        for n in 1...999 {
            let name = n == 1 ? base : "\(base) \(n)"
            let destination = library.appending(path: name)
            if fm.fileExists(atPath: destination.path(percentEncoded: false)) { continue }
            do {
                try fm.moveItem(at: item, to: destination)
                return name
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue // lost a race for this name; the existing item is untouched
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// A scratch directory on the same volume as the library, so the final `moveItem` is a
    /// rename rather than a second copy.
    private static func stagingDirectory(for library: URL) throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: library, create: true
        )
    }

    private static func firstFrameJPEG(of url: URL) -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)

        // The asynchronous API is the non-deprecated one; this runs off the main thread, so
        // waiting on it is fine. The time limit guards against a decoder that never answers.
        final class Box: @unchecked Sendable { var image: CGImage? }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(value: 1, timescale: 1))]) { _, image, _, _, _ in
            box.image = image
            done.signal()
        }
        guard done.wait(timeout: .now() + 20) == .success, let frame = box.image else {
            generator.cancelAllCGImageGeneration()
            return nil
        }
        return NSBitmapImageRep(cgImage: frame).representation(using: .jpeg, properties: [:])
    }

    private static func placeholderJPEG() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            context.cgContext.setFillColor(gray: 0.25, alpha: 1)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        }
        return rep.representation(using: .jpeg, properties: [:]) ?? Data()
    }
}
