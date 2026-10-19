import os.log

/// 统一日志工具，输出到系统日志（Console.app 可查）
enum AppLog {
    private static let subsystem = "com.tbox.app"
    private static let general = OSLog(subsystem: subsystem, category: "general")
    private static let capture = OSLog(subsystem: subsystem, category: "capture")
    private static let ui = OSLog(subsystem: subsystem, category: "ui")
    private static let recording = OSLog(subsystem: subsystem, category: "recording")

    // MARK: - 通用

    static func info(_ msg: String) {
        os_log(.info, log: general, "%{public}@", msg)
    }

    static func error(_ msg: String) {
        os_log(.error, log: general, "%{public}@", msg)
    }

    // MARK: - 截图

    static func capture(_ msg: String) {
        os_log(.info, log: capture, "%{public}@", msg)
    }

    static func captureError(_ msg: String) {
        os_log(.error, log: capture, "%{public}@", msg)
    }

    static func recording(_ msg: String) {
        os_log(.info, log: recording, "%{public}@", msg)
    }

    static func recordingError(_ msg: String) {
        os_log(.error, log: recording, "%{public}@", msg)
    }

    // MARK: - UI 交互

    static func ui(_ msg: String) {
        os_log(.info, log: ui, "%{public}@", msg)
    }
}
