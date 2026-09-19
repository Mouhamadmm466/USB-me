import Foundation

/// Lawrence Philips' Double Metaphone phonetic key, used to match names that sound alike but are
/// spelled differently by speech recognition ("Kathryn"/"Catherine", "Jon"/"John", "Geoffrey"/"Jeffrey").
///
/// A faithful port of the reference algorithm (as in Apache Commons Codec). Input is folded to
/// uppercase ASCII letters first; each call encodes one word. The implementation works on bytes
/// and never allocates while scanning, so thousands of names encode in milliseconds.
public struct DoubleMetaphone: Sendable {
    public struct Code: Sendable, Hashable, CustomStringConvertible {
        public let primary: String
        public let alternate: String

        public var description: String { primary == alternate ? primary : "\(primary)/\(alternate)" }

        /// True when any key of `self` equals any key of `other` (the standard Double Metaphone match).
        public func matches(_ other: Code) -> Bool {
            if !primary.isEmpty, primary == other.primary || primary == other.alternate { return true }
            if !alternate.isEmpty, alternate == other.primary || alternate == other.alternate { return true }
            return false
        }
    }

    public let maxLength: Int

    public init(maxLength: Int = 4) {
        self.maxLength = max(1, maxLength)
    }

    /// Encodes one word. Returns nil when the input has no letters.
    public func encode(_ word: String) -> Code? {
        var letters: [UInt8] = []
        letters.reserveCapacity(word.utf8.count)
        for byte in TextTokens.fold(word).utf8 {
            switch byte {
            case 0x61...0x7A: letters.append(byte - 0x20) // a–z -> A–Z
            case 0x41...0x5A: letters.append(byte)
            default: continue
            }
        }
        guard !letters.isEmpty else { return nil }
        var encoder = Encoder(value: letters, maxLength: maxLength)
        encoder.run()
        return Code(
            primary: String(decoding: encoder.primary.filter { $0 != Ch.space }, as: UTF8.self),
            alternate: String(decoding: encoder.alternate.filter { $0 != Ch.space }, as: UTF8.self)
        )
    }
}

/// ASCII codes used by the encoder.
private enum Ch {
    static let A: UInt8 = 0x41, B: UInt8 = 0x42, C: UInt8 = 0x43, D: UInt8 = 0x44, E: UInt8 = 0x45
    static let F: UInt8 = 0x46, G: UInt8 = 0x47, H: UInt8 = 0x48, I: UInt8 = 0x49, J: UInt8 = 0x4A
    static let K: UInt8 = 0x4B, L: UInt8 = 0x4C, M: UInt8 = 0x4D, N: UInt8 = 0x4E, O: UInt8 = 0x4F
    static let P: UInt8 = 0x50, Q: UInt8 = 0x51, R: UInt8 = 0x52, S: UInt8 = 0x53, T: UInt8 = 0x54
    static let U: UInt8 = 0x55, V: UInt8 = 0x56, W: UInt8 = 0x57, X: UInt8 = 0x58, Y: UInt8 = 0x59
    static let Z: UInt8 = 0x5A
    static let space: UInt8 = 0x20
    static let none: UInt8 = 0
}

// MARK: - Encoder

private struct Encoder {
    let value: [UInt8]
    let length: Int
    let maxLength: Int
    let slavoGermanic: Bool
    var primary: [UInt8] = []
    var alternate: [UInt8] = []

    init(value: [UInt8], maxLength: Int) {
        self.value = value
        length = value.count
        self.maxLength = maxLength
        var slavo = false
        for index in 0..<value.count {
            let byte = value[index]
            if byte == Ch.W || byte == Ch.K { slavo = true; break }
            if byte == Ch.C, index + 1 < value.count, value[index + 1] == Ch.Z { slavo = true; break }
        }
        slavoGermanic = slavo
        primary.reserveCapacity(maxLength)
        alternate.reserveCapacity(maxLength)
    }

    // MARK: Helpers

    func charAt(_ index: Int) -> UInt8 {
        index >= 0 && index < length ? value[index] : Ch.none
    }

