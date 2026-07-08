import Foundation
import MsgpackBaselineV1

struct Inner: Codable, Equatable { let x: String; let y: [Int] }
struct Nested: Codable, Equatable { let a: Int; let inner: Inner }
struct OptHolder: Codable, Equatable { let present: Int; let missing: Int? }
struct DateHolder: Codable, Equatable { let d: Date }

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

func dumpFixtures() {
    let enc = MsgpackBaselineV1.MsgPackEncoder()
    func line(_ name: String, _ value: some Encodable) {
        let data = (try? enc.encode(value)) ?? Data()
        print("\(name)\t\(hex(data))")
    }
    line("posFixint", 1)
    line("negFixint", -1)
    line("int8", -100)
    line("int16", -1000)
    line("int32", -100_000)
    line("int64", Int64(-5_000_000_000))
    line("uint8", 200)
    line("uint16", 40000)
    line("uint32", UInt32(3_000_000_000))
    line("uint64", UInt64(10_000_000_000_000_000_000))
    line("double", 3.14159)
    line("boolTrue", true)
    line("boolFalse", false)
    line("emptyString", "")
    line("ascii", "hello")
    line("multibyte", "héllo→😀")
    line("emptyArray", [Int]())
    line("emptyMap", [String: Int]())
    line("nested", Nested(a: 1, inner: Inner(x: "hi", y: [1, 2, 3])))
    line("optPresent", OptHolder(present: 7, missing: 42))
    line("optMissing", OptHolder(present: 7, missing: nil))
    line("dateFarPast", DateHolder(d: Date(timeIntervalSinceReferenceDate: -3_000_000_000)))
    line("dateFarFuture", DateHolder(d: Date(timeIntervalSinceReferenceDate: 3_000_000_000)))
}
