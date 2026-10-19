import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TBOX-TranscriptTest-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let audioURL = directory.appendingPathComponent("录音.m4a")
// Deliberately not playable: a completed result must bypass audio decoding and Speech.
try Data("audio fixture".utf8).write(to: audioURL)
let result = RecordingTranscriptionResult(
    audioURL: audioURL, duration: 90, text: "第一段。第二段。",
    segments: [RecordingTranscriptionSegment(start: 0, end: 45, text: "第一段。", speakerName: "我")]
)
require(RecordingTranscriptStore.load(for: audioURL) == nil, "新录音不应有缓存")
try RecordingTranscriptStore.save(result, completedChunks: 1, isComplete: false)
let checkpoint = RecordingTranscriptStore.load(for: audioURL)
require(checkpoint?.completedChunks == 1 && checkpoint?.isComplete == false, "分段进度未正确保存")
require(checkpoint?.result.segments.first?.end == 45, "恢复进度丢失时间戳")

try RecordingTranscriptStore.save(result, completedChunks: 2, isComplete: true)
let manager = RecordingTranscriptionManager()
var completed = false
manager.onResult = { outcome in
    guard case .success(let loaded) = outcome else { fatalError("已完成转写未直接读取缓存") }
    require(loaded.text == result.text, "读取的转写文本不一致")
    completed = true
}
manager.transcribeSavedRecording(at: audioURL)
let deadline = Date().addingTimeInterval(2)
while !completed && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
}
require(completed && manager.state == .idle, "缓存读取不应启动识别或等待授权")

try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: audioURL.path)
require(RecordingTranscriptStore.load(for: audioURL) == nil, "已修改音频不能复用旧转写")
try RecordingTranscriptStore.save(result, completedChunks: 2, isComplete: true)
try Data("damaged json".utf8).write(to: RecordingTranscriptStore.url(for: audioURL))
require(RecordingTranscriptStore.load(for: audioURL) == nil, "损坏的缓存应安全回退")
try FileManager.default.removeItem(at: audioURL)
require(RecordingTranscriptStore.load(for: audioURL) == nil, "已删除音频不能打开旧缓存")
print("Transcript persistence smoke tests passed")
