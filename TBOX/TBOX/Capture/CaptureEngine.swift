import Cocoa
import CoreGraphics
import os

class CaptureEngine {
    static let shared = CaptureEngine()
    private(set) var cachedScreenshots: [CGDirectDisplayID: CGImage] = [:]
    private let captureQueue = DispatchQueue(
        label: "com.tbox.capture.display",
        qos: .userInteractive,
        attributes: .concurrent
    )

    /// 每块显示器分别截图。CGDisplayCreateImage 返回该显示器自己的像素坐标空间，
    /// 避免将主屏截图错误地复用到副屏。
    func captureScreens(_ screens: [NSScreen], completion: @escaping ([CGDirectDisplayID: CGImage]) -> Void) {
        let displayIDs = screens.compactMap(\.displayID)
        guard !displayIDs.isEmpty else {
            AppLog.captureError("无法获取显示器 displayID")
            completion([:])
            return
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let group = DispatchGroup()
        let lock = NSLock()
        var screenshots: [CGDirectDisplayID: CGImage] = [:]

        // 多显示器不再串行等待；每块屏幕独立抓取，总耗时取最慢屏幕，
        // 而不是所有屏幕耗时之和。
        for displayID in displayIDs {
            group.enter()
            captureQueue.async {
                defer { group.leave() }
                guard let image = CGDisplayCreateImage(displayID) else {
                    AppLog.captureError("CGDisplayCreateImage 失败: displayID=\(displayID)")
                    return
                }
                lock.lock()
                screenshots[displayID] = image
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let milliseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
            AppLog.capture("并行屏幕抓取完成: \(screenshots.count)/\(displayIDs.count), \(milliseconds)ms")
            self.cachedScreenshots = screenshots
            completion(screenshots)
        }
    }

    func clearCache() {
        cachedScreenshots.removeAll()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
