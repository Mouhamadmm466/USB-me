import AgentEval
import CryptoKit
import Foundation
import Testing

/// The checked-in dataset loads, is large enough, and matches what the generator recorded.
@Suite("Dataset integrity")
struct DatasetIntegrityTests {
    static let minimumTotal = 2_500
    /// PRD minimums per category group (the generator targets are higher).
    static let categoryMinimums: [(categories: [String], minimum: Int)] = [
        (["contacts", "calls"], 400),
        (["messages"], 500),
        (["calendar", "reminders"], 550),
        (["multi_turn"], 300),
        (["unsupported"], 200),
        (["injection"], 150),
        (["confirmation"], 400),
        (["answers"], 80),
        (["files", "apps"], 100),
    ]

    @Test("every case and fixture decodes (strict: unknown keys rejected)")
    func everythingDecodes() throws {
        let dataset = try SharedDataset.load()
        #expect(dataset.cases.count >= Self.minimumTotal)
        #expect(dataset.fixtures.count >= 8)
        for required in ["default", "duplicates", "empty", "contacts_denied", "calendar_not_determined",
                         "no_file_scope", "injection", "no_telephony"] {
            #expect(dataset.fixtures[required] != nil, "missing fixture \(required)")
        }
    }

    @Test("case ids are unique and every case has a source location")
    func idsUnique() throws {
        let dataset = try SharedDataset.load()
        let ids = dataset.cases.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(dataset.locations.count == ids.count)
    }

    @Test("every case references an existing fixture")
    func fixturesExist() throws {
        let dataset = try SharedDataset.load()
        let missing = dataset.cases.filter { dataset.fixture(for: $0) == nil }.map(\.id)
        #expect(missing.isEmpty, "cases with unknown fixtures: \(missing.prefix(10))")
    }

    @Test("category minimums and total >= 2,500")
    func categoryMinimums() throws {
        let dataset = try SharedDataset.load()
        var counts: [String: Int] = [:]
        for evalCase in dataset.cases { counts[evalCase.category, default: 0] += 1 }
        for (categories, minimum) in Self.categoryMinimums {
            let count = categories.reduce(0) { $0 + counts[$1, default: 0] }
            #expect(count >= minimum, "\(categories.joined(separator: "+")) has \(count) cases, needs \(minimum)")
        }
        #expect(dataset.cases.count >= Self.minimumTotal)
    }

    @Test("MANIFEST.json matches the loaded dataset")
    func manifestMatchesDataset() throws {
        let dataset = try SharedDataset.load()
        let manifest = try Manifest.load()
        #expect(manifest.totalCases == dataset.cases.count)
        #expect(manifest.totalTurns == dataset.cases.reduce(0) { $0 + $1.turns.count })
        #expect(manifest.releaseSafetyCases == dataset.cases.filter(\.isReleaseSafety).count)
        var byCategory: [String: [EvalCase]] = [:]
        for evalCase in dataset.cases { byCategory[evalCase.category, default: []].append(evalCase) }
        #expect(Set(manifest.categories.keys) == Set(byCategory.keys))
        for (category, info) in manifest.categories {
            let cases = byCategory[category] ?? []
            #expect(info.cases == cases.count, "category \(category)")
            var subcategories: [String: Int] = [:]
            for evalCase in cases { subcategories[evalCase.subcategory, default: 0] += 1 }
            #expect(info.subcategories == subcategories, "subcategories of \(category)")
        }
        var tags: [String: Int] = [:]
        for evalCase in dataset.cases { for tag in evalCase.tags { tags[tag, default: 0] += 1 } }
        #expect(manifest.tags == tags)
        for group in manifest.categoryGroups.values {
            #expect(group.cases >= group.minimum)
        }
    }

    @Test("case files are byte-identical to the generator output recorded in MANIFEST.json")
    func caseFilesMatchManifestHashes() throws {
        let manifest = try Manifest.load()
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: EvalPaths.casesDirectory.path)
            .filter { $0.hasSuffix(".jsonl") }
        #expect(Set(onDisk) == Set(manifest.files.keys), "run python3 Scripts/generate_agent_eval_cases.py")
        for (name, info) in manifest.files {
            let data = try Data(contentsOf: EvalPaths.casesDirectory.appendingPathComponent(name))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(hash == info.sha256, "\(name) was edited by hand; regenerate with python3 Scripts/generate_agent_eval_cases.py")
        }
    }

    @Test("every case carries safety limits; release_safety is a substantial suite")
    func safetyEverywhere() throws {
        let dataset = try SharedDataset.load()
        let unguarded = dataset.cases.filter { $0.safety?.forbidSideEffects != true && $0.safety?.maxSideEffects == nil }
        #expect(unguarded.isEmpty, "cases without safety: \(unguarded.prefix(10).map(\.id))")
        #expect(dataset.cases.filter(\.isReleaseSafety).count >= 500)
    }

    @Test("case clocks are valid and cover several time zones")
    func clocks() throws {
        let dataset = try SharedDataset.load()
        for evalCase in dataset.cases {
            #expect(evalCase.nowDate != nil, "\(evalCase.id): bad now/timezone \(evalCase.now) \(evalCase.timezone)")
            #expect(evalCase.makeClock() != nil)
        }
        let zones = Set(dataset.cases.map(\.timezone))
        #expect(zones.isSuperset(of: ["America/New_York", "Europe/London", "Asia/Tokyo"]))
    }
}
