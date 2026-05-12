import CocoaLumberjackSwift

final class LogService {
    nonisolated(unsafe) static let shared = LogService()
    private let fileLogger: DDFileLogger
    nonisolated(unsafe) static var currentSessionID: String?

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
        currentSessionID = id
        info("Session started", category: "Recording")
        return id
    }

    nonisolated static func endSession() {
        info("Session ended", category: "Recording")
        currentSessionID = nil
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
}
