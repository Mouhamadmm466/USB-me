import Core
import Testing
@testable import LLM

@Suite struct OutputValidatorTests {
    let validator = OutputValidator()

    private func action(_ json: String) throws -> ProposedToolCall {
        let result = validator.validate(json)
        guard case let .success(.proposedAction(call, _)) = result else {
            Issue.record("expected proposed action, got \(result)")
            throw ValidationTestError.unexpected
        }
        return call
    }

    enum ValidationTestError: Error { case unexpected }

    @Test func acceptsCanonicalComposeMessage() throws {
        let call = try action(#"{"type":"proposed_action","tool":"compose_message","arguments":{"contact_query":"Alex","message":"I'll be 20 minutes late."},"requires_confirmation":true}"#)
        #expect(call.tool == .composeMessage)
        #expect(call.string("contact_query") == "Alex")
        #expect(call.string("message") == "I'll be 20 minutes late.")
    }

    @Test func acceptsSpeechTypes() {
        #expect(validator.validate(#"{"type":"answer","speech":"It's 12."}"#) == .success(.answer(speech: "It's 12.")))
        #expect(validator.validate(#"{"type":"clarification","speech":"What should it say?"}"#) == .success(.clarification(speech: "What should it say?")))
        #expect(validator.validate(#"{"type":"unsupported","speech":"I can't do that."}"#) == .success(.unsupported(speech: "I can't do that.")))
    }

    @Test func toleratesWhitespaceBetweenTokens() throws {
        let call = try action("""
        { "type" : "proposed_action", "tool" : "create_reminder", "arguments" : { "title" : "Buy milk" }, "requires_confirmation" : true }
        """)
        #expect(call.string("title") == "Buy milk")
    }

    @Test(arguments: [
        ("", OutputValidationError.malformedJSON),
        ("not json", .malformedJSON),
        (#"{"type":"answer","speech":"hi""#, .malformedJSON),
        (#"{"type":"answer","speech":"hi"} trailing"#, .malformedJSON),
        (#"["answer"]"#, .notAnObject),
        (#"{"speech":"hi"}"#, .missingField("type")),
        (#"{"type":7,"speech":"hi"}"#, .wrongFieldType("type")),
        (#"{"type":"execute","speech":"hi"}"#, .unknownType("execute")),
        (#"{"type":"answer"}"#, .missingField("speech")),
        (#"{"type":"answer","speech":"   "}"#, .emptyValue(field: "speech")),
        (#"{"type":"answer","speech":"hi","tool":"compose_message"}"#, .unexpectedField("tool")),
        (#"{"type":"answer","speech":"hi","speech":"again"}"#, .malformedJSON),
        (#"{"type":"answer","speech":"line\nbreak"}"#, .disallowedCharacters(field: "speech")),
        (#"{"type":"proposed_action","arguments":{}}"#, .missingField("tool")),
        (#"{"type":"proposed_action","tool":"send_email","arguments":{}}"#, .unknownTool("send_email")),
        (#"{"type":"proposed_action","tool":"create_reminder"}"#, .missingField("arguments")),
        (#"{"type":"proposed_action","tool":"create_reminder","arguments":"x"}"#, .wrongFieldType("arguments")),
        (#"{"type":"proposed_action","tool":"create_reminder","arguments":{"title":"a"},"requires_confirmation":"yes"}"#, .wrongFieldType("requires_confirmation")),
        (#"{"type":"proposed_action","tool":"create_reminder","arguments":{"title":"a"},"execute_now":true}"#, .unexpectedField("execute_now")),
    ])
    func rejectsMalformedOrUnknown(input: String, expected: OutputValidationError) {
        #expect(validator.validate(input) == .failure(expected))
    }

    @Test func rejectsUnknownArgument() {
        let result = validator.validate(#"{"type":"proposed_action","tool":"compose_message","arguments":{"contact_query":"Alex","message":"hi","contact_id":"123"},"requires_confirmation":true}"#)
        #expect(result == .failure(.unknownArgument(tool: .composeMessage, argument: "contact_id")))
    }

    @Test func rejectsMissingRequiredArgument() {
        let result = validator.validate(#"{"type":"proposed_action","tool":"compose_message","arguments":{"contact_query":"Alex"},"requires_confirmation":true}"#)
        #expect(result == .failure(.missingRequiredArgument(tool: .composeMessage, argument: "message")))
    }

    @Test func reportsEmptyRequiredArgumentDistinctly() {
        let result = validator.validate(#"{"type":"proposed_action","tool":"compose_message","arguments":{"contact_query":"Alex","message":"  "},"requires_confirmation":true}"#)
        #expect(result == .failure(.emptyValue(field: "message")))
    }

    @Test func enforcesAtLeastOneRecipient() {
        let result = validator.validate(#"{"type":"proposed_action","tool":"compose_message","arguments":{"message":"hi"},"requires_confirmation":true}"#)
        #expect(result == .failure(.missingOneOf(tool: .composeMessage, arguments: ["contact_query", "phone_number"])))
    }

    @Test func rejectsInvalidEnum() {
        let result = validator.validate(#"{"type":"proposed_action","tool":"open_supported_app","arguments":{"app":"terminal"},"requires_confirmation":false}"#)
        #expect(result == .failure(.invalidEnumValue(tool: .openSupportedApp, argument: "app")))
    }

    @Test func normalizesEnumCase() throws {
        let call = try action(#"{"type":"proposed_action","tool":"open_supported_app","arguments":{"app":"Maps","query":"coffee"},"requires_confirmation":false}"#)
        #expect(call.string("app") == "maps")
    }

    @Test func rejectsOversizedValues() {
        let long = String(repeating: "a", count: 501)
        let result = validator.validate(#"{"type":"proposed_action","tool":"compose_message","arguments":{"contact_query":"Alex","message":"\#(long)"},"requires_confirmation":true}"#)
        #expect(result == .failure(.valueTooLong(field: "message", limit: 500)))
        let hugeOutput = String(repeating: " ", count: 5_000)
        #expect(validator.validate(hugeOutput) == .failure(.valueTooLong(field: "output", limit: OutputValidator.maxOutputBytes)))
    }

    @Test func integerRules() throws {
        let call = try action(#"{"type":"proposed_action","tool":"create_calendar_event","arguments":{"title":"Run","start":"tomorrow at 7","duration_minutes":45},"requires_confirmation":true}"#)
        #expect(call.integer("duration_minutes") == 45)
        #expect(validator.validate(#"{"type":"proposed_action","tool":"create_calendar_event","arguments":{"title":"Run","start":"x","duration_minutes":0},"requires_confirmation":true}"#)
            == .failure(.valueOutOfRange(field: "duration_minutes")))
        #expect(validator.validate(#"{"type":"proposed_action","tool":"create_calendar_event","arguments":{"title":"Run","start":"x","duration_minutes":"45"},"requires_confirmation":true}"#)
            == .failure(.wrongFieldType("duration_minutes")))
        #expect(validator.validate(#"{"type":"proposed_action","tool":"create_calendar_event","arguments":{"title":"Run","start":"x","duration_minutes":4.5},"requires_confirmation":true}"#)
            == .failure(.wrongFieldType("duration_minutes")))
    }

    @Test(arguments: [
        ("555 010 4477", "5550104477"),
        ("+1 (555) 010-4477", "+15550104477"),
        ("555.010.4477", "5550104477"),
    ])
    func phoneNormalization(input: String, expected: String) {
        #expect(OutputValidator.normalizedPhone(input) == expected)
    }

    @Test(arguments: ["12", "555-010-4477 ext 9", "1+555", "123456789012345678901", "tel:5550104477", ""])
    func phoneRejections(input: String) {
        #expect(OutputValidator.normalizedPhone(input) == nil)
    }

    @Test func requiresConfirmationFlagIsRecordedNotTrusted() {
        let result = validator.validate(#"{"type":"proposed_action","tool":"initiate_call","arguments":{"contact_query":"Mom"},"requires_confirmation":false}"#)
        guard case let .success(.proposedAction(call, flag)) = result else {
            Issue.record("expected proposal"); return
        }
        #expect(flag == false)
        // Policy comes from the risk level, not the model's flag.
        #expect(ToolCatalog.spec(for: call.tool).riskLevel.requiresConfirmation)
    }

    @Test func collapsesWhitespaceInText() throws {
        let call = try action(#"{"type":"proposed_action","tool":"create_reminder","arguments":{"title":"  buy   milk  "},"requires_confirmation":true}"#)
        #expect(call.string("title") == "buy milk")
    }

    @Test func explicitNullIsTreatedAsAbsent() throws {
        let call = try action(#"{"type":"proposed_action","tool":"create_reminder","arguments":{"title":"x","due":null},"requires_confirmation":true}"#)
        #expect(call.string("due") == nil)
    }
}

@Suite struct StrictJSONParserTests {
    @Test func parsesNestedValues() throws {
        let value = try StrictJSONParser.parse(#"{"a":[1,2.5,true,false,null,"x\"yé😀"]}"#)
        #expect(value == .object(["a": .array([.integer(1), .double(2.5), .bool(true), .bool(false), .null, .string("x\"yé😀")])]))
    }

    @Test(arguments: [
        #"{"a":1,"a":2}"#, #"{"a":01}"#, #"{"a":1,}"#, #"{a:1}"#, #"{"a":"\x"}"#, #"{"a":"unterminated}"#,
        #"[[[[[[[[[[1]]]]]]]]]]"#, #"{"a":1} {"b":2}"#, #"{"a":NaN}"#, #"{"a":"\ud83d"}"#,
    ])
    func rejectsInvalid(input: String) {
        #expect(throws: (any Error).self) { try StrictJSONParser.parse(input) }
    }
}
