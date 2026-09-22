import XCTest
@testable import RestwattCore

/// A login item as macOS reports it: the status is what the double says, a register or
/// unregister either moves it or throws the way `SMAppService` does.
final class FakeLoginItem: LoginItemControlling {
    var status: LoginItemStatus
    /// Status after a successful register; macOS may answer requiresApproval instead of enabled.
    var statusAfterRegister: LoginItemStatus = .enabled
    var registerError: Error?
    var unregisterError: Error?
    var calls: [LoginItemAction] = []

    init(_ status: LoginItemStatus) {
        self.status = status
    }

    func register() throws {
        calls.append(.register)
        if let registerError {
            throw registerError
        }
        status = statusAfterRegister
    }

    func unregister() throws {
        calls.append(.unregister)
        if let unregisterError {
            throw unregisterError
        }
        status = .notRegistered
    }

    func openLoginItemsSettings() {
        calls.append(.openLoginItemsSettings)
    }
}

final class LoginItemTests: XCTestCase {
    private func labels(_ rows: [SettingsRow]) -> [String] {
        rows.map { row in
            switch row.kind {
            case .openAtLogin(let isOn): return (isOn ? "[x] " : "[ ] ") + row.label
            case .note: return "    " + row.label
            case .warning: return "  ! " + row.label
            case .heading, .toggle: return "unexpected " + row.label
            }
        }
    }

    private func menuAfterRefresh(_ status: LoginItemStatus) -> (LoginItemCoordinator, FakeLoginItem) {
        let fake = FakeLoginItem(status)
        let coordinator = LoginItemCoordinator(loginItem: fake)
        coordinator.refresh()
        return (coordinator, fake)
    }

    // MARK: Status to row, all four statuses

    func testEnabledIsChecked() {
        XCTAssertEqual(labels(menuAfterRefresh(.enabled).0.rows), ["[x] Open at Login"])
    }

    func testNotRegisteredIsUnchecked() {
        XCTAssertEqual(labels(menuAfterRefresh(.notRegistered).0.rows), ["[ ] Open at Login"])
    }

    func testNotFoundIsUnchecked() {
        XCTAssertEqual(labels(menuAfterRefresh(.notFound).0.rows), ["[ ] Open at Login"])
    }

    func testRequiresApprovalIsUncheckedWithANote() {
        XCTAssertEqual(labels(menuAfterRefresh(.requiresApproval).0.rows), [
            "[ ] Open at Login",
            "    needs approval in System Settings, Login Items",
        ])
    }

    /// Default OFF: before anything was read nothing is checked, and reading changes nothing.
    func testNothingIsCheckedOrCalledBeforeAClick() {
        let fake = FakeLoginItem(.notRegistered)
        let coordinator = LoginItemCoordinator(loginItem: fake)
        XCTAssertFalse(coordinator.status.isOn)
        coordinator.refresh()
        coordinator.refresh()
        XCTAssertEqual(fake.calls, [])
    }

    /// The checkmark follows the system, not what the last click did: a change in System
    /// Settings shows at the next menu open.
    func testRefreshReadsTheSystemEveryTime() {
        let (coordinator, fake) = menuAfterRefresh(.enabled)
        fake.status = .notRegistered
        coordinator.refresh()
        XCTAssertEqual(labels(coordinator.rows), ["[ ] Open at Login"])
    }

    // MARK: Click to action, all four statuses

    func testClickActionPerStatus() {
        XCTAssertEqual(LoginItemStatus.notRegistered.clickAction, .register)
        XCTAssertEqual(LoginItemStatus.notFound.clickAction, .register)
        XCTAssertEqual(LoginItemStatus.enabled.clickAction, .unregister)
        XCTAssertEqual(LoginItemStatus.requiresApproval.clickAction, .openLoginItemsSettings)
    }

    func testClickFromNotRegisteredRegisters() {
        let (coordinator, fake) = menuAfterRefresh(.notRegistered)
        coordinator.click()
        XCTAssertEqual(fake.calls, [.register])
        XCTAssertEqual(labels(coordinator.rows), ["[x] Open at Login"])
    }

    func testClickFromNotFoundRegisters() {
        let (coordinator, fake) = menuAfterRefresh(.notFound)
        coordinator.click()
        XCTAssertEqual(fake.calls, [.register])
        XCTAssertEqual(coordinator.status, .enabled)
    }

