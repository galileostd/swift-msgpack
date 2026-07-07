import Foundation

public struct MsgPackTimestamp: Equatable {
    public var seconds: Int64
    public var nanoseconds: Int32
    enum CodingKeys: CodingKey {
        case seconds
        case nanoseconds
    }

    public init(seconds: Int64, nanoseconds: Int32) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }
}

extension MsgPackTimestamp: MsgPackCodable {
    public init(msgPack data: Data) throws {
        let n = data.count
        switch n {
        case 4: // timestamp 32 bit
            seconds = Int64(UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            nanoseconds = 0
        case 8: // timestamp 64 bit
            let number = UInt64(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
            seconds = Int64(number & (1 << 34 - 1))
            nanoseconds = Int32(number >> 34)
        case 12: // timestamp 96 bit
            nanoseconds = Int32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
            seconds = Int64(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) })
        default:
            throw MsgPackDecodingError.dataCorrupted
        }
    }

    public var type: Int8 { -1 }
    public func encodeMsgPack() throws -> [UInt8] {
        guard nanoseconds >= 0, nanoseconds < 1_000_000_000 else {
            throw EncodingError.invalidValue(self, .init(
                codingPath: [],
                debugDescription: "MsgPackTimestamp nanoseconds must be in 0..<1_000_000_000, got \(nanoseconds)."
            ))
        }
        if seconds >> 34 == 0 {
            if nanoseconds == 0, seconds <= UInt32.max { // timestamp 32 bit
                var bytes: [UInt8] = []
                UInt32(seconds).appendBigEndian(to: &bytes)
                return bytes
            }
            // timestamp 64 bit
            let data = UInt64(nanoseconds) << 34 | UInt64(seconds)
            var bytes: [UInt8] = []
            data.appendBigEndian(to: &bytes)
            return bytes
        }
        var bytes: [UInt8] = []
        nanoseconds.appendBigEndian(to: &bytes)
        seconds.appendBigEndian(to: &bytes)
        return bytes
    }
}
