import Cocoa
import Carbon

class HotkeyManager {
    private var hotKeyRefs: [EventHotKeyRef?] = []
    
    init() {
        registerHotkey()
    }
    
    func registerHotkey() {
        let signature = OSType(0x5343544C)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        InstallEventHandler(GetApplicationEventTarget(), { (_, eventRef, _) -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            switch hkID.id {
            case 1:
                NotificationCenter.default.post(name: .tboxHotkeyTriggered, object: nil)
            case 2:
                NotificationCenter.default.post(name: .tboxRecordHotkeyTriggered, object: nil)
            default:
                break
            }
            return noErr
        }, 1, &eventType, nil, nil)

        let hotkeys: [(id: UInt32, keyCode: UInt32, label: String)] = [
            (1, 0, "Ctrl+Shift+A"),  // A：截图
            (2, 15, "Ctrl+Shift+R"), // R：录屏
        ]
        for hotkey in hotkeys {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                hotkey.keyCode,
                UInt32(shiftKey | controlKey),
                EventHotKeyID(signature: signature, id: hotkey.id),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            hotKeyRefs.append(ref)
            if status == noErr {
                AppLog.info("快捷键注册成功: \(hotkey.label)")
            } else {
                AppLog.error("快捷键注册失败: \(hotkey.label), status=\(status)")
            }
        }
    }
}

extension Notification.Name {
    static let tboxHotkeyTriggered = Notification.Name("tboxHotkeyTriggered")
    static let tboxRecordHotkeyTriggered = Notification.Name("tboxRecordHotkeyTriggered")
}
