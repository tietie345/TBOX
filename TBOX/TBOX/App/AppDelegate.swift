import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var hotkeyManager: HotkeyManager!
    var overlayPanels: [OverlayPanel] = []
    private var preparedOverlayPanels: [CGDirectDisplayID: OverlayPanel] = [:]
    private var pinWindows: [PinWindow] = []
    private var pinEditorWindows: [PinEditorWindow] = []
    private var isCapturing = false
    private var recorder: ScreenRecorder?
    private var recordingControlPanel: RecordingControlPanel?
    private var recordingRegionWindow: RecordingRegionWindow?
    private weak var recordingMenuItem: NSMenuItem?
    private var transcriptionManager: RecordingTranscriptionManager?
    private var transcriptionControlPanel: RecordingTranscriptionControlPanel?
    private var transcriptionResultWindow: RecordingTranscriptionResultWindow?
    private var savedTranscriptWindows: [URL: RecordingTranscriptionResultWindow] = [:]
    private weak var transcriptionMenuItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private var isShowingScreenCapturePermissionAlert = false

    private enum ScreenCapturePermissionDefaults {
        static let hasCapturedSuccessfully = "screenCaptureHasCapturedSuccessfully"
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // 客户端是用户感知的主应用；截图、录屏作为随客户端运行的常驻能力。
        NSApp.setActivationPolicy(.regular)
        print("[TBOX] 应用启动")
        AppLog.info("TBOX 启动")
        setupStatusItem()
        hotkeyManager = HotkeyManager()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeyTriggered),
            name: .tboxHotkeyTriggered,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordHotkeyTriggered),
            name: .tboxRecordHotkeyTriggered,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewRecordingTranscript(_:)),
            name: .tboxViewRecordingTranscript,
            object: nil
        )
        print("[TBOX] 启动完成，等待快捷键 Ctrl+Shift+A")
        AppLog.info("启动完成，等待快捷键")
        // 双击应用时直接展示客户端界面；菜单栏图标和全局快捷键仍然保留。
        DispatchQueue.main.async { [weak self] in
            self?.openSettings()
        }
        // 全屏遮罩包含较多控件和 SwiftUI/Translation 依赖。应用空闲时预先
        // 创建，快捷键触发后只替换截图，避免首次唤起承担初始化成本。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.prepareOverlayPanelsIfNeeded()
        }
        // 语音模型体积较大（约 637 MB），启动时只检查状态，不在后台静默下载；
        // 改由首次转写时经用户确认后下载，或在“设置 · 模型”手动触发。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            ModelPreloader.shared.checkAtLaunch()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openSettings() }
        return true
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "camera.viewfinder",
                accessibilityDescription: "TBOX"
            )
            button.image?.isTemplate = true
            button.toolTip = "TBOX 截图工具"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开 TBOX", action: #selector(openSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "截屏  Ctrl+Shift+A", action: #selector(hotkeyTriggered), keyEquivalent: ""))
        let recordItem = NSMenuItem(title: "录制当前屏幕  Ctrl+Shift+R", action: #selector(recordHotkeyTriggered), keyEquivalent: "")
        menu.addItem(recordItem)
        recordingMenuItem = recordItem
        let transcriptionItem = NSMenuItem(title: "开始录音转写", action: #selector(transcriptionMenuTriggered), keyEquivalent: "")
        menu.addItem(transcriptionItem)
        transcriptionMenuItem = transcriptionItem
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "权限设置...", action: #selector(openPrivacySettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "打开客户端...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    private func showScreenCapturePermissionAlert(nativeRequestAccepted: Bool = false) {
        guard !isShowingScreenCapturePermissionAlert else { return }
        isShowingScreenCapturePermissionAlert = true
        defer { isShowingScreenCapturePermissionAlert = false }

        let hasCapturedSuccessfully = UserDefaults.standard.bool(
            forKey: ScreenCapturePermissionDefaults.hasCapturedSuccessfully
        )
        let alert = NSAlert()
        alert.alertStyle = .warning
        if nativeRequestAccepted {
            alert.messageText = "屏幕录制权限已授权，需要重新启动 TBOX"
            alert.informativeText = "macOS 只会把新授权交给重新启动后的进程。现在重启后，Ctrl + Shift + A 就可以正常截图。"
            alert.addButton(withTitle: "退出并重新打开")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                relaunchApplication()
            }
            return
        }

        alert.messageText = hasCapturedSuccessfully
            ? "旧版本的屏幕录制授权已失效"
            : "TBOX 尚未获得当前版本的屏幕录制权限"
        alert.informativeText = "如果系统设置里的 TBOX 开关已经开启，说明它仍绑定旧版本的签名。请在“系统设置 → 隐私与安全性 → 屏幕与系统录音”中：\n\n1. 选中 TBOX，点击“−”删除旧条目；\n2. 点击“+”，重新添加当前 TBOX.app；\n3. 打开 TBOX 的权限开关；\n4. 返回这里，点击“退出并重新打开”。\n\n当前应用：\(Bundle.main.bundleURL.path)\n\n权限生效前不会进入截图遮罩，避免出现桌面像被清空的情况。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "退出并重新打开")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openPrivacySettings()
        case .alertSecondButtonReturn:
            relaunchApplication()
        default:
            break
        }
    }

    /// 屏幕录制权限在 macOS 中按进程缓存。即使用户刚刚打开了系统开关，
    /// 当前进程的预检结果也可能保持为 false，必须退出并重新启动后才会更新。
    /// 注意：截图（CGDisplayCreateImage）与录屏（ScreenCaptureKit）权限路径
    /// 不完全相同，截图成功不代表 SCStream 一定可用；最终以 startCapture 的
    /// 错误为准（见 handleRecordingFailure）。
    private func ensureScreenCapturePermission() -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            AppLog.capture("屏幕录制预检未通过，尝试触发系统原生授权请求")
            let accepted = CGRequestScreenCaptureAccess()
            AppLog.capture("系统原生屏幕录制授权结果: \(accepted ? "已接受，等待重启" : "未授权或旧记录失配")")
            showScreenCapturePermissionAlert(nativeRequestAccepted: accepted)
            return false
        }
        return true
    }

    /// SCStream 启动/运行失败时，判断是否为屏幕录制权限问题。
    /// macOS 15 上 CGPreflightScreenCaptureAccess() 可能误报 true，
    /// 因此以 startCapture 返回的实际错误为权威依据。
    private func isScreenCapturePermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        // SCStreamError 的 domain 在不同版本可能为 SCStreamErrorDomain
        // 或 com.apple.ScreenCaptureKit.error
        if nsError.domain.contains("ScreenCapture") || nsError.domain.contains("SCStream") {
            return true
        }
        // 兜底：权限失配时系统返回的泛化错误
        if nsError.localizedDescription.contains("operation could not be completed") {
            return true
        }
        return false
    }

    /// 使用延迟启动器，确保旧进程完全退出后再打开同一个 App，避免桌面上
    /// 短时间出现两个 TBOX 实例，也不会从其他路径启动旧副本。
    private func relaunchApplication() {
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = [
            "-c",
            "sleep 0.8; /usr/bin/open \"$1\"",
            "tbox-relaunch",
            Bundle.main.bundleURL.path
        ]

        do {
            try launcher.run()
            AppLog.info("准备退出并重新打开当前 TBOX.app")
            NSApp.terminate(nil)
        } catch {
            AppLog.error("无法重新启动 TBOX: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "无法自动重新启动 TBOX"
            alert.informativeText = "请手动退出 TBOX，然后重新打开：\(Bundle.main.bundleURL.path)"
            alert.runModal()
        }
    }

    @objc private func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        window.title = "TBOX"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 900, height: 620))
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 截图流程

    @objc func hotkeyTriggered() {
        let hotkeyStartedAt = ProcessInfo.processInfo.systemUptime
        print("[TBOX] 快捷键触发!")
        guard overlayPanels.isEmpty, !isCapturing, recorder == nil, !(transcriptionManager?.isActive ?? false) else {
            print("[TBOX] 截图会话进行中，忽略")
            AppLog.ui("快捷键触发，但截图会话进行中，忽略")
            return
        }

        // 未授权时 CGDisplayCreateImage 仍可能返回一张只含桌面的图片。
        // 若继续显示它，用户看到的效果会像所有窗口被“清屏”，因此必须
        // 在进入遮罩前阻断，并完成原生授权/重启流程。
        guard ensureScreenCapturePermission() else { return }
        AppLog.capture("屏幕录制预检已通过")

        // 隐藏客户端窗口，避免它被包含在待截取页面中。
        settingsWindow?.orderOut(nil)

        isCapturing = true
        print("[TBOX] 开始截图...")
        AppLog.ui("快捷键触发，开始截图")
        let screens = NSScreen.screens

        CaptureEngine.shared.captureScreens(screens) { [weak self] screenshots in
            guard let self = self else { return }
            guard !screenshots.isEmpty else {
                self.isCapturing = false
                print("[TBOX] ❌ 截图失败，请检查屏幕录制权限")
                AppLog.captureError("截图失败，请检查屏幕录制权限")
                self.showScreenCapturePermissionAlert()
                return
            }

            let captureMilliseconds = Int((ProcessInfo.processInfo.systemUptime - hotkeyStartedAt) * 1_000)
            AppLog.capture("截图成功: \(screenshots.count)/\(screens.count) 块屏幕，热键后 \(captureMilliseconds)ms")
            UserDefaults.standard.set(
                true,
                forKey: ScreenCapturePermissionDefaults.hasCapturedSuccessfully
            )

            var panels: [OverlayPanel] = []

            for screen in screens {
                guard let displayID = screen.displayID,
                      let cgImage = screenshots[displayID] else {
                    AppLog.captureError("跳过截图失败的显示器")
                    continue
                }
                let panel: OverlayPanel
                if let prepared = self.preparedOverlayPanels.removeValue(forKey: displayID),
                   prepared.frame == screen.frame {
                    panel = prepared
                    AppLog.ui("复用预热遮罩: displayID=\(displayID)")
                } else {
                    panel = OverlayPanel(screen: screen)
                    AppLog.ui("即时创建遮罩: displayID=\(displayID)")
                }
                panel.overlayView.setScreenshot(cgImage)
                panel.overlayView.onCapture = { [weak self, weak panel] rect in
                    guard let panel else { return }
                    self?.captureAndCopy(
                        image: cgImage,
                        rect: rect,
                        logicalSize: screen.frame.size,
                        cornerRadius: panel.overlayView.outputCornerRadius,
                        hasShadow: panel.overlayView.outputHasShadow
                    )
                }
                panel.overlayView.onCancel = { [weak self] in
                    self?.closeOverlays()
                }
                panel.overlayView.onSave = { [weak self, weak panel] in
                    guard let panel else { return }
                    self?.captureAndSave(
                        image: cgImage,
                        rect: panel.overlayView.selectionRect,
                        logicalSize: screen.frame.size,
                        cornerRadius: panel.overlayView.outputCornerRadius,
                        hasShadow: panel.overlayView.outputHasShadow
                    )
                }
                panel.overlayView.onPin = { [weak self, weak panel] rect in
                    guard let panel else { return }
                    self?.pinSelection(
                        image: cgImage,
                        rect: rect,
                        logicalSize: screen.frame.size,
                        cornerRadius: panel.overlayView.outputCornerRadius,
                        hasShadow: panel.overlayView.outputHasShadow
                    )
                }
                panel.overlayView.onRecord = { [weak self] rect in
                    self?.startRecording(screen: screen, localRect: rect)
                }
                panel.overlayView.onTranscribe = { [weak self] in
                    self?.startTranscriptionRecording()
                }
                panel.overlayView.onCaptureAnnotated = { [weak self] image in
                    ClipboardManager.copyImage(image)
                    AppLog.capture("标注合成完成，已复制到剪贴板")
                    self?.closeOverlays()
                }
                panel.overlayView.onSaveAnnotated = { [weak self] image in
                    self?.saveRenderedImage(image, suggestedName: "标注截图")
                }
                panels.append(panel)
            }

            self.overlayPanels = panels
            self.isCapturing = false

            guard !panels.isEmpty else {
                CaptureEngine.shared.clearCache()
                AppLog.captureError("没有可显示的截图面板")
                return
            }

            for panel in panels {
                panel.showOverlay()
            }
            let totalMilliseconds = Int((ProcessInfo.processInfo.systemUptime - hotkeyStartedAt) * 1_000)
            print("[TBOX] 遮罩已显示: \(panels.count) 个面板")
            AppLog.ui("遮罩已显示: \(panels.count) 个面板，热键总耗时 \(totalMilliseconds)ms")
        }
    }

    private func prepareOverlayPanelsIfNeeded() {
        guard overlayPanels.isEmpty, !isCapturing else { return }
        let screens = NSScreen.screens
        let validIDs = Set(screens.compactMap(\.displayID))
        preparedOverlayPanels = preparedOverlayPanels.filter { validIDs.contains($0.key) }

        let startedAt = ProcessInfo.processInfo.systemUptime
        for screen in screens {
            guard let displayID = screen.displayID else { continue }
            if let existing = preparedOverlayPanels[displayID], existing.frame == screen.frame {
                continue
            }
            preparedOverlayPanels[displayID] = OverlayPanel(screen: screen)
        }
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        AppLog.ui("遮罩预热完成: \(preparedOverlayPanels.count) 个，\(milliseconds)ms")
    }

    // MARK: - 录屏流程

    @objc private func recordHotkeyTriggered() {
        if recorder != nil {
            stopRecording()
            return
        }
        guard overlayPanels.isEmpty, !isCapturing, !(transcriptionManager?.isActive ?? false) else { return }
        // 与截图流程一致：权限缺失/签名失配时先触发系统原生授权并引导重启。
        // 否则 SCStream 能启动但静默不产帧，停止时报“没有录到画面”。
        guard ensureScreenCapturePermission() else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let screen else { return }
        startRecording(screen: screen, localRect: NSRect(origin: .zero, size: screen.frame.size))
    }

    private func startRecording(screen: NSScreen, localRect: NSRect) {
        guard recorder == nil, !(transcriptionManager?.isActive ?? false), let displayID = screen.displayID else { return }
        // 统一入口预检：工具栏“录制选区”与快捷键都经过这里。权限缺失时
        // 触发系统原生授权弹窗并引导重启，避免 SCStream 静默失败。
        guard ensureScreenCapturePermission() else { return }
        let rect = localRect.standardized.intersection(NSRect(origin: .zero, size: screen.frame.size))
        guard rect.width >= 2, rect.height >= 2 else { return }

        closeOverlays()
        let sourceRect = CGRect(
            x: rect.minX,
            y: screen.frame.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let globalFrame = NSRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.minY + rect.minY,
            width: rect.width,
            height: rect.height
        )

        let recorder = ScreenRecorder()
        self.recorder = recorder
        recorder.onStateChange = { [weak self] state in
            guard let self else { return }
            self.recordingMenuItem?.title = state == .idle
                ? "录制当前屏幕  Ctrl+Shift+R"
                : "停止录制  Ctrl+Shift+R"
            if state == .paused { self.recordingControlPanel?.setPaused(true) }
            if state == .recording { self.recordingControlPanel?.setPaused(false) }
        }
        recorder.onFailure = { [weak self] error in self?.handleRecordingFailure(error) }

        recorder.start(displayID: displayID, sourceRect: sourceRect) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                UserDefaults.standard.set(true, forKey: ScreenCapturePermissionDefaults.hasCapturedSuccessfully)
                let controls = RecordingControlPanel(screen: screen)
                controls.onPause = { [weak self] in self?.recorder?.togglePause() }
                controls.onStop = { [weak self] in self?.stopRecording() }
                self.recordingControlPanel = controls
                let border = RecordingRegionWindow(frame: globalFrame)
                self.recordingRegionWindow = border
                border.orderFrontRegardless()
                controls.show()
            case .failure(let error):
                self.recorder = nil
                self.recordingMenuItem?.title = "录制当前屏幕  Ctrl+Shift+R"
                if self.isScreenCapturePermissionError(error) {
                    AppLog.recordingError(
                        "SCStream 启动失败（疑似权限）：domain=\((error as NSError).domain) " +
                        "code=\((error as NSError).code)"
                    )
                    self.showScreenCapturePermissionAlert(nativeRequestAccepted: false)
                } else {
                    self.showRecordingError(error)
                }
            }
        }
    }

    private func stopRecording() {
        recordingControlPanel?.finish()
        recordingControlPanel = nil
        recordingRegionWindow?.orderOut(nil)
        recordingRegionWindow = nil
        guard let recorder else { return }
        recorder.stop { [weak self] result in
            guard let self else { return }
            self.recorder = nil
            self.recordingMenuItem?.title = "录制当前屏幕  Ctrl+Shift+R"
            switch result {
            case .success(let temporaryURL):
                self.presentRecordingSavePanel(temporaryURL: temporaryURL)
            case .failure(let error):
                self.showRecordingError(error)
            }
        }
    }

    private func presentRecordingSavePanel(temporaryURL: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "录屏_\(Int(Date().timeIntervalSince1970)).mp4"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            guard response == .OK, let destination = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: temporaryURL, to: destination)
                AppLog.recording("录屏保存成功: \(destination.lastPathComponent)")
            } catch {
                self.showRecordingError(error)
            }
        }
    }

    private func showRecordingError(_ error: Error) {
        let nsError = error as NSError
        AppLog.recordingError(
            "showRecordingError 被调用: domain=\(nsError.domain) code=\(nsError.code) " +
            "desc=\(nsError.localizedDescription)"
        )
        // 兜底：如果错误信息匹配权限失配特征，直接走权限弹窗
        if isScreenCapturePermissionError(error) {
            showScreenCapturePermissionAlert(nativeRequestAccepted: false)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "录屏失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func handleRecordingFailure(_ error: Error) {
        recordingControlPanel?.finish()
        recordingControlPanel = nil
        recordingRegionWindow?.orderOut(nil)
        recordingRegionWindow = nil
        recorder = nil
        recordingMenuItem?.title = "录制当前屏幕  Ctrl+Shift+R"
        if isScreenCapturePermissionError(error) {
            AppLog.recordingError(
                "录屏失败（权限相关）：domain=\((error as NSError).domain) code=\((error as NSError).code)"
            )
            showScreenCapturePermissionAlert(nativeRequestAccepted: false)
        } else {
            showRecordingError(error)
        }
    }

    // MARK: - 录音转写流程

    @objc private func transcriptionMenuTriggered() {
        if transcriptionManager?.isActive == true {
            stopTranscriptionRecording()
        } else {
            startTranscriptionRecording()
        }
    }

    private func startTranscriptionRecording() {
        guard recorder == nil, !(transcriptionManager?.isActive ?? false), !isCapturing else { return }
        closeOverlays()

        // 首次使用且模型缺失时，先经体积确认再后台下载；下载与录音并行，不阻塞。
        ModelPreloader.shared.prepareOnFirstUse()

        let manager = RecordingTranscriptionManager()
        configureTranscriptionManager(manager)
        manager.start()
        AppLog.recording("开始录音转写")
    }

    @objc private func viewRecordingTranscript(_ notification: Notification) {
        guard let audioURL = notification.object as? URL else { return }
        if let manager = transcriptionManager,
           manager.audioURL?.standardizedFileURL == audioURL.standardizedFileURL,
           manager.state == .transcribing {
            let window = transcriptionResultWindow ?? RecordingTranscriptionResultWindow()
            transcriptionResultWindow = window
            window.presentTranscribing(audioURL: audioURL, duration: manager.elapsed)
            if let partial = manager.latestPartialResult { window.updatePartial(result: partial) }
            window.updateProgress(manager.progress)
            return
        }
        if let saved = RecordingTranscriptStore.load(for: audioURL), saved.isComplete {
            if let window = savedTranscriptWindows[audioURL] {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            } else {
                let window = RecordingTranscriptionResultWindow()
                savedTranscriptWindows[audioURL] = window
                window.present(result: saved.result)
            }
            return
        }
        guard recorder == nil, !(transcriptionManager?.isActive ?? false), !isCapturing else {
            let alert = NSAlert()
            alert.messageText = "当前任务完成后可开始转写"
            alert.informativeText = "正在录制、截图或处理另一份录音，请稍后再次点击“查看转写”。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }

        closeOverlays()
        // 首次使用且模型缺失时，先经体积确认再后台下载。
        ModelPreloader.shared.prepareOnFirstUse()

        let manager = RecordingTranscriptionManager()
        configureTranscriptionManager(manager)
        manager.transcribeSavedRecording(at: audioURL)

        if manager.state == .transcribing {
            let window = transcriptionResultWindow ?? RecordingTranscriptionResultWindow()
            transcriptionResultWindow = window
            window.presentTranscribing(audioURL: audioURL, duration: manager.elapsed)
        }
    }

    private func configureTranscriptionManager(_ manager: RecordingTranscriptionManager) {
        transcriptionManager = manager
        manager.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .preparing:
                self.transcriptionMenuItem?.title = "准备录音转写..."
            case .recording:
                self.transcriptionMenuItem?.title = "结束录音转写"
                self.showTranscriptionControlPanelIfNeeded()
            case .paused:
                self.transcriptionMenuItem?.title = "继续录音转写"
                self.transcriptionControlPanel?.setPaused(true)
            case .transcribing:
                self.transcriptionMenuItem?.title = "转写处理中..."
                self.transcriptionControlPanel?.finish()
                self.transcriptionControlPanel = nil
            case .idle:
                self.transcriptionMenuItem?.title = "开始录音转写"
            }
        }
        manager.onElapsedChange = { [weak self] elapsed in
            self?.transcriptionControlPanel?.setElapsed(elapsed)
        }
        manager.onMeterChange = { [weak self] meter in
            self?.transcriptionControlPanel?.setMeter(meter)
        }
        manager.onPartialResult = { [weak self] result in
            guard let self else { return }
            let window = self.transcriptionResultWindow ?? RecordingTranscriptionResultWindow()
            self.transcriptionResultWindow = window
            window.updatePartial(result: result)
            if let progress = self.transcriptionManager?.progress { window.updateProgress(progress) }
        }
        manager.onProgress = { [weak self] progress in
            self?.transcriptionResultWindow?.updateProgress(progress)
        }
        manager.onResult = { [weak self, weak manager] result in
            guard let self else { return }
            self.transcriptionControlPanel?.finish()
            self.transcriptionControlPanel = nil
            self.transcriptionMenuItem?.title = "开始录音转写"
            let audioURL = manager?.audioURL
            self.transcriptionManager = nil
            self.showTranscriptionResult(result, audioURL: audioURL)
        }
    }

    private func showTranscriptionControlPanelIfNeeded() {
        guard transcriptionControlPanel == nil else {
            transcriptionControlPanel?.setPaused(false)
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.main
                ?? NSScreen.screens.first else { return }
        let panel = RecordingTranscriptionControlPanel(screen: screen)
        panel.onPause = { [weak self] in
            self?.transcriptionManager?.togglePause()
        }
        panel.onStop = { [weak self] in
            self?.stopTranscriptionRecording()
        }
        transcriptionControlPanel = panel
        panel.show()
    }

    private func stopTranscriptionRecording() {
        transcriptionControlPanel?.finish()
        transcriptionControlPanel = nil
        guard let manager = transcriptionManager,
              manager.state == .recording || manager.state == .paused else { return }
        manager.stop()
        if manager.state == .transcribing, let audioURL = manager.audioURL {
            let window = transcriptionResultWindow ?? RecordingTranscriptionResultWindow()
            transcriptionResultWindow = window
            window.presentTranscribing(audioURL: audioURL, duration: manager.elapsed)
        }
        AppLog.recording("录音结束，后台转写中")
    }

    private func showTranscriptionResult(
        _ result: Result<RecordingTranscriptionResult, Error>,
        audioURL: URL?
    ) {
        let window = transcriptionResultWindow ?? RecordingTranscriptionResultWindow()
        transcriptionResultWindow = window
        switch result {
        case .success(let transcription):
            window.present(result: transcription)
            AppLog.recording("录音转写完成: \(transcription.segments.count) 个时间片段")
        case .failure(let error):
            window.present(error: error, audioURL: audioURL)
            AppLog.recordingError("录音转写失败: \(error.localizedDescription)")
        }
    }

    private func captureAndCopy(
        image: CGImage,
        rect: NSRect,
        logicalSize: NSSize,
        cornerRadius: CGFloat,
        hasShadow: Bool
    ) {
        guard let cropped = styledSelection(
            image: image,
            rect: rect,
            logicalSize: logicalSize,
            cornerRadius: cornerRadius,
            hasShadow: hasShadow
        ) else {
            AppLog.error("裁剪失败: rect=\(rect)")
            closeOverlays()
            return
        }
        AppLog.capture("裁剪完成: \(Int(rect.width))x\(Int(rect.height)), 已复制到剪贴板")
        ClipboardManager.copyImage(cropped)
        closeOverlays()
    }

    private func captureAndSave(
        image: CGImage,
        rect: NSRect,
        logicalSize: NSSize,
        cornerRadius: CGFloat,
        hasShadow: Bool
    ) {
        guard let cropped = styledSelection(
            image: image,
            rect: rect,
            logicalSize: logicalSize,
            cornerRadius: cornerRadius,
            hasShadow: hasShadow
        ) else {
            AppLog.error("保存失败: 裁剪出错")
            return
        }
        saveRenderedImage(cropped, suggestedName: "截图", closeAfterSave: true)
    }

    private func pinSelection(
        image: CGImage,
        rect: NSRect,
        logicalSize: NSSize,
        cornerRadius: CGFloat,
        hasShadow: Bool
    ) {
        guard let cropped = styledSelection(
            image: image,
            rect: rect,
            logicalSize: logicalSize,
            cornerRadius: cornerRadius,
            hasShadow: hasShadow
        ) else {
            AppLog.error("贴图失败: 裁剪出错")
            return
        }

        let pinWindow = PinWindow(image: cropped)
        pinWindow.onClose = { [weak self, weak pinWindow] in
            guard let self, let pinWindow else { return }
            self.pinWindows.removeAll { $0 === pinWindow }
        }
        pinWindow.onEdit = { [weak self] window, image in
            self?.editPin(window: window, image: image)
        }
        pinWindows.append(pinWindow)
        closeOverlays()
        pinWindow.showNearMouse()
        AppLog.ui("已创建贴图: \(cropped.width)x\(cropped.height)")
    }

    private func editPin(window: PinWindow, image: CGImage) {
        let editor = PinEditorWindow(image: image)
        editor.onDone = { [weak window] updatedImage in
            window?.updateImage(updatedImage)
            AppLog.ui("贴图重新标注完成")
        }
        editor.onClose = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.pinEditorWindows.removeAll { $0 === editor }
            if self.pinEditorWindows.isEmpty, self.overlayPanels.isEmpty {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        pinEditorWindows.append(editor)
        NSApp.setActivationPolicy(.regular)
        editor.showEditor()
    }

    private func styledSelection(
        image: CGImage,
        rect: NSRect,
        logicalSize: NSSize,
        cornerRadius: CGFloat,
        hasShadow: Bool
    ) -> CGImage? {
        guard let cropped = ClipboardManager.cropImage(image, to: rect, logicalSize: logicalSize) else { return nil }
        let scale = CGFloat(cropped.width) / max(1, rect.width)
        return ImageProcessing.applyStyle(
            to: cropped,
            cornerRadiusPoints: cornerRadius,
            hasShadow: hasShadow,
            scale: scale
        )
    }

    private func saveRenderedImage(
        _ image: CGImage,
        suggestedName: String,
        closeAfterSave: Bool = false
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "\(suggestedName)_\(Int(Date().timeIntervalSince1970)).png"
        // 截图遮罩使用 shielding level，保存面板必须高于遮罩，否则看起来像“点击无反应”。
        panel.level = NSWindow.Level(Int(CGShieldingWindowLevel()) + 1)
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            ClipboardManager.saveImage(image, to: url)
            AppLog.info("保存成功: \(url.lastPathComponent)")
            if closeAfterSave { self?.closeOverlays() }
        }
    }

    private func closeOverlays() {
        AppLog.ui("关闭遮罩")
        for panel in overlayPanels {
            panel.orderOut(nil)
        }
        overlayPanels.removeAll()
        isCapturing = false
        CaptureEngine.shared.clearCache()
        DispatchQueue.main.async { [weak self] in
            self?.prepareOverlayPanelsIfNeeded()
        }
    }
}
