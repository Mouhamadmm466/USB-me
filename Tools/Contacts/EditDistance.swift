import Foundation

/// Unrestricted Damerau–Levenshtein distance (insertions, deletions, substitutions and adjacent
/// transpositions), computed over Unicode scalars with the Lowrance–Wagner algorithm.
public enum EditDistance {
    public static func damerauLevenshtein(_ lhs: String, _ rhs: String) -> Int {
        damerauLevenshtein(lhs.unicodeScalars.map(\.value), rhs.unicodeScalars.map(\.value))
    }

    static func damerauLevenshtein(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        let maxDistance = a.count + b.count
        let width = b.count + 2
        // (a.count + 2) x (b.count + 2) matrix, flattened.
        var table = [Int](repeating: 0, count: (a.count + 2) * width)
        table[0] = maxDistance
        for i in 0...a.count {
            table[(i + 1) * width] = maxDistance
            table[(i + 1) * width + 1] = i
        }
        for j in 0...b.count {
            table[j + 1] = maxDistance
            table[width + j + 1] = j
        }

        // Last row (1-based) in which each character of `a` was seen. Names are short, so a small
        // linear map beats a dictionary.
        var seenCharacters: [UInt32] = []
        var seenRows: [Int] = []
        func lastRow(of character: UInt32) -> Int {
            for index in seenCharacters.indices where seenCharacters[index] == character { return seenRows[index] }
            return 0
        }

        for i in 1...a.count {
            var lastMatchingColumn = 0
            for j in 1...b.count {
                let i1 = lastRow(of: b[j - 1])
                let j1 = lastMatchingColumn
                let cost: Int
                if a[i - 1] == b[j - 1] {
                    cost = 0
                    lastMatchingColumn = j
                } else {
                    cost = 1
                }
                let substitution = table[i * width + j] + cost
                let insertion = table[(i + 1) * width + j] + 1
                let deletion = table[i * width + j + 1] + 1
                let transposition = table[i1 * width + j1] + (i - i1 - 1) + 1 + (j - j1 - 1)
                table[(i + 1) * width + j + 1] = min(substitution, insertion, deletion, transposition)
            }
            let character = a[i - 1]
            if let index = seenCharacters.firstIndex(of: character) {
                seenRows[index] = i
            } else {
                seenCharacters.append(character)
                seenRows.append(i)
            }
        }
        return table[(a.count + 1) * width + b.count + 1]
    }
}
