import Foundation

/// Zip extraction and wallpaper-folder discovery. Installing what is found is
/// `WallpaperImporter`'s job, so a zip, a dropped folder and a panel selection all land in
/// the library by the same rules.
enum ZipImporter {
    /// Extracts a zip into a fresh temporary directory and returns it, or nil when `ditto`
    /// fails. The caller owns the directory and removes it.
    static func extract(zipAt zipURL: URL) -> URL? {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appending(path: UUID().uuidString)

        // Extract zip using macOS built-in ditto. Its output is not piped, so there is no
        // pipe buffer to fill and waitUntilExit cannot deadlock.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, tempDir.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("ZipImporter: ditto failed: \(error)")
            try? fm.removeItem(at: tempDir)
            return nil
        }
        guard process.terminationStatus == 0 else {
            print("ZipImporter: ditto exited with status \(process.terminationStatus)")
            try? fm.removeItem(at: tempDir)
            return nil
        }
        return tempDir
    }

    /// Directories containing project.json: `directory` itself if it is one, otherwise its
    /// children, otherwise its grandchildren (a zip or a download often has a wrapper folder).
    static func findWallpaperFolders(in directory: URL) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []

        // Check if this directory itself is a wallpaper
        if fm.fileExists(atPath: directory.appending(path: "project.json").path) {
            return [directory]
        }

        // Check immediate children
        guard let children = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        for child in children {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }

            if fm.fileExists(atPath: child.appending(path: "project.json").path) {
                results.append(child)
            } else {
                // One more level deep (zip may have a wrapper folder)
                if let grandchildren = try? fm.contentsOfDirectory(
                    at: child, includingPropertiesForKeys: [.isDirectoryKey],
                    options: .skipsHiddenFiles
                ) {
                    for grandchild in grandchildren {
                        var isSubDir: ObjCBool = false
                        if fm.fileExists(atPath: grandchild.path, isDirectory: &isSubDir),
                           isSubDir.boolValue,
                           fm.fileExists(atPath: grandchild.appending(path: "project.json").path) {
                            results.append(grandchild)
                        }
                    }
                }
            }
        }

        return results
    }
}
