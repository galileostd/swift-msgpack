# swift-msgpack

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fnnabeyang%2Fswift-msgpack%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/nnabeyang/swift-msgpack)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fnnabeyang%2Fswift-msgpack%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/nnabeyang/swift-msgpack)

[MessagePack](https://msgpack.io) is an efficient binary serialization format that lets you exchange data among multiple languages like JSON but in a more compact and faster form.
Small integers can be encoded in a single byte, and short strings require only a prefix plus the original byte array.
MessagePack implementations are available in various languages (see the list on https://msgpack.io).
For the specification, see https://github.com/msgpack/msgpack/blob/master/spec.md.

**MessagePack implementation for Swift**  
This repository provides a **MessagePack encoder and decoder for Swift** that integrates with the Swift `Codable` API.

## Features

- Encodes and decodes Swift types using the `Codable` protocol
- Seamless integration with **Swift Package Manager**
- Compatible with **Swift 6**
- Works on **Linux, iOS, and macOS**
- Published under the **MIT License**

## Usage

```swift
import SwiftMsgpack

struct Coordinate: Codable {
    let latitude: Double
    let longitude: Double
}

struct Landmark: Codable {
    let name: String
    let foundingYear: Int
    let location: Coordinate
}

let input = Landmark(
    name: "Mojave Desert",
    foundingYear: 0,
    location: Coordinate(
        latitude: 35.0110079,
        longitude: -115.4821313
    )
)
let encoder = MsgPackEncoder()
let decoder = MsgPackDecoder()
let data = try! encoder.encode(input)
let out = try! decoder.decode(Landmark.self, from: data)
let any = try! decoder.decode(AnyCodable.self, from: data)

print([UInt8](data))
// [131, 164, 110, 97, 109, 101, 173, 77, 111, 106,
//  97, 118, 101, 32, 68, 101, 115, 101, 114, 116,
//  172, 102, 111, 117, 110, 100, 105, 110, 103, 89,
//  101, 97, 114, 0, 168, 108, 111, 99, 97, 116,
//  105, 111, 110, 130, 168, 108, 97, 116, 105, 116,
//  117, 100, 101, 203, 64, 65, 129, 104, 180, 245,
//  63, 179, 169, 108, 111, 110, 103, 105, 116, 117,
//  100, 101, 203, 192, 92, 222, 219, 61, 61, 120,
//  49]

print(out)
// Landmark(
//   name: "Mojave Desert",
//   foundingYear: 0,
//   location: example.Coordinate(
//     latitude: 35.0110079,
//     longitude: -115.4821313
//   )
// )

print(any)
// AnyCodable(
//     [
//         AnyCodable("foundingYear"): AnyCodable(0),
//         AnyCodable("name"): AnyCodable("Mojave Desert"),
//         AnyCodable("location"): AnyCodable(
//             [
//                 AnyCodable("longitude"): AnyCodable(-115.4821313),
//                 AnyCodable("latitude"): AnyCodable(35.0110079),
//             ]
//         ),
//     ]
// )
```

## Performance

`MsgPackDecoder` has an opt-in lazy mode that defers walking the contents of MessagePack arrays and maps until the Codable target asks for them. Pass `.lazyScan` when constructing the decoder:

```swift
let decoder = MsgPackDecoder(options: .lazyScan)
let value = try decoder.decode(SparseStruct.self, from: largePayload)
```

The result is bit-identical to the default eager mode; only the cost profile of `decode(_:from:)` changes.

**When `.lazyScan` helps**

- Decoding a small subset of fields from a large map. Picking 3 keys from a 1000-key payload measures roughly 91% lower wall clock and 99% fewer allocations than the eager path.
- Sparse `struct` targets against dense maps scale similarly as the source grows (about 10% faster at size 10, around 90% at size 1000).

**When the eager default is preferable**

- Array payloads where every element is read. The per-element cursor allocation adds about 13% wall clock and 30% extra `malloc` calls on `[Item]` x 1000.
- Fully materialised dictionaries (`[String: String]`), nested map-of-map round trips, and `AnyCodable` are within ±5% of eager — either mode is fine.

**Safety**

- The lazy IR borrows the lifetime of the `Data` passed to `decode(_:from:)`. Do not retain the decoder or container objects past the call — the cursors hold raw pointers that are only valid while the decode call is on the stack.
- `MsgPackDecoder` is not `Sendable`; do not share a single decoder across threads.

## Installation

### Swift Package Manager

To use swift-msgpack in your Swift project, add it as a dependency in your Package.swift:

```swift
let package = Package(
    // name, platforms, products, etc.
    dependencies: [
        // other dependencies
        .package(url: "https://github.com/nnabeyang/swift-msgpack", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(name: "<executable-target-name>", dependencies: [
            // other dependencies
                .product(name: "SwiftMsgpack", package: "swift-msgpack"),
        ]),
        // other targets
    ]
)
```

### CocoaPods

Add the following to your Podfile:

```terminal
pod 'SwiftMessagePack'
```
## Benchmarks

This fork tracks encoder/decoder performance for the NyaruDB2 database engine.
The `bench` executable target measures the coder pair against the frozen
`v1.3.0` baseline (vendored in `Sources/MsgpackBaselineV1`) and Foundation
JSON as an external yardstick.

Run it with:

```terminal
swift run -c release bench
```

The reference shape mirrors NyaruDB2's harness document:

```swift
struct HarnessUser: Codable {
    let id: Int
    let name: String        // ~12 chars
    let email: String       // ~20 chars
    let age: Int
    let city: String        // ~8 chars, 10 distinct values
    let createdAt: Date
    let tags: [String]      // 0–3 short strings
}
```

**Ship gate (NyaruDB2 roadmap):** a change to the coders merges only if it is
≥1.5× faster on decode **or** ≥1.3× faster on encode versus `v1.3.0` on the
reference shape, with the compatibility/robustness suite green.

### P2.1 streaming encoder — landed (10,000 docs, best-of-15, Apple Silicon, Swift 6.2.4)

Reference shape `HarnessUser`, `current` = streaming encoder vs frozen `v1.3.0`:

| Operation | v1.3.0 (µs/op) | current (µs/op) | Foundation JSON (µs/op) | current vs v1.3.0 |
|-----------|---------------:|----------------:|------------------------:|------------------:|
| encode            | 4.513 | 2.224 | 2.912 | **2.03×** |
| decode (eager)    | 2.840 | 2.678 | 2.644 | 1.06× |
| decode (lazyScan) | 3.322 | 3.352 | 2.644 | 0.99× |

Avg payload: msgpack 115.8 B, JSON 145.0 B (byte-identical to v1.3.0 — headers
stay minimal).

**Result:** encode is **2.03× faster than v1.3.0** (gate: ≥1.3×) and now beats
Foundation JSON encode. Decode is unchanged (P2.1 is encoder-only; ±noise). The
old path built a full `MsgPackEncodedValue` tree per document and walked it
twice (`MsgPackValue.Writer.byteSize` then `writeValue`); the streaming encoder
(`MsgPackWriteBuffer`) writes MessagePack directly into one growable buffer.

String-heavy variant (5 strings): encode **2.15× faster** (2.115 → 0.983 µs/op).

Design notes:
- Minimal size-class headers are preserved (byte-identical output, all
  exact-hex `EncodeTests` pass) via in-place count patching, growing a header
  with a one-time `memmove` only when a container crosses 16 or 65536 entries.
- Zero heap allocations per leaf field: `Int`/`UInt`/`Float`/`Double`/`Bool`/
  `String`/keys are written straight into the buffer (`String` via
  `string.utf8`, no `Data` intermediate). One `_MsgPackEncoder` instance is
  reused for every nested value within a top-level `encode` call.
- Full cross-version + robustness suite green (§5), so v1.3.0 databases keep
  decoding and new output decodes under v1.3.0.

### §3 Date-cost probe (single-field structs, v1.3.0)

| Field | encode (µs/op) | decode (µs/op) | payload (B) |
|-------|---------------:|---------------:|------------:|
| Date  | 1.229 | 0.800 | 20 |
| Int   | 0.843 | 0.566 | 8 |

`Date` costs only ~1.4× an `Int` (not 10–50×). `Date` encodes as a plain
`float64` (9-byte value) via standard `Codable`, **not** the msgpack timestamp
extension — there is no per-call `Data` packing to eliminate, and any fast path
would change the wire format. **Verdict: no Date fast path; §3 is a measurement,
not an optimization target.**

### String-heavy variant (5 strings)

| Operation | v1.3.0 (µs/op) | current (µs/op) | current vs v1.3.0 |
|-----------|---------------:|----------------:|------------------:|
| encode         | 2.413 | 2.298 | 1.05× |
| decode (eager) | 1.431 | 1.409 | 1.02× |

### P2.2 decoder — byte-compared keys, and why ≥1.5× decode is not reachable here

The `.lazyScan` keyed decoder (`LazyMapCursor`) no longer allocates a `String`
per on-wire map key or builds a key→index dictionary: keys are matched by raw
UTF-8 bytes against the requested key, keeping the existing sequential
walk-and-cache behaviour. Effect, isolated on a scalar-only struct:

| Shape (decode, lazyScan) | v1.3.0 (µs/op) | current (µs/op) | current vs v1.3.0 |
|--------------------------|---------------:|----------------:|------------------:|
| 7×`Int` struct (no str/Date/array) | 1.731 | 1.506 | **1.15×** |
| `HarnessUser` (3 str + Date + [String]) | 3.005 | 3.139 | ~1.0× |

**The ≥1.5× decode target is not achievable on `HarnessUser`.** Isolation shows
the decoder's structural path is already fast (7 ints: 1.15× faster); the
remaining ~1.6 µs is materialising the struct's values — 5 `String`
allocations plus `Date`/`[String]` sub-decoders — which is inherent to the
`Codable` contract (C1: the document *is* a struct of `String`s). For scale:
Foundation's `JSONDecoder` decodes the same shape at ~2.7 µs, only ~1.1× faster
than v1.3.0's msgpack decoder — the `String` allocation floor bounds everyone.
Beating it by 1.5× would require not materialising the strings, i.e. changing
the document contract.

**Consequence for NyaruDB2:** the overall ship gate (≥1.5× decode **or** ≥1.3×
encode) is met by P2.1 (encode ~1.9×). The real lever for the Query gap is
reading/decoding *fewer* bytes and *fewer* fields (roadmap P1.1 coalesced reads
and P1.6 projections), not squeezing more from a full-struct decode that is
already allocation-bound.

## License

swift-msgpack is published under the MIT License. See the LICENSE file for details.

## Author
[Noriaki Watanabe@nnabeyang](https://bsky.app/profile/did:plc:bnh3bvyqr3vzxyvjdnrrusbr)

## About

swift-msgpack is a library of MessagePack encoder & decoder for Swift based on Codable, following the same design principles as Swift’s built-in JSON support.
