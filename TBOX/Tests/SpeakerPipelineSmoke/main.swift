import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("失败：\(message)\n", stderr)
        exit(1)
    }
}

// MARK: - 说话人对齐

let words = [
    RecordingTranscriptionSegment(start: 0.0, end: 0.5, text: "今天", speakerName: "我"),
    RecordingTranscriptionSegment(start: 0.5, end: 1.0, text: "开会", speakerName: "我"),
    RecordingTranscriptionSegment(start: 1.2, end: 2.0, text: "讨论", speakerName: "我"),
    RecordingTranscriptionSegment(start: 2.0, end: 2.8, text: "发布计划。", speakerName: "我"),
    RecordingTranscriptionSegment(start: 3.2, end: 4.0, text: "好的，", speakerName: "我"),
    RecordingTranscriptionSegment(start: 4.0, end: 5.0, text: "我先说。", speakerName: "我"),
]

// 两位说话人各发言足够时长，都应保留。
let turns = [
    SpeakerTurn(start: 0.0, end: 2.4, speakerID: 7),
    SpeakerTurn(start: 2.6, end: 5.0, speakerID: 3),
]
let annotated = TranscriptionAligner.assignSpeakers(to: words, turns: turns)
require(annotated[0].speakerID == 0, "说话人应重编号为 0，实际 \(String(describing: annotated[0].speakerID))")
require(annotated[3].speakerID == 0, "跨段重叠应归属重叠最大的说话人")
require(annotated[4].speakerID == 1, "第二位说话人应重编号为 1，实际 \(String(describing: annotated[4].speakerID))")
require(annotated[5].speakerID == 1, "同一句内说话人不应跳变")

// 空说话人结果：原样返回且不标注。
let untouched = TranscriptionAligner.assignSpeakers(to: words, turns: [])
require(untouched.allSatisfy { $0.speakerID == nil }, "无说话人时不应产生标注")

// 误分裂修剪：说话人 9 只有一句 0.5 秒（低于阈值），应被剔除。
let noisy = [
    SpeakerTurn(start: 0.0, end: 30.0, speakerID: 0),
    SpeakerTurn(start: 30.0, end: 60.0, speakerID: 1),
    SpeakerTurn(start: 61.0, end: 61.5, speakerID: 9),
]
let pruned = TranscriptionAligner.pruneShortSpeakers(in: noisy)
require(pruned.allSatisfy { $0.speakerID < 2 }, "短说话人应被剔除，实际 \(pruned.map(\.speakerID))")
require(pruned.count == 2, "误分裂段应被移除")

// 独白：只有一位说话人时按无分离处理。
let solo = [SpeakerTurn(start: 0, end: 10, speakerID: 0)]
require(TranscriptionAligner.pruneShortSpeakers(in: solo).isEmpty, "单说话人应回落为无分离")

// MARK: - 说话人感知聚合

let grouped = RecordingTranscriptionSegmenter.group(
    annotated,
    fallbackText: "",
    duration: 5
)
require(grouped.count == 2, "说话人变化处应断句，实际 \(grouped.count) 段")
require(grouped[0].speakerID != grouped[1].speakerID, "两段应属于不同说话人")
require(grouped[0].text.hasPrefix("今天"), "句段文本异常：\(grouped[0].text)")

// MARK: - 语气词清理

// 真实场景中 Whisper 幻觉语气词零星分布：12 句中 2 句（17%，低于保护阈值）。
var polishInput: [RecordingTranscriptionSegment] = [
    RecordingTranscriptionSegment(start: 0, end: 1, text: "嗯……", speakerName: "我"),
    RecordingTranscriptionSegment(start: 1, end: 2, text: "我们开始。", speakerName: "我"),
]
for index in 2...10 {
    polishInput.append(
        RecordingTranscriptionSegment(
            start: TimeInterval(index), end: TimeInterval(index) + 1,
            text: "第\(index)句话。", speakerName: "我"
        )
    )
}
polishInput.insert(
    RecordingTranscriptionSegment(start: 11, end: 12, text: "呃", speakerName: "我"),
    at: 6
)
let polished = TranscriptPolisher.polish(polishInput)
require(polished.count == 10, "纯语气词句段应被剔除，实际剩 \(polished.count) 段")
require(!polished.contains { $0.text == "嗯……" || $0.text == "呃" }, "语气词句段仍残留在 \(polished.map(\.text))")
require(polished.contains { $0.text == "我们开始。" }, "正常句段被误删")

// 语气词占比过高（例如感叹词对话）时不做剔除。
let allFillers = (0..<5).map {
    RecordingTranscriptionSegment(start: TimeInterval($0), end: TimeInterval($0) + 1, text: "嗯", speakerName: "我")
}
require(TranscriptPolisher.polish(allFillers).count == 5, "语气词占比过高时不应剔除")

// MARK: - Codable 向后兼容（旧快照没有 speakerID 字段）

let legacyJSON = """
{"start":0.5,"end":2.5,"text":"旧版本句段。","speakerName":"我"}
"""
let legacySegment = try JSONDecoder().decode(
    RecordingTranscriptionSegment.self, from: Data(legacyJSON.utf8)
)
require(legacySegment.speakerName == "我" && legacySegment.speakerID == nil, "旧快照应可解码且 speakerID 为 nil")

let modernSegment = RecordingTranscriptionSegment(
    start: 0.5, end: 2.5, text: "新版本句段。", speakerName: "说话人 1", speakerID: 0
)
let modernData = try JSONEncoder().encode(modernSegment)
let roundTrip = try JSONDecoder().decode(RecordingTranscriptionSegment.self, from: modernData)
require(roundTrip.speakerID == 0 && roundTrip.speakerName == "说话人 1", "新快照编解码应保留说话人")

// MARK: - 导出格式化

let exportSegments = [
    RecordingTranscriptionSegment(start: 62.5, end: 65.2, text: "第一句话。", speakerName: "说话人 1", speakerID: 0),
    RecordingTranscriptionSegment(start: 65.5, end: 68.0, text: "第二句话。", speakerName: "说话人 2", speakerID: 1),
]
let srt = TranscriptFormatter.format(exportSegments, as: .subtitles)
require(srt.contains("1\n00:01:02,500 --> 00:01:05,200\n说话人 1：第一句话。"), "SRT 格式异常：\n\(srt)")
require(srt.contains("2\n00:01:05,500 --> 00:01:08,000\n说话人 2：第二句话。"), "SRT 第二段格式异常：\n\(srt)")

let plain = TranscriptFormatter.format(exportSegments, as: .plainText)
require(plain == "[说话人 1] 00:01:02 第一句话。\n[说话人 2] 00:01:05 第二句话。", "纯文本格式异常：\n\(plain)")

let markdown = TranscriptFormatter.format(exportSegments, as: .markdown)
require(markdown.contains("## 说话人 1") && markdown.contains("- 00:01:02 第一句话。"), "Markdown 格式异常：\n\(markdown)")
require(markdown.contains("## 说话人 2"), "Markdown 说话人分组异常")

print("Speaker pipeline smoke tests passed")
