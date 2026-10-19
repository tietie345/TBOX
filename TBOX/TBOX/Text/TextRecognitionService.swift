import Cocoa
import Vision

enum TextRecognitionError: LocalizedError {
    case noText

    var errorDescription: String? {
        switch self {
        case .noText:
            return "未在框选区域识别到文字"
        }
    }
}

final class TextRecognitionService {
    static let shared = TextRecognitionService()

    private let queue = DispatchQueue(label: "com.local.TBOX.ocr", qos: .userInitiated)

    func recognizeText(in image: CGImage, completion: @escaping (Result<String, Error>) -> Void) {
        queue.async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            // Vision 的可用语言随系统版本和设备变化，不能把不支持的语言直接塞给请求。
            let preferredLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
            if let supported = try? request.supportedRecognitionLanguages() {
                let availablePreferred = preferredLanguages.filter(supported.contains)
                if !availablePreferred.isEmpty {
                    request.recognitionLanguages = availablePreferred
                }
            }

            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                let text = (request.results ?? [])
                    .sorted {
                        let verticalDistance = abs($0.boundingBox.midY - $1.boundingBox.midY)
                        if verticalDistance > 0.025 {
                            return $0.boundingBox.midY > $1.boundingBox.midY
                        }
                        return $0.boundingBox.minX < $1.boundingBox.minX
                    }
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                DispatchQueue.main.async {
                    if text.isEmpty {
                        completion(.failure(TextRecognitionError.noText))
                    } else {
                        completion(.success(text))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
}
