import Carbon
import Foundation
import UpstageCore

/// System-wide hotkeys through Carbon's RegisterEventHotKey, which works
/// without Accessibility permission and fires even when another app is frontmost.
final class HotkeyManager {
    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: (ref: EventHotKeyRef, action: ControlAction)] = [:]
    private var nextID: UInt32 = 1
    /// `pressed` is true on key down, false on key up (for push-to-talk / push-to-mute).
    var onAction: ((ControlAction, _ pressed: Bool) -> Void)?
    private static let signature: OSType = 0x55505354 // 'UPST'

    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotkeyEventHandler, 2, &types, selfPtr, &handlerRef)
    }

    deinit {
        unregisterAll()
        if let h = handlerRef { RemoveEventHandler(h) }
    }

    func apply(_ bindings: HotkeyBindings) {
        unregisterAll()
        for b in bindings.bindings {
            register(b.combo, action: b.action)
        }
    }

    private func register(_ combo: KeyCombo, action: ControlAction) {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers.rawValue, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            registrations[id] = (ref, action)
        } else {
            NSLog("Hotkey registration failed for \(combo.displayString): \(status)")
        }
    }

    private func unregisterAll() {
        for (_, r) in registrations { UnregisterEventHotKey(r.ref) }
        registrations.removeAll()
    }

    fileprivate func handle(id: UInt32, pressed: Bool) {
        guard let r = registrations[id] else { return }
        onAction?(r.action, pressed)
    }
}

private func hotkeyEventHandler(_ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    DispatchQueue.main.async { manager.handle(id: hotKeyID.id, pressed: pressed) }
    return noErr
}
