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

### Results — full optimization pass (10,000 docs, best-of-15, Apple Silicon, Swift 6.2.4)

Reference shape `HarnessUser`, `current` vs frozen `v1.3.0`:

| Operation | v1.3.0 (µs/op) | current (µs/op) | Foundation JSON (µs/op) | current vs v1.3.0 |
|-----------|---------------:|----------------:|------------------------:|------------------:|
| encode            | 4.619 | 2.297 | 2.971 | **2.01×** |
| decode (eager)    | 2.828 | 1.855 | 2.866 | **1.52×** |
| decode (lazyScan) | 3.166 | 2.221 | 2.866 | **1.43×** |

Avg payload: msgpack 115.8 B, JSON 145.0 B (byte-identical to v1.3.0 — headers
stay minimal). Both gates cleared: encode ≥1.3× **and** eager decode ≥1.5×.
Every row also beats Foundation JSON.

String-heavy variant (5 strings): encode **2.34×** (2.35 → 1.00 µs/op), decode
eager **1.69×** (1.34 → 0.79 µs/op). Scalar-only 7×`Int` struct on lazyScan:
**1.87×** (1.68 → 0.90 µs/op).

What landed, in order:

1. **Streaming encoder (`MsgPackWriteBuffer`).** The old path built a full
   `MsgPackEncodedValue` tree per document and walked it twice (`byteSize`
   then `writeValue`); the encoder now writes MessagePack directly into one
   growable buffer. Minimal size-class headers are preserved (byte-identical
   output) via in-place count patching, growing a header with a one-time
   `memmove` only when a container crosses 16 or 65536 entries. Zero heap
   allocations per leaf field; one `_MsgPackEncoder` instance is reused for
   every nested value.
2. **Span-carrying `MsgPackValue` struct.** The scanned IR was an enum whose
   `indirect case raw(from:count:_)` boxed *every* value on the heap to
   remember its byte span (~20 boxes per document). It is now a struct
   `{ kind, from, count }` — the span travels inline and building the tree
   allocates only the container arrays.
3. **Byte-compared map keys on both decode paths.** Neither the lazy
   (`LazyMapCursor`) nor the eager (`EagerMapCursor`) keyed container
   allocates a `String` per on-wire key or builds a key dictionary up front:
   keys are matched by raw UTF-8 comparison against a sequential cursor
   (declaration-order decoding matches immediately). The eager cursor builds
   a keep-first `String` index once if lookups go out of order, so large or
   adversarial maps keep O(1) behaviour.
4. **Lazily materialised coding paths.** Nested values carried
   `codingPath + [key]` arrays (and "Index N" keys) built eagerly on every
   dispatch; paths are now `(basePath, tail)` pairs appended only when an
   error context or a `codingPath` read actually needs them. Error payloads
   are unchanged.
5. **Zero-copy batch APIs** for NyaruDB2's batch paths:
   `encode(_:into: inout [UInt8])` appends to a caller-supplied buffer
   (capacity reused across calls, buffer untouched on error) and
   `decode(_:from: UnsafeRawBufferPointer)` decodes a record in place from a
   rebased slice of a coalesced read — no `Data` per record in either
   direction (~1.05× in isolation; the point is removing per-record
   allocations inside `appendBatch`/`readBatch` loops).

Compatibility is guarded by the cross-version suite (golden v1.3.0 fixtures,
live round-trips in both directions, map-key declaration order) plus the
robustness suite — all green.

### §3 Date-cost probe (single-field structs, v1.3.0)

| Field | encode (µs/op) | decode (µs/op) | payload (B) |
|-------|---------------:|---------------:|------------:|
| Date  | 1.188 | 0.767 | 20 |
| Int   | 0.775 | 0.546 | 8 |

`Date` costs only ~1.4× an `Int` (not 10–50×). `Date` encodes as a plain
`float64` (9-byte value) via standard `Codable`, **not** the msgpack timestamp
extension — there is no per-call `Data` packing to eliminate, and any fast path
would change the wire format. **Verdict: no Date fast path; §3 is a measurement,
not an optimization target.**

### What was measured and rejected

- **Unsafe manual write buffer** (replacing `[UInt8]` appends with
  uninitialized-capacity writes): encode already clears its gate at 2.01× and
  beats JSON; the remaining append bounds checks are worth ~10–20% at best,
  and a manual buffer breaks the zero-copy `encode(into:)` array-swap
  contract. Not worth the memory-safety risk.
- **`withUTF8` + `memcmp` key comparison**: measured *slower* than a plain
  byte loop for typical short keys (the `withUTF8` setup dominates); the byte
  loop stayed.
- **Date fast path** (§3 above): wire-format change, no real cost to remove.

**Consequence for NyaruDB2:** both ship gates are met (encode 2.01×, decode
1.52×), and the coders now sit at the `String`-allocation floor that bounds
every Codable decoder. The next lever for the Query gap is reading/decoding
*fewer* bytes and *fewer* fields (roadmap P1.1 coalesced reads and P1.6
projections) — wire those to `decode(_:from: UnsafeRawBufferPointer)` and
`encode(_:into:)` from this pass.

## License

swift-msgpack is published under the MIT License. See the LICENSE file for details.

## Author
[Noriaki Watanabe@nnabeyang](https://bsky.app/profile/did:plc:bnh3bvyqr3vzxyvjdnrrusbr)

## About

swift-msgpack is a library of MessagePack encoder & decoder for Swift based on Codable, following the same design principles as Swift’s built-in JSON support.
