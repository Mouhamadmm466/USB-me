import Core
import Foundation

/// Finds, in a partially generated model output, the point where the lead-in of a message
/// confirmation is already determined: `compose_message` with a finished `contact_query` value.
/// "Text Alex Kim:" can then be spoken (after native resolution) while the model is still writing
/// the message body. Only the lead-in is early; the action itself is still validated, resolved,
/// versioned and confirmed from the complete output.
public enum ConfirmationLead {
    /// Message body used for the read-only recipient probe (never shown or sent).
    public static let placeholderMessage = "\u{2026}"

    /// The finished `contact_query` of a `compose_message` proposal, or nil.
    public static func messageRecipient(in partialOutput: String) -> String? {
        guard partialOutput.contains(#""type":"proposed_action""#),
              let tool = partialOutput.range(of: #""tool":"compose_message""#),
              let key = partialOutput.range(of: #""contact_query":""#, range: tool.upperBound..<partialOutput.endIndex) else {
            return nil
        }
        var value = ""
        var index = key.upperBound
        while index < partialOutput.endIndex {
            let character = partialOutput[index]
            if character == "\\" { return nil } // escapes: leave it to the full pipeline
            if character == "\"" {
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
            value.append(character)
            index = partialOutput.index(after: index)
        }
        return nil // value still being generated
    }
}
