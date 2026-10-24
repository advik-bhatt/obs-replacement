import Foundation

/// Things a hotkey, a MIDI message or a remote-control request can trigger.
public enum ControlAction: Codable, Equatable, Hashable {
    case startStopStreaming
    case startStopRecording
    case pauseResumeRecording
    case saveReplay
    case toggleStudioMode
    case transition
    case switchToScene(UUID)
    case setPreviewScene(UUID)
    case toggleMute(UUID)
    case pushToMute(UUID)
    case pushToTalk(UUID)
    case toggleSceneItem(sceneID: UUID, itemID: UUID)
    case setVolume(UUID)   // MIDI only: continuous controller drives a fader
    case toggleVirtualCamera

    public var label: String {
        switch self {
        case .startStopStreaming: return "Start/Stop Streaming"
        case .startStopRecording: return "Start/Stop Recording"
        case .pauseResumeRecording: return "Pause/Resume Recording"
        case .saveReplay: return "Save Replay"
        case .toggleStudioMode: return "Toggle Studio Mode"
        case .transition: return "Transition (Studio Mode)"
        case .switchToScene: return "Switch to Scene"
        case .setPreviewScene: return "Set Preview Scene"
        case .toggleMute: return "Mute/Unmute"
        case .pushToMute: return "Push-to-Mute"
        case .pushToTalk: return "Push-to-Talk"
        case .toggleSceneItem: return "Show/Hide Item"
        case .setVolume: return "Set Volume"
        case .toggleVirtualCamera: return "Start/Stop Virtual Camera"
        }
    }

    /// Actions that mean something without any scene or source context.
    public static let global: [ControlAction] = [
        .startStopStreaming, .startStopRecording, .pauseResumeRecording, .saveReplay,
        .toggleStudioMode, .transition, .toggleVirtualCamera,
    ]
}

/// Modifier flags as Carbon expects them (so the app can hand them straight to
/// RegisterEventHotKey). Values match Carbon's cmdKey/shiftKey/optionKey/controlKey.
public struct KeyModifiers: OptionSet, Codable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 8)
    public static let shift = KeyModifiers(rawValue: 1 << 9)
    public static let option = KeyModifiers(rawValue: 1 << 11)
    public static let control = KeyModifiers(rawValue: 1 << 12)

    public var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// A key chord. `keyCode` is the macOS virtual key code (kVK_*).
public struct KeyCombo: Codable, Equatable, Hashable {
    public var keyCode: UInt32
    public var modifiers: KeyModifiers

    public init(keyCode: UInt32, modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var displayString: String {
        modifiers.symbols + (KeyCombo.keyNames[keyCode] ?? "Key \(keyCode)")
    }

    /// Virtual key codes for the keys a streamer binds. Letters and digits use the
    /// ANSI layout codes, which is what Carbon reports on every Mac keyboard layout
    /// for these positions.
    public static let keyNames: [UInt32: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H",
        0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P",
        0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7",
        0x1C: "8", 0x19: "9",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7",
        0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14",
        0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
        0x31: "Space", 0x24: "Return", 0x30: "Tab", 0x33: "Delete", 0x35: "Escape",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x73: "Home", 0x77: "End", 0x74: "Page Up", 0x79: "Page Down",
        0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]", 0x2A: "\\", 0x29: ";", 0x27: "'",
        0x2B: ",", 0x2F: ".", 0x2C: "/", 0x32: "`",
        0x52: "Keypad 0", 0x53: "Keypad 1", 0x54: "Keypad 2", 0x55: "Keypad 3", 0x56: "Keypad 4",
        0x57: "Keypad 5", 0x58: "Keypad 6", 0x59: "Keypad 7", 0x5B: "Keypad 8", 0x5C: "Keypad 9",
    ]

    public static func keyCode(named name: String) -> UInt32? {
        keyNames.first { $0.value.lowercased() == name.lowercased() }?.key
    }
}

public struct HotkeyBinding: Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var action: ControlAction
    public var combo: KeyCombo

    public init(id: UUID = UUID(), action: ControlAction, combo: KeyCombo) {
        self.id = id
        self.action = action
        self.combo = combo
    }
}

public struct HotkeyBindings: Codable, Equatable, Hashable {
    public var bindings: [HotkeyBinding]

    public init(bindings: [HotkeyBinding] = []) { self.bindings = bindings }

    /// Sensible defaults that do not collide with common macOS shortcuts.
    public static let defaults = HotkeyBindings(bindings: [
        HotkeyBinding(action: .startStopRecording, combo: KeyCombo(keyCode: 0x0F, modifiers: [.command, .shift, .option])), // ⌘⇧⌥R
        HotkeyBinding(action: .startStopStreaming, combo: KeyCombo(keyCode: 0x01, modifiers: [.command, .shift, .option])), // ⌘⇧⌥S
        HotkeyBinding(action: .saveReplay, combo: KeyCombo(keyCode: 0x7A, modifiers: [.command, .shift, .option])),          // ⌘⇧⌥F1
        HotkeyBinding(action: .transition, combo: KeyCombo(keyCode: 0x11, modifiers: [.command, .shift, .option])),          // ⌘⇧⌥T
    ])

