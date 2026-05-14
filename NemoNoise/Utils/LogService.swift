import CocoaLumberjackSwift
import os

final class LogService {
    nonisolated(unsafe) static let shared = LogService()
    private let fileLogger: DDFileLogger
    private static let sessionLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    nonisolated static var currentSessionID: String? {
        sessionLock.withLock { $0 }
    }

    private init() {
        let logDir = NSHomeDirectory() + "/.NemoNoise/logs"

        let fm = FileManager.default
        if !fm.fileExists(atPath: logDir) {
            try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        }

        DDLog.add(DDOSLogger.sharedInstance)

        let logFileManager = DDLogFileManagerDefault(logsDirectory: logDir)
        logFileManager.maximumNumberOfLogFiles = 7
        fileLogger = DDFileLogger(logFileManager: logFileManager)
        fileLogger.maximumFileSize = 5 * 1024 * 1024
        fileLogger.rollingFrequency = 60 * 60 * 24
        DDLog.add(fileLogger)

        #if DEBUG
        dynamicLogLevel = .all
        #else
        dynamicLogLevel = .info
        #endif
    }

    var currentLogFile: String? {
        fileLogger.currentLogFileInfo?.filePath
    }

    nonisolated static func startSession() -> String {
        let id = UUID().uuidString
        sessionLock.withLock { $0 = id }
        info("Session started", category: "Recording")
        return id
    }

    nonisolated static func endSession() {
        info("Session ended", category: "Recording")
        sessionLock.withLock { $0 = nil }
    }
}

extension LogService {
    nonisolated private static func formatted(_ message: String, category: String) -> String {
        if let sid = currentSessionID {
            return "[\(category)] [session:\(sid.prefix(8))] \(message)"
        }
        return "[\(category)] \(message)"
    }

    nonisolated static func debug(_ message: String, category: String = "App") {
        _ = shared
        DDLogDebug(formatted(message, category: category))
    }

    nonisolated static func info(_ message: String, category: String = "App") {
        _ = shared
        DDLogInfo(formatted(message, category: category))
    }

    nonisolated static func warn(_ message: String, category: String = "App") {
        _ = shared
        DDLogWarn(formatted(message, category: category))
    }

    nonisolated static func error(_ message: String, category: String = "App") {
        _ = shared
        DDLogError(formatted(message, category: category))
    }

    // MARK: - Export

    @discardableResult
    nonisolated static func exportLogs() -> String? {
        let fm = FileManager.default
        let logDir = NSHomeDirectory() + "/.NemoNoise/logs"

        guard let files = try? fm.contentsOfDirectory(atPath: logDir) else { return nil }

        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let username = NSUserName()
        let homeDir = NSHomeDirectory()

        var allLogs: [String] = []

        for file in files.sorted() {
            let filePath = (logDir as NSString).appendingPathComponent(file)
            guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate > sevenDaysAgo else { continue }

            guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }
            allLogs.append(sanitize(content, username: username, homeDir: homeDir))
        }

        guard !allLogs.isEmpty else { return nil }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let header = "NemoNoise Log Export\nExported: \(df.string(from: Date()))\nNote: User paths sanitized for privacy.\n---\n"

        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let desktopPath = NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first!
        let exportPath = (desktopPath as NSString).appendingPathComponent("NemoNoise_logs_\(df.string(from: Date())).txt")

        do {
            try (header + allLogs.joined(separator: "\n---\n")).write(toFile: exportPath, atomically: true, encoding: .utf8)
            return exportPath
        } catch {
            return nil
        }
    }

    nonisolated private static func sanitize(_ text: String, username: String, homeDir: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: homeDir, with: "/Users/[USER]")
        if !username.isEmpty {
            result = result.replacingOccurrences(of: "/Users/\(username)", with: "/Users/[USER]")
        }
        return result
    }
}
