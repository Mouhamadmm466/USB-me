import Core
import Testing
@testable import Permissions

@Suite struct PermissionManagerTests {
    @Test func requestsOnlyWhenNotDetermined() async {
        let backend = FakePermissionBackend(statuses: [.contacts: .granted], responses: [:])
        let manager = PermissionManager(backend: backend)
        #expect(await manager.request(.contacts) == .granted)
        #expect(await backend.requestCounts[.contacts] == nil)
    }

    @Test func deniedIsReportedWithoutPrompting() async {
        let backend = FakePermissionBackend(statuses: [.calendar: .denied])
        let manager = PermissionManager(backend: backend)
        #expect(await manager.request(.calendar) == .denied)
        #expect(await backend.requestCounts[.calendar] == nil)
    }

    @Test func promptsOnceThenReturnsResult() async {
        let backend = FakePermissionBackend(statuses: [:], responses: [.microphone: .granted])
        let manager = PermissionManager(backend: backend)
        #expect(await manager.request(.microphone) == .granted)
        #expect(await manager.request(.microphone) == .granted)
        #expect(await backend.requestCounts[.microphone] == 1)
    }

    @Test func neverLoopsEvenIfTheSystemKeepsReportingNotDetermined() async {
        let backend = LoopingBackend()
        let manager = PermissionManager(backend: backend)
        _ = await manager.request(.contacts)
        #expect(await manager.request(.contacts) == .denied)
        #expect(await backend.requests == 1)
    }

    @Test func usability() {
        #expect(PermissionManager.isUsable(.granted, for: .calendar))
        #expect(PermissionManager.isUsable(.limited, for: .contacts))
        #expect(PermissionManager.isUsable(.limited, for: .calendar)) // write-only: creating events still works
        #expect(!PermissionManager.isUsable(.limited, for: .reminders))
        #expect(!PermissionManager.isUsable(.denied, for: .contacts))
        #expect(!PermissionManager.isUsable(.restricted, for: .microphone))
    }

    @Test func snapshotCoversEveryKind() async {
        let manager = PermissionManager(backend: FakePermissionBackend.allGranted())
        let snapshot = await manager.snapshot()
        for kind in PermissionKind.allCases {
            #expect(snapshot.status(kind) == .granted)
        }
    }
}

/// Simulates an OS that never records the user's answer.
actor LoopingBackend: PermissionBackend {
    private(set) var requests = 0

    func currentStatus(_ kind: PermissionKind) async -> PermissionStatus { .notDetermined }

    func requestAccess(_ kind: PermissionKind) async -> PermissionStatus {
        requests += 1
        return .notDetermined
    }
}
