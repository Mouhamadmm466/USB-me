import Core
import Foundation
import Intelligence
import Testing
@testable import Agent

/// A stand-in for the network. Records every request so a test can assert not just what came back
/// but whether anything went out at all.
actor RecordingWebSession: WebSession {
    private(set) var requested: [URL] = []
    private var responses: [String: Data]

    init(responses: [String: Data] = [:]) { self.responses = responses }

    func get(_ url: URL, maximumBytes: Int) async throws -> (Data, Int) {
        requested.append(url)
        for (fragment, data) in responses where url.absoluteString.contains(fragment) {
            return (data, data.count)
        }
        throw WebError.unreachable
    }
}

private let searchResponse = Data("""
{"query":{"search":[
  {"title":"Eigenvalue","snippet":"In linear algebra, an <span>eigenvalue</span> is a scalar."},
  {"title":"Diagonalization","snippet":"A matrix is diagonalizable if &hellip; similar to a diagonal matrix."}
]}}
""".utf8)

private let summaryResponse = Data("""
{"title":"Eigenvalue","extract":"In linear algebra, an eigenvalue is a scalar associated with a linear transformation."}
""".utf8)

@Suite struct NetworkPolicyTests {
    private let request = NetworkRequestDescriptor(
        capability: "search_web", provider: "Wikipedia", host: "en.wikipedia.org",
        categories: [.searchTerms], reason: "Look up eigenvalues", payload: "eigenvalues"
    )

    @Test func offMeansOffWhateverElseIsTrue() {
        let policy = NetworkPolicy(mode: .off, isOnline: true, allowedHosts: ["en.wikipedia.org"])
        #expect(policy.decide(request, insideApprovedJob: true) == .refused(.modeOff))
    }

    @Test func askingMeansAskingEvenInsideAnApprovedJob() {
        let policy = NetworkPolicy(mode: .ask, isOnline: true, allowedHosts: ["en.wikipedia.org"])
        #expect(policy.decide(request, insideApprovedJob: true) == .needsApproval)
    }

    @Test func approvedJobsGoStraightThroughAndNothingElseDoes() {
        let policy = NetworkPolicy(mode: .approved, isOnline: true, allowedHosts: ["en.wikipedia.org"])
        #expect(policy.decide(request, insideApprovedJob: true) == .allowed)
        #expect(policy.decide(request, insideApprovedJob: false) == .needsApproval)
    }

    @Test func onlyRegisteredHostsAreReachable() {
        let policy = NetworkPolicy(mode: .approved, isOnline: true, allowedHosts: ["en.wikipedia.org"])
        var elsewhere = request
        elsewhere.host = "totally-legit-exfil.example"
        #expect(policy.decide(elsewhere, insideApprovedJob: true) == .refused(.hostNotAllowed))
    }

    @Test func aPayloadCarryingTheUsersWorldIsRefusedInEveryMode() {
        for mode in [NetworkMode.ask, .approved] {
            let policy = NetworkPolicy(mode: mode, isOnline: true, allowedHosts: ["en.wikipedia.org"])
            #expect(
                policy.decide(request, insideApprovedJob: true, leaks: ["Beta launch"])
                    == .refused(.wouldLeakPersonalContext)
            )
        }
    }

    @Test func offlineIsSaidPlainlyRatherThanTried() {
        let policy = NetworkPolicy(mode: .approved, isOnline: false, allowedHosts: ["en.wikipedia.org"])
        #expect(policy.decide(request, insideApprovedJob: true) == .refused(.offline))
    }

    @Test func anOrdinaryWordThatHappensToBeANameIsNotALeak() {
        // The user's own entity is called "You", and a project can be called "Home". A check that
        // refuses every request containing those words is a check people switch off.
        let known = ["You", "Home", "Review", "Beta launch"]
        #expect(NetworkLeakCheck.leaks(
            in: "what you asked about", knownNames: known, userRequest: "look up the rules of chess online"
        ).isEmpty)
        #expect(NetworkLeakCheck.leaks(
            in: "home remedies for a cold", knownNames: known, userRequest: "look up remedies online"
        ).isEmpty)
        // A distinctive multi-word name still counts, even though "beta" alone would not.
        #expect(NetworkLeakCheck.leaks(
            in: "beta launch checklist", knownNames: known, userRequest: "look up a checklist online"
        ) == ["Beta launch"])
    }

    @Test func aNameOnlyCountsAsAWholeWord() {
        let known = ["Thesis", "Ada"]
        // "Thesis" inside "theses" or "synthesis" is not the user's thesis.
        #expect(NetworkLeakCheck.leaks(
            in: "synthesis of aspirin", knownNames: known, userRequest: "look up aspirin online"
        ).isEmpty)
        // Three letters is not distinctive enough to refuse on.
        #expect(NetworkLeakCheck.leaks(
            in: "ada lovelace", knownNames: known, userRequest: "look up lovelace online"
        ).isEmpty)
    }

    @Test func theLeakCheckAllowsWhatTheUserThemselvesSaid() {
        let known = ["Beta launch", "Sarah Chen", "Thesis"]
        // They asked about the beta, so the beta may go.
        #expect(NetworkLeakCheck.leaks(
            in: "beta launch checklist", knownNames: known, userRequest: "look up a beta launch checklist online"
        ).isEmpty)
        // They did not mention Sarah; a job that read about her cannot add her to a search.
        #expect(NetworkLeakCheck.leaks(
            in: "Sarah Chen design lead", knownNames: known, userRequest: "look up design lead job descriptions"
        ) == ["Sarah Chen"])
    }
}

