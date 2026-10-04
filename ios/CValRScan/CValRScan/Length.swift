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
}

// Feet-and-inches to the nearest inch, the precision ANSI Z765 asks for.
enum Feet {
    static func inches(meters: Double) -> Int { Int((meters * 39.37007874).rounded()) }
    static func text(_ inches: Int) -> String { "\(inches / 12)′ \(inches % 12)″" }
}

// Reads a length as typed or dictated: "10 9", "10' 9\"", "10 ft 9 in",
// "ten feet nine inches", "10' 8 29/32", "10.74" (decimal feet), "129 in".
// Returns whole inches, rounded half up, or nil when it can't tell.
enum LengthParser {
    static func inches(from raw: String) -> Int? {
        var s = raw.lowercased()
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
        guard total > 0, total < 12_000 else { return nil }
        return Int(total.rounded())
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
