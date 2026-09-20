import Foundation
import Testing
@testable import ShareInbox

/// The inbox is a handoff between two processes, one of which the system can kill mid-sentence.
/// These tests are mostly about what happens when it does.
@Suite struct ShareInboxTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeInbox() -> (ShareInbox, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "inbox-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (ShareInbox(directory: root), root)
    }

    private func file(_ name: String, _ contents: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "\(UUID().uuidString)-\(name)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func aSharedFileIsWaitingWhenTheAppNextLooks() throws {
        let (inbox, _) = makeInbox()
        let source = try file("report.pdf", "%PDF-1.7 pretend")

        let written = try inbox.accept(fileAt: source, title: "Q3 report",
                                       mediaType: "application/pdf", now: now)
        let pending = inbox.pending()

        #expect(pending.count == 1)
        #expect(pending.first == written)
        #expect(pending.first?.kind == .document)
        #expect(pending.first?.title == "Q3 report")
        #expect(try String(decoding: inbox.data(of: written), as: UTF8.self) == "%PDF-1.7 pretend")
    }

    @Test func textAndLinksBecomeSomethingTheAppCanReadTheSameWay() throws {
        let (inbox, _) = makeInbox()

        let note = try inbox.accept(text: "Remember the mains voltage is 230V.", kind: .text,
                                    title: "Note", now: now)
        let link = try inbox.accept(text: "https://example.org/spec", kind: .link,
                                    title: "example.org", now: now)

        #expect(inbox.pending().count == 2)
        #expect(note.mediaType == "text/plain")
        #expect(try String(decoding: inbox.data(of: link), as: UTF8.self) == "https://example.org/spec")
        // A link is kept as an address. Nothing fetched it.
        #expect(link.kind == .link)
        #expect(link.byteCount == 24)
    }

    @Test func theOldestThingIsReadFirst() throws {
        let (inbox, _) = makeInbox()
        try inbox.accept(text: "second", kind: .text, title: "B", now: now.addingTimeInterval(60))
        try inbox.accept(text: "first", kind: .text, title: "A", now: now)

        #expect(inbox.pending().map(\.title) == ["A", "B"])
    }

    @Test func anInterruptedShareIsSweptRatherThanReported() throws {
        let (inbox, root) = makeInbox()
        let item = try inbox.accept(text: "half a share", kind: .text, title: "Note", now: now)
        // The extension was killed between copying the payload and... no: the manifest is written
        // last, so the failure that leaves state behind is the other one — a payload that went away.
        try FileManager.default.removeItem(at: inbox.payload(of: item))

        #expect(inbox.pending().isEmpty)
        // And the orphan manifest is gone, not left to be re-read forever.
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
        #expect(left.isEmpty)
    }

    @Test func nonsenseInTheDirectoryDoesNotStopTheRest() throws {
        let (inbox, root) = makeInbox()
        try inbox.accept(text: "real", kind: .text, title: "Real", now: now)
        try Data("{not json".utf8).write(to: root.appending(path: "\(UUID().uuidString).json"))

        #expect(inbox.pending().map(\.title) == ["Real"])
    }

    @Test func readingSomethingDoesNotRemoveIt() throws {
        let (inbox, _) = makeInbox()
        let item = try inbox.accept(text: "keep me", kind: .text, title: "Note", now: now)

        _ = try inbox.data(of: item)
        // Import can fail; the item has to still be there to try again.
        #expect(inbox.pending().count == 1)

        inbox.remove(item)
        #expect(inbox.pending().isEmpty)
    }

    @Test func nothingHugeGetsIn() throws {
        let (inbox, _) = makeInbox()
        let big = String(repeating: "x", count: ShareInbox.maximumBytes + 1)

        #expect(throws: ShareInboxError.tooLarge(limitBytes: ShareInbox.maximumBytes)) {
            try inbox.accept(text: big, kind: .text, title: "Huge", now: now)
        }
        #expect(inbox.pending().isEmpty)
    }

    @Test func aForgottenInboxStopsAcceptingRatherThanGrowing() throws {
        let (inbox, _) = makeInbox()
        for index in 0..<ShareInbox.maximumPending {
            try inbox.accept(text: "note \(index)", kind: .text, title: "N\(index)", now: now)
        }

        #expect(throws: ShareInboxError.inboxFull(limit: ShareInbox.maximumPending)) {
            try inbox.accept(text: "one too many", kind: .text, title: "N", now: now)
        }
        #expect(inbox.pending().count == ShareInbox.maximumPending)
    }

    @Test func aFileNameFromAnotherAppCannotShapeThePath() throws {
        // The name comes from a process we do not control and is about to become part of a path.
        #expect(ShareInbox.extensionOf(URL(fileURLWithPath: "/tmp/a.pdf")) == "pdf")
        #expect(ShareInbox.extensionOf(URL(fileURLWithPath: "/tmp/a.PDF")) == "pdf")
        #expect(ShareInbox.extensionOf(URL(fileURLWithPath: "/tmp/no-extension")) == "dat")
        #expect(ShareInbox.extensionOf(URL(fileURLWithPath: "/tmp/a.verylongextension")) == "dat")
        #expect(ShareInbox.extensionOf(URL(fileURLWithPath: "/tmp/a.p df")) == "dat")
    }

    @Test func emptyingItLeavesNothingBehind() throws {
        let (inbox, root) = makeInbox()
        try inbox.accept(text: "one", kind: .text, title: "A", now: now)
        try inbox.accept(text: "two", kind: .text, title: "B", now: now)

        inbox.empty()

        #expect(inbox.pending().isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
        #expect(left.isEmpty)
    }
}
