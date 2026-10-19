import Foundation

/// 说话人分离引擎输出的一段连续同说话人语音区间（秒）。
/// 独立于 SpeakerKit 定义，保证未链接第三方模块时管线的其余部分仍可编译。
struct SpeakerTurn: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let speakerID: Int

    var duration: TimeInterval { max(0, end - start) }

    func overlaps(_ segment: RecordingTranscriptionSegment) -> Bool {
        min(end, segment.end) - max(start, segment.start) > 0
    }
}

/// 将说话人分离结果按时间重叠对齐到转写词段上（Layer 3）。
///
/// 对齐策略与 SpeakerKit 官方 `.segment` 策略同思路：对每个词段取时间重叠
/// 最大的说话人段；无重叠的词段继承前一个词段的说话人，避免句首瞬态丢失标注。
enum TranscriptionAligner {
    /// 总发言低于该值的说话人视为噪声误分裂，并入邻近说话人。
    private static let minimumSpeakerDuration: TimeInterval = 8
    /// 总发言占比低于该比例的说话人同样视为误分裂。
    private static let minimumSpeakerFraction: Double = 0.03

    /// 给词级转写片段标注说话人。`turns` 为空时原样返回（speakerID 全部为 nil）。
    static func assignSpeakers(
        to words: [RecordingTranscriptionSegment],
        turns: [SpeakerTurn]
    ) -> [RecordingTranscriptionSegment] {
        let pruned = pruneShortSpeakers(in: turns)
        guard !pruned.isEmpty else { return words }

        var previousSpeaker: Int?
        return words.map { word in
            let speakerID = dominantSpeaker(for: word, in: pruned) ?? previousSpeaker
            previousSpeaker = speakerID
            guard let speakerID, speakerID != word.speakerID else { return word }
            return RecordingTranscriptionSegment(
                start: word.start,
                end: word.end,
                text: word.text,
                speakerName: word.speakerName,
                speakerID: speakerID
            )
        }
    }

    /// 修剪误分裂的说话人：发言过短的说话人段并入时间上紧邻的保留说话人。
    /// 剩余说话人重新编号为 0..<n，保证显示标签连续。
    static func pruneShortSpeakers(in turns: [SpeakerTurn]) -> [SpeakerTurn] {
        guard !turns.isEmpty else { return [] }

        let totalSpeech = turns.reduce(0) { $0 + $1.duration }
        guard totalSpeech > 0 else { return [] }

        let perSpeaker = Dictionary(grouping: turns, by: \.speakerID)
            .mapValues { $0.reduce(0) { $0 + $1.duration } }
        let survivors = perSpeaker.filter {
            $0.value >= minimumSpeakerDuration || Double($0.value) / totalSpeech >= minimumSpeakerFraction
        }

        // 只剩一个有效说话人时按“无分离”处理，避免独白录音出现噪音标签。
        guard survivors.count >= 2 else { return [] }

        // 按首次发言时间重编号：先开口的人是“说话人 1”，符合阅读直觉。
        let firstAppearance = Dictionary(
            turns.sorted { $0.start < $1.start }.map { turn in
                (turn.speakerID, turn.start)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let sortedSurvivors = survivors.keys.sorted {
            (firstAppearance[$0] ?? .infinity) < (firstAppearance[$1] ?? .infinity)
        }
        let remap = Dictionary(uniqueKeysWithValues: sortedSurvivors.enumerated().map { index, id in
            (id, index)
        })
        return turns.compactMap { turn in
            remap[turn.speakerID].map {
                SpeakerTurn(start: turn.start, end: turn.end, speakerID: $0)
            }
        }
    }

    /// 返回与词段时间重叠最大的说话人段 ID；重叠相同时取更早开始的段。
    private static func dominantSpeaker(
        for word: RecordingTranscriptionSegment,
        in turns: [SpeakerTurn]
    ) -> Int? {
        var best: (id: Int, overlap: TimeInterval, start: TimeInterval)?
        for turn in turns {
            let overlap = min(turn.end, word.end) - max(turn.start, word.start)
            guard overlap > 0 else { continue }
            if overlap > best?.overlap ?? 0
                || (overlap == best?.overlap && turn.start < best?.start ?? .infinity) {
                best = (turn.speakerID, overlap, turn.start)
            }
        }
        return best?.id
    }
}
