import XCTest
@testable import UpstageCore

final class GeometryAndModelTests: XCTestCase {
    func testFitLandscapeCameraOn4KCanvasIsExactly2x() {
        let t = Transform.fitting(source: Size2D(1920, 1080), in: CanvasPreset.landscape4K.size, mode: .fit)
        XCTAssertEqual(t.scale, Vec2(2, 2))
        XCTAssertEqual(t.position, Vec2(1920, 1080))
        XCTAssertEqual(t.renderedSize(for: Size2D(1920, 1080)), Vec2(3840, 2160))
    }

    func testPortraitCanvasWithRotatedCameraFitsByRotatedFootprint() {
        // iPhone mounted vertically: the 1920x1080 stream rotated 90° fills a 2160x3840 canvas at 2x.
        let t = Transform.fitting(source: Size2D(1920, 1080), in: CanvasPreset.portrait4K.size, mode: .fit, rotation: 90)
        XCTAssertEqual(t.scale.x, 2, accuracy: 1e-9)
        XCTAssertEqual(t.scale.y, 2, accuracy: 1e-9)
        let box = t.boundingBox(for: Size2D(1920, 1080))
        XCTAssertEqual(box.size.x, 2160, accuracy: 1e-6)
        XCTAssertEqual(box.size.y, 3840, accuracy: 1e-6)
    }

    func testPortraitCanvasWithLandscapeCameraFillCropsSides() {
        let t = Transform.fitting(source: Size2D(1920, 1080), in: CanvasPreset.portrait4K.size, mode: .fill)
        // Height must cover 3840 -> scale 3840/1080
        XCTAssertEqual(t.scale.y, 3840.0 / 1080.0, accuracy: 1e-9)
        XCTAssertEqual(t.scale.x, t.scale.y)
    }

    func testCropAppliesBeforeScale() {
        let crop = Crop(left: 420, top: 0, right: 420, bottom: 0) // 1920 -> 1080 wide, 9:16 from a 16:9 feed
        XCTAssertEqual(crop.apply(to: Size2D(1920, 1080)), Size2D(1080, 1080))
        let t = Transform.fitting(source: Size2D(1920, 1080), in: CanvasPreset.portrait1080p.size, mode: .fit, crop: crop)
        XCTAssertEqual(t.scale.x, 1, accuracy: 1e-9)
    }

    func testRotationTransposes() {
        XCTAssertEqual(Rotation.r90.apply(to: Size2D(1920, 1080)), Size2D(1080, 1920))
        XCTAssertEqual(Rotation.r180.apply(to: Size2D(1920, 1080)), Size2D(1920, 1080))
        XCTAssertEqual(Rotation.r0.next, .r90)
        XCTAssertEqual(Rotation.r270.next, .r0)
    }

    func testRGBAHexRoundTrip() {
        let c = RGBA(hex: "#FF8000")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.r ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(c?.g ?? 0, 128.0 / 255.0, accuracy: 1e-9)
        XCTAssertEqual(c?.hexString, "#FF8000FF")
        XCTAssertNil(RGBA(hex: "nope"))
    }

    func testSceneCollectionRoundTripsThroughJSON() throws {
        var c = SceneCollection.empty(name: "Test")
        let cam = SourceDescriptor(name: "iPhone", settings: .camera(CameraSettings(deviceUniqueID: "abc", rotation: .r90)))
        let item = c.addSource(cam, toScene: c.currentSceneID, transform: Transform.fitting(source: Size2D(1920, 1080), in: Size2D(2160, 3840), mode: .fit, rotation: 90))
        XCTAssertNotNil(item)
        let audio = SourceDescriptor(name: "BlackHole 16ch", settings: .audioInput(AudioInputSettings(deviceUID: "BlackHole16ch_UID", deviceName: "BlackHole 16ch", channelMatrix: .defaultMapping(inputChannels: 16))))
        c.addSource(audio, toScene: c.currentSceneID)
        var text = SourceDescriptor(name: "Title", settings: .text(TextSettings(text: "Hello")))
        text.filters = [FilterDescriptor(type: .colorCorrection(ColorCorrectionFilter(brightness: 0.1))), FilterDescriptor(type: .chromaKey(ChromaKeyFilter()))]
        c.addSource(text, toScene: c.currentSceneID)

        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(SceneCollection.self, from: data)
        XCTAssertEqual(back, c)
        XCTAssertEqual(back.sources.count, 3)
        if case .audioInput(let a) = back.sources[1].settings {
            XCTAssertEqual(a.channelMatrix.inputChannels, 16)
            XCTAssertTrue(a.channelMatrix.isRouted(input: 0, output: 0))
            XCTAssertTrue(a.channelMatrix.isRouted(input: 1, output: 1))
            XCTAssertFalse(a.channelMatrix.isRouted(input: 2, output: 0))
        } else {
            XCTFail("expected audio input")
        }
    }

