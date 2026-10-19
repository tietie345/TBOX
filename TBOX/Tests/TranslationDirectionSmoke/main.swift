import Foundation

func direction(for text: String) -> String {
    var chineseCount = 0
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            chineseCount += 1
        default:
            continue
        }
    }
    return chineseCount > 0 ? "zh-en" : "en-zh"
}

precondition(direction(for: "你好，这是一个测试。") == "zh-en")
precondition(direction(for: "Hello, this is a test.") == "en-zh")
precondition(direction(for: "macOS 截图工具") == "zh-en")
precondition(direction(for: "翻译 API") == "zh-en")
precondition(direction(for: "12345") == "en-zh")
print("Translation direction smoke tests passed")