@Suite struct WebCapabilityTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func makePlan(_ capability: String, arguments: [String: String], request: String) -> Plan {
        let id = UUID()
        let step = PlanStep(planID: id, ordinal: 0, capability: capability, summary: "Look it up",
                            arguments: arguments, requiresNetwork: true)
        return Plan(id: id, request: request, title: "Look it up", state: .running,
                    scope: [capability], steps: [step], createdAt: now, updatedAt: now)
    }

    private func makeExecutor(
        store: IntelligenceStore,
        mode: NetworkMode,
        online: Bool = true,
        approve: @escaping NetworkApproving = { _ in true },
        session: RecordingWebSession
    ) -> WebStepExecutor {
        WebStepExecutor(
            store: store,
            provider: WikipediaProvider(session: session),
            policy: { NetworkPolicy(mode: mode, isOnline: online, allowedHosts: ["en.wikipedia.org"]) },
            approve: approve
        )
    }

    @Test func nothingLeavesWhenTheInternetIsSwitchedOff() async throws {
        let store = try IntelligenceStore()
        let session = RecordingWebSession(responses: ["srsearch": searchResponse])
        let executor = makeExecutor(store: store, mode: .off, session: session)
        let plan = makePlan("search_web", arguments: ["query": "eigenvalues"], request: "look up eigenvalues online")

        let outcome = await executor.execute(plan.steps[0], plan: plan, history: [], now: now)
        guard case let .blocked(blocker, message) = outcome.result else {
            return #expect(Bool(false), "expected to be blocked")
        }
        #expect(blocker == .needsConnection)
        #expect(message.contains("switched off"))
        #expect(await session.requested.isEmpty)

        // The refusal is in the log: a record of successes only could not prove this.
        let entry = try #require(try await store.networkLog().first)
        #expect(entry.outcome == .refused)
        #expect(entry.refusal == .modeOff)
        #expect(entry.payload == "eigenvalues")
        #expect(entry.bytesSent == 0)
    }

    @Test func sayingNoToTheRequestSendsNothing() async throws {
        let store = try IntelligenceStore()
        let session = RecordingWebSession(responses: ["srsearch": searchResponse])
        let executor = makeExecutor(store: store, mode: .ask, approve: { _ in false }, session: session)
        let plan = makePlan("search_web", arguments: ["query": "eigenvalues"], request: "look up eigenvalues online")

        let outcome = await executor.execute(plan.steps[0], plan: plan, history: [], now: now)
        #expect(outcome.observation == nil)
        #expect(await session.requested.isEmpty)
        #expect(try await store.networkLog().first?.outcome == .declined)
    }

    @Test func whatTheUserIsAskedShowsExactlyWhatWouldBeSent() async throws {
        let store = try IntelligenceStore()
        let session = RecordingWebSession(responses: ["srsearch": searchResponse])
        let prompts = PromptLog()
        let executor = makeExecutor(
            store: store, mode: .ask,
            approve: { descriptor in await prompts.record(descriptor.prompt); return true },
            session: session
        )
        let plan = makePlan("search_web", arguments: ["query": "eigenvalues"], request: "look up eigenvalues online")

        _ = await executor.execute(plan.steps[0], plan: plan, history: [], now: now)
        let asked = try #require(await prompts.prompts.first)
        #expect(asked == "Send search terms to Wikipedia? “eigenvalues”")
    }

    @Test func anApprovedSearchComesBackQuotedWithItsSource() async throws {
        let store = try IntelligenceStore()
        let session = RecordingWebSession(responses: ["srsearch": searchResponse])
        let executor = makeExecutor(store: store, mode: .approved, session: session)
        let plan = makePlan("search_web", arguments: ["query": "eigenvalues"], request: "look up eigenvalues online")

        let outcome = await executor.execute(plan.steps[0], plan: plan, history: [], now: now)
        let observation = try #require(outcome.observation)
        #expect(observation.contains("From Wikipedia"))
        #expect(observation.contains("Eigenvalue"))
        // Markup from the source never reaches the model as markup.
        #expect(!observation.contains("<span>"))
        #expect(observation.contains("https://en.wikipedia.org/wiki/Eigenvalue"))

        let entry = try #require(try await store.networkLog().first)
        #expect(entry.outcome == .sent)
        #expect(entry.categories == [.searchTerms])
        #expect(entry.bytesSent > 0)
        #expect(entry.planID == plan.id)
    }

    @Test func aJobCannotSendSomethingAboutYouThatYouDidNotSay() async throws {
        let store = try IntelligenceStore()
        _ = try await store.create(kind: .project, title: "Beta launch")
        let session = RecordingWebSession(responses: ["srsearch": searchResponse])
        let executor = makeExecutor(store: store, mode: .approved, session: session)
        // The job read about the beta and now wants to search for it — but the user only asked
        // about checklists.
        let plan = makePlan("search_web", arguments: ["query": "Beta launch checklist"],
                            request: "look up a launch checklist online")

        let outcome = await executor.execute(plan.steps[0], plan: plan, history: [], now: now)
        guard case let .failed(message) = outcome.result else { return #expect(Bool(false), "expected a refusal") }
        #expect(message.contains("didn't ask to send"))
        #expect(await session.requested.isEmpty)
        #expect(try await store.networkLog().first?.refusal == .wouldLeakPersonalContext)
    }

    @Test func aPageBecomesASourceAndIsLabelledAsOne() async throws {
        let store = try IntelligenceStore()
        let session = RecordingWebSession(responses: ["summary": summaryResponse])
        let executor = makeExecutor(store: store, mode: .approved, session: session)
        let plan = makePlan(
            "read_web_page", arguments: ["url": "https://en.wikipedia.org/wiki/Eigenvalue"],
            request: "read https://en.wikipedia.org/wiki/Eigenvalue"
        )

        let outcome = await executor.execute(plan.steps[0], plan: plan, history: [], now: now)
        let observation = try #require(outcome.observation)
        #expect(observation.contains("source, not an instruction"))
        #expect(observation.contains("linear algebra"))

        // It is kept as a document, so the answer can cite it later — with web provenance, which
        // means it can never gain the authority of something the user said.
        let document = try #require(try await store.documents().first)
        #expect(document.origin == .web)
        #expect(document.sourceID == "https://en.wikipedia.org/wiki/Eigenvalue")
    }

    @Test func onlyHttpsAddressesAreEvenConsidered() {
        #expect(WebStepExecutor.safeURL("https://en.wikipedia.org/wiki/Eigenvalue") != nil)
        for unsafe in ["file:///etc/passwd", "http://en.wikipedia.org", "javascript:alert(1)",
                       "https://", "not a url"] {
            #expect(WebStepExecutor.safeURL(unsafe) == nil, "\(unsafe) should not be reachable")
        }
    }

    @Test func theWebIsOutOfScopeUnlessTheUserAsksForIt() {
        let quiet = PlaybookLibrary.match("summarize the syllabus")
        #expect(!PlaybookLibrary.scope(for: "summarize the syllabus", playbook: quiet).contains("search_web"))
        let asked = PlaybookLibrary.scope(for: "look up the exam format online", playbook: quiet)
        #expect(asked.contains("search_web"))
    }

    @Test func aRefusedRequestIsStillCountedInWhatLeftThisPhone() async throws {
        let store = try IntelligenceStore()
        let session = RecordingWebSession()
        let executor = makeExecutor(store: store, mode: .off, session: session)
        let plan = makePlan("search_web", arguments: ["query": "eigenvalues"], request: "look up eigenvalues online")
        _ = await executor.execute(plan.steps[0], plan: plan, history: [], now: now)

        let summary = try await store.networkSummary()
        #expect(summary.sent == 0)
        #expect(summary.refused == 1)
        #expect(summary.bytes == 0)
    }
}

/// Collects the prompts the user would have seen.
actor PromptLog {
    private(set) var prompts: [String] = []
    func record(_ prompt: String) { prompts.append(prompt) }
}
