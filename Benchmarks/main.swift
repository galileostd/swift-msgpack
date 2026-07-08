import Foundation
import MsgpackBaselineV1
import SwiftMsgpack

if CommandLine.arguments.contains("fixtures") {
    dumpFixtures()
    exit(0)
}

func measure(trials: Int = 15, warmup: Int = 5, _ body: () throws -> Int) rethrows -> Double {
    for _ in 0 ..< warmup {
        _ = try body()
    }
    var best = Double.greatestFiniteMagnitude
    for _ in 0 ..< trials {
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try body()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
        best = min(best, elapsed)
    }
    return best
}

struct Row {
    let label: String
    let baseline: Double
    let new: Double
    let json: Double
}

func fmtNs(_ ns: Double, ops: Int) -> String {
    String(format: "%.3f", ns / Double(ops) / 1000.0)
}

func table(_ rows: [Row], ops: Int) -> String {
    var out = "| Operation | v1.3.0 (µs/op) | current (µs/op) | Foundation JSON (µs/op) | current vs v1.3.0 |\n"
    out += "|-----------|---------------:|----------------:|------------------------:|------------------:|\n"
    for r in rows {
        let speedup = r.baseline / r.new
        out += "| \(r.label) | \(fmtNs(r.baseline, ops: ops)) | \(fmtNs(r.new, ops: ops)) | \(fmtNs(r.json, ops: ops)) | \(String(format: "%.2fx", speedup)) |\n"
    }
    return out
}

let count = 10000
let users = makeUsers(count)

// Encoders/decoders. Fresh instances, reused within a batch (per §4).
let baseEnc = MsgpackBaselineV1.MsgPackEncoder()
let newEnc = SwiftMsgpack.MsgPackEncoder()
let jsonEnc = JSONEncoder()

// Shared msgpack payloads (encoded by v1.3.0) so both decoders work on identical bytes.
let msgpackPayloads = try users.map { try baseEnc.encode($0) }
let jsonPayloads = try users.map { try jsonEnc.encode($0) }

func encodeBench<E>(_ enc: E, _ f: (E, HarnessUser) throws -> Data) rethrows -> Double {
    try measure {
        var acc = 0
        for u in users {
            acc &+= try f(enc, u).count
        }
        return acc
    }
}

func decodeBench<D>(_ dec: D, _ payloads: [Data], _ f: (D, Data) throws -> HarnessUser) rethrows -> Double {
    try measure {
        var acc = 0
        for p in payloads {
            acc &+= try f(dec, p).id
        }
        return acc
    }
}

// --- Encode ---
let encBase = try encodeBench(baseEnc) { try $0.encode($1) }
let encNew = try encodeBench(newEnc) { try $0.encode($1) }
let encJSON = try encodeBench(jsonEnc) { try $0.encode($1) }

// --- Decode (eager) ---
let baseDec = MsgpackBaselineV1.MsgPackDecoder()
let newDec = SwiftMsgpack.MsgPackDecoder()
let jsonDec = JSONDecoder()
let decBase = try decodeBench(baseDec, msgpackPayloads) { try $0.decode(HarnessUser.self, from: $1) }
let decNew = try decodeBench(newDec, msgpackPayloads) { try $0.decode(HarnessUser.self, from: $1) }
let decJSON = try decodeBench(jsonDec, jsonPayloads) { try $0.decode(HarnessUser.self, from: $1) }

// --- Decode (lazyScan — the path NyaruDB2's decodeBatch uses) ---
let baseDecLazy = MsgpackBaselineV1.MsgPackDecoder(options: .lazyScan)
let newDecLazy = SwiftMsgpack.MsgPackDecoder(options: .lazyScan)
let decBaseLazy = try decodeBench(baseDecLazy, msgpackPayloads) { try $0.decode(HarnessUser.self, from: $1) }
let decNewLazy = try decodeBench(newDecLazy, msgpackPayloads) { try $0.decode(HarnessUser.self, from: $1) }

let mainRows = [
    Row(label: "encode", baseline: encBase, new: encNew, json: encJSON),
    Row(label: "decode (eager)", baseline: decBase, new: decNew, json: decJSON),
    Row(label: "decode (lazyScan)", baseline: decBaseLazy, new: decNewLazy, json: decJSON),
]

print("## Reference shape: HarnessUser (\(count) docs)\n")
print(table(mainRows, ops: count))
let avgBytes = Double(msgpackPayloads.reduce(0) { $0 + $1.count }) / Double(count)
let avgJSON = Double(jsonPayloads.reduce(0) { $0 + $1.count }) / Double(count)
print(String(format: "Avg payload: msgpack %.1f B, JSON %.1f B\n", avgBytes, avgJSON))

// --- §3 Date cost probe: Date-only vs Int-only ---
let dateVals = (0 ..< count).map { DateOnly(createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double($0))) }
let intVals = (0 ..< count).map { IntOnly(value: $0) }
let dPayloads = try dateVals.map { try baseEnc.encode($0) }
let iPayloads = try intVals.map { try baseEnc.encode($0) }

func probeEnc<T: Encodable>(_ vals: [T], _ enc: MsgpackBaselineV1.MsgPackEncoder) throws -> Double {
    try measure {
        var acc = 0
        for v in vals {
            acc &+= try enc.encode(v).count
        }
        return acc
    }
}

