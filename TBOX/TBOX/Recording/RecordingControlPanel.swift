import Cocoa

final class RecordingControlPanel: NSPanel {
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?

    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let pauseButton = NSButton()
    private var timer: Timer?
    private var elapsed: TimeInterval = 0
    private var lastTick = Date()
    private var isPaused = false

    init(screen: NSScreen) {
        let size = NSSize(width: 224, height: 48)
        let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 12)
        super.init(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        contentView = effect

        let dot = NSView(frame: NSRect(x: 16, y: 18, width: 12, height: 12))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 6
        effect.addSubview(dot)

        timeLabel.frame = NSRect(x: 38, y: 14, width: 56, height: 20)
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        timeLabel.textColor = .white
        effect.addSubview(timeLabel)

        configureButton(pauseButton, icon: "pause.fill", tooltip: "暂停", frame: NSRect(x: 112, y: 8, width: 36, height: 32), action: #selector(pauseClicked))
        effect.addSubview(pauseButton)

        let stopButton = NSButton()
        configureButton(stopButton, icon: "stop.fill", tooltip: "停止并保存", frame: NSRect(x: 164, y: 8, width: 44, height: 32), action: #selector(stopClicked))
        stopButton.contentTintColor = .systemRed
        effect.addSubview(stopButton)
    }

    func show() {
        orderFrontRegardless()
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    func setPaused(_ paused: Bool) {
        if isPaused && !paused { lastTick = Date() }
        isPaused = paused
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: paused ? "继续" : "暂停")
        pauseButton.toolTip = paused ? "继续" : "暂停"
    }

    func finish() {
        timer?.invalidate()
        timer = nil
        orderOut(nil)
    }

    @objc private func pauseClicked() { onPause?() }
    @objc private func stopClicked() { onStop?() }

    private func tick() {
        let now = Date()
        if !isPaused { elapsed += now.timeIntervalSince(lastTick) }
        lastTick = now
        let seconds = Int(elapsed)
        timeLabel.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func configureButton(_ button: NSButton, icon: String, tooltip: String, frame: NSRect, action: Selector) {
        button.frame = frame
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: tooltip)
        button.contentTintColor = .white
        button.toolTip = tooltip
        button.target = self
        button.action = action
    }
}

/// 只负责在录制区域外沿显示红色虚线；ScreenRecorder 会排除本进程，所以不会录进视频。
final class RecordingRegionWindow: NSWindow {
    init(frame: NSRect) {
        super.init(contentRect: frame.insetBy(dx: -2, dy: -2), styleMask: [.borderless], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        isReleasedWhenClosed = false
        contentView = RecordingBorderView(frame: NSRect(origin: .zero, size: self.frame.size))
    }
}

private final class RecordingBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.setLineDash([7, 5], count: 2, phase: 0)
        path.stroke()
    }
}
