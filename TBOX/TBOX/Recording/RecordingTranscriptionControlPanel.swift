import Cocoa

/// 录音转写专用的悬浮控制条。录音本身由 RecordingTranscriptionManager 驱动，
/// 这里仅负责展示状态并转发暂停/结束操作。
final class RecordingTranscriptionControlPanel: NSPanel {
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?

    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let pauseButton = NSButton()
    private let meterView = RecordingMeterView(frame: .zero)
    private var isPaused = false

    init(screen: NSScreen) {
        let size = NSSize(width: 292, height: 58)
        let margin: CGFloat = 18
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.maxX - size.width - margin,
            y: visible.maxY - size.height - margin
        )
        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.white.cgColor
        background.layer?.cornerRadius = 16
        contentView = background

        let dot = NSView(frame: NSRect(x: 18, y: 23, width: 12, height: 12))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 6
        background.addSubview(dot)

        timeLabel.frame = NSRect(x: 39, y: 18, width: 58, height: 22)
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        timeLabel.textColor = NSColor(calibratedWhite: 0.18, alpha: 1)
        background.addSubview(timeLabel)

        meterView.frame = NSRect(x: 102, y: 14, width: 74, height: 30)
        background.addSubview(meterView)

        configureButton(
            pauseButton,
            icon: "pause.fill",
            tooltip: "暂停",
            frame: NSRect(x: 190, y: 12, width: 38, height: 34),
            action: #selector(pauseClicked)
        )
        background.addSubview(pauseButton)

        let stopButton = NSButton()
        configureButton(
            stopButton,
            icon: "stop.fill",
            tooltip: "结束录音并转写",
            frame: NSRect(x: 239, y: 12, width: 38, height: 34),
            action: #selector(stopClicked)
        )
        stopButton.contentTintColor = NSColor.systemRed
        background.addSubview(stopButton)
    }

    func show() {
        orderFrontRegardless()
    }

    func setElapsed(_ elapsed: TimeInterval) {
        let seconds = max(0, Int(elapsed.rounded(.down)))
        timeLabel.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func setMeter(_ value: Float) {
        meterView.level = CGFloat(max(0, min(1, value)))
        meterView.needsDisplay = true
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        let icon = paused ? "play.fill" : "pause.fill"
        pauseButton.image = NSImage(systemSymbolName: icon, accessibilityDescription: paused ? "继续" : "暂停")
        pauseButton.toolTip = paused ? "继续" : "暂停"
        meterView.isPaused = paused
        meterView.needsDisplay = true
    }

    func finish() {
        orderOut(nil)
    }

    @objc private func pauseClicked() { onPause?() }
    @objc private func stopClicked() { onStop?() }

    private func configureButton(_ button: NSButton, icon: String, tooltip: String, frame: NSRect, action: Selector) {
        button.frame = frame
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: tooltip)
        button.image = button.image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
        button.contentTintColor = NSColor(calibratedWhite: 0.18, alpha: 1)
        button.toolTip = tooltip
        button.target = self
        button.action = action
    }
}

private final class RecordingMeterView: NSView {
    var level: CGFloat = 0
    var isPaused = false

    override func draw(_ dirtyRect: NSRect) {
        let count = 12
        let gap: CGFloat = 3
        let barWidth = max(1, (bounds.width - CGFloat(count - 1) * gap) / CGFloat(count))
        for index in 0..<count {
            let x = CGFloat(index) * (barWidth + gap)
            let phase = CGFloat(index % 4) / 4
            let height = max(3, bounds.height * (0.25 + (0.75 * level * (0.65 + phase))))
            let rect = NSRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
            let color = isPaused
                ? NSColor.systemGray.withAlphaComponent(0.45)
                : NSColor.systemRed.withAlphaComponent(0.45 + 0.45 * level)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
