import XCTest
@testable import SwiftMsgpack

/// Regression tests for malformed-input handling and decode edge cases.
/// Every input here used to crash, hang, read out of bounds, or silently
/// return a wrong value.
final class RobustnessTests: XCTestCase {
    private let decoders: [(String, MsgPackDecoder)] = [
        ("eager", MsgPackDecoder()),
        ("lazy", MsgPackDecoder(options: .lazyScan)),
    ]

    private func assertThrows<T: Decodable>(_ type: T.Type, _ bytes: [UInt8], line: UInt = #line) {
        for (label, decoder) in decoders {
            XCTAssertThrowsError(try decoder.decode(type, from: Data(bytes)), "expected \(label) decode of \(bytes) to throw", line: line)
        }
    }

    // MARK: - Truncated input (used to read out of bounds)

    func testTruncatedFixedWidthPayloads() {
        assertThrows(UInt64.self, [0xCF]) // uint64 header, no payload
        assertThrows(UInt32.self, [0xCE, 0x01]) // uint32 header, 1 of 4 bytes
        assertThrows(Int64.self, [0xD3, 0x00, 0x00]) // int64 header, 2 of 8 bytes
        assertThrows(Float.self, [0xCA, 0x3F]) // float32 header, 1 of 4 bytes
        assertThrows(Double.self, [0xCB]) // float64 header, no payload
    }

    func testTruncatedVariableLengthPayloads() {
        assertThrows(String.self, [0xD9, 0xFF]) // str8 claims 255 bytes, has 0
        assertThrows(String.self, [0xDA, 0xFF, 0xFF, 0x61]) // str16 claims 65535, has 1
        assertThrows(Data.self, [0xC4, 0x10, 0x00]) // bin8 claims 16 bytes, has 1
        assertThrows(MsgPackTimestamp.self, [0xC7, 0x0C, 0xFF]) // ext8 claims 12 bytes, has 0
        assertThrows(String.self, [0xA5, 0x61, 0x62]) // fixstr claims 5 bytes, has 2
    }

    func testTruncatedContainers() {
        assertThrows([Int].self, [0x92, 0x01]) // fixarray of 2, one element present
        assertThrows([String: Int].self, [0x81, 0xA1, 0x61]) // fixmap of 1, value missing
    }

    // MARK: - Absurd claimed lengths (used to hang / exhaust memory)

    func testHugeClaimedLengthsFailFast() {
        assertThrows([Int].self, [0xDD, 0xFF, 0xFF, 0xFF, 0xFF]) // array32 of ~4B elements
        assertThrows([String: Int].self, [0xDF, 0xFF, 0xFF, 0xFF, 0xFF]) // map32 of ~4B pairs
        assertThrows(String.self, [0xDB, 0xFF, 0xFF, 0xFF, 0xFF]) // str32 of ~4GB
        assertThrows(Data.self, [0xC6, 0xFF, 0xFF, 0xFF, 0xFF]) // bin32 of ~4GB
    }

    // MARK: - Deep nesting (used to overflow the stack)

    func testDeeplyNestedInputDoesNotCrash() {
        let nested = Data(repeating: 0x91, count: 200_000) // 200k nested fixarray(1)
        for (label, decoder) in decoders {
            XCTAssertThrowsError(try decoder.decode(AnyCodable.self, from: nested), "expected \(label) decode to throw")
        }
    }

    func testReasonableNestingStillDecodes() throws {
        var bytes: [UInt8] = Array(repeating: 0x91, count: 100)
        bytes.append(0x01)
        let value = try MsgPackDecoder().decode(AnyCodable.self, from: Data(bytes))
        XCTAssertNotNil(value.base)
    }

    // MARK: - nil into non-optional (used to crash on force unwrap)

    func testNilIntoNonOptionalThrows() {
        assertThrows(Bool.self, [0xC0])
        assertThrows(String.self, [0xC0])
        assertThrows(Double.self, [0xC0])
        assertThrows(Float.self, [0xC0])
        assertThrows(Int.self, [0xC0])
        assertThrows(UInt.self, [0xC0])
    }

    func testNilIntoOptionalDecodesAsNil() throws {
        XCTAssertNil(try MsgPackDecoder().decode(String?.self, from: Data([0xC0])))
        XCTAssertNil(try MsgPackDecoder().decode(Int?.self, from: Data([0xC0])))
    }

    // MARK: - Invalid UTF-8 (used to crash on force unwrap)

