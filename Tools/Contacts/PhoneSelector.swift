import Core
import Foundation

/// Chooses which of a contact's numbers a call or message goes to.
public enum PhoneSelector {
    public enum Outcome: Sendable, Equatable {
        case selected(LabeledPhone)
        /// Several numbers qualify. `missingLabel` is set when the user asked for a label the contact
        /// does not have ("work" when there are only mobile and home numbers).
        case ambiguous([LabeledPhone], missingLabel: PhoneLabel?)
        /// The contact has no callable/textable number.
        case noPhone
    }

    /// Numbers that can be used for calls and messages: clean, 3–20 digits, not fax or pager, deduplicated by digits.
    public static func usablePhones(of contact: ContactRecord) -> [LabeledPhone] {
        var seen = Set<String>()
        var result: [LabeledPhone] = []
        for phone in contact.phones {
            let label = phone.label?.lowercased() ?? ""
            if label.contains("fax") || label.contains("pager") { continue }
            guard PhoneNumbers.isClean(phone.number), PhoneNumbers.dialable(phone.number) != nil else { continue }
            let digits = PhoneNumbers.digits(in: phone.number)
            if seen.insert(digits).inserted { result.append(phone) }
        }
        return result
    }

    /// The `PhoneLabel` class of a stored label ("iPhone"/"cell" -> mobile, "office" -> work, custom -> other).
    public static func labelClass(of label: String?) -> PhoneLabel {
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !label.isEmpty else {
            return .other
        }
        switch label {
        case "mobile", "iphone", "cell", "cellular", "cell phone", "cellphone", "mobile phone", "apple watch":
            return .mobile
        case "home", "house", "home phone":
            return .home
        case "work", "office", "business", "work phone":
            return .work
        default:
            return .other
        }
    }

    /// Selection order: pinned choice, the `phone_label` argument, the only number, a unique
    /// mobile/iPhone number, otherwise ambiguous.
    public static func select(
        from contact: ContactRecord,
        requestedLabel: PhoneLabel?,
        pinned: ClarificationCandidate?
    ) -> Outcome {
        let phones = usablePhones(of: contact)
        guard !phones.isEmpty else { return .noPhone }

        if let pinned, pinned.kind == .phoneNumber,
           let match = phones.first(where: { PhoneNumbers.sameNumber($0.number, pinned.identifier) }) {
            return .selected(match)
        }
        if let requestedLabel {
            let matching = phones.filter { labelClass(of: $0.label) == requestedLabel }
            switch matching.count {
            case 1: return .selected(matching[0])
            case 0: return .ambiguous(phones, missingLabel: requestedLabel)
            default: return .ambiguous(matching, missingLabel: nil)
            }
        }
        if phones.count == 1 { return .selected(phones[0]) }
        let mobiles = phones.filter { labelClass(of: $0.label) == .mobile }
        if mobiles.count == 1 { return .selected(mobiles[0]) }
        return .ambiguous(phones, missingLabel: nil)
    }

    /// Clarification candidates for an ambiguous choice. Identifier = the stored number.
    public static func candidates(for phones: [LabeledPhone]) -> [ClarificationCandidate] {
        let options = spokenOptions(for: phones)
        return zip(phones, options).map { phone, option in
            var terms: [String] = []
            if let label = phone.label { terms.append(label) }
            switch labelClass(of: phone.label) {
            case .mobile: terms += ["mobile", "cell", "cellphone"]
            case .home: terms += ["home"]
            case .work: terms += ["work", "office"]
            case .other: terms += ["other"]
            }
            let lastFour = PhoneNumbers.lastFour(phone.number)
            if !lastFour.isEmpty { terms.append(lastFour) }
            terms.append(PhoneNumbers.digits(in: phone.number))
            return ClarificationCandidate(
                kind: .phoneNumber,
                identifier: phone.number,
                displayText: "\(option): \(phone.number)",
                matchTerms: deduplicated(terms)
            )
        }
    }

    /// How each option is spoken: its label when labels are distinct, otherwise
    /// "<label> ending in 1234".
    static func spokenOptions(for phones: [LabeledPhone]) -> [String] {
        let labels = phones.map { $0.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let folded = labels.map { $0.lowercased() }
        let distinct = !folded.contains("") && Set(folded).count == folded.count
        if distinct { return labels }
        return zip(phones, labels).map { phone, label in
            "\(label.isEmpty ? "number" : label) ending in \(PhoneNumbers.lastFour(phone.number))"
        }
    }

    private static func deduplicated(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
