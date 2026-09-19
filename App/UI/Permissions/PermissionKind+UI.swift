import Core
import SwiftUI

extension PermissionKind {
    /// The name iOS uses for this permission.
    var displayName: String {
        switch self {
        case .microphone: "Microphone"
        case .contacts: "Contacts"
        case .calendar: "Calendars"
        case .reminders: "Reminders"
        case .fileScope: "Shared folders"
        }
    }

    /// What the assistant uses it for, in a few words.
    var purpose: String {
        switch self {
        case .microphone: "Hears your requests"
        case .contacts: "Finds people to call or text"
        case .calendar: "Reads and adds events"
        case .reminders: "Creates reminders"
        case .fileScope: "Searches folders you choose"
        }
    }

    var systemImage: String {
        switch self {
        case .microphone: "mic.fill"
        case .contacts: "person.crop.circle.fill"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .fileScope: "folder.fill"
        }
    }
}

extension PermissionStatus {
    var displayName: String {
        switch self {
        case .granted: "Allowed"
        case .limited: "Limited"
        case .denied: "Not allowed"
        case .restricted: "Restricted"
        case .notDetermined: "Not asked yet"
        }
    }

    var tone: Tone {
        switch self {
        case .granted: .jade
        case .limited: .amber
        case .denied, .restricted: .danger
        case .notDetermined: .neutral
        }
    }
}
