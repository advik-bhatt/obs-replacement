import XCTest
@testable import UpstageCore

final class RemoteTests: XCTestCase {
    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256.hash("").hexString, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hash("abc").hexString, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hash("The quick brown fox jumps over the lazy dog").hexString, "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
        // 64-byte message exercises the padding boundary
        XCTAssertEqual(SHA256.hash(String(repeating: "a", count: 64)).hexString, "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
    }

    func testObsWebSocketAuthMatchesSpecExample() {
        // Cross-checked against Python: base64(sha256(base64(sha256(password+salt)) + challenge))
        let auth = OBSWebSocket.Auth.authentication(password: "supersecretpassword",
                                                    salt: "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAHo3ixNg=",
                                                    challenge: "ztTBnnuqrqaKDzRM3xcVdbYm/+ulPyQ18qKkA4QlEK8=")
        XCTAssertEqual(auth, "yERCgEfItD4YZ+y71DKQv3gFeuZ9BGmrZQiLespWzik=")
        XCTAssertEqual(OBSWebSocket.Auth.secret(password: "supersecretpassword", salt: "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAHo3ixNg="), "yd8lADsleitX4n3YI1r0IDrpDR9HkkoSlzawI51LIQ8=")
    }

    final class Handler: OBSWebSocketRequestHandler {
        var seen: [String] = []
        func handle(requestType: String, requestData: JSONValue?) -> OBSWebSocket.RequestResult {
            seen.append(requestType)
            switch requestType {
            case "GetVersion": return .ok(["obsVersion": "0.1.0", "rpcVersion": 1])
            case "SetCurrentProgramScene":
                guard let name = requestData?["sceneName"]?.stringValue else { return .error(.missingRequestField, "sceneName") }
                return name == "Main" ? .ok() : .error(.resourceNotFound, "No scene \(name)")
            default: return .error(.unknownRequestType)
            }
        }
    }

    func testHandshakeWithoutPasswordThenRequest() throws {
        let h = Handler()
        let c = OBSWebSocketConnection(password: "", handler: h)
        let hello = c.hello()
        XCTAssertEqual(hello["op"]?.intValue, 0)
        XCTAssertNil(hello["d"]?["authentication"])
        let identified = c.receive(#"{"op":1,"d":{"rpcVersion":1,"eventSubscriptions":33}}"#)
        XCTAssertEqual(identified.count, 1)
        XCTAssertEqual(identified[0]["op"]?.intValue, 2)
        XCTAssertEqual(c.phase, .identified)
        XCTAssertEqual(c.eventSubscriptions, 33)
        XCTAssertTrue(c.wantsEvent(intent: OBSWebSocket.EventSubscription.general))
        XCTAssertFalse(c.wantsEvent(intent: OBSWebSocket.EventSubscription.scenes))

        let resp = c.receive(#"{"op":6,"d":{"requestType":"GetVersion","requestId":"abc"}}"#)
        XCTAssertEqual(resp.count, 1)
        XCTAssertEqual(resp[0]["op"]?.intValue, 7)
        XCTAssertEqual(resp[0]["d"]?["requestId"]?.stringValue, "abc")
        XCTAssertEqual(resp[0]["d"]?["requestStatus"]?["code"]?.intValue, 100)
        XCTAssertEqual(resp[0]["d"]?["requestStatus"]?["result"]?.boolValue, true)
        XCTAssertEqual(resp[0]["d"]?["responseData"]?["obsVersion"]?.stringValue, "0.1.0")

        let bad = c.receive(#"{"op":6,"d":{"requestType":"SetCurrentProgramScene","requestId":"2","requestData":{"sceneName":"Nope"}}}"#)
        XCTAssertEqual(bad[0]["d"]?["requestStatus"]?["code"]?.intValue, 600)
        XCTAssertEqual(bad[0]["d"]?["requestStatus"]?["result"]?.boolValue, false)
    }

    func testPasswordRequiredAndChecked() {
        let c = OBSWebSocketConnection(password: "pw", handler: Handler())
        let hello = c.hello()
        let salt = hello["d"]?["authentication"]?["salt"]?.stringValue ?? ""
        let challenge = hello["d"]?["authentication"]?["challenge"]?.stringValue ?? ""
        XCTAssertFalse(salt.isEmpty)
        var r = c.receive(#"{"op":1,"d":{"rpcVersion":1}}"#)
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(c.phase, .closed(code: 4007, reason: "Authentication required"))

        let c2 = OBSWebSocketConnection(password: "pw", handler: Handler())
        _ = c2.hello()
        r = c2.receive(#"{"op":1,"d":{"rpcVersion":1,"authentication":"wrong"}}"#)
        XCTAssertEqual(c2.phase, .closed(code: 4009, reason: "Authentication failed"))

        let c3 = OBSWebSocketConnection(password: "pw", handler: Handler())
        let hello3 = c3.hello()
        let s3 = hello3["d"]?["authentication"]?["salt"]?.stringValue ?? ""
        let ch3 = hello3["d"]?["authentication"]?["challenge"]?.stringValue ?? ""
        let auth = OBSWebSocket.Auth.authentication(password: "pw", salt: s3, challenge: ch3)
        r = c3.receive(JSONValue.object(["op": 1, "d": .object(["rpcVersion": 1, "authentication": .string(auth)])]).serializedString)
        XCTAssertEqual(c3.phase, .identified)
        XCTAssertEqual(r.count, 1)
    }

    func testRequestBeforeIdentifyCloses() {
        let c = OBSWebSocketConnection(password: "", handler: Handler())
        _ = c.receive(#"{"op":6,"d":{"requestType":"GetVersion","requestId":"1"}}"#)
        XCTAssertEqual(c.phase, .closed(code: 4008, reason: "Not identified"))
    }

    func testBatchHaltsOnFailure() {
        let h = Handler()
        let c = OBSWebSocketConnection(password: "", handler: h)
        _ = c.receive(#"{"op":1,"d":{"rpcVersion":1}}"#)
        let r = c.receive(#"{"op":8,"d":{"requestId":"b","haltOnFailure":true,"requests":[{"requestType":"GetVersion","requestId":"1"},{"requestType":"Nope","requestId":"2"},{"requestType":"GetVersion","requestId":"3"}]}}"#)
        XCTAssertEqual(r[0]["op"]?.intValue, 9)
        XCTAssertEqual(r[0]["d"]?["results"]?.arrayValue?.count, 2)
        XCTAssertEqual(h.seen, ["GetVersion", "Nope"])
    }

    func testEventEnvelope() {
        let e = OBSWebSocket.event(type: "CurrentProgramSceneChanged", intent: OBSWebSocket.EventSubscription.scenes, data: ["sceneName": "Main"])
        XCTAssertEqual(e["op"]?.intValue, 5)
        XCTAssertEqual(e["d"]?["eventType"]?.stringValue, "CurrentProgramSceneChanged")
        XCTAssertEqual(e["d"]?["eventData"]?["sceneName"]?.stringValue, "Main")
    }

    func testJSONValueSerializesIntegersWithoutDecimals() {
        let v: JSONValue = ["a": 1, "b": 1.5, "c": [true, nil], "d": "x"]
        let s = v.serializedString
        XCTAssertTrue(s.contains(#""a":1"#), s)
        XCTAssertTrue(s.contains(#""b":1.5"#), s)
        let back = try? JSONValue.parse(s)
        XCTAssertEqual(back, v)
    }
}
