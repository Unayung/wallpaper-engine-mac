import Foundation
import Combine

class SteamCmdService: ObservableObject {
    @Published var steamCmdPath: String?
    @Published var isLoggedIn = false
    @Published var steamUsername: String = ""
    @Published var loginError: String?
    @Published var isLoggingIn = false
    @Published var downloadProgress: [String: DownloadState] = [:]
    @Published var pathError: String?

    enum DownloadState: Equatable {
        case downloading(status: String)
        case completed
        case failed(String)
    }

    private static let lastUsernameKey = "SteamLastUsername"
    private var sessionPassword: String = ""

    init() {
        detectSteamCmd()
        attemptCachedLogin()
    }

    // MARK: - Detection

    func detectSteamCmd() {
        if let custom = UserDefaults.standard.string(forKey: "SteamCmdPath"),
           FileManager.default.isExecutableFile(atPath: custom) {
            steamCmdPath = custom
            return
        }

        // Bundled DepotDownloader — architecture-specific sub-directory
        if let res = Bundle.main.resourcePath {
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x64"
            #endif
            let bundled = "\(res)/depotdownloader/\(arch)/DepotDownloader"
            if FileManager.default.isExecutableFile(atPath: bundled) {
                steamCmdPath = bundled
                return
            }
        }

        let searchPaths = [
            "/opt/homebrew/bin/DepotDownloader",
            "/usr/local/bin/DepotDownloader",
            "/opt/homebrew/bin/depotdownloader",
            "/usr/local/bin/depotdownloader",
        ]
        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                steamCmdPath = path
                return
            }
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            for name in ["DepotDownloader", "depotdownloader"] {
                let p = Process(); let pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                p.arguments = [name]
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                try? p.run(); p.waitUntilExit()
                guard p.terminationStatus == 0 else { continue }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                    DispatchQueue.main.async { self?.steamCmdPath = path }
                    return
                }
            }
        }
    }

    var isInstalled: Bool { steamCmdPath != nil }

    func setCustomPath(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            pathError = "File not found at selected path."
            return
        }
        if !FileManager.default.isExecutableFile(atPath: path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        pathError = nil
        UserDefaults.standard.set(path, forKey: "SteamCmdPath")
        steamCmdPath = path
    }

    // MARK: - Auth

    private func attemptCachedLogin() {
        guard isInstalled else { return }
        if let saved = UserDefaults.standard.string(forKey: Self.lastUsernameKey), !saved.isEmpty {
            loginWithCachedSession(username: saved)
        }
    }

    func login(username: String, password: String, guardCode: String? = nil) {
        guard steamCmdPath != nil else { return }
        isLoggingIn = true
        loginError = nil
        steamUsername = username
        sessionPassword = password

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let tempDir = FileManager.default.temporaryDirectory
                .appending(path: "depot_auth_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let (output, _) = self.runDepotDownloader(
                arguments: [
                    "-app", "431960", "-pubfile", "0",
                    "-username", username, "-password", password,
                    "-remember-password", "-dir", tempDir.path,
                ],
                guardCode: guardCode,
                timeout: 60
            )

            DispatchQueue.main.async {
                self.isLoggingIn = false
                if output.contains("InvalidPassword") || output.contains("Invalid Password") {
                    self.loginError = "Invalid username or password"
                } else if output.contains("STEAM GUARD!") && (guardCode?.isEmpty ?? true) {
                    self.loginError = "Steam Guard code required"
                } else if output.contains("AccountNotFound") {
                    self.loginError = "Account not found"
                } else if output.contains("Done!") || output.contains("Using app branch")
                            || output.contains("Logging '") {
                    self.isLoggedIn = true
                    self.loginError = nil
                    UserDefaults.standard.set(username, forKey: Self.lastUsernameKey)
                } else {
                    self.loginError = "Login failed. Check credentials and try again."
                }
            }
        }
    }

    func loginWithCachedSession(username: String) {
        guard steamCmdPath != nil else { return }
        isLoggingIn = true
        loginError = nil
        steamUsername = username

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let tempDir = FileManager.default.temporaryDirectory
                .appending(path: "depot_auth_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let (output, _) = self.runDepotDownloader(
                arguments: [
                    "-app", "431960", "-pubfile", "0",
                    "-username", username,
                    "-remember-password", "-dir", tempDir.path,
                ],
                guardCode: nil,
                timeout: 30
            )

            DispatchQueue.main.async {
                self.isLoggingIn = false
                if output.contains("Access token was rejected") || output.contains("InvalidPassword") {
                    self.loginError = "Cached session expired. Please log in with password."
                } else if output.contains("Done!") || output.contains("Using app branch")
                            || output.contains("Logging '") {
                    self.isLoggedIn = true
                    UserDefaults.standard.set(username, forKey: Self.lastUsernameKey)
                } else {
                    self.loginError = "Cached session expired. Please log in with password."
                }
            }
        }
    }

    // MARK: - Download

    func downloadWorkshopItem(workshopId: String) {
        guard let cmdPath = steamCmdPath, isLoggedIn else { return }
        downloadProgress[workshopId] = .downloading(status: "Starting download...")

        let tempDir = FileManager.default.temporaryDirectory.appending(path: "depot_\(workshopId)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            try? FileManager.default.removeItem(at: tempDir)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            var args = [
                "-app", "431960", "-pubfile", workshopId,
                "-username", self.steamUsername,
                "-remember-password", "-dir", tempDir.path,
            ]
            if !self.sessionPassword.isEmpty {
                args += ["-password", self.sessionPassword]
            }

            let process = Process()
            let stdoutPipe = Pipe(); let stderrPipe = Pipe(); let stdinPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: cmdPath)
            process.arguments = args
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = stdinPipe

            var fullOutput = ""

            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
                let data = fh.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                fullOutput += chunk
                if let status = self?.parseProgress(chunk) {
                    DispatchQueue.main.async { self?.downloadProgress[workshopId] = .downloading(status: status) }
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                fullOutput += chunk
            }

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    self.downloadProgress[workshopId] = .failed("Failed to start: \(error.localizedDescription)")
                }
                return
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            fullOutput += String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            fullOutput += String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            print("DepotDownloader [\(workshopId)] exit=\(process.terminationStatus)\n\(fullOutput)")

            DispatchQueue.main.async {
                if fullOutput.contains("Total downloaded") || fullOutput.contains("100.00%") {
                    self.downloadProgress[workshopId] = .downloading(status: "Copying to library...")
                    let fm = FileManager.default
                    let dest = fm.wallpapersDirectory.appending(path: workshopId)
                    do {
                        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                        // Copy files excluding .DepotDownloader staging folder
                        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                        let contents = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                        for item in contents where item.lastPathComponent != ".DepotDownloader" {
                            try fm.copyItem(at: item, to: dest.appending(path: item.lastPathComponent))
                        }
                        self.downloadProgress[workshopId] = .completed
                    } catch {
                        self.downloadProgress[workshopId] = .failed("Copy failed: \(error.localizedDescription)")
                    }
                } else {
                    let errorLine = fullOutput.components(separatedBy: "\n")
                        .first { $0.lowercased().contains("error") || $0.contains("FAILED") }
                        ?? "Download failed"
                    self.downloadProgress[workshopId] = .failed(errorLine)
                }
                try? FileManager.default.removeItem(at: tempDir)
            }
        }
    }

    // MARK: - Private helpers

    private func runDepotDownloader(
        arguments: [String],
        guardCode: String?,
        timeout: TimeInterval
    ) -> (output: String, exitCode: Int32) {
        guard let cmdPath = steamCmdPath else { return ("", -1) }

        let process = Process()
        let stdoutPipe = Pipe(); let stderrPipe = Pipe(); let stdinPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cmdPath)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        var combinedOutput = ""
        var guardCodeWritten = false
        let readQueue = DispatchQueue(label: "depot.pipe.read")

        stdoutPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            if let s = String(data: data, encoding: .utf8) { readQueue.sync { combinedOutput += s } }
        }

        // Steam Guard prompts come from stderr
        stderrPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            if let chunk = String(data: data, encoding: .utf8) {
                readQueue.sync { combinedOutput += chunk }
                let needsGuard = chunk.contains("STEAM GUARD!") || chunk.contains("2 factor auth")
                    || chunk.contains("authentication code")
                if needsGuard && !guardCodeWritten {
                    if let code = guardCode, !code.isEmpty {
                        guardCodeWritten = true
                        stdinPipe.fileHandleForWriting.write(Data((code + "\n").utf8))
                    } else {
                        // No code available — kill immediately instead of waiting for timeout
                        process.terminate()
                    }
                }
            }
        }

        do { try process.run() } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return ("Failed to run DepotDownloader: \(error.localizedDescription)", -1)
        }

        let wg = DispatchGroup(); wg.enter()
        DispatchQueue.global().async { process.waitUntilExit(); wg.leave() }
        if wg.wait(timeout: .now() + timeout) == .timedOut { process.terminate() }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let remainOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let remainErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        readQueue.sync {
            combinedOutput += String(data: remainOut, encoding: .utf8) ?? ""
            combinedOutput += String(data: remainErr, encoding: .utf8) ?? ""
        }
        return (readQueue.sync { combinedOutput }, process.terminationStatus)
    }

    private func parseProgress(_ output: String) -> String? {
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            // DepotDownloader stdout format: "  5.23% path/to/file"
            if let match = t.range(of: #"^(\d+\.\d+)%"#, options: .regularExpression) {
                let pctStr = String(t[match]).replacingOccurrences(of: "%", with: "")
                if let pct = Double(pctStr) {
                    return String(format: "Downloading... %.0f%%", min(pct, 100))
                }
            }
            if t.contains("Total downloaded") { return "Download complete, importing..." }
            if t.contains("Connecting to Steam") { return "Connecting..." }
            if t.contains("Logging '") { return "Authenticating..." }
            if t.contains("Done!") { return "Preparing download..." }
            if t.contains("Processing depot") || t.contains("Downloading depot") { return "Fetching manifest..." }
            if t.contains("Pre-allocating") { return "Allocating space..." }
        }
        return nil
    }
}
