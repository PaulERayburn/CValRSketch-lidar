import Foundation

// A laser or tape reading. It always runs face to face: `face` and `sideSign`
// say which faces (the room it was taken in, or outside), `walls` is the run
// of scanned segments it spans, and `moving` the end walls the importer may
// shift to honour it.
struct WallMeasurement: Equatable {
    enum Face: String, CaseIterable { case inside, outside }
    enum Move: String, CaseIterable { case auto, start, end, both }
    var inches: Int
    var face: Face
    var sideSign: Int = 1         // +1: the side the normal (−dy, dx) of the wall's a→b points to
    var room: String = ""
    var walls: [UUID] = []
    var move: Move = .auto
    var moving: [UUID] = []
    var entered = ""              // as typed, e.g. "11 11 + 6 5 + 6 2"
}

// A reading between two scanned corners, for a stretch no single scanned wall
// covers (RoomPlan splits an outside wall where rooms meet inside). Corners are
// world metres (x, z); the reading runs along the house's main direction.
// Outside, it is siding corner to siding corner; inside, face to face.
struct SpanReading: Equatable {
    var a: SIMD2<Double>
    var b: SIMD2<Double>
    var story: Int
    var inches: Int
    var face: WallMeasurement.Face
    var entered = ""
}

// Feet-and-inches to the nearest inch, the precision ANSI Z765 asks for.
enum Feet {
    static func inches(meters: Double) -> Int { Int((meters * 39.37007874).rounded()) }
    static func text(_ inches: Int) -> String { "\(inches / 12)′ \(inches % 12)″" }
}

// Reads a length as typed or dictated: "10 9", "10' 9\"", "10 ft 9 in",
// "ten feet nine inches", "10' 8 29/32", "10.74" (decimal feet), "129 in".
// Lengths add and subtract, the way a laser is used in pieces:
// "11 11 + 6 5 + 6 2", "30 0 − 5 6", "ten four plus six two". A minus needs
// spaces round it, so "10-6" still reads as 10′ 6″.
// Returns whole inches, rounded half up, or nil when it can't tell.
enum LengthParser {
    static func inches(from raw: String) -> Int? { reading(from: raw)?.total }

    // The total and each signed part, in whole inches. The total is rounded
    // once, after adding, so fractions are not rounded part by part.
    static func reading(from raw: String) -> (total: Int, parts: [Int])? {
        var s = " " + raw.lowercased() + " "
        for (from, to) in [("+", " plus "), ("−", " minus "), ("–", " minus "), (" - ", " minus ")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        var terms: [(sign: Double, text: String)] = []
        var sign = 1.0, current: [Substring] = []
        func flush() {
            if !current.isEmpty { terms.append((sign, current.joined(separator: " "))) }
            current = []
        }
        for token in s.split(separator: " ") {
            if token == "plus" { flush(); sign = 1 }
            else if token == "minus" { flush(); sign = -1 }
            else { current.append(token) }
        }
        flush()
        guard !terms.isEmpty else { return nil }
        var total = 0.0, parts: [Int] = []
        for t in terms {
            guard let v = exactInches(t.text) else { return nil }
            total += t.sign * v
            parts.append(Int((t.sign * v).rounded()))
        }
        guard total > 0, total < 12_000 else { return nil }
        return (Int(total.rounded()), parts)
    }

    // "11 11 + 6 5 + 6 2" → "11′ 11″ + 6′ 5″ + 6′ 2″"; nil for a single length.
    static func describe(_ parts: [Int]) -> String? {
        guard parts.count > 1 else { return nil }
        return parts.enumerated().map { i, p in
            (i == 0 ? (p < 0 ? "−" : "") : (p < 0 ? " − " : " + ")) + Feet.text(abs(p))
        }.joined()
    }

    private static func exactInches(_ raw: String) -> Double? {
        var s = raw
        for (from, to) in [("’", "'"), ("′", "'"), ("”", "\""), ("″", "\""), ("“", "\"")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        s = wordsToDigits(s)
        var fraction = 0.0
        if let r = s.range(of: #"\d+\s*/\s*\d+"#, options: .regularExpression) {
            let parts = s[r].split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, parts[1] > 0 { fraction = parts[0] / parts[1] }
            s.removeSubrange(r)
        }
        let numbers = matches(#"\d+(\.\d+)?"#, in: s).compactMap(Double.init)
        let feetMark = s.contains("'") || s.contains("ft") || s.contains("feet") || s.contains("foot")
        let inchMark = s.contains("\"") || s.contains("in")
        let total: Double
        switch numbers.count {
        case 1: total = (inchMark && !feetMark) ? numbers[0] + fraction : numbers[0] * 12 + fraction
        case 2: total = numbers[0] * 12 + numbers[1] + fraction
        default: return nil
        }
        guard total > 0 else { return nil }
        return total
    }

    private static let small = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                                "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
                                "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
                                "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
    private static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
                               "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]

    // "twenty three" joins into 23, but "ten nine" stays two numbers.
    static func wordsToDigits(_ s: String) -> String {
        var out: [String] = []
        var pendingTens: Int?
        func flush() {
            if let p = pendingTens { out.append(String(p)); pendingTens = nil }
        }
        for token in s.replacingOccurrences(of: "-", with: " ").split(separator: " ").map(String.init) {
            let word = token.trimmingCharacters(in: .punctuationCharacters)
            if let t = tens[word] {
                flush()
                pendingTens = t
            } else if let v = small[word] {
                if let t = pendingTens, v < 10 {
                    out.append(String(t + v))
                    pendingTens = nil
                } else {
                    flush()
                    out.append(String(v))
                }
            } else {
                flush()
                out.append(token)
            }
        }
        flush()
        return out.joined(separator: " ")
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s))
            .compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }
}
