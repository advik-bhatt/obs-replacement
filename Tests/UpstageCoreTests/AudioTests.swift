import XCTest
@testable import UpstageCore

final class AudioTests: XCTestCase {
    func testDBConversions() {
        XCTAssertEqual(AudioMath.linear(fromDB: 0), 1, accuracy: 1e-6)
        XCTAssertEqual(AudioMath.linear(fromDB: -6.0206), 0.5, accuracy: 1e-4)
        XCTAssertEqual(AudioMath.dB(fromLinear: 0.5), -6.0206, accuracy: 1e-3)
        XCTAssertEqual(AudioMath.dB(fromLinear: 0), AudioMath.silenceDB)
        XCTAssertEqual(AudioMath.linear(fromDB: AudioMath.silenceDB), 0)
    }

    func testCubicFaderRoundTrip() {
        for pos in stride(from: 0.0, through: 1.0, by: 0.1) {
            let g = AudioMath.gain(fromFaderPosition: pos)
            XCTAssertEqual(AudioMath.faderPosition(fromGain: g), pos, accuracy: 1e-5)
        }
        XCTAssertEqual(AudioMath.dB(fromFaderPosition: 1), 0, accuracy: 1e-9)
    }

    func testDefaultMatrixPicksFirstTwoChannelsOf16() {
        let m = ChannelMatrix.defaultMapping(inputChannels: 16)
        XCTAssertEqual(m.gains[0][0], 1)
        XCTAssertEqual(m.gains[1][1], 1)
        XCTAssertEqual(m.gains[0][1], 0)
        XCTAssertEqual(m.gains.flatMap { $0 }.reduce(0, +), 2)
    }

    func testMonoMatrixFeedsBothSides() {
        let m = ChannelMatrix.defaultMapping(inputChannels: 1)
        XCTAssertEqual(m.gains, [[1], [1]])
    }

    func testMatrixApply() {
        var m = ChannelMatrix(inputChannels: 4)
        m.setRouted(input: 2, output: 0, true)
        m.setRouted(input: 3, output: 1, true)
        m.setRouted(input: 0, output: 1, true)
        let input: [[Float]] = [[1, 1], [2, 2], [3, 3], [4, 4]]
        let out = m.apply(input, frames: 2)
        XCTAssertEqual(out[0], [3, 3])
        XCTAssertEqual(out[1], [5, 5])
    }

    func testMatrixResizeKeepsRoutingOrFallsBack() {
        var m = ChannelMatrix.defaultMapping(inputChannels: 2)
        m.setRouted(input: 1, output: 0, true)
        let grown = m.resized(toInputChannels: 16)
        XCTAssertEqual(grown.inputChannels, 16)
        XCTAssertTrue(grown.isRouted(input: 1, output: 0))
        var all = ChannelMatrix(inputChannels: 16)
        all.setRouted(input: 15, output: 0, true)
        let shrunk = all.resized(toInputChannels: 2)
        XCTAssertEqual(shrunk, .defaultMapping(inputChannels: 2), "routing referenced channels that no longer exist, so defaults return")
    }

    func testSumAllIsEqualPower() {
        let m = ChannelMatrix.sumAll(inputChannels: 4)
        XCTAssertEqual(m.gains[0][0], 0.5, accuracy: 1e-6)
    }

    func testRingBufferWritesReadsAndUnderruns() {
        let rb = AudioRingBuffer(channels: 2, capacityFrames: 8)
        rb.write(planes: [[1, 2, 3], [10, 20, 30]], frames: 3)
        XCTAssertEqual(rb.availableFrames, 3)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        defer { l.deallocate(); r.deallocate() }
        let got = rb.read(into: [l, r], frames: 4)
        XCTAssertEqual(got, 3)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: l, count: 4)), [1, 2, 3, 0])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: r, count: 4)), [10, 20, 30, 0])
        XCTAssertEqual(rb.underruns, 1)
    }

    func testRingBufferOverrunDropsOldest() {
        let rb = AudioRingBuffer(channels: 1, capacityFrames: 4)
        rb.write(planes: [[1, 2, 3]], frames: 3)
        rb.write(planes: [[4, 5, 6]], frames: 3)
        XCTAssertEqual(rb.availableFrames, 4)
        XCTAssertEqual(rb.overruns, 1)
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        defer { p.deallocate() }
        rb.read(into: [p], frames: 4)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: p, count: 4)), [3, 4, 5, 6])
    }

    func testRingBufferTrimBoundsLatency() {
        let rb = AudioRingBuffer(channels: 1, capacityFrames: 100)
        rb.write(planes: [[Float](repeating: 1, count: 50)], frames: 50)
        rb.trim(keepFrames: 10)
        XCTAssertEqual(rb.availableFrames, 10)
    }

    func testPeakMeterDecays() {
        var m = PeakMeter(channels: 1, decayDBPerSecond: 20)
        m.update(peaks: [1], elapsed: 0.01)
        XCTAssertEqual(m.peakDB[0], 0, accuracy: 1e-9)
        m.update(peaks: [0], elapsed: 0.5)
        XCTAssertEqual(m.peakDB[0], -10, accuracy: 1e-6)
        XCTAssertEqual(m.holdDB[0], 0, accuracy: 1e-9, "hold lasts 1.5s")
    }
}
