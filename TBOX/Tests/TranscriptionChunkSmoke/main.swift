import Foundation

@main
enum TranscriptionChunkSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              let duration = TimeInterval(CommandLine.arguments[2]) else {
            fputs("usage: transcription_chunk_smoke <audio-path> <duration>\n", stderr)
            exit(2)
        }

        let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let prepared = try await RecordingTranscriptionManager.exportRecognitionChunks(
            sourceURL: sourceURL,
            duration: duration,
            maximumChunkDuration: 45
        )
        defer { try? FileManager.default.removeItem(at: prepared.directory) }

        guard prepared.chunks.count == Int(ceil(duration / 45)) else {
            fatalError("分段数量异常：\(prepared.chunks.count)")
        }
        for chunk in prepared.chunks {
            let attributes = try FileManager.default.attributesOfItem(atPath: chunk.url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else { fatalError("分段文件为空：\(chunk.url.lastPathComponent)") }
            print(
                String(
                    format: "%@ start=%.1fs duration=%.1fs size=%d",
                    chunk.url.lastPathComponent,
                    chunk.start,
                    chunk.duration,
                    size
                )
            )
        }
        print("Transcription chunk export smoke tests passed")
    }
}
