import Foundation
import Testing
@testable import Intelligence

@Suite struct DocumentParserTests {
    private let parser = DocumentParser()

    @Test func readsPlainTextAndTakesItsMarkdownTitle() throws {
        let text = "# Syllabus\n\nLate work loses 10% per day.\n"
        let parsed = try parser.parse(data: Data(text.utf8), fileName: "notes.md", mediaType: nil)
        #expect(parsed.title == "Syllabus")
        #expect(parsed.pages.count == 1)
        #expect(parsed.pages[0].text.contains("Late work"))
    }

    @Test func readsAWebPageWithoutRunningIt() throws {
        let html = """
        <html><head><title>Course policies</title><style>p{color:red}</style>
        <script>alert('no')</script></head>
        <body><h1>Policies</h1><p>Late work loses 10&#37; per day.</p><p>Email the TA &amp; cc me.</p></body></html>
        """
        let parsed = try parser.parse(data: Data(html.utf8), fileName: "page.html", mediaType: "text/html")
        #expect(parsed.title == "Course policies")
        let text = parsed.pages[0].text
        // Script and style content is code, not reading matter.
        #expect(!text.contains("alert"))
        #expect(!text.contains("color:red"))
        // Entities are decoded and paragraphs survive as lines.
        #expect(text.contains("Late work loses 10% per day."))
        #expect(text.contains("Email the TA & cc me."))
    }

    @Test func refusesWhatItCannotRead() {
        #expect(throws: DocumentParseError.self) {
            try parser.parse(data: Data([0x00, 0x01]), fileName: "photo.heic", mediaType: nil)
        }
        #expect(throws: DocumentParseError.empty) {
            try parser.parse(data: Data("   \n  ".utf8), fileName: "empty.txt", mediaType: nil)
        }
    }

    @Test func picksTheFormatFromTheNameOrTheType() {
        #expect(parser.format(fileName: "a.pdf", mediaType: nil) == .pdf)
        #expect(parser.format(fileName: "a.docx", mediaType: nil) == .docx)
        #expect(parser.format(fileName: "shared", mediaType: "application/pdf") == .pdf)
        #expect(parser.format(fileName: "a.key", mediaType: nil) == .unsupported("key"))
    }

    @Test func readsTheTextRunsOutOfWordMarkup() {
        let xml = """
        <w:document><w:body><w:p><w:r><w:t xml:space="preserve">Ship the </w:t></w:r>
        <w:r><w:t>beta</w:t></w:r></w:p><w:p><w:r><w:t>Due next Friday &amp; no later.</w:t></w:r></w:p></w:body></w:document>
        """
        let text = DOCXReader.paragraphs(in: xml)
        #expect(text == "Ship the beta\nDue next Friday & no later.")
    }
}

@Suite struct DocumentChunkerTests {
    private let chunker = DocumentChunker()
    private let documentID = UUID()

    @Test func aShortDocumentIsOnePassage() {
        let parsed = ParsedDocument(title: "Note", pages: [.init(text: "Ship the beta by Friday.")])
        let chunks = chunker.chunks(of: parsed, documentID: documentID)
        #expect(chunks.count == 1)
        #expect(chunks[0].text == "Ship the beta by Friday.")
        #expect(chunks[0].ordinal == 0)
    }

    @Test func headingsBecomeThePassageTheyCoverPassages() {
        let text = """
        # Grading
        Late work loses 10% per day.

        # Attendance
        Two absences are allowed.
        """
        let chunks = chunker.chunks(of: ParsedDocument(title: nil, pages: [.init(text: text)]), documentID: documentID)
        #expect(chunks.map(\.heading) == ["Grading", "Attendance"])
        #expect(chunks[0].text.contains("10%"))
        #expect(chunks[1].text.contains("Two absences"))
    }

    @Test func longTextIsCutOnSentencesWithOverlap() {
        let sentence = "The committee reviewed the proposal and asked for a revision by the end of the month. "
        let parsed = ParsedDocument(title: nil, pages: [.init(text: String(repeating: sentence, count: 40))])
        let chunks = chunker.chunks(of: parsed, documentID: documentID)

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.text.count <= 1_400 })
        // Cuts land on sentence ends, so no passage begins mid-word.
        #expect(chunks.dropFirst().allSatisfy { $0.text.first?.isUppercase == true || $0.text.hasPrefix("the ") })
        #expect(chunks.map(\.ordinal) == Array(0..<chunks.count))
    }

    @Test func pageNumbersAreKeptForCitations() {
        let parsed = ParsedDocument(title: "Syllabus", pages: [
            .init(number: 1, text: "Course overview."),
            .init(number: 2, text: "Late work loses 10% per day."),
        ])
        let chunks = chunker.chunks(of: parsed, documentID: documentID)
        #expect(chunks.map(\.page) == [1, 2])
        #expect(chunks[1].citation(documentTitle: "Syllabus") == "Syllabus, page 2")
    }

    @Test func doesNotBreakSentencesOnAbbreviations() {
        let sentences = DocumentChunker.sentences(in: "Dr. Diallo met Prof. Chen at 3 p.m. The room was full.")
        #expect(sentences.count == 2)
        #expect(sentences[0].hasPrefix("Dr. Diallo"))
    }
}