    func testInvalidUTF8Throws() {
        assertThrows(String.self, [0xA1, 0xFF])
        assertThrows(String.self, [0xA3, 0xED, 0xA0, 0x80]) // UTF-16 surrogate half
    }

    // MARK: - Integer overflow (used to truncate silently)

    func testIntegerOverflowThrows() {
        assertThrows(Int8.self, [0xCD, 0x01, 0x00]) // 256 as Int8
        assertThrows(UInt8.self, [0xCD, 0x01, 0x00]) // 256 as UInt8
        assertThrows(UInt8.self, [0xFF]) // -1 as UInt8
        assertThrows(UInt64.self, [0xD0, 0xFF]) // -1 (int8 format) as UInt64
        assertThrows(Int64.self, [0xCF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) // UInt64.max as Int64
    }

    func testExactIntegerConversions() throws {
        let decoder = MsgPackDecoder()
        XCTAssertEqual(try decoder.decode(Int8.self, from: Data([0xCC, 0x7F])), 127) // uint8 format into Int8
        XCTAssertEqual(try decoder.decode(UInt8.self, from: Data([0xCC, 0xFF])), 255)
        XCTAssertEqual(try decoder.decode(UInt64.self, from: Data([0xCF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])), UInt64.max)
    }

    // MARK: - Cross-format numeric interop

    func testUnsignedFromSignedFormat() throws {
        let decoder = MsgPackDecoder()
        // int8/int16 formats holding non-negative values decode as unsigned
        XCTAssertEqual(try decoder.decode(UInt.self, from: Data([0xD0, 0x05])), 5)
        XCTAssertEqual(try decoder.decode(UInt16.self, from: Data([0xD1, 0x01, 0x00])), 256)
    }

    func testFloatFromIntegerFormat() throws {
        let decoder = MsgPackDecoder()
        XCTAssertEqual(try decoder.decode(Double.self, from: Data([0x05])), 5.0)
        XCTAssertEqual(try decoder.decode(Float.self, from: Data([0xD0, 0xFB])), -5.0)
    }

    // MARK: - Empty input

    func testEmptyDataThrows() {
        assertThrows(Bool.self, [])
        assertThrows(String.self, [])
    }

    // MARK: - Timestamp edge cases

    func testTimestampNegativeNanosecondsThrows() {
        let ts = MsgPackTimestamp(seconds: 1, nanoseconds: -1)
        XCTAssertThrowsError(try MsgPackEncoder().encode(ts))
    }

    func testTimestampTooLargeNanosecondsThrows() {
        let ts = MsgPackTimestamp(seconds: 1, nanoseconds: 1_000_000_000)
        XCTAssertThrowsError(try MsgPackEncoder().encode(ts))
    }

    func testTimestampSecondsBeyondUInt32RoundTrips() throws {
        // seconds in [2^32, 2^34) with zero nanoseconds used to trap in UInt32()
        let ts = MsgPackTimestamp(seconds: Int64(UInt32.max) + 1, nanoseconds: 0)
        let encoded = try MsgPackEncoder().encode(ts)
        let decoded = try MsgPackDecoder().decode(MsgPackTimestamp.self, from: encoded)
        XCTAssertEqual(decoded, ts)
    }

    func testTimestampRoundTrips() throws {
        let cases: [MsgPackTimestamp] = [
            .init(seconds: 0, nanoseconds: 0), // 32 bit
            .init(seconds: Int64(UInt32.max), nanoseconds: 0), // 32 bit, max
            .init(seconds: 1, nanoseconds: 999_999_999), // 64 bit
            .init(seconds: (1 << 34) - 1, nanoseconds: 1), // 64 bit, max seconds
            .init(seconds: 1 << 34, nanoseconds: 0), // 96 bit
            .init(seconds: -1, nanoseconds: 500), // 96 bit, negative seconds
        ]
        for ts in cases {
            let encoded = try MsgPackEncoder().encode(ts)
            let decoded = try MsgPackDecoder().decode(MsgPackTimestamp.self, from: encoded)
            XCTAssertEqual(decoded, ts, "round trip failed for \(ts)")
        }
    }

    // MARK: - Data slices decode like their copies

    func testDecodeFromDataSlice() throws {
        let payload = try MsgPackEncoder().encode(["a": 1, "b": 2])
        var padded = Data([0x00, 0x01, 0x02])
        padded.append(payload)
        let slice = padded[3...]
        for (label, decoder) in decoders {
            let decoded = try decoder.decode([String: Int].self, from: slice)
            XCTAssertEqual(decoded, ["a": 1, "b": 2], "slice decode failed for \(label)")
        }
    }
}
