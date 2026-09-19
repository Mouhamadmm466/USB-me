import Foundation
import Testing
@testable import Tools

@Suite struct DoubleMetaphoneTests {
    private let encoder = DoubleMetaphone()

    @Test(arguments: [
        ("Smith", "SM0", "XMT"),
        ("Schmidt", "XMT", "SMT"),
        ("Michael", "MKL", "MXL"),
        ("Xavier", "SF", "SFR"),
        ("Catherine", "K0RN", "KTRN"),
        ("Kathryn", "K0RN", "KTRN"),
        ("Jose", "HS", "HS"),
        ("Gough", "KF", "KF"),
        ("Thomas", "TMS", "TMS"),
    ])
    func knownCodes(word: String, primary: String, alternate: String) throws {
        let code = try #require(encoder.encode(word))
        #expect(code.primary == primary, "\(word)")
        #expect(code.alternate == alternate, "\(word)")
    }

    @Test func soundAlikeNamesShareAKey() throws {
        let pairs = [("Jon", "John"), ("Kym", "Kim"), ("Geoffrey", "Jeffrey"), ("Stephen", "Steven"), ("Catherine", "Kathryn"), ("Zach", "Zack")]
        for (lhs, rhs) in pairs {
            let left = try #require(encoder.encode(lhs))
            let right = try #require(encoder.encode(rhs))
            #expect(left.matches(right), "\(lhs) / \(rhs)")
        }
        let different = try #require(encoder.encode("Alex"))
        #expect(!different.matches(try #require(encoder.encode("Kim"))))
    }

    @Test func foldsDiacriticsAndIgnoresNonLetters() throws {
        #expect(encoder.encode("José")?.primary == "HS")
        #expect(encoder.encode("123") == nil)
        #expect(encoder.encode("") == nil)
    }

    @Test func respectsMaximumLength() throws {
        let short = try #require(DoubleMetaphone(maxLength: 4).encode("Christopher"))
        let long = try #require(DoubleMetaphone(maxLength: 8).encode("Christopher"))
        #expect(short.primary.count == 4)
        #expect(long.primary.count > 4)
    }
}

@Suite struct EditDistanceTests {
    @Test(arguments: [
        ("kim", "kym", 1),
        ("jon", "john", 1),
        ("ca", "ac", 1),
        ("ca", "abc", 2),
        ("kitten", "sitting", 3),
        ("", "abc", 3),
        ("abc", "", 3),
        ("same", "same", 0),
        ("alexandra", "alxeandra", 1),
    ])
    func damerauLevenshtein(lhs: String, rhs: String, expected: Int) {
        #expect(EditDistance.damerauLevenshtein(lhs, rhs) == expected)
        #expect(EditDistance.damerauLevenshtein(rhs, lhs) == expected)
    }
}

@Suite struct NameSimilarityTests {
    private func match(_ spoken: String, _ stored: String) -> TokenMatchKind? {
        NameSimilarity.match(NameToken(spoken), NameToken(stored))
    }

    @Test func exactAndHomophones() {
        #expect(match("kim", "kim") == .exact)
        #expect(match("jon", "john") == .homophone)
        #expect(match("kym", "kim") == .homophone)
        #expect(match("stephen", "steven") == .homophone)
        #expect(match("sarah", "sara") == .homophone)
    }

    @Test func fuzzyMatchesAreRankedByCost() {
        // One typo that also sounds alike is cheaper than one typo alone.
        let soundsAlike = match("tom", "tim")?.cost
        let typo = match("kin", "kim")?.cost
        #expect(soundsAlike == 1)
        #expect(typo == 2)
        #expect(match("mike", "michael") == .fuzzy(cost: 2))
        #expect(match("catherine", "kathryn") != nil)
    }

    @Test func shortAndUnrelatedTokensDoNotMatch() {
        #expect(match("al", "eli") == nil)
        #expect(match("ed", "ted") == nil)
        #expect(match("alex", "kim") == nil)
        #expect(match("tim", "kim") == nil) // different first letter and different sound
        #expect(match("2", "3") == nil)
    }

    @Test func editDistanceThresholdGrowsWithLength() {
        #expect(match("jonathon", "jonathan") != nil) // 1 edit, 8 letters
        #expect(match("alexandr", "alexandra") != nil)
        #expect(match("abcd", "abxy") == nil) // 2 edits on a short name
    }
}

@Suite struct TextNormalizationTests {
    @Test func wordsFoldAndSplit() {
        #expect(TextTokens.words("José O'Brien-Smith") == ["jose", "obrien", "smith"])
        #expect(TextTokens.words("Alex's") == ["alex"])
        #expect(TextTokens.words("  ") == [])
        #expect(TextTokens.phrase("That meeting!") == "that meeting")
    }

    @Test func fileNameWordsBreakCamelCaseAndDigits() {
        #expect(TextTokens.fileNameWords("QuarterlyReport2026") == ["quarterly", "report", "2026"])
        #expect(TextTokens.fileNameWords("budget_final-v2") == ["budget", "final", "v", "2"])
    }

    @Test func stemming() {
        #expect(TextTokens.stem("meetings") == "meeting")
        #expect(TextTokens.stem("parties") == "party")
        #expect(TextTokens.stem("class") == "class")
        #expect(TextTokens.stem("bus") == "bus")
    }

    @Test func sanitizerRemovesInvisibleAndControlCharacters() {
        #expect(TextSanitizer.clean("  Hi\u{202E}there\u{0007} ", allowNewlines: false) == "Hithere")
        #expect(TextSanitizer.clean("a\u{200B}b\u{FEFF}c", allowNewlines: false) == "abc")
        #expect(TextSanitizer.clean("line one\r\nline two", allowNewlines: true) == "line one\nline two")
        #expect(TextSanitizer.clean("line one\nline two", allowNewlines: false) == "line one line two")
        #expect(TextSanitizer.clean("a\n\n\n\nb", allowNewlines: true) == "a\n\nb")
        #expect(TextSanitizer.clean("tab\tand   spaces", allowNewlines: false) == "tab and spaces")
        // Emoji sequences survive (ZWJ is kept).
        #expect(TextSanitizer.clean("👨‍👩‍👧", allowNewlines: false) == "👨‍👩‍👧")
    }

    @Test func singleLineValidation() {
        #expect(TextSanitizer.singleLine(nil, maxLength: 5) == .empty)
        #expect(TextSanitizer.singleLine(" \u{200B} ", maxLength: 5) == .empty)
        #expect(TextSanitizer.singleLine("hello", maxLength: 5) == .valid("hello"))
        #expect(TextSanitizer.singleLine("hello!", maxLength: 5) == .tooLong)
    }
}

@Suite struct DiminutiveTests {
    @Test func formalAndDiminutiveAreRelated() {
        #expect(Diminutives.related("mike", "michael"))
        #expect(Diminutives.related("michael", "mike"))
        #expect(Diminutives.related("bob", "robert"))
        #expect(Diminutives.related("catherine", "kathryn")) // spelling variants of one formal name
    }

    @Test func twoDiminutivesAreNotRelated() {
        #expect(!Diminutives.related("ed", "ted"))
        #expect(!Diminutives.related("liz", "beth"))
        #expect(!Diminutives.related("mike", "mike"))
        #expect(!Diminutives.related("mike", "robert"))
    }
}
