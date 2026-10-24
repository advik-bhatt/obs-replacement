import AudioToolbox
import CoreAudio
import Foundation
import UpstageCore

/// Captures one CoreAudio input device through an AUHAL unit, the lowest
/// latency path macOS offers and the only one that hands over every channel of
/// a multichannel device (BlackHole 16ch, interfaces, aggregates) untouched.
/// The ChannelMatrix in the source settings decides which channels reach the
/// stereo mix.
final class AudioInputSource: AudioSourceInstance {
    let id: UUID
    private(set) var descriptor: SourceDescriptor
    private var settings: AudioInputSettings
    let audioOutput: AudioSourceOutput
    private var unit: AudioComponentInstance?
    private var deviceID: AudioDeviceID = 0
    private var bufferList: UnsafeMutableAudioBufferListPointer?
    private var bufferFrames = 0
    private var channels = 0
    private var sampleRate: Double = 0
    private let queue = DispatchQueue(label: "upstage.audioinput", qos: .userInitiated)
    private(set) var isActive = false
    private(set) var status = "Not started"
    private var restartTimer: DispatchSourceTimer?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    init(descriptor: SourceDescriptor, settings: AudioInputSettings) {
        id = descriptor.id
        self.descriptor = descriptor
        self.settings = settings
        audioOutput = AudioSourceOutput(matrix: settings.channelMatrix)
        audioOutput.syncOffsetMs = descriptor.audio.syncOffsetMs
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        queue.async { [weak self] in self?.open() }
        installDeviceListListener()
    }

    func stop() {
        isActive = false
        restartTimer?.cancel()
        restartTimer = nil
        removeDeviceListListener()
        queue.sync { [self] in close() }
        status = "Stopped"
    }

    func update(descriptor: SourceDescriptor) {
        self.descriptor = descriptor
        guard case .audioInput(let s) = descriptor.settings else { return }
        let deviceChanged = s.deviceUID != settings.deviceUID
        settings = s
        audioOutput.channelMatrix = s.channelMatrix
        audioOutput.syncOffsetMs = descriptor.audio.syncOffsetMs
        if deviceChanged, isActive {
            queue.async { [weak self] in
                self?.close()
                self?.open()
            }
        }
    }

    /// The device's real channel count once open (so the UI can draw the matrix).
    var deviceChannels: Int { channels }
    var deviceSampleRate: Double { sampleRate }

    // MARK: AUHAL

    private func resolveDeviceID() -> AudioDeviceID? {
        if let uid = settings.deviceUID {
            return CoreAudioDevices.device(uid: uid)
        }
        return CoreAudioDevices.defaultDevice(input: true)
    }

