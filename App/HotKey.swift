import AppKit
import Carbon.HIToolbox

/// Minimal global hotkey via Carbon (no third-party dependency, no Accessibility permission needed).
final class HotKey {
    static let shared = HotKey()
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false
    var action: (() -> Void)?

    func register(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        unregister()
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x4C49_444C) /* 'LIDL' */, id: 1)
        RegisterEventHotKey(keyCode, Self.carbonFlags(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.shared.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }

    static func carbonFlags(_ m: NSEvent.ModifierFlags) -> UInt32 {
        var f: UInt32 = 0
        if m.contains(.command) { f |= UInt32(cmdKey) }
        if m.contains(.option) { f |= UInt32(optionKey) }
        if m.contains(.control) { f |= UInt32(controlKey) }
        if m.contains(.shift) { f |= UInt32(shiftKey) }
        return f
    }

    static func describe(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + keyName(keyCode)
    }

    private static func keyName(_ code: UInt32) -> String {
        let src = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        data.withUnsafeBytes { raw in
            _ = UCKeyTranslate(raw.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(code),
                               UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return len > 0 ? String(utf16CodeUnits: chars, count: len).uppercased() : "#\(code)"
    }
}
