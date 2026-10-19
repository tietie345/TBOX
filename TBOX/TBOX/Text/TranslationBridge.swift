import Cocoa
import NaturalLanguage
import SwiftUI
import Translation

enum TranslationDirection {
    case chineseToEnglish
    case englishToChinese

    var sourceIdentifier: String {
        switch self {
        case .chineseToEnglish: return "zh-Hans"
        case .englishToChinese: return "en"
        }
    }

    var targetIdentifier: String {
        switch self {
        case .chineseToEnglish: return "en"
        case .englishToChinese: return "zh-Hans"
        }
    }

    var displayName: String {
        switch self {
        case .chineseToEnglish: return "中文 → English"
        case .englishToChinese: return "English → 中文"
        }
    }

    static func detect(from text: String) -> TranslationDirection {
        var chineseCount = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                chineseCount += 1
            default:
                continue
            }
        }
        return chineseCount > 0 ? .chineseToEnglish : .englishToChinese
    }
}

enum TBOXTranslationError: LocalizedError {
    case unsupportedPair

    var errorDescription: String? {
        "当前系统不支持这组中英文翻译，请确认已升级到 macOS 15 或更高版本。"
    }
}

@available(macOS 15.0, *)
@MainActor
final class TranslationBridgeModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?

    private var pendingText = ""
    private var pendingDirection: TranslationDirection = .englishToChinese
    private var completion: ((Result<String, Error>) -> Void)?
    private var statusHandler: ((String) -> Void)?

    func translate(
        _ text: String,
        direction: TranslationDirection,
        status: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        pendingText = text
        pendingDirection = direction
        self.completion = completion
        statusHandler = status

        var next = TranslationSession.Configuration(
            source: Locale.Language(identifier: direction.sourceIdentifier),
            target: Locale.Language(identifier: direction.targetIdentifier)
        )
        if var current = configuration,
           current.source == next.source,
           current.target == next.target {
            current.invalidate()
            next = current
        }
        configuration = next
    }

    func perform(using session: TranslationSession) async {
        let text = pendingText
        let direction = pendingDirection
        do {
            let availability = LanguageAvailability()
            let availabilityStatus = await availability.status(
                from: Locale.Language(identifier: direction.sourceIdentifier),
                to: Locale.Language(identifier: direction.targetIdentifier)
            )
            guard availabilityStatus != .unsupported else {
                throw TBOXTranslationError.unsupportedPair
            }

            if availabilityStatus == .supported {
                statusHandler?("正在准备中英文翻译语言包，首次使用可能需要确认下载…")
                try await session.prepareTranslation()
            }

            statusHandler?("正在翻译…")
            let response = try await session.translate(text)
            guard text == pendingText else { return }
            completion?(.success(response.targetText))
            completion = nil
            statusHandler = nil
        } catch {
            guard text == pendingText else { return }
            completion?(.failure(error))
            completion = nil
            statusHandler = nil
        }
    }

    func cancelPending() {
        pendingText = ""
        completion = nil
        statusHandler = nil
    }
}

@available(macOS 15.0, *)
private struct TranslationRunnerView: View {
    @ObservedObject var model: TranslationBridgeModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(model.configuration) { session in
                await model.perform(using: session)
            }
    }
}

@available(macOS 15.0, *)
@MainActor
final class TranslationBridgeHost: NSView {
    private let model = TranslationBridgeModel()
    private let hostingView: NSHostingView<TranslationRunnerView>

    override init(frame frameRect: NSRect) {
        hostingView = NSHostingView(rootView: TranslationRunnerView(model: model))
        super.init(frame: frameRect)
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func translate(
        _ text: String,
        direction: TranslationDirection,
        status: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        model.translate(text, direction: direction, status: status, completion: completion)
    }

    func cancelPending() {
        model.cancelPending()
    }
}
