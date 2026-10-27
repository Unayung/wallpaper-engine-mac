import Foundation

extension FileManager {
    /// `UserDefaults` key holding the folder the user chose for the library in Settings →
    /// General → Library, as a path. Absent means the default.
    static let wallpapersDirectoryOverrideKey = "WallpaperLibraryPath"

    /// `~/Documents/Open Wallpaper Engine/`, where the library lives unless the user moved it.
    var defaultWallpapersDirectory: URL {
        urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Open Wallpaper Engine")
    }

    /// The folder the user chose, when one is set — whether or not it is there right now.
    var wallpapersDirectoryOverride: URL? {
        guard let path = UserDefaults.standard.string(forKey: Self.wallpapersDirectoryOverrideKey),
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The dedicated directory for storing wallpaper packages: the folder chosen in Settings, else
    /// `~/Documents/Open Wallpaper Engine/`, created automatically if missing. The single access
    /// point to the library — never build the path anywhere else (an earlier version used raw
    /// `~/Documents` and picked up unrelated folders as broken wallpapers).
    ///
    /// A chosen folder is used only while it exists, and is never created. It is typically on an
    /// external or network volume, and creating it while that volume is unmounted would put an
    /// empty stand-in under `/Volumes` that shadows the real one when it comes back. So while it
    /// is missing the library reads the default folder — and Workshop imports land there — until
    /// it reappears; Settings says so beside the path.
    ///
    /// Read on every access, like the directory listing itself, so a change in Settings takes
    /// effect at once. The offline tools in `Tools/` run under their own defaults domain, where no
    /// override is set, so they always check the default folder. (`-WallpaperLibraryPath <dir>`
    /// on their command line does redirect them, through the argument domain, but `appcheck`
    /// also reads those two words as wallpaper ids and reports them as failures.)
    var wallpapersDirectory: URL {
        if let chosen = wallpapersDirectoryOverride, isDirectory(chosen) {
            return chosen
        }
        let dir = defaultWallpapersDirectory
        if !fileExists(atPath: dir.path) {
            try? createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Whether `url` exists and is a directory (following symlinks).
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
    }
}
