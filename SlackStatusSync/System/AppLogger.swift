import Foundation
import OSLog

public enum AppLogger {
    public static let subsystem = "dev.local.SlackStatusSync"

    private static let logger = Logger(subsystem: subsystem, category: "app")

    public static func info(_ message: String, category: String = "app") {
        Logger(subsystem: subsystem, category: category).info("\(message, privacy: .public)")
    }

    public static func error(_ message: String, category: String = "app") {
        Logger(subsystem: subsystem, category: category).error("\(message, privacy: .public)")
    }

    public static func debug(_ message: String, category: String = "app") {
        Logger(subsystem: subsystem, category: category).debug("\(message, privacy: .public)")
    }

    /// Never pass tokens, event titles, or status text.
    public static func syncEvent(_ reason: String, applied: Bool) {
        logger.info("sync reason=\(reason, privacy: .public) applied=\(applied, privacy: .public)")
    }
}
