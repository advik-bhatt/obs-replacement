import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import UpstageCore

/// A block of mixed audio handed to outputs: planar Float32, `channels` planes
/// of `frames` samples at 48 kHz, stamped on the engine clock.
struct MixedAudioBlock {
    let planes: [[Float]]
    let frames: Int
    let sampleRate: Double
    /// Seconds on the engine clock (same clock as video frames).
    let timestamp: Double
    let trackMask: UInt8
}

protocol AudioSink: AnyObject {
    func receiveAudio(_ block: MixedAudioBlock)
}

/// Per-source mixer channel: pulls from the source's ring buffer, applies fader
/// and mute, meters, and routes to tracks + monitoring.
final class MixerChannel {
    let sourceID: UUID
    let output: AudioSourceOutput
    var audioSettings: SourceAudioSettings
    var meter: PeakMeter
    var inputMeter: PeakMeter
    /// Scratch block, one raw plane per mix channel (stable pointers for the ring buffer read).
    private(set) var planes: [UnsafeMutablePointer<Float>]
    private(set) var capacity: Int

    init(sourceID: UUID, output: AudioSourceOutput, audioSettings: SourceAudioSettings, channels: Int, blockFrames: Int) {
        self.sourceID = sourceID
        self.output = output
        self.audioSettings = audioSettings
        meter = PeakMeter(channels: channels)
        inputMeter = PeakMeter(channels: channels)
        capacity = blockFrames
        planes = (0..<channels).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
            p.initialize(repeating: 0, count: blockFrames)
            return p
        }
    }

    deinit {
        planes.forEach { $0.deallocate() }
    }

    func ensureBlock(frames n: Int, channels: Int) {
        if planes.count != channels || capacity < n {
            planes.forEach { $0.deallocate() }
            capacity = max(n, capacity)
            planes = (0..<channels).map { _ in
                let p = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
                p.initialize(repeating: 0, count: capacity)
                return p
            }
        }
    }
}

struct AudioLevels {
    var peakDB: [Double]
    var holdDB: [Double]
    var inputPeakDB: [Double]
}

/// Pulls every audio source at a fixed cadence, sums them, meters them, feeds
/// recording/streaming sinks and the monitoring output. Runs on its own queue;
/// the UI reads `levels` on a timer.
final class AudioMixer {
    let sampleRate: Double = 48_000
    let channels: Int = 2
    let blockFrames = 480 // 10 ms
    private let queue = DispatchQueue(label: "upstage.mixer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var channelsByID: [UUID: MixerChannel] = [:]
    private var sinks: [ObjectIdentifier: AudioSink] = [:]
    private var masterMeter: PeakMeter
    private var startTime: Double = 0
    private var samplesProduced: Int64 = 0
    private var monitor: MonitorOutput?
    private(set) var isRunning = false
    var monitoringDeviceUID: String?
    private var masterTrackBuffers: [UInt8: [[Float]]] = [:]
    private var activeSources: Set<UUID>? = nil
    /// Latency target for each source ring, in frames. Rings above 4x this are trimmed.
    var targetLatencyFrames = 48_000 / 20 // 50 ms

    init() {
        masterMeter = PeakMeter(channels: 2)
    }

    /// Engine clock: seconds since `start()`.
    func clock() -> Double { hostTimeSeconds() - startTime }
    func clockOrigin() -> Double { startTime }

    func start(startTime: Double) {
        guard !isRunning else { return }
        isRunning = true
        self.startTime = startTime
        samplesProduced = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        startMonitor()
    }

    func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
        monitor?.stop()
        monitor = nil
    }

    // MARK: channels & sinks

    func addSource(_ id: UUID, output: AudioSourceOutput, audio: SourceAudioSettings) {
        lock.lock()
        channelsByID[id] = MixerChannel(sourceID: id, output: output, audioSettings: audio, channels: channels, blockFrames: blockFrames)
        lock.unlock()
    }

    func removeSource(_ id: UUID) {
        lock.lock()
        channelsByID.removeValue(forKey: id)
        lock.unlock()
    }

