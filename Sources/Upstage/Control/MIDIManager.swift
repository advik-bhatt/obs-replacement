import CoreMIDI
import Foundation
import UpstageCore

/// Listens to every MIDI source on the system and maps notes/CCs to actions.
/// Also drives "learn" mode: the last event seen is exposed for the UI.
final class MIDIManager {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: [MIDIEndpointRef: String] = [:]
    private let lock = NSLock()
    private(set) var bindings: [MIDIBinding] = []
    private(set) var sourceNames: [String] = []
    /// (device, channel, message, value, isRelease)
    var onEvent: ((String, UInt8, MIDIMessageKind, UInt8, Bool) -> Void)?
    var onAction: ((ControlAction, _ pressed: Bool, _ value: Double?) -> Void)?
    private(set) var isAvailable = false

    init() {
        let st = MIDIClientCreateWithBlock("Upstage" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async { self?.connectAllSources() }
        }
        guard st == noErr else { return }
        let pst = MIDIInputPortCreateWithBlock(client, "Upstage In" as CFString, &port) { [weak self] packetList, srcRef in
            self?.handle(packetList, srcRef: srcRef)
        }
        guard pst == noErr else { return }
        isAvailable = true
        connectAllSources()
    }

    deinit {
        if port != 0 { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
    }

    func apply(_ bindings: [MIDIBinding]) {
        lock.lock()
        self.bindings = bindings
        lock.unlock()
    }

    private func connectAllSources() {
        guard isAvailable else { return }
        var names: [String] = []
        let n = MIDIGetNumberOfSources()
        var seen = Set<MIDIEndpointRef>()
        lock.lock()
        var current = connected
        lock.unlock()
        for i in 0..<n {
            let src = MIDIGetSource(i)
            seen.insert(src)
            let name = MIDIManager.name(of: src)
            names.append(name)
            if current[src] == nil {
                let refCon = UnsafeMutableRawPointer(bitPattern: Int(src))
                if MIDIPortConnectSource(port, src, refCon) == noErr { current[src] = name }
            }
        }
        for (src, _) in current where !seen.contains(src) {
            MIDIPortDisconnectSource(port, src)
            current.removeValue(forKey: src)
        }
        lock.lock()
        connected = current
        lock.unlock()
        sourceNames = names
    }

    static func name(of endpoint: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &cf) == noErr, let s = cf?.takeRetainedValue() {
            return s as String
        }
        return "MIDI \(endpoint)"
    }

    private func handle(_ packetList: UnsafePointer<MIDIPacketList>, srcRef: UnsafeMutableRawPointer?) {
        let endpoint = MIDIEndpointRef(UInt(bitPattern: srcRef))
        lock.lock()
        let device = connected[endpoint] ?? "MIDI"
        lock.unlock()
        var bytes: [UInt8] = []
        // Walk the packets in place: MIDIPacket is variable length, so copying
        // one onto the stack and calling MIDIPacketNext on the copy reads garbage.
        guard let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data),
              let firstOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet) else { return }
        var p = UnsafeRawPointer(packetList).advanced(by: firstOffset).assumingMemoryBound(to: MIDIPacket.self)
        for _ in 0..<packetList.pointee.numPackets {
            let length = Int(p.pointee.length)
            let data = UnsafeRawPointer(p).advanced(by: dataOffset)
            bytes.append(contentsOf: UnsafeRawBufferPointer(start: data, count: length))
            p = UnsafePointer(MIDIPacketNext(p))
        }
        let events = MIDIParser.parse(bytes)
        guard !events.isEmpty else { return }
        lock.lock()
        let bindings = self.bindings
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for e in events {
                self.onEvent?(device, e.channel, e.kind, e.value, e.isRelease)
                for b in bindings where b.matches(deviceName: device, channel: e.channel, message: e.kind) {
                    switch b.mode {
                    case .trigger:
                        let on: Bool
                        switch e.kind {
                        case .note: on = !e.isRelease
                        case .controlChange: on = e.value >= 64
                        case .programChange: on = true
                        }
                        if on { self.onAction?(b.action, true, nil) }
                    case .momentary:
                        self.onAction?(b.action, !e.isRelease, nil)
                    case .continuous:
                        self.onAction?(b.action, true, Double(e.value) / 127)
                    }
                }
            }
        }
    }
}