let encDate = try probeEnc(dateVals, baseEnc)
let encInt = try probeEnc(intVals, baseEnc)
let decDate = try measure { var a = 0; for p in dPayloads {
    try a &+= Int(baseDec.decode(DateOnly.self, from: p).createdAt.timeIntervalSinceReferenceDate)
}; return a }
let decInt = try measure { var a = 0; for p in iPayloads {
    a &+= try baseDec.decode(IntOnly.self, from: p).value
}; return a }

print("## §3 Date-cost probe (v1.3.0, single-field structs)\n")
print("| Field | encode (µs/op) | decode (µs/op) | payload (B) |")
print("|-------|---------------:|---------------:|------------:|")
print("| Date  | \(fmtNs(encDate, ops: count)) | \(fmtNs(decDate, ops: count)) | \(dPayloads[0].count) |")
print("| Int   | \(fmtNs(encInt, ops: count)) | \(fmtNs(decInt, ops: count)) | \(iPayloads[0].count) |")
print("")

// --- String-heavy variant ---
let strVals = makeStringHeavy(count)
let strPayloads = try strVals.map { try baseEnc.encode($0) }
let encStrBase = try measure { var a = 0; for v in strVals {
    a &+= try baseEnc.encode(v).count
}; return a }
let encStrNew = try measure { var a = 0; for v in strVals {
    a &+= try newEnc.encode(v).count
}; return a }
let decStrBase = try measure { var a = 0; for p in strPayloads {
    a &+= try baseDec.decode(StringHeavy.self, from: p).a.count
}; return a }
let decStrNew = try measure { var a = 0; for p in strPayloads {
    a &+= try newDec.decode(StringHeavy.self, from: p).a.count
}; return a }

print("## String-heavy variant (5 strings, \(count) docs)\n")
print(table([
    Row(label: "encode", baseline: encStrBase, new: encStrNew, json: 0),
    Row(label: "decode (eager)", baseline: decStrBase, new: decStrNew, json: 0),
], ops: count))

// --- Decode cost isolation: 7-int struct (no strings/Date/array) vs HarnessUser ---
struct SevenInts: Codable, Equatable {
    let a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int
}

let ints = (0 ..< count).map { SevenInts(a: $0, b: $0, c: $0, d: $0, e: $0, f: $0, g: $0) }
let intStructPayloads = try ints.map { try baseEnc.encode($0) }
let baseDecLazy2 = MsgpackBaselineV1.MsgPackDecoder(options: .lazyScan)
let newDecLazy2 = SwiftMsgpack.MsgPackDecoder(options: .lazyScan)
let di7Base = try measure { var a = 0; for p in intStructPayloads {
    a &+= try baseDecLazy2.decode(SevenInts.self, from: p).a
}; return a }
let di7New = try measure { var a = 0; for p in intStructPayloads {
    a &+= try newDecLazy2.decode(SevenInts.self, from: p).a
}; return a }

print("## Decode cost isolation (lazyScan, \(count) docs)\n")
print("| Shape | v1.3.0 (µs/op) | current (µs/op) |")
print("|-------|---------------:|----------------:|")
print("| 7×Int struct (no str/Date/array) | \(fmtNs(di7Base, ops: count)) | \(fmtNs(di7New, ops: count)) |")
print("| HarnessUser (3 str + Date + [String]) | \(fmtNs(decBaseLazy, ops: count)) | \(fmtNs(decNewLazy, ops: count)) |")
print("")

// --- Zero-copy batch APIs (current only; the batch shape NyaruDB2 uses) ---
// encode: one Data per doc vs appending into one reused contiguous buffer.
let encPerDoc = try measure { var a = 0; for u in users {
    a &+= try newEnc.encode(u).count
}; return a }
var batchBuf: [UInt8] = []
batchBuf.reserveCapacity(count * 160)
let encIntoBatch = try measure {
    batchBuf.removeAll(keepingCapacity: true)
    for u in users {
        try newEnc.encode(u, into: &batchBuf)
    }
    return batchBuf.count
}

// decode: one contiguous block of records, decoded per record either by
// slicing a Data per record or in place via UnsafeRawBufferPointer.
var blockRanges: [Range<Int>] = []
blockRanges.reserveCapacity(count)
var block: [UInt8] = []
for u in users {
    let s = block.count
    try newEnc.encode(u, into: &block)
    blockRanges.append(s ..< block.count)
}

let blockData = Data(block)
let decDataSlices = try measure { var a = 0; for r in blockRanges {
    a &+= try newDec.decode(HarnessUser.self, from: blockData.subdata(in: r)).id
}; return a }
let decBufferSlices = try block.withUnsafeBytes { raw in
    try measure { var a = 0; for r in blockRanges {
        a &+= try newDec.decode(HarnessUser.self, from: UnsafeRawBufferPointer(rebasing: raw[r])).id
    }; return a }
}

print("## Zero-copy batch APIs (current, \(count) docs)\n")
print("| Operation | Data per record (µs/op) | zero-copy (µs/op) | speedup |")
print("|-----------|------------------------:|------------------:|--------:|")
print("| encode -> Data vs encode(into: reused buffer) | \(fmtNs(encPerDoc, ops: count)) | \(fmtNs(encIntoBatch, ops: count)) | \(String(format: "%.2fx", encPerDoc / encIntoBatch)) |")
print("| decode Data-slice vs decode(from: bytes) | \(fmtNs(decDataSlices, ops: count)) | \(fmtNs(decBufferSlices, ops: count)) | \(String(format: "%.2fx", decDataSlices / decBufferSlices)) |")
