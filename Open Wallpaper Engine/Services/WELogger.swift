import Foundation

final class WELogger {
    static let shared = WELogger()

    private let queue = DispatchQueue(label: "WELogger", qos: .utility)
    private var fileHandle: FileHandle?
    private var activeDate: String = ""

    private let logDir: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Open Wallpaper Engine/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // Set from main thread only (GlobalSettingsViewModel.validate)
    var level: GSLogLevel = .none {
        didSet {
            guard oldValue != level else { return }
            if level == .none {
                queue.async { [weak self] in
                    self?.fileHandle?.closeFile()
                    self?.fileHandle = nil
                }
            } else if oldValue == .none {
                queue.async { [weak self] in self?.openTodayFile() }
            }
        }
    }

    var logDirURL: URL { logDir }

    var todayLogURL: URL { logDir.appendingPathComponent("app-\(todayString).log") }

    private var todayString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private init() {}

    private func openTodayFile() {
        let today = todayString
        activeDate = today
        let url = logDir.appendingPathComponent("app-\(today).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle?.closeFile()
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
        let header = "\n=== Session started \(Date()) ===\n"
        fileHandle?.write(header.data(using: .utf8) ?? Data())
        pruneOldLogs()
    }

    // Delete log files older than 7 days
    private func pruneOldLogs() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "log" {
            let name = file.deletingPathExtension().lastPathComponent // "app-2026-06-01"
            let datePart = String(name.dropFirst(4)) // "2026-06-01"
            if let date = df.date(from: datePart), date < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func verbose(_ message: @autoclosure () -> String) {
        guard level == .verbose else { return }
        write(message(), tag: "VERBOSE")
    }

    func error(_ message: @autoclosure () -> String) {
        guard level != .none else { return }
        write(message(), tag: "ERROR")
    }

    private static let tsFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func write(_ message: String, tag: String) {
        let ts = WELogger.tsFormatter.string(from: Date())
        let line = "[\(ts)] [\(tag)] \(message)\n"
        queue.async { [weak self] in
            guard let self else { return }
            // Rotate at midnight
            let today = todayString
            if today != activeDate {
                openTodayFile()
            }
            fileHandle?.write(line.data(using: .utf8) ?? Data())
        }
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: logDir, includingPropertiesForKeys: nil) else { return }
            files.filter { $0.pathExtension == "log" }
                 .forEach { try? FileManager.default.removeItem(at: $0) }
            if level != .none {
                fileHandle?.closeFile()
                fileHandle = nil
                openTodayFile()
            }
        }
    }
}