    private func open() {
        guard isActive else { return }
        guard let dev = resolveDeviceID() else {
            status = "Device not found: \(settings.deviceName ?? settings.deviceUID ?? "default input")"
            scheduleRetry()
            return
        }
        deviceID = dev
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            status = "AUHAL unavailable"
            return
        }
        var au: AudioComponentInstance?
        guard AudioComponentInstanceNew(comp, &au) == noErr, let au else {
            status = "Could not create AUHAL"
            return
        }
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        var st = AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        st = st | AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size))
        var devID = dev
        st = st | AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard st == noErr else {
            status = "AUHAL setup failed (\(st))"
            AudioComponentInstanceDispose(au)
            scheduleRetry()
            return
        }

        // Device-side format: what the hardware delivers.
        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &size) == noErr else {
            status = "Could not read device format"
            AudioComponentInstanceDispose(au)
            scheduleRetry()
            return
        }
        channels = Int(deviceFormat.mChannelsPerFrame)
        sampleRate = deviceFormat.mSampleRate
        guard channels > 0 else {
            status = "Device has no input channels"
            AudioComponentInstanceDispose(au)
            return
        }

        // Client-side format: planar Float32, same channels and rate (no SRC inside AUHAL).
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        guard AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr else {
            status = "Could not set client format"
            AudioComponentInstanceDispose(au)
            return
        }

        bufferFrames = max(CoreAudioDevices.bufferFrameSize(dev), 512)
        var maxFrames = UInt32(bufferFrames)
        AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))

        let abl = AudioBufferList.allocate(maximumBuffers: channels)
        for ch in 0..<channels {
            abl[ch].mNumberChannels = 1
            abl[ch].mDataByteSize = UInt32(bufferFrames * 4 * 4)
            abl[ch].mData = UnsafeMutableRawPointer.allocate(byteCount: bufferFrames * 4 * 4, alignment: 16)
        }
        bufferList = abl

        var callback = AURenderCallbackStruct(inputProc: audioInputRenderCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(au) == noErr else {
            status = "Could not initialize AUHAL"
            freeBuffers()
            AudioComponentInstanceDispose(au)
            return
        }
        guard AudioOutputUnitStart(au) == noErr else {
            status = "Could not start input"
            AudioUnitUninitialize(au)
            freeBuffers()
            AudioComponentInstanceDispose(au)
            scheduleRetry()
            return
        }
        unit = au
        audioOutput.configureInput(channels: channels, sampleRate: sampleRate)
        let name = CoreAudioDevices.string(dev, kAudioObjectPropertyName)
        status = "\(name): \(channels) ch @ \(Int(sampleRate)) Hz"
    }

    private func close() {
        if let au = unit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            unit = nil
        }
        freeBuffers()
    }

    private func freeBuffers() {
        if let abl = bufferList {
            for b in abl { b.mData?.deallocate() }
            free(abl.unsafeMutablePointer)
            bufferList = nil
        }
    }

    private func scheduleRetry() {
        guard isActive else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3)
        t.setEventHandler { [weak self] in
            guard let self, self.isActive, self.unit == nil else { return }
            self.open()
        }
        t.resume()
        restartTimer = t
    }

    private func installDeviceListListener() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isActive else { return }
            // Device may have come or gone; re-open if we are not running or our device vanished.
            if self.unit == nil || self.resolveDeviceID() != self.deviceID {
                self.close()
                self.open()
            }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
    }

    private func removeDeviceListListener() {
        guard let block = deviceListener else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        deviceListener = nil
    }

    // MARK: render callback (audio thread)

    fileprivate func render(_ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ inTimeStamp: UnsafePointer<AudioTimeStamp>, _ inBusNumber: UInt32, _ inNumberFrames: UInt32) -> OSStatus {
        guard let au = unit, let abl = bufferList else { return noErr }
        let frames = Int(inNumberFrames)
        guard frames > 0 else { return noErr }
        let needed = frames * 4
        if Int(abl[0].mDataByteSize) < needed {
            // Device asked for more than we allocated; grow once (allocation on the audio thread is rare and bounded).
            for ch in 0..<channels {
                abl[ch].mData?.deallocate()
                abl[ch].mData = UnsafeMutableRawPointer.allocate(byteCount: needed * 2, alignment: 16)
                abl[ch].mDataByteSize = UInt32(needed * 2)
            }
        }
        for ch in 0..<channels { abl[ch].mDataByteSize = UInt32(needed) }
        let st = AudioUnitRender(au, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, abl.unsafeMutablePointer)
        guard st == noErr else { return st }
        var planes: [UnsafePointer<Float>] = []
        planes.reserveCapacity(channels)
        for ch in 0..<channels {
            guard let p = abl[ch].mData else { return noErr }
            planes.append(UnsafePointer(p.assumingMemoryBound(to: Float.self)))
        }
        audioOutput.push(planes: planes, frames: frames, sampleRate: sampleRate)
        return noErr
    }
}

private func audioInputRenderCallback(inRefCon: UnsafeMutableRawPointer,
                                      ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                      inTimeStamp: UnsafePointer<AudioTimeStamp>,
                                      inBusNumber: UInt32,
                                      inNumberFrames: UInt32,
                                      ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let source = Unmanaged<AudioInputSource>.fromOpaque(inRefCon).takeUnretainedValue()
    return source.render(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames)
}
