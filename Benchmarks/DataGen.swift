import Foundation

struct HarnessUser: Codable, Sendable, Equatable {
    let id: Int
    let name: String
    let email: String
    let age: Int
    let city: String
    let createdAt: Date
    let tags: [String]
}

struct DateOnly: Codable, Equatable {
    let createdAt: Date
}

struct StringHeavy: Codable, Equatable {
    let a: String
    let b: String
    let c: String
    let d: String
    let e: String
}

struct IntOnly: Codable, Equatable {
    let value: Int
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ upperBound: Int) -> Int { Int(next() % UInt64(upperBound)) }
}

let cities = [
    "NewYork", "London", "Tokyo", "Berlin", "Paris",
    "Madrid", "Rome", "Lisbon", "Vienna", "Prague",
]
let firstNames = ["Alexander", "Charlotte", "Benjamin", "Isabella", "Sebastian", "Victoria", "Nathaniel", "Josephine"]
let lastNames = ["Whitmore", "Castellano", "Fairbanks", "Kensington", "Abernathy", "Montgomery"]
let tagPool = ["swift", "db", "perf", "index", "async", "cache", "batch", "query"]

func makeUsers(_ count: Int, seed: UInt64 = 100) -> [HarnessUser] { var rng = SplitMix64(seed: seed)
    var users = [HarnessUser]()
    users.reserveCapacity(count)
    let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
    for i in 0 ..< count {
        let name = "\(firstNames[rng.int(firstNames.count)]) \(lastNames[rng.int(lastNames.count)])"
        let email = "user\(i)@example-domain.com"
        let city = cities[rng.int(cities.count)]
        let tagCount = rng.int(4)
        var tags = [String]()
        for _ in 0 ..< tagCount {
            tags.append(tagPool[rng.int(tagPool.count)])
        }
        users.append(HarnessUser(
            id: i,
            name: name,
            email: email,
            age: 18 + rng.int(60),
            city: city,
            createdAt: base.addingTimeInterval(Double(rng.int(10_000_000))),
            tags: tags
        ))
    }
    return users
}

func makeStringHeavy(_ count: Int, seed: UInt64 = 7) -> [StringHeavy] {
    var rng = SplitMix64(seed: seed)
    var out = [StringHeavy]()
    out.reserveCapacity(count)
    for _ in 0 ..< count {
        func s() -> String { firstNames[rng.int(firstNames.count)] + lastNames[rng.int(lastNames.count)] }
        out.append(StringHeavy(a: s(), b: s(), c: s(), d: s(), e: s()))
    }
    return out
}
