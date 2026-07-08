import Foundation
import SwiftMsgpack
import XCTest

/// Tests for the zero-copy batch APIs: `encode(_:into:)` appending to a
/// caller-supplied buffer, and `decode(_:from: UnsafeRawBufferPointer)`
/// decoding records in place from a contiguous block.
final class BufferAPITests: XCTestCase {
    private struct User: Codable, Equatable {
        let id: Int
        let name: String
        let tags: [String]
        let createdAt: Date
    }

    private struct ThrowingHolder: Codable {
        let a: Int
        let t: MsgPackTimestamp
    }

    private func makeUser(_ i: Int) -> User {
        User(id: i, name: "user-\(i)", tags: ["a\(i)", "b"], createdAt: Date(timeIntervalSince1970: Double(1_600_000_000 + i)))
    }

    // MARK: - encode(into:)

    func testEncodeIntoMatchesEncode() throws {
        let enc = MsgPackEncoder()
        let user = makeUser(1)
        var buf: [UInt8] = []
        try enc.encode(user, into: &buf)
        XCTAssertEqual(Data(buf), try enc.encode(user))
    }

    func testEncodeIntoAppendsAfterExistingContent() throws {
        let enc = MsgPackEncoder()
        var buf: [UInt8] = [0xDE, 0xAD]
        try enc.encode(makeUser(1), into: &buf)
        let mark = buf.count
        try enc.encode(makeUser(2), into: &buf)
        XCTAssertEqual(Array(buf[0 ..< 2]), [0xDE, 0xAD])
        XCTAssertEqual(Data(buf[2 ..< mark]), try enc.encode(makeUser(1)))
        XCTAssertEqual(Data(buf[mark...]), try enc.encode(makeUser(2)))
    }

    func testEncodeIntoReusesCapacity() throws {
        let enc = MsgPackEncoder()
        var buf: [UInt8] = []
        buf.reserveCapacity(4096)
        let cap = buf.capacity
        for i in 0 ..< 20 {
            buf.removeAll(keepingCapacity: true)
            try enc.encode(makeUser(i), into: &buf)
        }
        XCTAssertEqual(buf.capacity, cap)
    }

    func testEncodeIntoLeavesBufferUntouchedOnError() throws {
        let enc = MsgPackEncoder()
        var buf: [UInt8] = []
        try enc.encode(makeUser(1), into: &buf)
        let before = buf
        // Encoding throws mid-value (after the map header, key and int are
        // already written) because the timestamp has negative nanoseconds.
        XCTAssertThrowsError(try enc.encode(ThrowingHolder(a: 1, t: .init(seconds: 0, nanoseconds: -1)), into: &buf))
        XCTAssertEqual(buf, before)
    }

    // MARK: - decode(from: UnsafeRawBufferPointer)

    func testDecodeFromBufferMatchesDecodeFromData() throws {
        let enc = MsgPackEncoder()
        let user = makeUser(3)
        let payload = try enc.encode(user)
        for dec in [MsgPackDecoder(), MsgPackDecoder(options: .lazyScan)] {
            let fromData = try dec.decode(User.self, from: payload)
            let fromBuffer = try payload.withUnsafeBytes { try dec.decode(User.self, from: $0) }
            XCTAssertEqual(fromBuffer, fromData)
            XCTAssertEqual(fromBuffer, user)
        }
    }

    func testDecodeRecordsInPlaceFromConcatenatedBlock() throws {
        // The NyaruDB2 shape: one coalesced read produces a block holding N
        // records; each record is decoded from a rebased slice, no Data
        // allocation per record.
        let enc = MsgPackEncoder()
        let users = (0 ..< 50).map(makeUser)
        var block: [UInt8] = []
        var ranges: [Range<Int>] = []
        for u in users {
            let start = block.count
            try enc.encode(u, into: &block)
            ranges.append(start ..< block.count)
        }
        for dec in [MsgPackDecoder(), MsgPackDecoder(options: .lazyScan)] {
            let decoded: [User] = try block.withUnsafeBytes { raw in
                try ranges.map { try dec.decode(User.self, from: UnsafeRawBufferPointer(rebasing: raw[$0])) }
            }
            XCTAssertEqual(decoded, users)
        }
    }

    func testDecodeFromBufferSupportsMsgPackRawValue() throws {
        struct Holder: Codable { let id: Int; let payload: MsgPackRawValue }
        let enc = MsgPackEncoder()
        let inner = try enc.encode(["k": [1, 2, 3]])
        let payload = try enc.encode(Holder(id: 9, payload: MsgPackRawValue(inner)))
        let decoded = try payload.withUnsafeBytes { try MsgPackDecoder().decode(Holder.self, from: $0) }
        XCTAssertEqual(decoded.payload.data, inner)
        XCTAssertEqual(try MsgPackDecoder().decode([String: [Int]].self, from: decoded.payload.data), ["k": [1, 2, 3]])
    }

    func testDecodeFromEmptyBufferThrows() {
        let empty = UnsafeRawBufferPointer(start: nil, count: 0)
        XCTAssertThrowsError(try MsgPackDecoder().decode(Int.self, from: empty))
    }

    func testDecodeFromTruncatedBufferThrows() throws {
        let payload = try MsgPackEncoder().encode(makeUser(1))
        try payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let cut = UnsafeRawBufferPointer(rebasing: raw[0 ..< raw.count - 3])
            XCTAssertThrowsError(try MsgPackDecoder().decode(User.self, from: cut))
        }
    }
}
