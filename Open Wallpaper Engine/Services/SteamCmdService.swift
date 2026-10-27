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

    private static let lastUsernameKey = "SteamLastUsername"

    init() {
        detectSteamCmd()
        attemptCachedLogin()
    }

    /// Something steamcmd will ask for on its console, and what to type back.
    ///
    /// steamcmd prompts on stdout and reads the reply from stdin whenever `+login <user>` is given
    /// without the secret it needs. The prompts are fixed strings in `steamconsole.dylib`:
    /// `password: ` (no newline, so it arrives as a partial line), and `Steam Guard code:` for an
    /// e-mailed code or `Two-factor code:` for the mobile authenticator.
    struct PromptAnswer {
        /// Any of these, matched case-insensitively in output not yet answered.
        let prompts: [String]
        let reply: String

        static func password(_ password: String) -> PromptAnswer {
            PromptAnswer(prompts: ["password:"], reply: password)
        }
        static func guardCode(_ code: String) -> PromptAnswer {
            PromptAnswer(prompts: ["Steam Guard code:", "Two-factor code:"], reply: code)
        }
    }

    /// Run a steamcmd process with proper pipe handling to avoid deadlocks.
    /// Reads stdout/stderr concurrently with process execution and applies a timeout.
    ///
    /// Secrets go to steamcmd through `answers`, never through `arguments`. A process's argv is
    /// readable by every user on the machine — `ps -o args` shows it, as does anything that
    /// lists processes — and `+login <user> <password>` left the Steam password there for the
    /// whole of the login, up to 60 s. An answer is typed into stdin only once its prompt has
    /// appeared, which is also what keeps a Steam Guard code from being swallowed as the password
    /// by a read that takes the whole buffer.
    ///
    /// stdin is always a pipe of ours and is closed once the last answer is written, or at once
    /// when there are none. A prompt nothing answers then reads EOF and steamcmd fails it straight
    /// away ("Two-factor code:" followed by a failure), where an open, silent stdin would leave it
    /// waiting out the whole timeout — and the failure text is what tells the UI to ask for a code.
    private func runSteamCmd(arguments: [String], answers: [PromptAnswer] = [],
                             timeout: TimeInterval = 30) -> (output: String, exitCode: Int32) {
        guard let cmdPath = steamCmdPath else { return ("", -1) }

        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cmdPath)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = inputPipe

        // A write into a pipe whose reader has gone raises SIGPIPE, which terminates the app —
        // steamcmd exiting between printing a prompt and our reply is enough. With this flag the
        // write fails with EPIPE instead, which is simply ignored.
        let stdinFD = inputPipe.fileHandleForWriting.fileDescriptor
        _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1)

        // Read pipe concurrently to prevent buffer deadlock. Answers are written from the same
        // serial queue that owns the output, so a prompt split across two reads is still seen
        // whole, and nothing is answered twice.
        var outputData = Data()
        var unanswered = answers
        var scannedTo = 0
        var stdinOpen = true
        let readQueue = DispatchQueue(label: "steamcmd.pipe.read")
        func closeStdin() {
            guard stdinOpen else { return }
            stdinOpen = false
            try? inputPipe.fileHandleForWriting.close()
        }
        let handle = outputPipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            readQueue.sync {
                outputData.append(data)
                guard stdinOpen, !unanswered.isEmpty else { return }
                let pending = String(decoding: outputData[scannedTo...], as: UTF8.self)
                guard let index = unanswered.firstIndex(where: { answer in
                    answer.prompts.contains { pending.range(of: $0, options: .caseInsensitive) != nil }
                }) else { return }
                let answer = unanswered.remove(at: index)
                scannedTo = outputData.count
                let line = Array((answer.reply + "\n").utf8)
                _ = line.withUnsafeBytes { write(stdinFD, $0.baseAddress, $0.count) }
                if unanswered.isEmpty { closeStdin() }
            }
        }

        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            return ("Failed to run steamcmd: \(error.localizedDescription)", -1)
        }
        // Closing our write end is what delivers EOF to steamcmd's stdin.
        if answers.isEmpty { readQueue.sync { closeStdin() } }

        // Wait with timeout
        let deadline = DispatchTime.now() + timeout
        let waitGroup = DispatchGroup()
        waitGroup.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            waitGroup.leave()
        }

        if waitGroup.wait(timeout: deadline) == .timedOut {
            // The whole tree, not process.terminate(): that signals only the steamcmd.sh
            // wrapper, and the real steamcmd under it kept running and holding the install lock,
            // so every later login or download failed until it was killed by hand. A tree that
            // ignores SIGTERM gets SIGKILL, so the waiter above is released either way.
            let tree = Self.terminateTree(process.processIdentifier)
            _ = waitGroup.wait(timeout: .now() + 3)
            // Whatever is left of the snapshot gets SIGKILL. A member that already exited is a
            // reaped pid, and a kill on it fails harmlessly with ESRCH.
            for member in tree { kill(member, SIGKILL) }
            _ = waitGroup.wait(timeout: .now() + 3)
            handle.readabilityHandler = nil
            readQueue.sync { closeStdin() }
            return ("steamcmd timed out after \(Int(timeout))s", -1)
        }

        // No readDataToEndOfFile: a child that outlives the wrapper keeps the pipe's write end
        // open, and the read would then block forever — the same trap the download path
        // documents. Whatever was still buffered at exit arrives through the handler within a
        // moment.
        Thread.sleep(forTimeInterval: 0.25)
        handle.readabilityHandler = nil
        let output = readQueue.sync { () -> String in
            closeStdin()
            return String(decoding: outputData, as: UTF8.self)
        }
        return (output, process.terminationStatus)
    }

    /// Automatically try cached session if we have a saved username and steamcmd is installed.
    private func attemptCachedLogin() {
        guard isInstalled, !isLoggedIn else { return }
        if let saved = UserDefaults.standard.string(forKey: Self.lastUsernameKey), !saved.isEmpty {
            loginWithCachedSession(username: saved)
        }
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
            // Homebrew / system installs
            "/usr/local/bin/steamcmd",
            "/opt/homebrew/bin/steamcmd",
            "/usr/bin/steamcmd",
            // Steam client / SDK locations
            "\(homeDir)/Library/Application Support/Steam/steamcmd",
            "\(homeDir)/Library/Application Support/Steam/steamcmd/steamcmd",
            "\(homeDir)/Library/Application Support/Steam/steamcmd.sh",
            // Standalone SteamCMD package (common extract locations)
            "\(homeDir)/steamcmd/steamcmd.sh",
            "\(homeDir)/steamcmd/steamcmd",
            "\(homeDir)/Downloads/steamcmd/steamcmd.sh",
            "\(homeDir)/Downloads/steamcmd/steamcmd",
            "/Applications/steamcmd/steamcmd.sh",
            "/Applications/steamcmd/steamcmd",
            "\(homeDir)/Projects/SteamSDK/tools/ContentBuilder/builder_osx/steamcmd",
        ]

        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                steamCmdPath = path
                return
            }
        }

        // Try `which` as fallback — run on background thread to avoid blocking main thread
        DispatchQueue.global(qos: .utility).async { [weak self] in
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
                    DispatchQueue.main.async {
                        self?.steamCmdPath = path
                    }
                }
            }
        }
    }

    var isInstalled: Bool { steamCmdPath != nil }

    @Published var pathError: String?

    func setCustomPath(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            pathError = "File not found at selected path."
            return
        }
        // Make executable if needed (e.g. steamcmd.sh from Steam package)
        if !FileManager.default.isExecutableFile(atPath: path) {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: path
            )
        }
        pathError = nil
        UserDefaults.standard.set(path, forKey: "SteamCmdPath")
        steamCmdPath = path
    }

    /// Whether a `+login` transcript ended in a session.
    ///
    /// The old test also accepted any "OK" with exit status 0, which every run satisfies:
    /// steamcmd prints "Loading Steam API...OK" before it has even tried to log in, so the clause
    /// rested on the exit status alone, which is no statement about the session. Current
    /// builds no longer print "Logged in OK" at all — the string is absent from
    /// `steamconsole.dylib` — and end a successful login with "Waiting for user info...OK",
    /// which is printed only once the account is authenticated (its failure is
    /// "ERROR! (Timed out)"). Older builds' "Logged in OK" is still accepted.
    static func loginSucceeded(_ output: String) -> Bool {
        output.contains("Logged in OK")
            || output.range(of: #"Waiting for user info\.\.\.\s*OK"#, options: .regularExpression) != nil
    }

    /// Attempt login with username and password. Steam Guard code is optional.
    func login(username: String, password: String, guardCode: String? = nil) {
        guard steamCmdPath != nil else { return }

        isLoggingIn = true
        loginError = nil
        steamUsername = username

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Only the username is on the command line; see `runSteamCmd` for why the password
            // and the code are typed at steamcmd's prompts instead.
            var answers = [PromptAnswer.password(password)]
            if let code = guardCode, !code.isEmpty {
                answers.append(.guardCode(code))
            }
            let (output, _) = self.runSteamCmd(arguments: ["+login", username, "+quit"],
                                                      answers: answers, timeout: 60)

            DispatchQueue.main.async {
                self.isLoggingIn = false
                if Self.loginSucceeded(output) {
                    self.isLoggedIn = true
                    self.loginError = nil
                    UserDefaults.standard.set(username, forKey: Self.lastUsernameKey)
                } else if output.contains("Steam Guard") || output.contains("Two-factor") {
                    self.loginError = "Steam Guard code required"
                } else if output.contains("Invalid Password") || output.contains("FAILED") {
                    self.loginError = "Invalid username or password"
                } else {
                    self.loginError = "Login failed. Check credentials and try again."
                }
            }
        }
    }

    /// Try login with cached session (no password needed if previously authenticated).
    func loginWithCachedSession(username: String) {
        guard steamCmdPath != nil else { return }

        isLoggingIn = true
        loginError = nil
        steamUsername = username

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let (output, _) = self.runSteamCmd(arguments: ["+login", username, "+quit"], timeout: 30)

            DispatchQueue.main.async {
                self.isLoggingIn = false
                if Self.loginSucceeded(output) {
                    self.isLoggedIn = true
                    UserDefaults.standard.set(username, forKey: Self.lastUsernameKey)
                } else {
                    self.loginError = "Cached session expired. Please log in with password."
                }
            }
        }
    }

    /// Downloads in flight, so Cancel can reach them. Main thread only.
    private var runningDownloads: [String: Process] = [:]
    private var cancelledDownloads: Set<String> = []

    /// How long a download may go without printing anything *and* without its files growing
    /// before it is considered stuck. steamcmd is silent for the whole transfer of a single
    /// Workshop item, so output alone cannot be the heartbeat; the staging directory is.
    private static let downloadInactivityTimeout: TimeInterval = 180
    /// How long steamcmd may take to exit by itself after reporting a finished download.
    private static let exitGraceAfterSuccess: TimeInterval = 10

    func cancelDownload(workshopId: String) {
        guard let process = runningDownloads[workshopId] else { return }
        cancelledDownloads.insert(workshopId)
        Self.terminateTree(process.processIdentifier)
    }

    /// Download a workshop item by its ID.
    func downloadWorkshopItem(workshopId: String) {
        guard let cmdPath = steamCmdPath, isLoggedIn, runningDownloads[workshopId] == nil else { return }

        downloadProgress[workshopId] = .downloading(status: "Starting steamcmd...")
        cancelledDownloads.remove(workshopId)

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
        // An expired cached session makes steamcmd prompt for a password or a Steam Guard
        // code. With the app's own stdin inherited it waited on it forever; at EOF it gives up
        // and says so, which ends up in the failure message.
        process.standardInput = FileHandle.nullDevice
        runningDownloads[workshopId] = process

        let steamAppsDir = self.findSteamAppsDir(cmdPath: cmdPath)
        let stagingDirs = [
            steamAppsDir?.appending(path: "workshop/downloads/431960/\(workshopId)"),
            steamAppsDir?.appending(path: "workshop/content/431960/\(workshopId)"),
        ].compactMap { $0 }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Output is accumulated as bytes on one serial queue and decoded once at the end.
            // Decoding each pipe chunk on its own dropped any chunk that ended part-way through
            // a multibyte character — possibly the very ERROR line the failure message needed —
            // and the String it was appended to was written from the pipe's thread and read
            // from this one with nothing ordering the two.
            let ioQueue = DispatchQueue(label: "steamcmd.download.io")
            var output = Data()
            var partialLine = Data()
            var lastActivity = Date()
            // When steamcmd printed "Success. Downloaded item <id>", if it has. See the wait below.
            var succeededAt: Date?

            let handle = outputPipe.fileHandleForReading
            handle.readabilityHandler = { [weak self] fileHandle in
                let data = fileHandle.availableData
                guard !data.isEmpty else { return }
                var lines: [String] = []
                ioQueue.sync {
                    output.append(data)
                    lastActivity = Date()
                    // Progress is parsed per complete line, split at the byte level so a
                    // character is never cut in two. steamcmd redraws progress with \r.
                    partialLine.append(data)
                    while let end = partialLine.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                        let line = partialLine[partialLine.startIndex..<end]
                        partialLine.removeSubrange(partialLine.startIndex...end)
                        if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
                    }
                    if succeededAt == nil,
                       lines.contains(where: { $0.contains("Downloaded item \(workshopId)") }) {
                        succeededAt = Date()
                    }
                }
                guard let status = lines.compactMap({ self?.parseProgress($0) }).last else { return }
                DispatchQueue.main.async {
                    guard case .downloading = self?.downloadProgress[workshopId] else { return }
                    self?.downloadProgress[workshopId] = .downloading(status: status)
                }
            }

            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }

            do {
                try process.run()
            } catch {
                handle.readabilityHandler = nil
                DispatchQueue.main.async {
                    self.runningDownloads[workshopId] = nil
                    self.downloadProgress[workshopId] = .failed("steamcmd failed to run: \(error.localizedDescription)")
                }
                return
            }

            // Wait for exit, but give up on a steamcmd that has stopped making progress: no
            // network mid-transfer, a prompt it cannot answer, a self-update that hangs. The
            // project rule is that no steamcmd call may wait unbounded; this one used to.
            var stagedBytes = Self.totalSize(of: stagingDirs)
            var timedOut = false
            while exited.wait(timeout: .now() + 5) == .timedOut {
                // steamcmd on macOS often hangs on its way out after a download has finished — a
                // race in the Steam API teardown, reported upstream (Unayung/wallpaper-engine-mac
                // #2) — instead of exiting on +quit. The item is complete in workshop/content once
                // the success line prints, so it is given a short grace period to exit on its own
                // and then ended. Without this the inactivity timeout below caught it three
                // minutes later and reported a finished download as "stopped responding". This is
                // not counted as a timeout: the import that follows checks for project.json, not
                // the exit status.
                if let done = ioQueue.sync(execute: { succeededAt }),
                   Date().timeIntervalSince(done) > Self.exitGraceAfterSuccess {
                    Self.terminateTree(process.processIdentifier)
                    _ = exited.wait(timeout: .now() + 10)
                    break
                }
                let bytes = Self.totalSize(of: stagingDirs)
                if bytes != stagedBytes {
                    stagedBytes = bytes
                    ioQueue.sync { lastActivity = Date() }
                }
                let idle = ioQueue.sync { Date().timeIntervalSince(lastActivity) }
                if idle > Self.downloadInactivityTimeout {
                    timedOut = true
                    Self.terminateTree(process.processIdentifier)
                    _ = exited.wait(timeout: .now() + 10)
                    break
                }
            }

            // No readDataToEndOfFile here: steamcmd.sh runs the real binary as a child, and a
            // child that outlives a terminated script keeps the pipe open, which would block
            // that read forever. Whatever was still buffered at exit arrives through the
            // handler within a moment.
            Thread.sleep(forTimeInterval: 0.25)
            handle.readabilityHandler = nil
            let fullOutput = ioQueue.sync { String(decoding: output, as: UTF8.self) }

            let wasCancelled = DispatchQueue.main.sync { () -> Bool in
                self.runningDownloads[workshopId] = nil
                return self.cancelledDownloads.remove(workshopId) != nil
            }
            if wasCancelled || timedOut {
                DispatchQueue.main.async {
                    self.downloadProgress[workshopId] = .failed(wasCancelled
                        ? "Cancelled"
                        : "steamcmd stopped responding (no progress for \(Int(Self.downloadInactivityTimeout / 60)) min)")
                }
                return
            }

            let exitCode = process.terminationStatus
            // Only the tail, and never the account: the whole transcript used to be printed for
            // every download, "Logging in user '<name>'" included, which is more than a console
            // capture or a pasted bug report should carry. The failure lines are at the end.
            let tail = fullOutput.components(separatedBy: .newlines).suffix(15)
                .filter { !$0.contains("Logging in user") }
                .joined(separator: "\n")
            print("steamcmd download [\(workshopId)] exit=\(exitCode)\n\(tail)")

            // Find downloaded content
            let sourcePath = steamAppsDir?
                .appending(path: "workshop/content/431960/\(workshopId)")

            // Importing happens here, on the download's own background thread. It used to run
            // inside DispatchQueue.main.async, which is instant on one APFS volume (copyItem
            // clones) but a multi-second freeze of the UI and every wallpaper window when
            // steamcmd's steamapps lives on another volume and a 4K video has to be copied.
            let fm = FileManager.default
            if let sourceDir = sourcePath,
               fm.fileExists(atPath: sourceDir.appending(path: "project.json").path) {
                DispatchQueue.main.async {
                    self.downloadProgress[workshopId] = .downloading(status: "Copying to library...")
                }
                let result = Self.importItem(from: sourceDir, workshopId: workshopId)
                DispatchQueue.main.async {
                    switch result {
                    case .success(let imported):
                        self.downloadProgress[workshopId] = .completed
                        NotificationCenter.default.post(name: .workshopItemImported, object: nil,
                                                        userInfo: ["directory": imported])
                    case .failure(let message):
                        self.downloadProgress[workshopId] = .failed(message.text)
                    }
                }
                return
            }

            DispatchQueue.main.async {
                if fullOutput.contains("ERROR") || fullOutput.contains("FAILED") {
                    let errorLine = fullOutput.components(separatedBy: "\n")
                        .first(where: { $0.contains("ERROR") || $0.contains("FAILED") })
                        ?? "Unknown error"
                    self.downloadProgress[workshopId] = .failed(errorLine)
                } else if exitCode != 0 {
                    self.downloadProgress[workshopId] = .failed("Exit code \(exitCode)")
                } else if let sourceDir = sourcePath, fm.fileExists(atPath: sourceDir.path) {
                    // steamcmd reported success and made the folder, but there is no manifest
                    // in it — typically an item that was removed from the Workshop.
                    self.downloadProgress[workshopId] = .failed("Download is empty — item may be delisted")
                } else {
                    self.downloadProgress[workshopId] = .failed("Files not found at expected path")
                }
            }
        }
    }

    struct ImportFailure: Error { let text: String }

    /// Copy a downloaded item into the library, replacing any copy already there.
    ///
    /// A wallpaper is its `project.json`; the directory existing proves nothing. steamcmd leaves
    /// an empty folder behind for a delisted or failed item, and an old check ("does the
    /// destination path exist?") reported Downloaded for it permanently.
    ///
    /// A destination that *is* a wallpaper is replaced, not kept. Skipping it meant that
    /// re-downloading an item its author had updated fetched the new version, reported
    /// Downloaded, and left the library playing the old one. The new copy is staged as a hidden
    /// sibling (the library listing skips hidden entries) and swapped in with replaceItemAt, so a
    /// failure part-way through leaves the old wallpaper intact rather than half of each.
    static func importItem(from sourceDir: URL, workshopId: String) -> Result<URL, ImportFailure> {
        let fm = FileManager.default
        let library = fm.wallpapersDirectory
        let dest = library.appending(path: workshopId)
        let manifest = dest.appending(path: "project.json")

        // An empty or partial earlier copy has nothing worth keeping.
        if fm.fileExists(atPath: dest.path), !fm.fileExists(atPath: manifest.path) {
            try? fm.removeItem(at: dest)
        }

        do {
            if fm.fileExists(atPath: dest.path) {
                let staging = library.appending(path: ".\(workshopId).incoming-\(UUID().uuidString)")
                do {
                    try fm.copyItem(at: sourceDir, to: staging)
                    _ = try fm.replaceItemAt(dest, withItemAt: staging)
                } catch {
                    try? fm.removeItem(at: staging)
                    throw error
                }
            } else {
                try fm.copyItem(at: sourceDir, to: dest)
            }
        } catch {
            return .failure(ImportFailure(text: "Copy failed: \(error.localizedDescription)"))
        }

        guard fm.fileExists(atPath: manifest.path) else {
            return .failure(ImportFailure(text: "Copied files are missing project.json"))
        }
        return .success(dest)
    }

    /// Total size of the regular files under the given directories; missing ones count as 0.
    private static func totalSize(of directories: [URL]) -> Int {
        let fm = FileManager.default
        var total = 0
        for dir in directories {
            guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])
            else { continue }
            for case let url as URL in walker {
                total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return total
    }

    /// SIGTERM a process and everything under it, children first. steamcmd.sh is a wrapper
    /// script, so terminating only the Process would leave the real steamcmd running — still
    /// downloading, and still holding the install lock the next login or download needs.
    @discardableResult
    private static func terminateTree(_ pid: pid_t) -> [pid_t] {
        let tree = processTree(pid)
        for member in tree { kill(member, SIGTERM) }
        return tree
    }

    /// A process and everything under it, children before parents. Taken as a snapshot so a
    /// later SIGKILL can still reach a grandchild that ignored SIGTERM: once its parent has
    /// exited it is reparented to launchd and no longer findable from the root.
    private static func processTree(_ pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        var children = [pid_t](repeating: 0, count: 64)
        let count = proc_listchildpids(pid, &children,
                                       Int32(children.count * MemoryLayout<pid_t>.size))
        var tree: [pid_t] = []
        for child in children.prefix(max(0, min(Int(count), children.count))) where child > 0 {
            tree += processTree(child)
        }
        return tree + [pid]
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

extension Notification.Name {
    /// Posted on the main thread after a Workshop item lands in the library, new or replacing an
    /// older copy. `userInfo["directory"]` is its URL.
    static let workshopItemImported = Notification.Name("WorkshopItemImported")
}
