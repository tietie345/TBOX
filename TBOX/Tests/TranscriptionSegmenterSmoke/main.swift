import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("失败：\(message)\n", stderr)
        exit(1)
    }
}

let tokens = [
    RecordingTranscriptionSegment(start: 0.0, end: 0.4, text: "马路上", speakerName: "我"),
    RecordingTranscriptionSegment(start: 0.4, end: 0.7, text: "有", speakerName: "我"),
    RecordingTranscriptionSegment(start: 0.7, end: 1.1, text: "一根", speakerName: "我"),
    RecordingTranscriptionSegment(start: 1.1, end: 1.5, text: "钢轨，", speakerName: "我"),
    RecordingTranscriptionSegment(start: 1.5, end: 1.9, text: "到底", speakerName: "我"),
    RecordingTranscriptionSegment(start: 1.9, end: 2.2, text: "怎么", speakerName: "我"),
    RecordingTranscriptionSegment(start: 2.2, end: 2.4, text: "不", speakerName: "我"),
    RecordingTranscriptionSegment(start: 2.4, end: 2.8, text: "跑偏", speakerName: "我"),
    RecordingTranscriptionSegment(start: 2.8, end: 3.0, text: "的？", speakerName: "我"),
    RecordingTranscriptionSegment(start: 4.2, end: 4.6, text: "这种", speakerName: "我"),
    RecordingTranscriptionSegment(start: 4.6, end: 5.0, text: "情况", speakerName: "我"),
    RecordingTranscriptionSegment(start: 6.1, end: 6.5, text: "很常见。", speakerName: "我"),
]

let grouped = RecordingTranscriptionSegmenter.group(
    tokens,
    fallbackText: "马路上有一根钢轨，到底怎么不跑偏的？这种情况很常见。",
    duration: 7
)
require(grouped.count == 3, "中文词元应聚合成 3 个自然句段，实际为 \(grouped.count)")
require(grouped[0].text == "马路上有一根钢轨，到底怎么不跑偏的？", "中文词元拼接异常：\(grouped[0].text)")
require(grouped[1].text == "这种情况", "长停顿没有断句")
require(grouped[2].text == "很常见。", "末尾句段异常")
require(grouped[1].start == 4.2, "句段时间戳没有保留")

let english = RecordingTranscriptionSegmenter.group(
    [
        RecordingTranscriptionSegment(start: 0, end: 0.3, text: "Hello", speakerName: "我"),
        RecordingTranscriptionSegment(start: 0.3, end: 0.6, text: "world.", speakerName: "我"),
    ],
    fallbackText: "Hello world.",
    duration: 1
)
require(english.first?.text == "Hello world.", "英文词元之间应保留空格")

let fallback = RecordingTranscriptionSegmenter.group(
    [],
    fallbackText: "第一句。第二句！最后一句",
    duration: 9
)
require(fallback.map(\.text) == ["第一句。", "第二句！", "最后一句"], "无时间片段时应按标点回退分句")

print("Transcription segmenter smoke tests passed")