@Suite struct KnowledgeStoreTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeIntelligence() throws -> (PersonalIntelligence, IntelligenceStore) {
        let store = try IntelligenceStore()
        return (PersonalIntelligence(store: store, dates: FixedDateResolver()), store)
    }

    private var syllabus: Data {
        Data("""
        # Grading
        Late work loses 10% of the grade per day. Nothing is accepted more than five days late.

        # Midterm
        The midterm is on the fourth Friday and covers eigenvalues and diagonalization.
        """.utf8)
    }

    @Test func importingAFileIndexesItAndSaysSoInActivity() async throws {
        let (intelligence, store) = try makeIntelligence()
        let document = try await intelligence.importDocument(
            data: syllabus, fileName: "Linear Algebra Syllabus.md", origin: .share, now: now
        )

        #expect(document.title == "Grading" || document.title == "Linear Algebra Syllabus")
        #expect(document.chunkCount >= 2)
        // The document is also an entity, so it can be named, linked and forgotten like anything else.
        #expect(try await store.entity(document.id)?.kind == .document)
        let entry = try #require(try await store.activity().first)
        #expect(entry.kind == .imported)
        #expect(entry.canUndo)
    }

    @Test func theSameContentTwiceIsOneDocument() async throws {
        let (intelligence, store) = try makeIntelligence()
        let first = try await intelligence.importDocument(data: syllabus, fileName: "syllabus.md", now: now)
        let second = try await intelligence.importDocument(
            data: syllabus, fileName: "syllabus copy.md", now: now.addingTimeInterval(600)
        )
        #expect(first.id == second.id)
        #expect(try await store.documents().count == 1)
    }

    @Test func aQuestionFindsThePassageThatAnswersIt() async throws {
        let (intelligence, _) = try makeIntelligence()
        _ = try await intelligence.importDocument(data: syllabus, fileName: "Syllabus.md", now: now)

        let passages = try await intelligence.passages(for: "what happens if I hand work in late?", now: now)
        let best = try #require(passages.first)
        #expect(best.chunk.text.contains("10%"))
        #expect(best.citation.contains("Grading") || best.citation.contains("Syllabus"))

        let midterm = try await intelligence.passages(for: "when is the midterm?", now: now)
        #expect(midterm.first?.chunk.text.contains("fourth Friday") == true)
        // A question the documents do not answer returns nothing rather than the nearest thing.
        #expect(try await intelligence.passages(for: "what is the refund policy for parking?", now: now).isEmpty)
    }

    @Test func passagesFromTheProjectYouAreAskingAboutComeFirst() async throws {
        let (intelligence, store) = try makeIntelligence()
        let course = try await store.create(kind: .project, title: "Linear Algebra")
        _ = try await intelligence.importDocument(
            data: Data("The midterm covers eigenvalues.".utf8), fileName: "Other class notes.md", now: now
        )
        _ = try await intelligence.importDocument(
            data: syllabus, fileName: "Linear Algebra Syllabus.md", projectID: course.id,
            now: now.addingTimeInterval(60)
        )

        let passages = try await store.passages(
            matching: "when is the midterm", limit: 3, projectID: course.id, now: now
        )
        #expect(passages.first?.document.title.contains("Linear Algebra") == true
            || passages.first?.chunk.text.contains("fourth Friday") == true)
    }

    @Test func forgettingADocumentRemovesItsPassagesToo() async throws {
        let (intelligence, store) = try makeIntelligence()
        let document = try await intelligence.importDocument(data: syllabus, fileName: "syllabus.md", now: now)
        try await store.forgetDocument(document.id)

        #expect(try await store.document(document.id) == nil)
        #expect(try await store.entity(document.id) == nil)
        #expect(try await intelligence.passages(for: "late work", now: now).isEmpty)
    }

    @Test func aQuestionAboutADocumentReachesTheTurnContext() async throws {
        let (intelligence, _) = try makeIntelligence()
        _ = try await intelligence.importDocument(data: syllabus, fileName: "Syllabus.md", now: now)

        let context = try await intelligence.context(for: "what's the policy on late work?", now: now)
        let rendered = context.render()
        #expect(rendered.contains("10%"))
        #expect(rendered.contains("from "))
        #expect(context.lines.contains { $0.priority == .knowledge })

        // A command is not a question, and costs nothing.
        #expect(try await intelligence.context(for: "set a timer for five minutes", now: now).isEmpty)
    }
}