    /// True when the `count` letters at `start` equal one of the "|"-separated `options`.
    func contains(_ start: Int, _ count: Int, _ options: StaticString) -> Bool {
        guard start >= 0, count > 0, start + count <= length else { return false }
        return options.withUTF8Buffer { buffer in
            var segmentStart = 0
            var index = 0
            while index <= buffer.count {
                if index == buffer.count || buffer[index] == 0x7C /* | */ {
                    if index - segmentStart == count {
                        var equal = true
                        for offset in 0..<count where value[start + offset] != buffer[segmentStart + offset] {
                            equal = false
                            break
                        }
                        if equal { return true }
                    }
                    segmentStart = index + 1
                }
                index += 1
            }
            return false
        }
    }

    static func isVowel(_ byte: UInt8) -> Bool {
        switch byte {
        case Ch.A, Ch.E, Ch.I, Ch.O, Ch.U, Ch.Y: true
        default: false
        }
    }

    var isComplete: Bool { primary.count >= maxLength && alternate.count >= maxLength }

    mutating func appendPrimary(_ text: StaticString) {
        text.withUTF8Buffer { buffer in
            for byte in buffer where primary.count < maxLength { primary.append(byte) }
        }
    }

    mutating func appendAlternate(_ text: StaticString) {
        text.withUTF8Buffer { buffer in
            for byte in buffer where alternate.count < maxLength { alternate.append(byte) }
        }
    }

    mutating func append(_ text: StaticString) {
        appendPrimary(text)
        appendAlternate(text)
    }

    mutating func append(_ primaryText: StaticString, _ alternateText: StaticString) {
        appendPrimary(primaryText)
        appendAlternate(alternateText)
    }

    // MARK: Main loop

    mutating func run() {
        var index = contains(0, 2, "GN|KN|PN|WR|PS") ? 1 : 0
        while !isComplete, index <= length - 1 {
            switch value[index] {
            case Ch.A, Ch.E, Ch.I, Ch.O, Ch.U, Ch.Y:
                if index == 0 { append("A") }
                index += 1
            case Ch.B:
                append("P")
                index = charAt(index + 1) == Ch.B ? index + 2 : index + 1
            case Ch.C:
                index = handleC(index)
            case Ch.D:
                index = handleD(index)
            case Ch.F:
                append("F")
                index = charAt(index + 1) == Ch.F ? index + 2 : index + 1
            case Ch.G:
                index = handleG(index)
            case Ch.H:
                index = handleH(index)
            case Ch.J:
                index = handleJ(index)
            case Ch.K:
                append("K")
                index = charAt(index + 1) == Ch.K ? index + 2 : index + 1
            case Ch.L:
                index = handleL(index)
            case Ch.M:
                append("M")
                index = conditionM0(index) ? index + 2 : index + 1
            case Ch.N:
                append("N")
                index = charAt(index + 1) == Ch.N ? index + 2 : index + 1
            case Ch.P:
                index = handleP(index)
            case Ch.Q:
                append("K")
                index = charAt(index + 1) == Ch.Q ? index + 2 : index + 1
            case Ch.R:
                index = handleR(index)
            case Ch.S:
                index = handleS(index)
            case Ch.T:
                index = handleT(index)
            case Ch.V:
                append("F")
                index = charAt(index + 1) == Ch.V ? index + 2 : index + 1
            case Ch.W:
                index = handleW(index)
            case Ch.X:
                index = handleX(index)
            case Ch.Z:
                index = handleZ(index)
            default:
                index += 1
            }
        }
    }

    // MARK: Letter handlers

    mutating func handleC(_ start: Int) -> Int {
        var index = start
        if conditionC0(index) {
            append("K")
            index += 2
        } else if index == 0, contains(index, 6, "CAESAR") {
            append("S")
            index += 2
        } else if contains(index, 2, "CH") {
            index = handleCH(index)
        } else if contains(index, 2, "CZ"), !contains(index - 2, 4, "WICZ") {
            append("S", "X")
            index += 2
        } else if contains(index + 1, 3, "CIA") {
            append("X")
            index += 3
        } else if contains(index, 2, "CC"), !(index == 1 && charAt(0) == Ch.M) {
            return handleCC(index)
        } else if contains(index, 2, "CK|CG|CQ") {
            append("K")
            index += 2
        } else if contains(index, 2, "CI|CE|CY") {
            if contains(index, 3, "CIO|CIE|CIA") {
                append("S", "X")
            } else {
                append("S")
            }
            index += 2
        } else {
            append("K")
            if contains(index + 1, 2, " C| Q| G") {
                index += 3
            } else if contains(index + 1, 1, "C|K|Q"), !contains(index + 1, 2, "CE|CI") {
                index += 2
            } else {
                index += 1
            }
        }
        return index
    }