    func updateSource(_ id: UUID, audio: SourceAudioSettings) {
        lock.lock()
        channelsByID[id]?.audioSettings = audio
        lock.unlock()
    }

    /// Sources outside the program scene are silent (nil = everything active).
    func setActiveSources(_ ids: Set<UUID>?) {
        lock.lock()
        activeSources = ids
        lock.unlock()
    }

    func addSink(_ sink: AudioSink) {
        lock.lock()
        sinks[ObjectIdentifier(sink)] = sink
        lock.unlock()
    }

    func removeSink(_ sink: AudioSink) {
        lock.lock()
        sinks.removeValue(forKey: ObjectIdentifier(sink))
        lock.unlock()
    }

    /// Snapshot of meters for the UI.
    func levels() -> (master: AudioLevels, sources: [UUID: AudioLevels]) {
        lock.lock(); defer { lock.unlock() }
        var out: [UUID: AudioLevels] = [:]
        for (id, ch) in channelsByID {
            out[id] = AudioLevels(peakDB: ch.meter.peakDB, holdDB: ch.meter.holdDB, inputPeakDB: ch.inputMeter.peakDB)
        }
        return (AudioLevels(peakDB: masterMeter.peakDB, holdDB: masterMeter.holdDB, inputPeakDB: masterMeter.peakDB), out)
    }

    // MARK: monitoring

    private func startMonitor() {
        monitor?.stop()
        let m = MonitorOutput(sampleRate: sampleRate, channels: channels)
        m.start(deviceUID: monitoringDeviceUID)
        monitor = m
    }

    func setMonitoringDevice(uid: String?) {
        monitoringDeviceUID = uid
        if isRunning { queue.async { [weak self] in self?.startMonitor() } }
    }

    // MARK: the loop

    private func tick() {
        guard isRunning else { return }
        // Catch up to the host clock in whole blocks so audio pts tracks video pts.
        let expectedSamples = Int64((hostTimeSeconds() - startTime) * sampleRate)
        var blocks = 0
        while samplesProduced + Int64(blockFrames) <= expectedSamples && blocks < 20 {
            produceBlock()
            blocks += 1
        }
    }

