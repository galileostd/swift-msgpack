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
    private var stringIndex: [String: Int]
    private(set) var consumedPairs: Int

    init(scanner: MsgPackScanner, start: UnsafeRawPointer, pairCount: Int, positions: [UnsafeRawPointer]) {
        self.scanner = scanner
        self.start = start
        self.pairCount = pairCount
        pairPositions = positions
        pairs = []
        pairs.reserveCapacity(pairCount)
        stringIndex = [:]
        stringIndex.reserveCapacity(pairCount)
        consumedPairs = 0
    }

    private func consumeNext() -> (MsgPackValue, MsgPackValue, String?) {
        let i = consumedPairs
        scanner.seek(to: pairPositions[i])
        let k = scanner.scanLazy()
        let v = scanner.scanLazy()
        consumedPairs += 1
        pairs.append((k, v))
        var keyString: String?
        if case let .literal(.str(buf)) = k.stripped, let s = String._tryFromUTF8(buf) {
            if stringIndex[s] == nil {
                stringIndex[s] = pairs.count - 1
            }
            keyString = s
        }
        return (k, v, keyString)
    }

    func value(forStringKey key: String) -> MsgPackValue? {
        if let idx = stringIndex[key] {
            return pairs[idx].1
        }
        while consumedPairs < pairCount {
            let (_, v, keyString) = consumeNext()
            if keyString == key {
                return v
            }
        }
        return nil
    }

    func entries() -> [MsgPackValue] {
        while consumedPairs < pairCount {
            _ = consumeNext()
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
            _ = consumeNext()
        }
        return Array(stringIndex.keys)
    }

    func contains(stringKey key: String) -> Bool {
        value(forStringKey: key) != nil
    }
}
