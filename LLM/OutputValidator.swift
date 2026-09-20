import Core
import Foundation

/// Strict validator for model output (PRD §7). The grammar already constrains decoding, but this
/// validator trusts nothing: unknown type, unknown tool, unknown/missing argument, invalid enum,
/// oversized value, wrong JSON type, duplicate keys or malformed JSON are all rejected.
public struct OutputValidator: Sendable {
    public static let maxSpeechLength = 600
    public static let maxOutputBytes = 4_096

    public init() {}

    public func validate(_ text: String) -> Result<AgentOutput, OutputValidationError> {
        guard text.utf8.count <= Self.maxOutputBytes else { return .failure(.valueTooLong(field: "output", limit: Self.maxOutputBytes)) }
        let value: StrictJSON
        do {
            value = try StrictJSONParser.parse(text)
        } catch {
            return .failure(.malformedJSON)
        }
        guard case let .object(fields) = value else { return .failure(.notAnObject) }
        guard let typeValue = fields["type"] else { return .failure(.missingField("type")) }
        guard case let .string(typeString) = typeValue else { return .failure(.wrongFieldType("type")) }
        guard let type = AgentOutputType(rawValue: typeString) else { return .failure(.unknownType(typeString)) }

        switch type {
        case .answer, .clarification, .unsupported:
            for key in fields.keys where key != "type" && key != "speech" {
                return .failure(.unexpectedField(key))
            }
            let speech: String
            switch Self.text(fields["speech"], field: "speech", maxLength: Self.maxSpeechLength) {
            case let .success(value): speech = value
            case let .failure(error): return .failure(error)
            }
            switch type {
            case .answer: return .success(.answer(speech: speech))
            case .clarification: return .success(.clarification(speech: speech))
            default: return .success(.unsupported(speech: speech))
            }

        case .task:
            for key in fields.keys where key != "type" && key != "outcome" {
                return .failure(.unexpectedField(key))
            }
            switch Self.text(fields["outcome"], field: "outcome", maxLength: Self.maxSpeechLength) {
            case let .success(outcome): return .success(.task(outcome: outcome))
            case let .failure(error): return .failure(error)
            }

        case .proposedAction:
            let allowed: Set<String> = ["type", "tool", "arguments", "requires_confirmation", "speech"]
            for key in fields.keys where !allowed.contains(key) {
                return .failure(.unexpectedField(key))
            }
            guard let toolValue = fields["tool"] else { return .failure(.missingField("tool")) }
            guard case let .string(toolName) = toolValue else { return .failure(.wrongFieldType("tool")) }
            guard let tool = ToolID(rawValue: toolName) else { return .failure(.unknownTool(toolName)) }
            guard let argumentsValue = fields["arguments"] else { return .failure(.missingField("arguments")) }
            guard case let .object(arguments) = argumentsValue else { return .failure(.wrongFieldType("arguments")) }
            var requiresConfirmation = true
            if let flag = fields["requires_confirmation"] {
                guard case let .bool(value) = flag else { return .failure(.wrongFieldType("requires_confirmation")) }
                requiresConfirmation = value
            }
            if let speech = fields["speech"] {
                // Accepted for contract compatibility but never spoken: consequential actions are
                // always described by Swift from the resolved action.
                guard case .string = speech else { return .failure(.wrongFieldType("speech")) }
            }
            switch validateArguments(arguments, for: ToolCatalog.spec(for: tool)) {
            case let .success(call):
                return .success(.proposedAction(call, modelRequestedConfirmation: requiresConfirmation))
            case let .failure(error):
                return .failure(error)
            }
        }
    }

    public func validateArguments(_ arguments: [String: StrictJSON], for spec: ToolSpec) -> Result<ProposedToolCall, OutputValidationError> {
        var validated: [String: ToolArgumentValue] = [:]
        for (name, raw) in arguments {
            guard let argument = spec.argument(named: name) else {
                return .failure(.unknownArgument(tool: spec.id, argument: name))
            }
            if case .null = raw { continue } // explicit null == absent
            switch argument.kind {
            case let .text(maxLength):
                switch Self.text(raw, field: name, maxLength: maxLength) {
                case let .success(value): validated[name] = .string(value)
                case let .failure(error): return .failure(error)
                }
            case .phoneNumber:
                guard case let .string(value) = raw else { return .failure(.wrongFieldType(name)) }
                guard let phone = Self.normalizedPhone(value) else { return .failure(.invalidPhoneNumber) }
                validated[name] = .string(phone)
            case let .integer(range):
                guard case let .integer(value) = raw else { return .failure(.wrongFieldType(name)) }
                guard range.contains(value) else { return .failure(.valueOutOfRange(field: name)) }
                validated[name] = .integer(value)
            case let .choice(values):
                guard case let .string(value) = raw else { return .failure(.wrongFieldType(name)) }
                let normalized = value.trimmingCharacters(in: .whitespaces).lowercased()
                guard values.contains(normalized) else { return .failure(.invalidEnumValue(tool: spec.id, argument: name)) }
                validated[name] = .string(normalized)
            }
        }
        for argument in spec.arguments where argument.isRequired && validated[argument.name] == nil {
            if arguments[argument.name] != nil {
                return .failure(.emptyValue(field: argument.name))
            }
            return .failure(.missingRequiredArgument(tool: spec.id, argument: argument.name))
        }
        for group in spec.atLeastOneOf where !group.contains(where: { validated[$0] != nil }) {
            return .failure(.missingOneOf(tool: spec.id, arguments: group))
        }
        return .success(ProposedToolCall(tool: spec.id, arguments: validated))
    }