    mutating func handleCC(_ index: Int) -> Int {
        if contains(index + 2, 1, "I|E|H"), !contains(index + 2, 2, "HU") {
            if (index == 1 && charAt(index - 1) == Ch.A) || contains(index - 1, 5, "UCCEE|UCCES") {
                append("KS")
            } else {
                append("X")
            }
            return index + 3
        }
        append("K")
        return index + 2
    }

    mutating func handleCH(_ index: Int) -> Int {
        if index > 0, contains(index, 4, "CHAE") {
            append("K", "X")
            return index + 2
        }
        if conditionCH0(index) {
            append("K")
            return index + 2
        }
        if conditionCH1(index) {
            append("K")
            return index + 2
        }
        if index > 0 {
            if contains(0, 2, "MC") {
                append("K")
            } else {
                append("X", "K")
            }
        } else {
            append("X")
        }
        return index + 2
    }

    mutating func handleD(_ start: Int) -> Int {
        var index = start
        if contains(index, 2, "DG") {
            if contains(index + 2, 1, "I|E|Y") {
                append("J")
                index += 3
            } else {
                append("TK")
                index += 2
            }
        } else if contains(index, 2, "DT|DD") {
            append("T")
            index += 2
        } else {
            append("T")
            index += 1
        }
        return index
    }

    mutating func handleG(_ start: Int) -> Int {
        var index = start
        if charAt(index + 1) == Ch.H {
            index = handleGH(index)
        } else if charAt(index + 1) == Ch.N {
            if index == 1, Self.isVowel(charAt(0)), !slavoGermanic {
                append("KN", "N")
            } else if !contains(index + 2, 2, "EY"), charAt(index + 1) != Ch.Y, !slavoGermanic {
                append("N", "KN")
            } else {
                append("KN")
            }
            index += 2
        } else if contains(index + 1, 2, "LI"), !slavoGermanic {
            append("KL", "L")
            index += 2
        } else if index == 0,
                  charAt(index + 1) == Ch.Y || contains(index + 1, 2, "ES|EP|EB|EL|EY|IB|IL|IN|IE|EI|ER") {
            append("K", "J")
            index += 2
        } else if contains(index + 1, 2, "ER") || charAt(index + 1) == Ch.Y,
                  !contains(0, 6, "DANGER|RANGER|MANGER"),
                  !contains(index - 1, 1, "E|I"),
                  !contains(index - 1, 3, "RGY|OGY") {
            append("K", "J")
            index += 2
        } else if contains(index + 1, 1, "E|I|Y") || contains(index - 1, 4, "AGGI|OGGI") {
            if contains(0, 4, "VAN |VON ") || contains(0, 3, "SCH") || contains(index + 1, 2, "ET") {
                append("K")
            } else if contains(index + 1, 3, "IER") {
                append("J")
            } else {
                append("J", "K")
            }
            index += 2
        } else if charAt(index + 1) == Ch.G {
            index += 2
            append("K")
        } else {
            index += 1
            append("K")
        }
        return index
    }

    mutating func handleGH(_ start: Int) -> Int {
        var index = start
        if index > 0, !Self.isVowel(charAt(index - 1)) {
            append("K")
            index += 2
        } else if index == 0 {
            if charAt(index + 2) == Ch.I {
                append("J")
            } else {
                append("K")
            }
            index += 2
        } else if (index > 1 && contains(index - 2, 1, "B|H|D"))
                    || (index > 2 && contains(index - 3, 1, "B|H|D"))
                    || (index > 3 && contains(index - 4, 1, "B|H")) {
            // Parker's rule: "hugh".
            index += 2
        } else {
            if index > 2, charAt(index - 1) == Ch.U, contains(index - 3, 1, "C|G|L|R|T") {
                // "laugh", "McLaughlin", "cough", "gough", "rough", "tough".
                append("F")
            } else if index > 0, charAt(index - 1) != Ch.I {
                append("K")
            }
            index += 2
        }
        return index
    }

