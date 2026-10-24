import Foundation

/// Big-endian byte writer for the RTMP/FLV/AMF wire formats.
public struct ByteWriter {
    public private(set) var bytes: [UInt8]

    public init(capacity: Int = 256) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    public var count: Int { bytes.count }

    public mutating func u8(_ v: UInt8) { bytes.append(v) }

    public mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(v >> 8))
        bytes.append(UInt8(v & 0xFF))
    }

    public mutating func u24(_ v: UInt32) {
        bytes.append(UInt8((v >> 16) & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8(v & 0xFF))
    }

    public mutating func u32(_ v: UInt32) {
        bytes.append(UInt8((v >> 24) & 0xFF))
        bytes.append(UInt8((v >> 16) & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8(v & 0xFF))
    }

    public mutating func u32le(_ v: UInt32) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8((v >> 16) & 0xFF))
        bytes.append(UInt8((v >> 24) & 0xFF))
    }

    public mutating func u64(_ v: UInt64) {
        u32(UInt32(v >> 32))
        u32(UInt32(v & 0xFFFF_FFFF))
    }

    public mutating func double(_ v: Double) { u64(v.bitPattern) }

    public mutating func append(_ data: [UInt8]) { bytes.append(contentsOf: data) }
    public mutating func append(_ data: Data) { bytes.append(contentsOf: data) }
    public mutating func append<S: Sequence>(contentsOf s: S) where S.Element == UInt8 { bytes.append(contentsOf: s) }

    public mutating func utf8(_ s: String) { bytes.append(contentsOf: Array(s.utf8)) }
}

public enum ByteReaderError: Error, Equatable {
    case outOfBounds(needed: Int, available: Int)
    case malformed(String)
}

/// Big-endian byte reader. Throws instead of trapping on short input.
public struct ByteReader {
    public let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset >= bytes.count }

    private mutating func need(_ n: Int) throws {
        if remaining < n { throw ByteReaderError.outOfBounds(needed: n, available: remaining) }
    }

    public mutating func u8() throws -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func u16() throws -> UInt16 {
        try need(2)
        let v = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        offset += 2
        return v
    }

    public mutating func u24() throws -> UInt32 {
        try need(3)
        let v = UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
        offset += 3
        return v
    }

    public mutating func u32() throws -> UInt32 {
        try need(4)
        let v = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        offset += 4
        return v
    }

    public mutating func u32le() throws -> UInt32 {
        try need(4)
        let v = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        offset += 4
        return v
    }

    public mutating func u64() throws -> UInt64 {
        let hi = try u32()
        let lo = try u32()
        return UInt64(hi) << 32 | UInt64(lo)
    }

    public mutating func double() throws -> Double { Double(bitPattern: try u64()) }

    public mutating func take(_ n: Int) throws -> [UInt8] {
        try need(n)
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }

    public mutating func utf8(_ n: Int) throws -> String {
        let b = try take(n)
        guard let s = String(bytes: b, encoding: .utf8) else { throw ByteReaderError.malformed("invalid utf8") }
        return s
    }

    public mutating func skip(_ n: Int) throws {
        try need(n)
        offset += n
    }

    public func peek() -> UInt8? { isAtEnd ? nil : bytes[offset] }
}

public extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        let s = hexString.replacingOccurrences(of: " ", with: "")
        guard s.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self = out
    }
}
