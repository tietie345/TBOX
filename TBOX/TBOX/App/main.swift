import Cocoa
import AVFoundation

/// End-to-end acceptance entry point for the same local engine used by the UI.
/// It never opens a window or requests permissions, and it never uploads audio.
/// The successful result is persisted through the production transcript store.
private func runTranscriptionDiagnostic(audioPath: String) -> Never {
    let audioURL = URL(fileURLWithPath: audioPath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: audioURL.path),
          let audioFile = try? AVAudioFile(forReading: audioURL),
          audioFile.length > 0,
          audioFile.processingFormat.sampleRate > 0 else {
        fputs("转写验收失败：录音文件不存在或没有有效音频帧\n", stderr)
        exit(2)
    }

    let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
    Task {
        do {
            // 与 UI 相同的完整管线：转写与说话人识别并行，再对齐、聚合、整理。
            async let speakerTurns = RecordingTranscriptionManager.diarizeSpeakers(
                url: audioURL,
                duration: duration
            )
            let output = try await HighQualityTranscriptionEngine.transcribe(
                audioURL: audioURL,
                duration: duration
            ) { progress in
                fputs("[TBOX transcription acceptance] \(progress.message)\n", stderr)
            }
            let turns = await speakerTurns
            let result = RecordingTranscriptionManager.assembleTranscript(
                recognized: output,
                speakerTurns: turns,
                url: audioURL,
                duration: duration
            )
            try RecordingTranscriptStore.save(result, completedChunks: 1, isComplete: true)
            print(
                "转写验收通过：engine=whisperKit, language=\(output.language), "
                    + "duration=\(String(format: "%.2f", duration))s, "
                    + "characters=\(result.text.count), segments=\(result.segments.count)"
            )
            exit(0)
        } catch {
            fputs("转写验收失败：\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    dispatchMain()
}

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--transcribe-file" {
    runTranscriptionDiagnostic(audioPath: arguments[2])
}

let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