    mutating func handleH(_ index: Int) -> Int {
        // Keep only if first and before a vowel, or between two vowels.
        if index == 0 || Self.isVowel(charAt(index - 1)), Self.isVowel(charAt(index + 1)) {
            append("H")
            return index + 2
        }
        return index + 1
    }

    mutating func handleJ(_ start: Int) -> Int {
        var index = start
        if contains(index, 4, "JOSE") || contains(0, 4, "SAN ") {
            if (index == 0 && charAt(index + 4) == Ch.space) || length == 4 || contains(0, 4, "SAN ") {
                append("H")
            } else {
                append("J", "H")
            }
            index += 1
        } else {
            if index == 0, !contains(index, 4, "JOSE") {
                append("J", "A")
            } else if Self.isVowel(charAt(index - 1)), !slavoGermanic,
                      charAt(index + 1) == Ch.A || charAt(index + 1) == Ch.O {
                append("J", "H")
            } else if index == length - 1 {
                append("J", " ")
            } else if !contains(index + 1, 1, "L|T|K|S|N|M|B|Z"), !contains(index - 1, 1, "S|K|L") {
                append("J")
            }
            index = charAt(index + 1) == Ch.J ? index + 2 : index + 1
        }
        return index
    }

    mutating func handleL(_ index: Int) -> Int {
        if charAt(index + 1) == Ch.L {
            if conditionL0(index) {
                appendPrimary("L")
            } else {
                append("L")
            }
            return index + 2
        }
        append("L")
        return index + 1
    }

    mutating func handleP(_ index: Int) -> Int {
        if charAt(index + 1) == Ch.H {
            append("F")
            return index + 2
        }
        append("P")
        return contains(index + 1, 1, "P|B") ? index + 2 : index + 1
    }

    mutating func handleR(_ index: Int) -> Int {
        if index == length - 1, !slavoGermanic, contains(index - 2, 2, "IE"), !contains(index - 4, 2, "ME|MA") {
            appendAlternate("R")
        } else {
            append("R")
        }
        return charAt(index + 1) == Ch.R ? index + 2 : index + 1
    }

    mutating func handleS(_ start: Int) -> Int {
        var index = start
        if contains(index - 1, 3, "ISL|YSL") {
            // "island", "isle", "carlisle", "carlysle".
            index += 1
        } else if index == 0, contains(index, 5, "SUGAR") {
            append("X", "S")
            index += 1
        } else if contains(index, 2, "SH") {
            if contains(index + 1, 4, "HEIM|HOEK|HOLM|HOLZ") {
                append("S")
            } else {
                append("X")
            }
            index += 2
        } else if contains(index, 3, "SIO|SIA") || contains(index, 4, "SIAN") {
            if slavoGermanic {
                append("S")
            } else {
                append("S", "X")
            }
            index += 3
        } else if (index == 0 && contains(index + 1, 1, "M|N|L|W")) || contains(index + 1, 1, "Z") {
            // "smith" matches "schmidt", "snider" matches "schneider".
            append("S", "X")
            index = contains(index + 1, 1, "Z") ? index + 2 : index + 1
        } else if contains(index, 2, "SC") {
            index = handleSC(index)
        } else {
            if index == length - 1, contains(index - 2, 2, "AI|OI") {
                // French: "resnais", "artois".
                appendAlternate("S")
            } else {
                append("S")
            }
            index = contains(index + 1, 1, "S|Z") ? index + 2 : index + 1
        }
        return index
    }

    mutating func handleSC(_ index: Int) -> Int {
        if charAt(index + 2) == Ch.H {
            if contains(index + 3, 2, "OO|ER|EN|UY|ED|EM") {
                if contains(index + 3, 2, "ER|EN") {
                    append("X", "SK")
                } else {
                    append("SK")
                }
            } else if index == 0, !Self.isVowel(charAt(3)), charAt(3) != Ch.W {
                append("X", "S")
            } else {
                append("X")
            }
        } else if contains(index + 2, 1, "I|E|Y") {
            append("S")
        } else {
            append("SK")
        }
        return index + 3
    }

