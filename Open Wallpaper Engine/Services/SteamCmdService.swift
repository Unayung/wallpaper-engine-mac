import Foundation
import Combine

class SteamCmdService: ObservableObject {
    @Published var steamCmdPath: String?
    @Published var isLoggedIn = false
    @Published var steamUsername: String = ""
    @Published var loginError: String?
    @Published var isLoggingIn = false
    @Published var downloadProgress: [String: DownloadState] = [:]

    enum DownloadState: Equatable {
        case downloading(status: String)
        case completed
        case failed(String)
    }

    init() {
        detectSteamCmd()
    }

    func detectSteamCmd() {
        // Check user-configured path first
        if let customPath = UserDefaults.standard.string(forKey: "SteamCmdPath"),
           FileManager.default.isExecutableFile(atPath: customPath) {
            steamCmdPath = customPath
            return
        }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let searchPaths = [
            "/usr/local/bin/steamcmd",
            "/opt/homebrew/bin/steamcmd",
            "/usr/bin/steamcmd",
            "\(homeDir)/Projects/SteamSDK/tools/ContentBuilder/builder_osx/steamcmd",
        ]

        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                steamCmdPath = path
                return
            }
        }

        // Try `which` as fallback
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["steamcmd"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                steamCmdPath = path
            }
        }
    }

    var isInstalled: Bool { steamCmdPath != nil }

    func setCustomPath(_ path: String) {
        if FileManager.default.isExecutableFile(atPath: path) {
            UserDefaults.standard.set(path, forKey: "SteamCmdPath")
            steamCmdPath = path
        }
    }

    /// Attempt login with username and password. Steam Guard code is optional.
    func login(username: String, password: String, guardCode: String? = nil) {
        guard let cmdPath = steamCmdPath else { return }

        isLoggingIn = true
        loginError = nil
        steamUsername = username

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var args = ["+login", username, password]
            if let code = guardCode, !code.isEmpty {
                args = ["+login", username, password, code]
            }
            args += ["+quit"]

            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: cmdPath)
            process.arguments = args
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    self?.loginError = "Failed to run steamcmd: \(error.localizedDescription)"
                    self?.isLoggingIn = false
                }
                return
            }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            DispatchQueue.main.async {
                self?.isLoggingIn = false
                if output.contains("Logged in OK") || output.contains("OK") && process.terminationStatus == 0 {
                    self?.isLoggedIn = true
                    self?.loginError = nil
                } else if output.contains("Steam Guard") || output.contains("Two-factor") {
                    self?.loginError = "Steam Guard code required"
                } else if output.contains("Invalid Password") || output.contains("FAILED") {
                    self?.loginError = "Invalid username or password"
                } else {
                    self?.loginError = "Login failed. Check credentials and try again."
                }
            }
        }
    }

    /// Try login with cached session (no password needed if previously authenticated).
    func loginWithCachedSession(username: String) {
        guard let cmdPath = steamCmdPath else { return }

        isLoggingIn = true
        loginError = nil
        steamUsername = username

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: cmdPath)
            process.arguments = ["+login", username, "+quit"]
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    self?.isLoggingIn = false
                    self?.loginError = "Failed to run steamcmd"
                }
                return
            }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            DispatchQueue.main.async {
                self?.isLoggingIn = false
                if output.contains("Logged in OK") || (output.contains("OK") && process.terminationStatus == 0) {
                    self?.isLoggedIn = true
                } else {
                    self?.loginError = "Cached session expired. Please log in with password."
                }
            }
        }
    }

    /// Download a workshop item by its ID.
    func downloadWorkshopItem(workshopId: String) {
        guard let cmdPath = steamCmdPath, isLoggedIn else { return }

        downloadProgress[workshopId] = .downloading(status: "Starting steamcmd...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: cmdPath)
            process.currentDirectoryURL = URL(fileURLWithPath: cmdPath).deletingLastPathComponent()
            process.arguments = [
                "+login", self.steamUsername,
                "+workshop_download_item", "431960", workshopId, "validate",
                "+quit"
            ]
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            // Read output in real-time for progress updates
            var fullOutput = ""
            let handle = outputPipe.fileHandleForReading
            handle.readabilityHandler = { [weak self] fileHandle in
                let data = fileHandle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                fullOutput += line

                let status = self?.parseProgress(line) ?? nil
                if let status = status {
                    DispatchQueue.main.async {
                        self?.downloadProgress[workshopId] = .downloading(status: status)
                    }
                }
            }

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                handle.readabilityHandler = nil
                DispatchQueue.main.async {
                    self.downloadProgress[workshopId] = .failed("steamcmd failed to run: \(error.localizedDescription)")
                }
                return
            }

            handle.readabilityHandler = nil
            // Read any remaining data
            let remaining = handle.readDataToEndOfFile()
            if let str = String(data: remaining, encoding: .utf8) { fullOutput += str }

            let exitCode = process.terminationStatus
            print("steamcmd download [\(workshopId)] exit=\(exitCode)\n\(fullOutput)")

            // Find downloaded content
            let steamAppsDir = self.findSteamAppsDir(cmdPath: cmdPath)
            let sourcePath = steamAppsDir?
                .appending(path: "workshop/content/431960/\(workshopId)")

            DispatchQueue.main.async {
                self.downloadProgress[workshopId] = .downloading(status: "Copying to library...")

                if let sourceDir = sourcePath {
                    let fm = FileManager.default
                    if fm.fileExists(atPath: sourceDir.path) {
                        let dest = fm.wallpapersDirectory.appending(path: workshopId)
                        if !fm.fileExists(atPath: dest.path) {
                            do {
                                try fm.copyItem(at: sourceDir, to: dest)
                            } catch {
                                self.downloadProgress[workshopId] = .failed("Copy failed: \(error.localizedDescription)")
                                return
                            }
                        }
                        self.downloadProgress[workshopId] = .completed
                        return
                    }
                }

                if fullOutput.contains("ERROR") || fullOutput.contains("FAILED") {
                    let errorLine = fullOutput.components(separatedBy: "\n")
                        .first(where: { $0.contains("ERROR") || $0.contains("FAILED") })
                        ?? "Unknown error"
                    self.downloadProgress[workshopId] = .failed(errorLine)
                } else if exitCode != 0 {
                    self.downloadProgress[workshopId] = .failed("Exit code \(exitCode)")
                } else {
                    self.downloadProgress[workshopId] = .failed("Files not found at expected path")
                }
            }
        }
    }

    /// Parse steamcmd output lines into human-readable progress.
    private func parseProgress(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("Logging in") || trimmed.contains("Logged in") {
            return "Authenticating..."
        }
        if trimmed.contains("Downloading item") || trimmed.contains("workshop_download_item") {
            return "Requesting download..."
        }
        if trimmed.contains("Downloading") || trimmed.contains("downloading") {
            // Try to extract percentage like "Update state (0x61) downloading, progress: 45.23"
            if let range = trimmed.range(of: "progress:\\s*([\\d.]+)", options: .regularExpression),
               let pct = Double(trimmed[range].replacingOccurrences(of: "progress:", with: "").trimmingCharacters(in: .whitespaces)) {
                return String(format: "Downloading... %.0f%%", min(pct, 100))
            }
            return "Downloading..."
        }
        if trimmed.contains("Validating") || trimmed.contains("validating") {
            return "Validating..."
        }
        if trimmed.contains("Success") {
            return "Download complete, importing..."
        }
        if trimmed.contains("Update state") {
            // Generic state update
            if trimmed.contains("0x5") { return "Validating..." }
            if trimmed.contains("0x61") { return "Downloading..." }
            if trimmed.contains("0x101") { return "Committing..." }
        }
        return nil
    }

    private func findSteamAppsDir(cmdPath: String) -> URL? {
        // steamcmd typically stores downloads relative to its install location
        let cmdURL = URL(fileURLWithPath: cmdPath)

        // Homebrew: /opt/homebrew/Cellar/steamcmd/...  -> steamapps at ~/Library/Application Support/Steam
        // Manual: wherever steamcmd is -> steamapps in same dir
        let possiblePaths = [
            cmdURL.deletingLastPathComponent().appending(path: "steamapps"),
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Steam/steamapps"),
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Steam/steamapps"),
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }
        return nil
    }
}
