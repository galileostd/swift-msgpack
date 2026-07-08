import Foundation
import MsgpackBaselineV1
import SwiftMsgpack
import XCTest

/// §5 compatibility & robustness gate for the NyaruDB2 performance track.
///
/// Guards format-level compatibility across the v1.3.0 baseline (vendored as
/// `MsgpackBaselineV1`) and the current `SwiftMsgpack`:
///  1. Static golden fixtures captured from v1.3.0 must decode under the
///     current decoder to the expected value.
///  2. Live cross-version round-trips: bytes from v1.3.0 decode with the
///     current decoder, and current bytes decode under v1.3.0 — both also as
///     mid-buffer `Data` slices.
///  3. Map key order equals Codable declaration order (NyaruDB2's skip-scan
///     `MsgPackExtractor` depends on it).
final class CompatibilityTests: XCTestCase {
    private struct Inner: Codable, Equatable { let x: String; let y: [Int] }
    private struct Nested: Codable, Equatable { let a: Int; let inner: Inner }
    private struct OptHolder: Codable, Equatable { let present: Int; let missing: Int? }
    private struct DateHolder: Codable, Equatable { let d: Date }

    private func bytes(_ hex: String) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i ..< j], radix: 16)!)
            i = j
        }
        return Data(out)
    }

    // MARK: - 1. Static golden fixtures (captured from v1.3.0)

    /// The current decoder must read every v1.3.0-produced blob to the exact
    /// expected value. If the vendored baseline is ever tampered with, these
    /// pinned wire bytes still catch a decoder regression.
    func testGoldenFixturesDecodeUnderCurrentDecoder() throws {
        let dec = SwiftMsgpack.MsgPackDecoder()
        func g<T: Decodable & Equatable>(_ hex: String, _ expected: T) throws {
            XCTAssertEqual(try dec.decode(T.self, from: bytes(hex)), expected, "golden \(hex)")
        }
        try g("01", 1)
        try g("ff", -1)
        try g("d09c", -100)
        try g("d1fc18", -1000)
        try g("d2fffe7960", -100_000)
        try g("d3fffffffed5fa0e00", Int64(-5_000_000_000))
        try g("d100c8", 200)
        try g("d200009c40", 40000)
        try g("ceb2d05e00", UInt32(3_000_000_000))
        try g("cf8ac7230489e80000", UInt64(10_000_000_000_000_000_000))
        try g("cb400921f9f01b866e", 3.14159)
        try g("c3", true)
        try g("c2", false)
        try g("a0", "")
        try g("a568656c6c6f", "hello")
        try g("ad68c3a96c6c6fe28692f09f9880", "héllo→😀")
        try g("90", [Int]())
        try g("80", [String: Int]())
        try g("82a16101a5696e6e657282a178a26869a17993010203", Nested(a: 1, inner: Inner(x: "hi", y: [1, 2, 3])))
        try g("82a770726573656e7407a76d697373696e672a", OptHolder(present: 7, missing: 42))
        try g("81a770726573656e7407", OptHolder(present: 7, missing: nil))
        try g("81a164cbc1e65a0bc0000000", DateHolder(d: Date(timeIntervalSinceReferenceDate: -3_000_000_000)))
        try g("81a164cb41e65a0bc0000000", DateHolder(d: Date(timeIntervalSinceReferenceDate: 3_000_000_000)))
    }

    // MARK: - 2. Live cross-version round-trips

    private let oldEnc = MsgpackBaselineV1.MsgPackEncoder()
    private let oldDec = MsgpackBaselineV1.MsgPackDecoder()
    private let oldDecLazy = MsgpackBaselineV1.MsgPackDecoder(options: .lazyScan)
    private let newEnc = SwiftMsgpack.MsgPackEncoder()
    private let newDec = SwiftMsgpack.MsgPackDecoder()
    private let newDecLazy = SwiftMsgpack.MsgPackDecoder(options: .lazyScan)

    private func slice(_ data: Data) -> Data {
        var padded = Data([0x00, 0x01, 0x02])
        padded.append(data)
        return padded[3...]
    }

    private func crossVersion<T: Codable & Equatable>(_ value: T, _ type: T.Type, line: UInt = #line) throws {
        // v1.3.0 bytes decoded by the current decoder (eager + lazy, direct + slice).
        let old = try oldEnc.encode(value)
        XCTAssertEqual(try newDec.decode(type, from: old), value, "old→new eager", line: line)
        XCTAssertEqual(try newDecLazy.decode(type, from: old), value, "old→new lazy", line: line)
        XCTAssertEqual(try newDec.decode(type, from: slice(old)), value, "old→new eager slice", line: line)
        XCTAssertEqual(try newDecLazy.decode(type, from: slice(old)), value, "old→new lazy slice", line: line)
        // Current bytes decoded under v1.3.0 (eager + lazy, direct + slice).
        let new = try newEnc.encode(value)
        XCTAssertEqual(try oldDec.decode(type, from: new), value, "new→old eager", line: line)
        XCTAssertEqual(try oldDecLazy.decode(type, from: new), value, "new→old lazy", line: line)
        XCTAssertEqual(try oldDec.decode(type, from: slice(new)), value, "new→old eager slice", line: line)
        XCTAssertEqual(try oldDecLazy.decode(type, from: slice(new)), value, "new→old lazy slice", line: line)
    }

    func testCrossVersionScalarsAndContainers() throws {
        try crossVersion(1, Int.self)
        try crossVersion(-1, Int.self)
        try crossVersion(Int64(-5_000_000_000), Int64.self)
        try crossVersion(UInt64(10_000_000_000_000_000_000), UInt64.self)
        try crossVersion(3.14159, Double.self)
        try crossVersion(Float(-2.5), Float.self)
        try crossVersion(true, Bool.self)
        try crossVersion("", String.self)
        try crossVersion("héllo→😀", String.self)
        try crossVersion([Int](), [Int].self)
        try crossVersion([String: Int](), [String: Int].self)
        try crossVersion(Nested(a: 1, inner: Inner(x: "hi", y: [1, 2, 3])), Nested.self)
        try crossVersion(OptHolder(present: 7, missing: nil), OptHolder.self)
        try crossVersion(OptHolder(present: 7, missing: 42), OptHolder.self)
        try crossVersion(DateHolder(d: Date(timeIntervalSinceReferenceDate: -3_000_000_000)), DateHolder.self)
        try crossVersion(DateHolder(d: Date(timeIntervalSinceReferenceDate: 3_000_000_000)), DateHolder.self)
    }

    /// 16-bit and 32-bit container-size classes and long strings (str8/16/32).
    func testCrossVersionSizeClasses() throws {
        try crossVersion(String(repeating: "x", count: 200), String.self) // str8
        try crossVersion(String(repeating: "y", count: 300), String.self) // str16
        try crossVersion(String(repeating: "z", count: 70000), String.self) // str32
        try crossVersion(Array(0 ..< 300), [Int].self) // array16
        try crossVersion(Array(0 ..< 70000), [Int].self) // array32
        var map16 = [String: Int]()
        for i in 0 ..< 300 {
            map16["k\(i)"] = i
        } // map16
        try crossVersion(map16, [String: Int].self)
    }

    // MARK: - 3. Map key order == declaration order (protects skip-scan)

    /// Reads top-level map keys in wire order without depending on decoder
    /// internals, mirroring what NyaruDB2's `MsgPackExtractor` relies on.
    private func topLevelKeys(_ data: Data) -> [String] {
        var b = [UInt8](data)
        var i = 0
        func u(_ n: Int) -> Int { var v = 0; for _ in 0 ..< n {
            v = (v << 8) | Int(b[i]); i += 1
        }; return v }
        func skip() {
            let c = b[i]; i += 1
            switch c {
            case 0x00 ... 0x7F, 0xE0 ... 0xFF, 0xC0, 0xC2, 0xC3: break
            case 0xCC, 0xD0: i += 1
            case 0xCD, 0xD1: i += 2
            case 0xCA, 0xCE, 0xD2: i += 4
            case 0xCB, 0xCF, 0xD3: i += 8
            case 0xA0 ... 0xBF: i += Int(c & 0x1F)
            case 0xD9, 0xC4: i += u(1)
            case 0xDA, 0xC5: i += u(2)
            case 0xDB, 0xC6: i += u(4)
            case 0x90 ... 0x9F: for _ in 0 ..< Int(c & 0x0F) {
                    skip()
                }
            case 0xDC: let n = u(2); for _ in 0 ..< n {
                    skip()
                }
            case 0xDD: let n = u(4); for _ in 0 ..< n {
                    skip()
                }
            case 0x80 ... 0x8F: for _ in 0 ..< Int(c & 0x0F) {
                    skip(); skip()
                }
            case 0xDE: let n = u(2); for _ in 0 ..< n {
                    skip(); skip()
                }
            case 0xDF: let n = u(4); for _ in 0 ..< n {
                    skip(); skip()
                }
            case 0xD4: i += 2
            case 0xD5: i += 3
            case 0xD6: i += 5
            case 0xD7: i += 9
            case 0xD8: i += 17
            case 0xC7: let n = u(1); i += 1 + n
            case 0xC8: let n = u(2); i += 1 + n
            case 0xC9: let n = u(4); i += 1 + n
            default: break
            }
        }
        func readString() -> String {
            let c = b[i]; i += 1
            let len: Int
            switch c {
            case 0xA0 ... 0xBF: len = Int(c & 0x1F)
            case 0xD9: len = u(1)
            case 0xDA: len = u(2)
            case 0xDB: len = u(4)
            default: return ""
            }
            let s = String(decoding: b[i ..< i + len], as: UTF8.self); i += len
            return s
        }
        let header = b[i]; i += 1
        let pairs: Int
        switch header {
        case 0x80 ... 0x8F: pairs = Int(header & 0x0F)
        case 0xDE: pairs = u(2)
        case 0xDF: pairs = u(4)
        default: return []
        }
        var keys = [String]()
        for _ in 0 ..< pairs {
            keys.append(readString()); skip()
        }
        return keys
    }

    func testMapKeyOrderMatchesDeclarationOrder() throws {
        let user = HarnessUser(
            id: 1, name: "Ada Lovelace", email: "ada@example.com",
            age: 36, city: "London",
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            tags: ["a", "b"]
        )
        let expected = ["id", "name", "email", "age", "city", "createdAt", "tags"]
        XCTAssertEqual(try topLevelKeys(newEnc.encode(user)), expected, "current encoder key order")
        XCTAssertEqual(try topLevelKeys(oldEnc.encode(user)), expected, "v1.3.0 encoder key order")
    }
}

private struct HarnessUser: Codable, Equatable {
    let id: Int
    let name: String
    let email: String
    let age: Int
    let city: String
    let createdAt: Date
    let tags: [String]
}
