import Foundation

final class LazyArrayCursor {
    let scanner: MsgPackScanner
    let start: UnsafeRawPointer
    let count: Int

    private let positions: [UnsafeRawPointer]
    private var materialised: [MsgPackValue]

    var consumedCount: Int { materialised.count }

    init(scanner: MsgPackScanner, start: UnsafeRawPointer, count: Int, positions: [UnsafeRawPointer]) {
        self.scanner = scanner
        self.start = start
        self.count = count
        self.positions = positions
        materialised = []
        materialised.reserveCapacity(count)
    }

    func element(at index: Int) -> MsgPackValue {
        precondition(index >= 0 && index < count, "LazyArrayCursor element(at:) out of range \(index) vs count \(count)")
        while materialised.count <= index {
            let i = materialised.count
            scanner.seek(to: positions[i])
            materialised.append(scanner.scanLazy())
        }
        return materialised[index]
    }

    func elements() -> [MsgPackValue] {
        while materialised.count < count {
            let i = materialised.count
            scanner.seek(to: positions[i])
            materialised.append(scanner.scanLazy())
        }
        return materialised
    }
}

final class LazyMapCursor {
    let scanner: MsgPackScanner
    let start: UnsafeRawPointer
    let pairCount: Int

    private let pairPositions: [UnsafeRawPointer]
    private var pairs: [(MsgPackValue, MsgPackValue)]
    private(set) var consumedPairs: Int

    init(scanner: MsgPackScanner, start: UnsafeRawPointer, pairCount: Int, positions: [UnsafeRawPointer]) {
        self.scanner = scanner
        self.start = start
        self.pairCount = pairCount
        pairPositions = positions
        pairs = []
        pairs.reserveCapacity(pairCount)
        consumedPairs = 0
    }

    /// Consumes the next unvisited pair, caching it.
    private func consumeNext() {
        let i = consumedPairs
        scanner.seek(to: pairPositions[i])
        let k = scanner.scanLazy()
        let v = scanner.scanLazy()
        consumedPairs += 1
        pairs.append((k, v))
    }

    /// Compares a cached map key against the requested Swift key by raw UTF-8
    /// bytes — no `String` is allocated for the on-wire key.
    private func keyMatches(_ key: MsgPackValue, _ wanted: String) -> Bool {
        guard case let .literal(.str(buf)) = key.kind else { return false }
        var it = wanted.utf8.makeIterator()
        var i = 0
        while let b = it.next() {
            if i >= buf.count || buf[i] != b { return false }
            i += 1
        }
        return i == buf.count
    }

    func value(forStringKey key: String) -> MsgPackValue? {
        // 1. Already-consumed pairs (byte-compare, no walk, no allocation).
        for i in 0 ..< consumedPairs where keyMatches(pairs[i].0, key) {
            return pairs[i].1
        }
        // 2. Walk forward from the sequential cursor until the key is found.
        //    For declaration-order decoding this consumes exactly one pair.
        while consumedPairs < pairCount {
            consumeNext()
            let pair = pairs[consumedPairs - 1]
            if keyMatches(pair.0, key) {
                return pair.1
            }
        }
        return nil
    }

    func entries() -> [MsgPackValue] {
        while consumedPairs < pairCount {
            consumeNext()
        }
        var arr: [MsgPackValue] = []
        arr.reserveCapacity(pairCount * 2)
        for (k, v) in pairs {
            arr.append(k)
            arr.append(v)
        }
        return arr
    }

    func allStringKeys() -> [String] {
        while consumedPairs < pairCount {
            consumeNext()
        }
        var keys: [String] = []
        keys.reserveCapacity(pairs.count)
        for (k, _) in pairs {
            if case let .literal(.str(buf)) = k.kind, let s = String._tryFromUTF8(buf) {
                keys.append(s)
            }
        }
        return keys
    }

    func contains(stringKey key: String) -> Bool {
        value(forStringKey: key) != nil
    }
}