    mutating func handleT(_ start: Int) -> Int {
        var index = start
        if contains(index, 4, "TION") {
            append("X")
            index += 3
        } else if contains(index, 3, "TIA|TCH") {
            append("X")
            index += 3
        } else if contains(index, 2, "TH") || contains(index, 3, "TTH") {
            if contains(index + 2, 2, "OM|AM") || contains(0, 4, "VAN |VON ") || contains(0, 3, "SCH") {
                append("T")
            } else {
                append("0", "T")
            }
            index += 2
        } else {
            append("T")
            index = contains(index + 1, 1, "T|D") ? index + 2 : index + 1
        }
        return index
    }

    mutating func handleW(_ start: Int) -> Int {
        var index = start
        if contains(index, 2, "WR") {
            append("R")
            index += 2
        } else if index == 0, Self.isVowel(charAt(index + 1)) || contains(index, 2, "WH") {
            if Self.isVowel(charAt(index + 1)) {
                append("A", "F")
            } else {
                append("A")
            }
            index += 1
        } else if (index == length - 1 && Self.isVowel(charAt(index - 1)))
                    || contains(index - 1, 5, "EWSKI|EWSKY|OWSKI|OWSKY")
                    || contains(0, 3, "SCH") {
            appendAlternate("F")
            index += 1
        } else if contains(index, 4, "WICZ|WITZ") {
            append("TS", "FX")
            index += 4
        } else {
            index += 1
        }
        return index
    }

    mutating func handleX(_ start: Int) -> Int {
        var index = start
        if index == 0 {
            append("S")
            index += 1
        } else {
            let frenchEnding = index == length - 1
                && (contains(index - 3, 3, "IAU|EAU") || contains(index - 2, 2, "AU|OU"))
            if !frenchEnding {
                append("KS")
            }
            index = contains(index + 1, 1, "C|X") ? index + 2 : index + 1
        }
        return index
    }

    mutating func handleZ(_ start: Int) -> Int {
        var index = start
        if charAt(index + 1) == Ch.H {
            append("J")
            index += 2
        } else {
            if contains(index + 1, 2, "ZO|ZI|ZA") || (slavoGermanic && index > 0 && charAt(index - 1) != Ch.T) {
                append("S", "TS")
            } else {
                append("S")
            }
            index = charAt(index + 1) == Ch.Z ? index + 2 : index + 1
        }
        return index
    }

    // MARK: Conditions

    func conditionC0(_ index: Int) -> Bool {
        if contains(index, 4, "CHIA") { return true }
        if index <= 1 { return false }
        if Self.isVowel(charAt(index - 2)) { return false }
        if !contains(index - 1, 3, "ACH") { return false }
        let next = charAt(index + 2)
        return (next != Ch.I && next != Ch.E) || contains(index - 2, 6, "BACHER|MACHER")
    }

    func conditionCH0(_ index: Int) -> Bool {
        if index != 0 { return false }
        if !contains(index + 1, 5, "HARAC|HARIS"), !contains(index + 1, 3, "HOR|HYM|HIA|HEM") {
            return false
        }
        return !contains(0, 5, "CHORE")
    }

    func conditionCH1(_ index: Int) -> Bool {
        contains(0, 4, "VAN |VON ")
            || contains(0, 3, "SCH")
            || contains(index - 2, 6, "ORCHES|ARCHIT|ORCHID")
            || contains(index + 2, 1, "T|S")
            || ((contains(index - 1, 1, "A|O|U|E") || index == 0)
                && (contains(index + 2, 1, "L|R|N|M|B|H|F|V|W| ") || index + 1 == length - 1))
    }

    func conditionL0(_ index: Int) -> Bool {
        if index == length - 3, contains(index - 1, 4, "ILLO|ILLA|ALLE") { return true }
        if contains(length - 2, 2, "AS|OS") || contains(length - 1, 1, "A|O"),
           contains(index - 1, 4, "ALLE") {
            return true
        }
        return false
    }

    func conditionM0(_ index: Int) -> Bool {
        if charAt(index + 1) == Ch.M { return true }
        return contains(index - 1, 3, "UMB") && (index + 1 == length - 1 || contains(index + 2, 2, "ER"))
    }
}
