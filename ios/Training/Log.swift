import Foundation
import os

/// One place for diagnostics, so a problem on the device can be read out of the
/// Console app without a debugger attached.
enum Log {
    private static let logger = Logger(subsystem: "de.besemedia.training", category: "shell")

    static func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    static func warn(_ message: String) { logger.warning("\(message, privacy: .public)") }
}
