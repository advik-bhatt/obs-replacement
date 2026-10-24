import Foundation

/// Action Message Format 0, the command encoding RTMP uses. Only the types a
/// publishing client needs; objects keep key order because servers are picky.
public indirect enum AMF0Value: Equatable {
    case number(Double)
    case bool(Bool)
    case string(String)
    case object([(String, AMF0Value)])
    case null
    case undefined
    case ecmaArray([(String, AMF0Value)])
    case strictArray([AMF0Value])
    case date(Double, Int16)
    case longString(String)

    public static func == (a: AMF0Value, b: AMF0Value) -> Bool {
        switch (a, b) {
        case (.number(let x), .number(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.longString(let x), .longString(let y)): return x == y
        case (.null, .null), (.undefined, .undefined): return true
        case (.object(let x), .object(let y)), (.ecmaArray(let x), .ecmaArray(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.strictArray(let x), .strictArray(let y)): return x == y
        case (.date(let x, let tx), .date(let y, let ty)): return x == y && tx == ty
        default: return false
        }
    }

    public var numberValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var stringValue: String? {
        switch self {
        case .string(let s), .longString(let s): return s
        default: return nil
        }
    }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }

    /// Property lookup on object / ECMA array values.
    public subscript(key: String) -> AMF0Value? {
        switch self {
        case .object(let props), .ecmaArray(let props):
            return props.first { $0.0 == key }?.1
        default:
            return nil
        }
    }

    // MARK: encoding

    private enum Marker: UInt8 {
        case number = 0x00, bool = 0x01, string = 0x02, object = 0x03, null = 0x05, undefined = 0x06
        case ecmaArray = 0x08, objectEnd = 0x09, strictArray = 0x0A, date = 0x0B, longString = 0x0C
    }

    public func encode(into w: inout ByteWriter) {
        switch self {
        case .number(let n):
            w.u8(Marker.number.rawValue)
            w.double(n)
        case .bool(let b):
            w.u8(Marker.bool.rawValue)
            w.u8(b ? 1 : 0)
        case .string(let s):
            let utf8 = Array(s.utf8)
            if utf8.count > 0xFFFF {
                w.u8(Marker.longString.rawValue)
                w.u32(UInt32(utf8.count))
            } else {
                w.u8(Marker.string.rawValue)
                w.u16(UInt16(utf8.count))
            }
            w.append(utf8)
        case .longString(let s):
            let utf8 = Array(s.utf8)
            w.u8(Marker.longString.rawValue)
            w.u32(UInt32(utf8.count))
            w.append(utf8)
        case .object(let props):
            w.u8(Marker.object.rawValue)
            AMF0Value.encodeProperties(props, into: &w)
        case .ecmaArray(let props):
            w.u8(Marker.ecmaArray.rawValue)
            w.u32(UInt32(props.count))
            AMF0Value.encodeProperties(props, into: &w)
        case .null:
            w.u8(Marker.null.rawValue)
        case .undefined:
            w.u8(Marker.undefined.rawValue)
        case .strictArray(let items):
            w.u8(Marker.strictArray.rawValue)
            w.u32(UInt32(items.count))
            for item in items { item.encode(into: &w) }
        case .date(let ms, let tz):
            w.u8(Marker.date.rawValue)
            w.double(ms)
            w.u16(UInt16(bitPattern: tz))
        }
    }

    private static func encodeProperties(_ props: [(String, AMF0Value)], into w: inout ByteWriter) {
        for (key, value) in props {
            let k = Array(key.utf8)
            w.u16(UInt16(min(k.count, 0xFFFF)))
            w.append(Array(k.prefix(0xFFFF)))
            value.encode(into: &w)
        }
        w.u16(0)
        w.u8(Marker.objectEnd.rawValue)
    }

    public var encoded: [UInt8] {
        var w = ByteWriter()
        encode(into: &w)
        return w.bytes
    }

    public static func encodeAll(_ values: [AMF0Value]) -> [UInt8] {
        var w = ByteWriter()
        for v in values { v.encode(into: &w) }
        return w.bytes
    }

    // MARK: decoding

    public static func decode(from r: inout ByteReader) throws -> AMF0Value {
        let markerByte = try r.u8()
        guard let marker = Marker(rawValue: markerByte) else {
            throw ByteReaderError.malformed("unsupported AMF0 marker 0x\(String(markerByte, radix: 16))")
        }
        switch marker {
        case .number: return .number(try r.double())
        case .bool: return .bool(try r.u8() != 0)
        case .string:
            let len = Int(try r.u16())
            return .string(try r.utf8(len))
        case .longString:
            let len = Int(try r.u32())
            return .longString(try r.utf8(len))
        case .object: return .object(try decodeProperties(from: &r))
        case .ecmaArray:
            _ = try r.u32()
            return .ecmaArray(try decodeProperties(from: &r))
        case .null: return .null
        case .undefined: return .undefined
        case .objectEnd: throw ByteReaderError.malformed("unexpected object end")
        case .strictArray:
            let n = Int(try r.u32())
            var items: [AMF0Value] = []
            for _ in 0..<n { items.append(try decode(from: &r)) }
            return .strictArray(items)
        case .date:
            let ms = try r.double()
            let tz = Int16(bitPattern: try r.u16())
            return .date(ms, tz)
        }
    }

    private static func decodeProperties(from r: inout ByteReader) throws -> [(String, AMF0Value)] {
        var props: [(String, AMF0Value)] = []
        while true {
            let len = Int(try r.u16())
            if len == 0 {
                let end = try r.u8()
                guard end == Marker.objectEnd.rawValue else { throw ByteReaderError.malformed("expected object end") }
                return props
            }
            let key = try r.utf8(len)
            let value = try decode(from: &r)
            props.append((key, value))
        }
    }

    /// Decodes every value in a command payload.
    public static func decodeAll(_ bytes: [UInt8]) throws -> [AMF0Value] {
        var r = ByteReader(bytes)
        var out: [AMF0Value] = []
        while !r.isAtEnd { out.append(try decode(from: &r)) }
        return out
    }
}
