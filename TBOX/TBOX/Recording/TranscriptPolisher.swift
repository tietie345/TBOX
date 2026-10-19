import Foundation

/// 转写文字稿的确定性整理（Layer 4）：不依赖网络与模型，只做可回滚的规则处理。
///
/// 职责：
/// - 剔除仅由语气词组成的句段（Whisper 在静音段的常见幻觉产物）；
/// - 规范中英文混排时的多余空白。
/// LLM 语义后处理（错字修正、纪要生成）是后续可选扩展，不在本期范围。
enum TranscriptPolisher {
    /// 仅由这些语气词及其标点变体组成的句段会被剔除。
    private static let fillerTokens: Set<String> = [
        "嗯", "呃", "啊", "哦", "噢", "唔", "唉", "诶", "欸", "呀",
    ]
    private static let fillerPunctuation = CharacterSet(charactersIn: "，。！？；…, .!?~-—")

    /// 语气词句段占全文的比例超过该值时视为误判，不做剔除（保护正常的感叹词对话）。
    private static let maximumFillerRatio: Double = 0.2

    static func polish(_ segments: [RecordingTranscriptionSegment]) -> [RecordingTranscriptionSegment] {
        guard segments.count > 1 else { return segments }
        let fillerCount = segments.filter { isFillerOnly($0.text) }.count
        guard Double(fillerCount) / Double(segments.count) <= maximumFillerRatio else {
            return segments.map(normalized)
        }
        return segments
            .filter { !isFillerOnly($0.text) }
            .map(normalized)
    }

    private static func normalized(_ segment: RecordingTranscriptionSegment) -> RecordingTranscriptionSegment {
        let cleaned = segment.text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ?([，。！？；：、])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned != segment.text, !cleaned.isEmpty else { return segment }
        return RecordingTranscriptionSegment(
            start: segment.start,
            end: segment.end,
            text: cleaned,
            speakerName: segment.speakerName,
            speakerID: segment.speakerID
        )
    }

    private static func isFillerOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            fillerPunctuation.contains(scalar)
                || fillerTokens.contains(String(scalar))
        }
    }
}

/// 转写结果的导出格式化。输出纯文本，便于结果窗口的保存面板直接写文件。
enum TranscriptFormatter {
    enum Format: String, CaseIterable {
        case plainText = "txt"
        case subtitles = "srt"
        case markdown = "md"

        var displayName: String {
            switch self {
            case .plainText: return "文本 (.txt)"
            case .subtitles: return "字幕 (.srt)"
            case .markdown: return "Markdown (.md)"
            }
        }
    }

    static func format(
        _ segments: [RecordingTranscriptionSegment],
        as format: Format
    ) -> String {
        switch format {
        case .plainText: return plain(segments)
        case .subtitles: return srt(segments)
        case .markdown: return markdown(segments)
        }
    }

    /// `[说话人] 00:12 文本` 逐句布局，时间戳支持小时。
    private static func plain(_ segments: [RecordingTranscriptionSegment]) -> String {
        segments.map { segment in
            "[\(segment.speakerName)] \(timestamp(segment.start, allowHours: true)) \(segment.text)"
        }
        .joined(separator: "\n")
    }

    private static func srt(_ segments: [RecordingTranscriptionSegment]) -> String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(srtTime(segment.start)) --> \(srtTime(max(segment.start, segment.end)))\n\(segment.speakerName)：\(segment.text)\n"
        }
        .joined(separator: "\n")
    }

    private static func markdown(_ segments: [RecordingTranscriptionSegment]) -> String {
        var lines: [String] = ["# 录音转写", ""]
        var previousSpeaker: String?
        for segment in segments {
            if segment.speakerName != previousSpeaker {
                lines.append("## \(segment.speakerName)")
                previousSpeaker = segment.speakerName
            }
            lines.append("- \(timestamp(segment.start, allowHours: true)) \(segment.text)")
        }
        return lines.joined(separator: "\n")
    }

    private static func timestamp(_ time: TimeInterval, allowHours: Bool) -> String {
        let seconds = max(0, Int(time.rounded(.down)))
        if allowHours || seconds >= 3600 {
            return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static func srtTime(_ time: TimeInterval) -> String {
        let total = max(0, Int((time * 1000).rounded(.down)))
        let milliseconds = total % 1000
        let seconds = (total / 1000) % 60
        let minutes = (total / 60_000) % 60
        let hours = total / 3_600_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }
}