    func testClickFromEnabledUnregisters() {
        let (coordinator, fake) = menuAfterRefresh(.enabled)
        coordinator.click()
        XCTAssertEqual(fake.calls, [.unregister])
        XCTAssertEqual(labels(coordinator.rows), ["[ ] Open at Login"])
    }

    func testClickWhileApprovalIsNeededOpensSystemSettingsAndDoesNotRegisterAgain() {
        let (coordinator, fake) = menuAfterRefresh(.requiresApproval)
        coordinator.click()
        XCTAssertEqual(fake.calls, [.openLoginItemsSettings])
        XCTAssertEqual(coordinator.status, .requiresApproval)
    }

    /// A register that macOS answers with requiresApproval shows unchecked with the note.
    func testRegisterThatNeedsApprovalShowsTheNote() {
        let (coordinator, fake) = menuAfterRefresh(.notRegistered)
        fake.statusAfterRegister = .requiresApproval
        coordinator.click()
        XCTAssertEqual(labels(coordinator.rows), [
            "[ ] Open at Login",
            "    needs approval in System Settings, Login Items",
        ])
    }

    // MARK: Errors, fail-closed

    func testRegisterErrorShowsAWarningAndKeepsTheObservedStatus() {
        let (coordinator, fake) = menuAfterRefresh(.notRegistered)
        fake.registerError = SettingsFailure("Operation not permitted")
        coordinator.click()
        XCTAssertEqual(fake.calls, [.register])
        XCTAssertEqual(labels(coordinator.rows), [
            "[ ] Open at Login",
            "  ! could not change: Operation not permitted",
        ])
    }

    func testUnregisterErrorShowsAWarningAndKeepsTheObservedStatus() {
        let (coordinator, fake) = menuAfterRefresh(.enabled)
        fake.unregisterError = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        coordinator.click()
        XCTAssertEqual(fake.calls, [.unregister])
        let rows = labels(coordinator.rows)
        XCTAssertEqual(rows.first, "[x] Open at Login", "the checkmark stays on what the system reports")
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[1].hasPrefix("  ! could not change: "), rows[1])
        XCTAssertTrue(rows[1].contains("SMAppServiceErrorDomain"), rows[1])
    }

    /// After a failed click the checkmark shows what the system reports now, not the status
    /// from before the click: an unregister that throws but did take effect shows unchecked.
    func testAFailedClickReReadsTheSystem() {
        let (coordinator, fake) = menuAfterRefresh(.enabled)
        fake.unregisterError = SettingsFailure("timed out")
        fake.status = .notRegistered
        coordinator.click()
        XCTAssertEqual(fake.calls, [.unregister])
        XCTAssertEqual(labels(coordinator.rows), [
            "[ ] Open at Login",
            "  ! could not change: timed out",
        ])
    }

    func testTheWarningStaysUntilAClickSucceeds() {
        let (coordinator, fake) = menuAfterRefresh(.notRegistered)
        fake.registerError = SettingsFailure("refused")
        coordinator.click()
        coordinator.refresh()
        XCTAssertEqual(labels(coordinator.rows).last, "  ! could not change: refused")

        fake.registerError = nil
        coordinator.click()
        XCTAssertEqual(labels(coordinator.rows), ["[x] Open at Login"])
    }

    func testWarningDisappearsOnceTheStatusMovedOn() {
        final class Flaky: LoginItemControlling {
            var status: LoginItemStatus = .notRegistered
            func register() throws { throw SettingsFailure("Operation not permitted") }
            func unregister() throws {}
            func openLoginItemsSettings() {}
        }
        let item = Flaky()
        let coordinator = LoginItemCoordinator(loginItem: item)
        coordinator.refresh()
        coordinator.click()
        XCTAssertEqual(coordinator.lastError, "Operation not permitted")
        coordinator.refresh()
        XCTAssertEqual(coordinator.lastError, "Operation not permitted", "same state, the warning stays")
        item.status = .enabled  // the user enabled Restwatt in System Settings
        coordinator.refresh()
        XCTAssertNil(coordinator.lastError, "the state moved on, the old warning no longer describes it")
        XCTAssertEqual(coordinator.status, .enabled)
    }
}