    public func binding(for action: ControlAction) -> HotkeyBinding? {
        bindings.first { $0.action == action }
    }

    public func actions(for combo: KeyCombo) -> [ControlAction] {
        bindings.filter { $0.combo == combo }.map { $0.action }
    }

    public mutating func set(_ combo: KeyCombo?, for action: ControlAction) {
        bindings.removeAll { $0.action == action }
        if let combo { bindings.append(HotkeyBinding(action: action, combo: combo)) }
    }

    /// Other actions already bound to this combo.
    public func conflicts(for combo: KeyCombo, excluding action: ControlAction) -> [ControlAction] {
        bindings.filter { $0.combo == combo && $0.action != action }.map { $0.action }
    }
}

// MARK: - MIDI

public enum MIDIMessageKind: Codable, Equatable, Hashable {
    case note(UInt8)
    case controlChange(UInt8)
    case programChange(UInt8)

    public var label: String {
        switch self {
        case .note(let n): return "Note \(n) (\(MIDIMessageKind.noteName(n)))"
        case .controlChange(let c): return "CC \(c)"
        case .programChange(let p): return "Program \(p)"
        }
    }

    public static func noteName(_ n: UInt8) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[Int(n) % 12])\(Int(n) / 12 - 1)"
    }
}

public enum MIDITriggerMode: String, Codable, CaseIterable, Hashable {
    /// Fire on note-on / CC value >= 64.
    case trigger
    /// Note on = press, note off = release (push-to-talk etc).
    case momentary
    /// CC 0...127 maps to the fader.
    case continuous
}

public struct MIDIBinding: Codable, Equatable, Hashable, Identifiable {
    public var id: UUID
    /// Source endpoint name; nil = any device.
    public var deviceName: String?
    /// 0-based MIDI channel; nil = any.
    public var channel: UInt8?
    public var message: MIDIMessageKind
    public var mode: MIDITriggerMode
    public var action: ControlAction

    public init(id: UUID = UUID(), deviceName: String? = nil, channel: UInt8? = nil,
                message: MIDIMessageKind, mode: MIDITriggerMode = .trigger, action: ControlAction) {
        self.id = id
        self.deviceName = deviceName
        self.channel = channel
        self.message = message
        self.mode = mode
        self.action = action
    }

    public func matches(deviceName: String, channel: UInt8, message: MIDIMessageKind) -> Bool {
        if let d = self.deviceName, d != deviceName { return false }
        if let c = self.channel, c != channel { return false }
        return self.message == message
    }
}

/// Parses raw MIDI 1.0 bytes into the subset of messages the bindings understand.
public struct MIDIParser {
    public struct Event: Equatable {
        public var channel: UInt8
        public var kind: MIDIMessageKind
        /// Note velocity, CC value or program number.
        public var value: UInt8
        public var isRelease: Bool
    }

    public static func parse(_ bytes: [UInt8]) -> [Event] {
        var events: [Event] = []
        var i = 0
        while i < bytes.count {
            let status = bytes[i]
            guard status & 0x80 != 0 else { i += 1; continue }
            let type = status & 0xF0
            let channel = status & 0x0F
            switch type {
            case 0x90, 0x80:
                guard i + 2 < bytes.count else { return events }
                let note = bytes[i + 1] & 0x7F, vel = bytes[i + 2] & 0x7F
                let release = type == 0x80 || vel == 0
                events.append(Event(channel: channel, kind: .note(note), value: vel, isRelease: release))
                i += 3
            case 0xB0:
                guard i + 2 < bytes.count else { return events }
                events.append(Event(channel: channel, kind: .controlChange(bytes[i + 1] & 0x7F), value: bytes[i + 2] & 0x7F, isRelease: false))
                i += 3
            case 0xC0:
                guard i + 1 < bytes.count else { return events }
                events.append(Event(channel: channel, kind: .programChange(bytes[i + 1] & 0x7F), value: bytes[i + 1] & 0x7F, isRelease: false))
                i += 2
            case 0xA0, 0xE0:
                i += 3
            case 0xD0:
                i += 2
            case 0xF0:
                // System messages: skip SysEx until F7, others are 1-3 bytes; be lenient.
                if status == 0xF0 {
                    while i < bytes.count && bytes[i] != 0xF7 { i += 1 }
                    i += 1
                } else if status == 0xF1 || status == 0xF3 {
                    i += 2
                } else if status == 0xF2 {
                    i += 3
                } else {
                    i += 1
                }
            default:
                i += 1
            }
        }
        return events
    }
}
