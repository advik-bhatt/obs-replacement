import AudioToolbox
import CoreAudio
import Foundation

struct AudioDeviceInfo: Identifiable, Hashable {
    var id: String { uid }
    var deviceID: AudioDeviceID
    var uid: String
    var name: String
    var manufacturer: String
    var inputChannels: Int
    var outputChannels: Int
    var sampleRate: Double
    var isDefaultInput: Bool
    var isDefaultOutput: Bool
    var transport: String

    var label: String {
        var s = name
        if inputChannels > 0 { s += " (\(inputChannels) in)" }
        return s
    }
}

/// CoreAudio device enumeration: every device Audio MIDI Setup shows, with its
/// real channel count, so BlackHole 16ch shows up as 16 inputs and an aggregate
/// device shows the sum of its members.
enum CoreAudioDevices {
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let st = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard st == noErr, let v = value?.takeRetainedValue() else { return "" }
        return v as String
    }

    static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let mem = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { mem.deallocate() }
        let abl = mem.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, abl) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(abl)
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func sampleRate(_ id: AudioDeviceID) -> Double {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    static func transport(_ id: AudioDeviceID) -> String {
        var addr = address(kAudioDevicePropertyTransportType)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr else { return "" }
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeContinuityCaptureWired: return "Continuity (wired)"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity (wireless)"
        default: return ""
        }
    }

    static func info(_ id: AudioDeviceID, defaultIn: AudioDeviceID?, defaultOut: AudioDeviceID?) -> AudioDeviceInfo {
        AudioDeviceInfo(deviceID: id,
                        uid: string(id, kAudioDevicePropertyDeviceUID),
                        name: string(id, kAudioObjectPropertyName),
                        manufacturer: string(id, kAudioObjectPropertyManufacturer),
                        inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
                        outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
                        sampleRate: sampleRate(id),
                        isDefaultInput: id == defaultIn,
                        isDefaultOutput: id == defaultOut,
                        transport: transport(id))
    }

    static func all() -> [AudioDeviceInfo] {
        let din = defaultDevice(input: true), dout = defaultDevice(input: false)
        return allDeviceIDs().map { info($0, defaultIn: din, defaultOut: dout) }.filter { !$0.name.isEmpty }
    }

    static func device(uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func bufferFrameSize(_ id: AudioDeviceID) -> Int {
        var addr = address(kAudioDevicePropertyBufferFrameSize)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &frames) == noErr else { return 512 }
        return Int(frames)
    }
}

final class AudioDeviceManager: ObservableObject {
    @Published private(set) var inputDevices: [AudioDeviceInfo] = []
    @Published private(set) var outputDevices: [AudioDeviceInfo] = []
    private var listenerInstalled = false
    var onChange: (() -> Void)?

    init() {
        refresh()
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
            self?.refresh()
            self?.onChange?()
        }
        listenerInstalled = st == noErr
    }

    func refresh() {
        let all = CoreAudioDevices.all()
        let ins = all.filter { $0.inputChannels > 0 }.sorted { $0.name < $1.name }
        let outs = all.filter { $0.outputChannels > 0 }.sorted { $0.name < $1.name }
        if Thread.isMainThread {
            inputDevices = ins
            outputDevices = outs
        } else {
            DispatchQueue.main.async {
                self.inputDevices = ins
                self.outputDevices = outs
            }
        }
    }
}
