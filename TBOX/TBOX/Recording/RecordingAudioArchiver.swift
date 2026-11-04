import AVFoundation

/// 转写完成后把未压缩的 PCM 录音归档为 AAC（.m4a），回收磁盘占用。
///
/// 48 kHz / 16-bit 单声道 Linear PCM 约 5.76 MB/分钟（≈345 MB/小时）；
/// AAC 约 0.7 MB/分钟（≈43 MB/小时）。归档只在转写结果已经完整落盘之后进行，
/// 并且**只有导出成功并写好新缓存后**才会删除原录音；任何一步失败都保留原文件。
enum RecordingAudioArchiver {
    /// 需要归档的源扩展名（未压缩 PCM 容器）。
    private static let archivableExtensions: Set<String> = ["caf", "wav"]
    private static let archivedExtension = "m4a"

    enum ArchiveError: LocalizedError {
        case sessionUnavailable
        case noAudioTrack
        case exportFailed
        case exportCancelled

        var errorDescription: String? {
            switch self {
            case .sessionUnavailable: return "无法创建音频导出会话"
            case .noAudioTrack: return "源音频没有可导出的音轨"
            case .exportFailed: return "音频导出失败"
            case .exportCancelled: return "音频导出被取消"
            }
        }
    }

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: RecordingTranscriptionPreferences.archiveRecordingsKey) != nil else {
            return true // 默认开启
        }
        return defaults.bool(forKey: RecordingTranscriptionPreferences.archiveRecordingsKey)
    }

    /// 需要归档且成功时返回指向新音频的结果；否则原样返回，绝不丢数据。
    static func archiveIfNeeded(
        _ result: RecordingTranscriptionResult
    ) async -> RecordingTranscriptionResult {
        let source = result.audioURL
        guard isEnabled,
            archivableExtensions.contains(source.pathExtension.lowercased()),
            FileManager.default.fileExists(atPath: source.path) else { return result }

        let sourceSize = fileSize(of: source)
        let completedChunks = RecordingTranscriptStore.load(for: source)?.completedChunks ?? 1

        let destination: URL
        do {
            destination = try await exportAAC(from: source)
        } catch {
            AppLog.recordingError(
                "录音归档失败，保留原始录音 \(source.lastPathComponent): \(error.localizedDescription)"
            )
            return result
        }

        let archived = RecordingTranscriptionResult(
            audioURL: destination,
            duration: result.duration,
            text: result.text,
            segments: result.segments,
            engine: result.engine
        )
        do {
            try RecordingTranscriptStore.save(archived, completedChunks: completedChunks, isComplete: true)
        } catch {
            // 新缓存写不进去就撤销归档，保留原文件，避免出现「有音频没缓存」的中间态。
            try? FileManager.default.removeItem(at: destination)
            AppLog.recordingError("录音归档后写入缓存失败，保留原始录音: \(error.localizedDescription)")
            return result
        }

        try? FileManager.default.removeItem(at: RecordingTranscriptStore.url(for: source))
        try? FileManager.default.removeItem(at: source)

        AppLog.recording(
            "录音已归档: \(source.lastPathComponent) → \(destination.lastPathComponent), "
                + "\(formatSize(sourceSize)) → \(formatSize(fileSize(of: destination)))"
        )
        // 通知“记录”列表刷新，替换为新文件。
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .tboxRecordingSaved, object: destination)
        }
        return archived
    }

    /// AVAssetExportSession 的完成回调在系统队列执行，用受控包装满足 Sendable 检查。
    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    private static func exportAAC(from source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw ArchiveError.noAudioTrack }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
        else { throw ArchiveError.sessionUnavailable }

        let directory = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var destination = directory.appendingPathComponent(base).appendingPathExtension(archivedExtension)
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory
                .appendingPathComponent("\(base)-\(suffix)")
                .appendingPathExtension(archivedExtension)
            suffix += 1
        }

        // 先导出到隐藏临时文件，成功后再移到目标名，避免留下半截 m4a。
        let temporary = directory.appendingPathComponent(".\(base)-\(UUID().uuidString).m4a")
        session.outputURL = temporary
        session.outputFileType = .m4a
        session.shouldOptimizeForNetworkUse = false

        let box = SessionBox(session)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.session.exportAsynchronously {
                switch box.session.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: ArchiveError.exportCancelled)
                default:
                    continuation.resume(throwing: box.session.error ?? ArchiveError.exportFailed)
                }
            }
        }

        guard FileManager.default.fileExists(atPath: temporary.path) else {
            throw ArchiveError.exportFailed
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func formatSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