    private func produceBlock() {
        lock.lock()
        let chans = Array(channelsByID.values)
        let sinkList = Array(sinks.values)
        let active = activeSources
        lock.unlock()

        let n = blockFrames
        var master = Array(repeating: [Float](repeating: 0, count: n), count: channels)
        var monitorMix = Array(repeating: [Float](repeating: 0, count: n), count: channels)
        var tracks: [UInt8: [[Float]]] = [:]
        let elapsed = Double(n) / sampleRate
        var masterPeaks = [Float](repeating: 0, count: channels)
        var anyMonitor = false

        for ch in chans {
            ch.ensureBlock(frames: n, channels: channels)
            // Bound latency: if the ring has grown far past the target, drop the backlog.
            let offsetFrames = Int(Double(ch.output.syncOffsetMs) / 1000 * sampleRate)
            let target = targetLatencyFrames + max(0, offsetFrames)
            // Media sources legitimately read ahead; only trim a real backlog.
            let trimLine = max(target * 4, Int(sampleRate / 2)) + n
            if ch.output.ring.availableFrames > trimLine { ch.output.ring.trim(keepFrames: target) }
            // Respect a positive sync offset by waiting until enough has accumulated.
            if offsetFrames > 0, ch.output.ring.availableFrames < offsetFrames {
                for c in 0..<channels { ch.planes[c].update(repeating: 0, count: n) }
            } else {
                ch.output.ring.read(into: ch.planes, frames: n)
            }
            var inPeaks = [Float](repeating: 0, count: channels)
            for c in 0..<channels {
                inPeaks[c] = AudioMath.peak(UnsafeBufferPointer(start: ch.planes[c], count: n))
            }
            ch.inputMeter.update(peaks: inPeaks, elapsed: elapsed)
            let isActive = active?.contains(ch.sourceID) ?? true
            let gain: Float = isActive ? ch.audioSettings.linearGain : 0
            let mode = ch.audioSettings.monitoring
            var peaks = [Float](repeating: 0, count: channels)
            for c in 0..<channels {
                let g = gain
                if g > 0 {
                    let plane = ch.planes[c]
                    for f in 0..<n {
                        let v = plane[f] * g
                        if mode != .monitorOnly {
                            master[c][f] += v
                        }
                        if mode != .off {
                            monitorMix[c][f] += v
                        }
                        let a = abs(v)
                        if a > peaks[c] { peaks[c] = a }
                    }
                }
            }
            if mode != .off { anyMonitor = true }
            ch.meter.update(peaks: peaks, elapsed: elapsed)
            // Tracks: a source can feed any subset of 6 mix tracks (bit mask).
            if mode != .monitorOnly, gain > 0 {
                for bit in 0..<6 where ch.audioSettings.tracks & (1 << bit) != 0 {
                    let trackIndex = UInt8(bit + 1)
                    if trackIndex == 1 { continue } // track 1 is the master mix
                    var t = tracks[trackIndex] ?? Array(repeating: [Float](repeating: 0, count: n), count: channels)
                    for c in 0..<channels { let plane = ch.planes[c]; for f in 0..<n { t[c][f] += plane[f] * gain } }
                    tracks[trackIndex] = t
                }
            }
        }
        for c in 0..<channels {
            master[c].withUnsafeBufferPointer { masterPeaks[c] = AudioMath.peak($0) }
            // Soft clip the master so a hot mix does not wrap.
            for f in 0..<n where abs(master[c][f]) > 1 { master[c][f] = master[c][f] > 0 ? 1 : -1 }
        }
        lock.lock()
        masterMeter.update(peaks: masterPeaks, elapsed: elapsed)
        lock.unlock()

        let ts = Double(samplesProduced) / sampleRate
        samplesProduced += Int64(n)
        let block = MixedAudioBlock(planes: master, frames: n, sampleRate: sampleRate, timestamp: ts, trackMask: 1)
        for s in sinkList { s.receiveAudio(block) }
        for (track, planes) in tracks {
            let tb = MixedAudioBlock(planes: planes, frames: n, sampleRate: sampleRate, timestamp: ts, trackMask: 1 << (track - 1))
            for s in sinkList { s.receiveAudio(tb) }
        }
        if anyMonitor { monitor?.push(monitorMix, frames: n) } else { monitor?.pushSilence(frames: n) }
    }
}

/// Plays the monitor mix on a chosen output device through AVAudioEngine.
final class MonitorOutput {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let ring: AudioRingBuffer
    private let channels: Int
    private let sampleRate: Double
    private(set) var isRunning = false

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        ring = AudioRingBuffer(channels: channels, capacityFrames: Int(sampleRate))
    }

    func start(deviceUID: String?) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false) else { return }
        if let uid = deviceUID, let dev = CoreAudioDevices.device(uid: uid), let au = engine.outputNode.audioUnit {
            var id = dev
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            var ptrs: [UnsafeMutablePointer<Float>] = []
            for b in abl { ptrs.append(b.mData!.assumingMemoryBound(to: Float.self)) }
            self.ring.read(into: ptrs, frames: Int(frameCount))
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        do {
            try engine.start()
            isRunning = true
        } catch {
            NSLog("Monitor output failed to start: \(error)")
        }
    }

    func stop() {
        engine.stop()
        if let n = sourceNode { engine.detach(n) }
        sourceNode = nil
        isRunning = false
    }

    func push(_ planes: [[Float]], frames: Int) {
        // keep monitoring latency low: never queue more than 100 ms
        if ring.availableFrames > Int(sampleRate / 10) { ring.trim(keepFrames: Int(sampleRate / 20)) }
        ring.write(planes: planes, frames: frames)
    }

    func pushSilence(frames: Int) {
        if ring.availableFrames > Int(sampleRate / 10) { ring.trim(keepFrames: 0) }
    }
}
