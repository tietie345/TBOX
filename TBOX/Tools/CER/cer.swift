// CER（字错率）计算器：比较人工校对基准文本与 TBOX 转写缓存中的识别文本。
//
// 用法：
//   cer.swift <reference.txt> <audio.transcript.json>
//
// 参考文本为 UTF-8 纯文本；转写结果读取 TBOX 的 *.transcript.json 缓存
// （取 result.text）。为抵消中英文标点与大小写差异，比较前对两侧统一归一化：
// 去空白、去标点、英文小写，保留汉字与字母数字。
// 输出：单行浮点数（0~1，1 表示 100% 字错率），便于脚本解析。
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("cer: " + message + "\n").utf8))
    exit(2)
}

private struct TranscriptSnapshot: Decodable {
    struct Body: Decodable { let text: String }
    let result: Body
}

/// 归一化：去空白与标点，英文转小写，只保留汉字、字母与数字。
private func normalize(_ text: String) -> [Character] {
    text.lowercased().filter { character in
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: // CJK
                return true
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: // 0-9 A-Z a-z
                return true
            default:
                return false
            }
        }
    }
}

/// 字符级 Levenshtein 距离，滚动数组降低内存。
private func editDistance(_ reference: [Character], _ hypothesis: [Character]) -> Int {
    if reference.isEmpty { return hypothesis.count }
    if hypothesis.isEmpty { return reference.count }
    var previous = Array(0...hypothesis.count)
    var current = [Int](repeating: 0, count: hypothesis.count + 1)
    for i in 1...reference.count {
        current[0] = i
        for j in 1...hypothesis.count {
            let substitution = previous[j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1)
            current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
        }
        swap(&previous, &current)
    }
    return previous[hypothesis.count]
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fail("用法: cer.swift <reference.txt> <audio.transcript.json>")
}

let referenceURL = URL(fileURLWithPath: arguments[1])
let transcriptURL = URL(fileURLWithPath: arguments[2])
guard let referenceText = try? String(contentsOf: referenceURL, encoding: .utf8) else {
    fail("无法读取参考文本: \(referenceURL.path)")
}
guard let data = try? Data(contentsOf: transcriptURL) else {
    fail("无法读取转写缓存: \(transcriptURL.path)")
}
guard let snapshot = try? JSONDecoder().decode(TranscriptSnapshot.self, from: data) else {
    fail("转写缓存格式无法解析: \(transcriptURL.path)")
}

let reference = normalize(referenceText)
let hypothesis = normalize(snapshot.result.text)
guard !reference.isEmpty else {
    fail("参考文本归一化后为空: \(referenceURL.path)")
}

let distance = editDistance(reference, hypothesis)
let cer = Double(distance) / Double(reference.count)
print(String(format: "%.6f", cer))