    func testRemovingLastItemDeletesOrphanSourceButKeepsSharedOnes() {
        var c = SceneCollection.empty()
        let second = c.addScene(named: "Scene")
        XCTAssertEqual(second.name, "Scene 2")
        let cam = SourceDescriptor(name: "Cam", settings: .camera(CameraSettings()))
        let i1 = c.addSource(cam, toScene: c.currentSceneID)!
        let i2 = c.addItem(sourceID: cam.id, toScene: second.id)!
        c.removeItem(i1.id, fromScene: c.currentSceneID)
        XCTAssertEqual(c.sources.count, 1, "still referenced by scene 2")
        c.removeItem(i2.id, fromScene: second.id)
        XCTAssertEqual(c.sources.count, 0)
    }

    func testUniqueNames() {
        var c = SceneCollection.empty()
        c.addSource(SourceDescriptor(name: "Cam", settings: .camera(CameraSettings())), toScene: c.currentSceneID)
        c.addSource(SourceDescriptor(name: "Cam", settings: .camera(CameraSettings())), toScene: c.currentSceneID)
        XCTAssertEqual(c.sources.map(\.name), ["Cam", "Cam 2"])
    }

    func testProfileRoundTripAndValidation() throws {
        var p = Profile.portrait4K()
        p.stream.streamKey = "live_123"
        p.stream.videoBitrateKbps = 6000
        p.recording.codec = .proRes422
        XCTAssertEqual(p.recording.validationErrors, ["ProRes requires the MOV container."])
        p.recording.container = .mov
        XCTAssertTrue(p.validationErrors.isEmpty)
        XCTAssertTrue(p.video.isPortrait)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.hotkeys.binding(for: .startStopRecording)?.combo.displayString, "⌥⇧⌘R")
    }

    func testOddResolutionsAreRejected() {
        var v = VideoSettings()
        v.outputSize = Size2D(2159, 3840)
        XCTAssertEqual(v.validationErrors.count, 1)
    }

    func testRecordingFilename() {
        var r = RecordingSettings()
        r.filenameFormat = "%SCENE %Y-%m-%d"
        var comps = DateComponents()
        comps.year = 2026; comps.month = 10; comps.day = 24; comps.hour = 12
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(r.filename(date: date, sceneName: "Main/Scene"), "Main-Scene 2026-10-24.mp4")
    }

    func testHotkeyConflicts() {
        var h = HotkeyBindings.defaults
        let combo = h.binding(for: .startStopRecording)!.combo
        XCTAssertEqual(h.conflicts(for: combo, excluding: .startStopStreaming), [.startStopRecording])
        h.set(nil, for: .startStopRecording)
        XCTAssertNil(h.binding(for: .startStopRecording))
        XCTAssertEqual(KeyCombo.keyCode(named: "r"), 0x0F)
    }

    func testMIDIParser() {
        let events = MIDIParser.parse([0x90, 60, 100, 0x80, 60, 0, 0xB0, 7, 127, 0xC0, 3])
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0], MIDIParser.Event(channel: 0, kind: .note(60), value: 100, isRelease: false))
        XCTAssertEqual(events[1].isRelease, true)
        XCTAssertEqual(events[2].kind, .controlChange(7))
        XCTAssertEqual(events[3].kind, .programChange(3))
        XCTAssertEqual(MIDIMessageKind.noteName(60), "C4")
        let b = MIDIBinding(deviceName: nil, channel: 0, message: .note(60), action: .transition)
        XCTAssertTrue(b.matches(deviceName: "APC", channel: 0, message: .note(60)))
        XCTAssertFalse(b.matches(deviceName: "APC", channel: 1, message: .note(60)))
    }

    func testCanvasPresetMatching() {
        XCTAssertEqual(CanvasPreset.matching(Size2D(2160, 3840)), .portrait4K)
        XCTAssertNil(CanvasPreset.matching(Size2D(100, 100)))
    }
}
