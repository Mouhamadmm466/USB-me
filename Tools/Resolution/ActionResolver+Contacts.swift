import Core
import Foundation
import Telemetry

extension ActionResolver {
    // MARK: search_contacts

    func resolveSearchContacts(_ call: ProposedToolCall, context: ResolutionContext) async -> ResolutionOutcome {
        let tool = ToolID.searchContacts
        if let blocked = await permissionBlock(.contacts, for: tool) { return blocked }
        let maxLength = TextSanitizer.maxLength(of: "name", in: tool, fallback: 80)
        guard case let .valid(name) = TextSanitizer.singleLine(call.string("name"), maxLength: maxLength) else {
            return clarify(.missingField, ClarificationText.whoToLookUp, missingArgument: "name", call: call, context: context)
        }
        if ContactResolver.isPronoun(name) {
            guard let last = context.session.lastContact else {
                return clarify(.contactNotFound, ClarificationText.whoDoYouMean, missingArgument: "name", call: call, context: context)
            }
            return .resolved(.searchContacts(query: last.displayName))
        }
        return .resolved(.searchContacts(query: name))
    }

    // MARK: initiate_call / compose_message

    func resolveCommunication(
        _ call: ProposedToolCall,
        context: ResolutionContext,
        purpose: ClarificationText.Purpose
    ) async -> ResolutionOutcome {
        let tool = call.tool
        let contactQuery = Self.nonEmpty(call.string("contact_query"))
        let pinnedContact = context.pinnedSelections["contact_query"]
        let namesSomeone = contactQuery != nil || pinnedContact != nil

        // 1. A dictated number must appear in the user's own words.
        var dictated: DictatedPhoneNumber?
        if let proposedNumber = Self.nonEmpty(call.string("phone_number")) {
            switch DictatedNumberVerifier.verify(proposedNumber, transcript: context.transcript) {
            case let .verified(number):
                dictated = number
            case .invalid:
                environment.logger.log(.safety(check: "dictated_number", outcome: "invalid"))
                if !namesSomeone {
                    return clarify(.missingField, ClarificationText.numberNotHeard(purpose), missingArgument: "phone_number", call: call, context: context)
                }
            case .notInTranscript:
                environment.logger.log(.safety(check: "dictated_number", outcome: "not_in_transcript"))
                if !namesSomeone {
                    return clarify(.phoneNumberNotInTranscript, ClarificationText.numberNotHeard(purpose), missingArgument: "phone_number", call: call, context: context)
                }
                // Someone was named: ignore the unverified number and use their contact card.
            }
        }

        // 2. Recipient.
        let target: ContactTarget
        if let dictated {
            target = await dictatedTarget(dictated, tool: tool, contactQuery: contactQuery, pinned: pinnedContact, context: context, purpose: purpose)
        } else {
            guard namesSomeone else {
                return clarify(.missingField, ClarificationText.whoTo(purpose), missingArgument: "contact_query", call: call, context: context)
            }
            if let blocked = await permissionBlock(.contacts, for: tool) { return blocked }
            let started = ContinuousClock.now
            let resolution = await ContactResolver(store: environment.contacts).resolve(
                query: contactQuery,
                pinned: pinnedContact,
                session: context.session,
                purpose: purpose
            )
            logLatency(.contactResolution, since: started)
            switch resolution {
            case let .failure(code):
                return failed(tool, code)
            case let .clarification(reason, question, candidates):
                return clarify(reason, question, candidates: candidates, missingArgument: "contact_query", call: call, context: context)
            case let .contact(contact):
                switch phoneTarget(for: contact, call: call, context: context, purpose: purpose) {
                case let .target(resolvedTarget): target = resolvedTarget
                case let .stop(outcome): return outcome
                }
            }
        }

        // 3. Message body.
        guard purpose == .message else { return .resolved(.initiateCall(target)) }
        let maxLength = TextSanitizer.maxLength(of: "message", in: tool, fallback: 500)
        switch TextSanitizer.multiLine(call.string("message"), maxLength: maxLength) {
        case let .valid(body):
            return .resolved(.composeMessage(target, body: body))
        case .empty:
            return clarify(.missingField, ClarificationText.whatShouldMessageSay, missingArgument: "message", call: call, context: context)
        case .tooLong:
            return clarify(.missingField, ClarificationText.messageTooLong, missingArgument: "message", call: call, context: context)
        }
    }

    private enum PhoneTarget {
        case target(ContactTarget)
        /// A clarification to return instead.
        case stop(ResolutionOutcome)
    }

    private func phoneTarget(
        for contact: ContactRecord,
        call: ProposedToolCall,
        context: ResolutionContext,
        purpose: ClarificationText.Purpose
    ) -> PhoneTarget {
        let requestedLabel = Self.nonEmpty(call.string("phone_label")).map { raw in
            PhoneLabel(rawValue: raw.lowercased()) ?? PhoneSelector.labelClass(of: raw)
        }
        switch PhoneSelector.select(from: contact, requestedLabel: requestedLabel, pinned: context.pinnedSelections["phone"]) {
        case let .selected(phone):
            return .target(ContactTarget(
                contactIdentifier: contact.identifier,
                displayName: contact.displayName,
                phoneNumber: phone.number,
                phoneLabel: phone.label
            ))
        case .noPhone:
            return .stop(clarify(
                .contactHasNoPhone,
                ClarificationText.contactHasNoPhone(contact.displayName, purpose: purpose),
                missingArgument: "phone_number",
                call: call,
                context: context
            ))
        case let .ambiguous(phones, missingLabel):
            let options = PhoneSelector.spokenOptions(for: phones)
            let question = missingLabel.map { ClarificationText.missingLabel($0, for: contact.displayName, options: options) }
                ?? ClarificationText.whichNumber(for: contact.displayName, options: options)
            // The answer is pinned as "phone"; re-resolving the same call finds the same contact.
            return .stop(clarify(
                .phoneNumberAmbiguous,
                question,
                candidates: PhoneSelector.candidates(for: phones),
                missingArgument: "phone",
                call: call,
                context: context
            ))
        }
    }

    /// A verified dictated number; the contact's identity is attached only when a named contact
    /// resolves unambiguously and has exactly this number.
    private func dictatedTarget(
        _ number: DictatedPhoneNumber,
        tool: ToolID,
        contactQuery: String?,
        pinned: ClarificationCandidate?,
        context: ResolutionContext,
        purpose: ClarificationText.Purpose
    ) async -> ContactTarget {
        let anonymous = ContactTarget(contactIdentifier: nil, displayName: number.displayText, phoneNumber: number.dialable, phoneLabel: nil)
        guard contactQuery != nil || pinned != nil,
              await PermissionGate.check(.contacts, for: tool, environment: environment) == .proceed else {
            return anonymous
        }
        let resolution = await ContactResolver(store: environment.contacts).resolve(
            query: contactQuery,
            pinned: pinned,
            session: context.session,
            purpose: purpose
        )
        guard case let .contact(contact) = resolution,
              let phone = contact.phones.first(where: { PhoneNumbers.sameNumber($0.number, number.digits) }),
              PhoneNumbers.isClean(phone.number) else {
            return anonymous
        }
        return ContactTarget(contactIdentifier: contact.identifier, displayName: contact.displayName, phoneNumber: phone.number, phoneLabel: phone.label)
    }

    func logLatency(_ stage: LatencyStage, since start: ContinuousClock.Instant) {
        environment.logger.log(.stageLatency(stage: stage, milliseconds: (ContinuousClock.now - start).wholeMilliseconds))
    }
}