    // MARK: - Field rules

    static func text(_ raw: StrictJSON?, field: String, maxLength: Int) -> Result<String, OutputValidationError> {
        guard let raw else { return .failure(.missingField(field)) }
        guard case let .string(value) = raw else { return .failure(.wrongFieldType(field)) }
        if value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != " " }) {
            return .failure(.disallowedCharacters(field: field))
        }
        let collapsed = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return .failure(.emptyValue(field: field)) }
        guard collapsed.count <= maxLength else { return .failure(.valueTooLong(field: field, limit: maxLength)) }
        return .success(collapsed)
    }

    /// Accepts digits with common separators and an optional leading "+". 3–20 digits.
    public static func normalizedPhone(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var digits = ""
        for (index, character) in trimmed.enumerated() {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else if character == "+" {
                guard index == 0 else { return nil }
            } else if !" ()-.".contains(character) {
                return nil
            }
        }
        guard (3...20).contains(digits.count) else { return nil }
        return trimmed.hasPrefix("+") ? "+" + digits : digits
    }
}

// MARK: - Strict JSON

/// Minimal JSON value used at the model-output trust boundary.
public enum StrictJSON: Sendable, Equatable {
    case object([String: StrictJSON])
    case array([StrictJSON])
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case null
}

public enum StrictJSONError: Error, Equatable {
    case unexpectedEnd
    case unexpectedCharacter(Int)
    case duplicateKey(String)
    case invalidEscape
    case invalidNumber
    case trailingContent
    case tooDeep
}

/// RFC 8259 parser that rejects duplicate keys, trailing content, and nesting deeper than 8.
public enum StrictJSONParser {
    public static func parse(_ text: String) throws -> StrictJSON {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw StrictJSONError.trailingContent }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func parseValue(depth: Int) throws -> StrictJSON {
            guard depth <= 8 else { throw StrictJSONError.tooDeep }
            guard index < bytes.count else { throw StrictJSONError.unexpectedEnd }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
            default: throw StrictJSONError.unexpectedCharacter(index)
            }
        }

        mutating func expect(_ literal: String) throws {
            for byte in literal.utf8 {
                guard index < bytes.count, bytes[index] == byte else { throw StrictJSONError.unexpectedCharacter(index) }
                index += 1
            }
        }

        mutating func parseObject(depth: Int) throws -> StrictJSON {
            index += 1
            var result: [String: StrictJSON] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(result) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw StrictJSONError.unexpectedCharacter(index) }
                let key = try parseString()
                guard result[key] == nil else { throw StrictJSONError.duplicateKey(key) }
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                result[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                guard index < bytes.count else { throw StrictJSONError.unexpectedEnd }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(result) }
                throw StrictJSONError.unexpectedCharacter(index)
            }
        }

        mutating func parseArray(depth: Int) throws -> StrictJSON {
            index += 1
            var result: [StrictJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(result) }
            while true {
                skipWhitespace()
                result.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw StrictJSONError.unexpectedEnd }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(result) }
                throw StrictJSONError.unexpectedCharacter(index)
            }
        }

        mutating func parseString() throws -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var raw: [UInt8] = []
            func flush() throws {
                if !raw.isEmpty {
                    guard let chunk = String(bytes: raw, encoding: .utf8) else { throw StrictJSONError.invalidEscape }
                    scalars.append(contentsOf: chunk.unicodeScalars)
                    raw.removeAll(keepingCapacity: true)
                }
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    try flush()
                    return String(scalars)
                }
                if byte < 0x20 { throw StrictJSONError.unexpectedCharacter(index) }
                if byte == UInt8(ascii: "\\") {
                    try flush()
                    index += 1
                    guard index < bytes.count else { throw StrictJSONError.unexpectedEnd }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        var code = try parseHex4()
                        if (0xD800...0xDBFF).contains(code) {
                            try expect("\\u")
                            let low = try parseHex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw StrictJSONError.invalidEscape }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(code) else { throw StrictJSONError.invalidEscape }
                        scalars.append(scalar)
                    default:
                        throw StrictJSONError.invalidEscape
                    }
                    continue
                }
                raw.append(byte)
                index += 1
            }
            throw StrictJSONError.unexpectedEnd
        }

        mutating func parseHex4() throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw StrictJSONError.unexpectedEnd }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                index += 1
                value <<= 4
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): value |= UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): value |= UInt32(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): value |= UInt32(byte - UInt8(ascii: "A") + 10)
                default: throw StrictJSONError.invalidEscape
                }
            }
            return value
        }

        mutating func parseNumber() throws -> StrictJSON {
            let start = index
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count else { throw StrictJSONError.invalidNumber }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else if (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(bytes[index]) {
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            } else {
                throw StrictJSONError.invalidNumber
            }
            var isInteger = true
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                isInteger = false
                index += 1
                let digitsStart = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                guard index > digitsStart else { throw StrictJSONError.invalidNumber }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                isInteger = false
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                let digitsStart = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                guard index > digitsStart else { throw StrictJSONError.invalidNumber }
            }
            let literal = String(decoding: bytes[start..<index], as: UTF8.self)
            if isInteger, let value = Int(literal) { return .integer(value) }
            guard let value = Double(literal), value.isFinite else { throw StrictJSONError.invalidNumber }
            return .double(value)
        }
    }
}
