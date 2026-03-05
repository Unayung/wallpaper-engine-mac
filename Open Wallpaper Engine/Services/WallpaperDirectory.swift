import Foundation

extension FileManager {
    /// The dedicated directory for storing wallpaper packages.
    /// Located at `~/Documents/Open Wallpaper Engine/`, created automatically if missing.
    var wallpapersDirectory: URL {
        let dir = urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Open Wallpaper Engine")
        if !fileExists(atPath: dir.path) {
            try? createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
