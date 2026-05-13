import Foundation

final class CrashGuard {
    static let shared = CrashGuard()

    private init() {
        installHandlers()
    }

    private func installHandlers() {
        signal(SIGSEGV) { sig in CrashGuard.handle(sig) }
        signal(SIGBUS)  { sig in CrashGuard.handle(sig) }
        signal(SIGABRT) { sig in CrashGuard.handle(sig) }
        signal(SIGILL)  { sig in CrashGuard.handle(sig) }
    }

    private static func handle(_ sig: Int32) {
        let name: String
        switch sig {
        case SIGSEGV: name = "SIGSEGV"
        case SIGBUS:  name = "SIGBUS"
        case SIGABRT: name = "SIGABRT"
        case SIGILL:  name = "SIGILL"
        default:      name = "SIG\(sig)"
        }

        var bt = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let count = backtrace(&bt, 64)
        let symbols = backtrace_symbols(bt, count)

        let logDir = NSHomeDirectory() + "/.NemoNoise/logs"
        let crashPath = logDir + "/crash.log"
        var msg = "=== CRASH \(name) ===\n"
        if let symbols {
            for i in 0..<Int(count) {
                if let sym = symbols[i] {
                    msg += "  \(String(cString: sym))\n"
                }
            }
        }
        msg += "\n"

        // Write directly to file (cannot use LogService safely in signal handler)
        let fm = FileManager.default
        if !fm.fileExists(atPath: logDir) {
            try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        }
        if let handle = FileHandle(forWritingAtPath: crashPath) {
            handle.seekToEndOfFile()
            handle.write(Data(msg.utf8))
            handle.closeFile()
        } else {
            try? msg.write(toFile: crashPath, atomically: true, encoding: .utf8)
        }

        // Re-raise with default handler so macOS generates a proper crash report
        signal(sig, SIG_DFL)
        raise(sig)
    }
}
