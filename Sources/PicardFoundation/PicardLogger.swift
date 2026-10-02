import OSLog

public enum PicardLogger {
    public static let subsystem = "com.interlacedpixel.MacPicard"

    public static let application = Logger(subsystem: subsystem, category: "application")
    public static let configuration = Logger(subsystem: subsystem, category: "configuration")
    public static let security = Logger(subsystem: subsystem, category: "security")
    public static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")

    public static func info(_ message: String) {
        application.info("\(message, privacy: .public)")
    }

    public static func warning(_ message: String) {
        application.warning("\(message, privacy: .public)")
    }

    public static func error(_ message: String) {
        application.error("\(message, privacy: .public)")
    }
}
